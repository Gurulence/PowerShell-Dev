<#
.SYNOPSIS
    Arena-built agent loop for PowerShell + .NET work. Full-control, always-approve.
.DESCRIPTION
    A self-contained, dependency-free agent. It speaks the OpenAI Chat Completions
    protocol, so it works with OpenAI, Azure OpenAI, Groq, OpenRouter, Ollama, LM Studio
    and anything else exposing /v1/chat/completions.

    Every single action the model requests (tool call) is shown to you with a diff or a
    command preview and blocked until you press Y. Nothing runs "on its own".
.PARAMETER Task
    The task text. If omitted, you are prompted.
.PARAMETER Mode
    planner | hybrid | executor  (see prompts/modes)
.PARAMETER ConfigPath
    Path to agent.config.json. Defaults to <repo>/config/agent.config.json
.PARAMETER DryRun
    Show the tool call and approval prompt but never execute. Great for auditing.
.PARAMETER Resume
    Session id to resume (e.g. 2026-11-10T09-31-02).
.EXAMPLE
    ./Agent.ps1 "Add a Pester test for ConvertTo-SqlIdentifier and make it pass"
.EXAMPLE
    $env:OPENAI_API_KEY='sk-...'; ./Agent.ps1 -Mode planner "Design a module for CSV dedup"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Task,

    [ValidateSet('planner', 'hybrid', 'executor')]
    [string]$Mode,

    [string]$ConfigPath,
    [string]$SessionId,
    [switch]$DryRun,
    [switch]$NoColor
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'config/agent.config.json' }
if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }

# ---------------------------------------------------------------- libraries ----
. (Join-Path $PSScriptRoot 'AgentConfig.ps1')
. (Join-Path $PSScriptRoot 'AgentLlm.ps1')
. (Join-Path $PSScriptRoot 'AgentTools.ps1')
. (Join-Path $PSScriptRoot 'AgentApproval.ps1')

$Cfg = Read-AgentConfig -Path $ConfigPath
if ($Mode) { $Cfg.agent.mode = $Mode }

$script:Workspace = $RepoRoot
$script:Tools = New-AgentToolRegistry
$script:DryRun = [bool]$DryRun
$script:CommandTimeout = [int]$Cfg.agent.commandTimeoutSec
$script:MaxToolOutput = [int]$Cfg.agent.maxToolOutputChars

# ---------------------------------------------------------------- UI helpers ---
$script:UseColor = -not $NoColor
function Write-UI {
    param([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline)
    if ($script:UseColor) { Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline }
    else { Write-Host $Text -NoNewline:$NoNewline }
}
function Write-Banner {
    $w = 74
    $line = '=' * $w
    Write-UI $line 'DarkCyan'
    Write-UI ("  PS/.NET AGENT  mode={0}  model={1}" -f $Cfg.agent.mode, $Cfg.provider.model) 'Cyan'
    Write-UI ("  workspace: {0}" -f $script:Workspace) 'DarkGray'
    Write-UI ("  approval : {0}  {1}" -f $Cfg.agent.approvalGate, ($(if ($script:DryRun) { '(DRY RUN - nothing executes)' } else { '' }))) 'DarkGray'
    Write-UI $line 'DarkCyan'
}

# ------------------------------------------------------------------ session ----
function New-SessionState {
    param([string]$Task)
    $id = if ($SessionId) { $SessionId } else { (Get-Date).ToString('yyyy-MM-ddTHH-mm-ss') }
    $dir = Join-Path $script:Workspace $Cfg.agent.sessionDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [pscustomobject]@{
        id        = $id
        path      = Join-Path $dir "$id.json"
        startedAt = (Get-Date).ToString('o')
        task      = $Task
        mode      = $Cfg.agent.mode
        messages  = @()
        approvals = @()
        toolCalls = 0
        tokens    = @{ prompt = 0; completion = 0 }
    }
}
function Save-Session { param($Session)
    $Session | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $Session.path -Encoding utf8
}

# ------------------------------------------------------------------- prompt ----
function Get-SystemPrompt {
    param([string]$Mode)

    $modeFile = Join-Path $script:Workspace "prompts/modes/$Mode.md"
    if (-not (Test-Path $modeFile)) { $modeFile = Join-Path $PSScriptRoot "../prompts/modes/$Mode.md" }
    $modeText = if (Test-Path $modeFile) { Get-Content -Raw -LiteralPath $modeFile } else { '' }

    $core = @'
You are a senior PowerShell and .NET engineer operating inside a gated, auditable agent loop.

## Non-negotiable behaviour
1. You may only affect the world through the provided tools. Never claim you ran something you did not run.
2. Every tool call is reviewed by a human who can approve or reject it. Design each call to be small,
   obvious and independently justifiable. Never bundle unrelated edits into one call.
3. Read before you write. Never edit a file you have not read in this session.
4. Verify with evidence: after writing code, run the build/tests/analysis tools and paste real output.
   If you could not verify something, say so explicitly in your final message.
5. Never guess an API. If unsure whether a cmdlet, type, parameter or overload exists, inspect it
   (Get-Command / Get-Help / dotnet build error / reflection via a script) instead of inventing it.
6. No secrets in code, logs, or commands. Use environment variables and mention them by name only.

## PowerShell rules
- Target Windows PowerShell 5.1 AND PowerShell 7+ unless the user says otherwise. Write code that
  parses on 5.1: no `??`, `?.`, `-Parallel`, ternary `? :`, `&&`/`||` chaining, or 7-only operators.
- Use [CmdletBinding()] with SupportsShouldProcess for anything destructive; implement
  Process/End blocks; accept pipeline input where it is natural.
- PSCustomObject over hashtable for output objects; always emit typed, documented output.
- Parameter validation attributes over manual `if (!$x) { throw }` checks.
- No `Write-Host` in library code (use Write-Verbose/Write-Information); `Write-Host` is only for
  interactive UX in end-user scripts.
- Prefer native providers (Test-Path, Get-ChildItem) over spawning external processes.
- Handle errors with -ErrorAction/-ErrorVariable and terminating errors; set $ErrorActionPreference
  deliberately, and restore it in finally.
- Every public function gets comment-based help with .SYNOPSIS .DESCRIPTION .PARAMETER .EXAMPLE .OUTPUTS.

## .NET rules
- Nullable reference types on for new libraries; keep existing projects' settings unchanged.
- async methods end in Async and take a CancellationToken by default.
- No .Result / .Wait() - propagate async, or document why blocking is required.
- IDisposable/IAsyncDisposable implemented correctly; await using for IAsyncDisposable.
- Public API gets XML doc comments; enable GenerateDocumentationFile and keep the build warning-clean.
- Prefer records and init-only setters for immutable DTOs; avoid public fields.
- Keep the build at zero warnings for new projects; do not suppress warnings to make it green.

## Working style
- Work in small verified steps. Announce the step, do it, verify it, move on.
- When you hit an unexpected error, read the actual message and fix the cause, not the symptom.
- If the task is ambiguous, use AskUserQuestion instead of guessing.
- Keep your prose in the transcript short. The value is in the tool calls and their output.
'@

    return @"
$core

# Current operating mode: $Mode

$modeText
"@
}

# -------------------------------------------------------------------- tools ----
function Get-ToolSpecs {
    $specs = foreach ($name in $script:Tools.Keys) {
        $t = $script:Tools[$name]
        [ordered]@{ type = 'function'; function = [ordered]@{
                name        = $name
                description = $t.Description
                parameters  = $t.Parameters
            } }
    }
    return @($specs)
}

# ------------------------------------------------------------- tool execute ----
function Invoke-AgentTool {
    param([string]$Name, $ArgumentsJson)

    if (-not $script:Tools.ContainsKey($Name)) {
        return [pscustomobject]@{ ok = $false; output = "ERROR: unknown tool '$Name'." }
    }

    $argsObj = @{}
    if ($ArgumentsJson -and $ArgumentsJson.Trim()) {
        try {
            $parsed = $ArgumentsJson | ConvertFrom-Json -AsHashtable -Depth 12
            if ($parsed) { $argsObj = $parsed }
        }
        catch {
            return [pscustomobject]@{ ok = $false; output = "ERROR: arguments were not valid JSON: $($_.Exception.Message)" }
        }
    }

    $tool = $script:Tools[$Name]
    try {
        $result = & $tool.Script -Args $argsObj
        return $result
    }
    catch {
        return [pscustomobject]@{ ok = $false; output = "ERROR in tool '$Name': $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
    }
}

# ------------------------------------------------------------------- main ------ 
if (-not $Task) {
    Write-Banner
    $Task = Read-Host 'Task'
    if (-not $Task) { throw 'No task given.' }
}

Write-Banner
Write-UI "`nTASK: $Task`n" 'White'

$apiKey = [Environment]::GetEnvironmentVariable($Cfg.provider.apiKeyEnv)
if (-not $apiKey -and -not $script:DryRun) {
    throw "Environment variable $($Cfg.provider.apiKeyEnv) is not set. Set it, or run with -DryRun to inspect the loop without calling the model."
}

$session = New-SessionState -Task $Task

# Resume: replay prior messages so the model keeps context.
$history = @()
if ($SessionId -and (Test-Path $session.path)) {
    $prev = Get-Content -Raw -LiteralPath $session.path | ConvertFrom-Json
    $history = @($prev.messages | Where-Object { $_.role -in @('user', 'assistant', 'tool') })
    Write-UI "Resuming session $SessionId with $($history.Count) prior messages." 'Yellow'
}

$messages = [System.Collections.Generic.List[object]]::new()
$messages.Add(@{ role = 'system'; content = (Get-SystemPrompt -Mode $Cfg.agent.mode) })
foreach ($m in $history) { $messages.Add($m) }
$messages.Add(@{ role = 'user'; content = $Task })

$toolSpecs = Get-ToolSpecs
$script:TodoWritten = $false
$turn = 0

while ($turn -lt [int]$Cfg.agent.maxTurns) {
    $turn++
    Write-UI "`n--- turn $turn ---" 'DarkGray'

    try {
        $response = Invoke-ChatCompletion -Config $Cfg -Messages $messages.ToArray() -Tools $toolSpecs -ApiKey $apiKey -DryRun:$script:DryRun
    }
    catch {
        Write-UI "`nMODEL CALL FAILED: $($_.Exception.Message)" 'Red'
        Write-UI "Session saved to $($session.path)" 'DarkGray'
        $session.messages = $messages.ToArray()
        Save-Session $session
        throw
    }

    if ($response.usage) {
        $session.tokens.prompt += [int]$response.usage.prompt_tokens
        $session.tokens.completion += [int]$response.usage.completion_tokens
    }

    $msg = $response.choices[0].message
    $text = $msg.content
    $toolCalls = @($msg.tool_calls | Where-Object { $_ })

    if ($text) {
        Write-UI "`n$text" 'White'
        $messages.Add(@{ role = 'assistant'; content = $text })
    }

    if ($msg.tool_calls) {
        # Record the assistant turn WITH tool_calls so the protocol stays valid.
        $messages.Add(@{
                role       = 'assistant'
                content    = $(if ($text) { $text } else { $null })
                tool_calls = @($msg.tool_calls)
            })
    }

    if ($toolCalls.Count -eq 0) {
        Write-UI "`n=== agent finished (turn $turn) ===" 'Green'
        break
    }

    foreach ($tc in $toolCalls) {
        $name = $tc.function.name
        $argJson = $tc.function.arguments
        $session.toolCalls++

        Write-UI "`n>> TOOL: $name" 'Cyan'

        $verdict = Request-Approval -ToolName $name -ArgumentsJson $argJson -Registry $script:Tools -Workspace $script:Workspace
        $session.approvals += [pscustomobject]@{ at = (Get-Date).ToString('o'); tool = $name; args = $argJson; decision = $verdict.Decision; note = $verdict.Note }

        switch ($verdict.Decision) {
            'approve' {
                if ($script:DryRun) {
                    $result = [pscustomobject]@{ ok = $true; output = '[DRY RUN] Command not executed. Output withheld.' }
                }
                else {
                    $watch = [System.Diagnostics.Stopwatch]::StartNew()
                    $result = Invoke-AgentTool -Name $name -ArgumentsJson $argJson
                    $watch.Stop()
                    Write-UI ("   done in {0:N2}s  ({1})" -f $watch.Elapsed.TotalSeconds, $(if ($result.ok) { 'ok' } else { 'failed' })) $(if ($result.ok) { 'Green' } else { 'Red' })
                }
            }
            'deny' {
                $result = [pscustomobject]@{ ok = $false; output = "DENIED BY USER. Do not retry this exact call. Ask for guidance or propose an alternative." }
                Write-UI '   denied' 'Yellow'
            }
            'abort' {
                Write-UI "`nAborted by user. Session: $($session.path)" 'Yellow'
                $session.messages = $messages.ToArray()
                Save-Session $session
                return
            }
            'feedback' {
                $result = [pscustomobject]@{ ok = $false; output = "USER FEEDBACK (treat as instruction, then adjust): $($verdict.Note)" }
                Write-UI "   feedback sent: $($verdict.Note)" 'Yellow'
            }
        }

        $out = [string]$result.output
        if ($null -eq $result.output) { $out = '' }
        if ($out.Length -gt $script:MaxToolOutput) {
            $out = $out.Substring(0, $script:MaxToolOutput) + "`n...[truncated: original $($result.output.Length) chars]"
        }

        $messages.Add(@{
                role         = 'tool'
                tool_call_id = $tc.id
                content      = $out
            })
    }

    $session.messages = $messages.ToArray()
    Save-Session $session
}

if ($turn -ge [int]$Cfg.agent.maxTurns) {
    Write-UI "`nReached maxTurns ($($Cfg.agent.maxTurns)). Stopping." 'Yellow'
}

$session.messages = $messages.ToArray()
Save-Session $session
Write-UI ("`nSession: {0}" -f $session.path) 'DarkGray'
Write-UI ("Tool calls: {0}   Approvals: {1}   Tokens: {2} prompt / {3} completion" -f `
        $session.toolCalls, $session.approvals.Count, $session.tokens.prompt, $session.tokens.completion) 'DarkGray'
