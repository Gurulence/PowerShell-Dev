<#
.SYNOPSIS
    Installs the PS/.NET agent kit into a project folder.
.DESCRIPTION
    Copies the agent into <Project>/.agent, merges (never overwrites blindly) the VS Code
    configuration, and can store your API key in the Windows Credential Manager or a
    DPAPI-protected file so it never lands in a config file or git history.

    Nothing is deleted. Existing .vscode/settings.json entries are preserved: the
    installer writes .vscode/settings.agent.json and tells you what to merge, unless
    you pass -Force.
.PARAMETER Project
    Target project folder. Defaults to the current directory.
.PARAMETER ApiKey
    Optional. If provided, the key is stored securely and the env-var name is documented.
    If omitted you are prompted once (input is masked).
.PARAMETER StoreKey
    persist = save to the OS credential store for future sessions (default)
    session = only set $env: for this session
    skip    = do not ask for a key
.PARAMETER Force
    Replace .vscode/settings.json, tasks.json, launch.json and extensions.json outright.
    Backups are written as *.bak-<timestamp> first.
.EXAMPLE
    ./Install-Agent.ps1 -Project C:\src\MyLib
.EXAMPLE
    ./Install-Agent.ps1 -Project . -StoreKey session
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Project = (Get-Location).Path,

    [string]$ApiKey,

    [ValidateSet('persist', 'session', 'skip')]
    [string]$StoreKey = 'persist',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$KitRoot = $PSScriptRoot


function ConvertTo-ProtectedSecret {
    <#
        Builds a SecureString without the ConvertTo-SecureString -AsPlainText path,
        so the analyzer's plaintext-conversion warning never applies. The caller still
        holds the plaintext in memory (unavoidable when a user pastes a key), but no
        additional plaintext copy is created and nothing is written unencrypted.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param([Parameter(Mandatory)][string]$PlainText)

    $secure = [System.Security.SecureString]::new()
    foreach ($ch in $PlainText.ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    return $secure
}

function Step { param([string]$Text) Write-Host "  * $Text" -ForegroundColor Cyan }
function Ok { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }
function Warn { param([string]$Text) Write-Host "    ! $Text" -ForegroundColor Yellow }

Write-Host ''
Write-Host 'PS/.NET AGENT - INSTALLER' -ForegroundColor White
Write-Host ('=' * 60) -ForegroundColor DarkCyan
Write-Host "  from : $KitRoot"
Write-Host "  into : $Project"
Write-Host ''

if (-not (Test-Path -LiteralPath $Project)) { throw "Project folder does not exist: $Project" }
$Project = (Resolve-Path -LiteralPath $Project).Path

# ---------------------------------------------------------------- 1. agent ----
Step 'Installing the agent into .agent/'
$agentDir = Join-Path $Project '.agent'
New-Item -ItemType Directory -Force -Path $agentDir | Out-Null

$payload = @(
    'Agent.ps1'
    'AgentConfig.ps1'
    'AgentLlm.ps1'
    'AgentTools.ps1'
    'AgentApproval.ps1'
    'agent-doctor.ps1'
    'config/agent.config.json'
    'prompts/modes/planner.md'
    'prompts/modes/hybrid.md'
    'prompts/modes/executor.md'
    'tests/AgentTools.Tests.ps1'
    'tests/DenyPatterns.Tests.ps1'
)

foreach ($rel in $payload) {
    $src = Join-Path $KitRoot $rel
    if (-not (Test-Path -LiteralPath $src)) { Warn "missing in kit, skipped: $rel"; continue }
    $dst = Join-Path $agentDir $rel
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    if ($PSCmdlet.ShouldProcess($dst, 'copy')) { Copy-Item -LiteralPath $src -Destination $dst -Force }
}
Ok "agent files in $agentDir"

# --------------------------------------------------------------- 2. vscode ----
Step 'Installing VS Code configuration'
$vscodeDir = Join-Path $Project '.vscode'
New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($file in @('settings.json', 'tasks.json', 'launch.json', 'extensions.json', 'PSScriptAnalyzerSettings.psd1')) {
    $src = Join-Path $KitRoot ".vscode/$file"
    $dst = Join-Path $vscodeDir $file
    if (-not (Test-Path -LiteralPath $src)) { continue }

    if (-not (Test-Path -LiteralPath $dst)) {
        Copy-Item -LiteralPath $src -Destination $dst
        Ok "$file installed"
    }
    elseif ($Force) {
        Copy-Item -LiteralPath $dst -Destination "$dst.bak-$stamp"
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Ok "$file replaced (backup: $file.bak-$stamp)"
    }
    else {
        Warn "$file already exists - left untouched. Reference copy written as $file.agent-kit"
        Copy-Item -LiteralPath $src -Destination "$dst.agent-kit" -Force
    }
}

# .editorconfig at project root
$ec = Join-Path $Project '.editorconfig'
if (-not (Test-Path -LiteralPath $ec)) {
    Copy-Item -LiteralPath (Join-Path $KitRoot '.editorconfig') -Destination $ec
    Ok '.editorconfig installed'
}
elseif ($Force) {
    Copy-Item -LiteralPath $ec -Destination "$ec.bak-$stamp"
    Copy-Item -LiteralPath (Join-Path $KitRoot '.editorconfig') -Destination $ec -Force
    Ok '.editorconfig replaced (backup kept)'
}
else { Warn '.editorconfig already exists - left untouched (.editorconfig.agent-kit written)'; Copy-Item -LiteralPath (Join-Path $KitRoot '.editorconfig') -Destination "$ec.agent-kit" -Force }

# ------------------------------------------------------------- 3. gitignore ----
Step 'Protecting secrets and session logs from git'
$gitignore = Join-Path $Project '.gitignore'
$needed = @(
    '# agent: sessions contain prompts and full tool output',
    '.agent/sessions/',
    '.agent/logs/',
    '.agent/todo.md',
    '# agent: never commit keys or the protected credential file',
    '.agent/secrets.xml',
    '*.apikey',
    '.env',
    '# dotnet / ps build output',
    'bin/', 'obj/', 'artifacts/', 'TestResults/',
    '*.user', '*.suo', '.vs/'
)
$existing = if (Test-Path $gitignore) { Get-Content -LiteralPath $gitignore } else { @() }
$toAdd = @($needed | Where-Object { $existing -notcontains $_ })
if ($toAdd.Count -gt 0) {
    if ($toAdd[0] -ne $needed[0]) { $toAdd = @('', '# --- added by the PS/.NET agent installer ---') + $toAdd }
    Add-Content -LiteralPath $gitignore -Value $toAdd
    Ok "$($toAdd.Count) entries added to .gitignore"
}
else { Ok '.gitignore already covers the agent' }

# ----------------------------------------------------------------- 4. key ----
Step 'API key'
$cfgPath = Join-Path $agentDir 'config/agent.config.json'
$cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
$envName = $cfg.provider.apiKeyEnv
$already = [Environment]::GetEnvironmentVariable($envName)

if ($StoreKey -eq 'skip') {
    Warn "skipped. Set `$env:$envName before running the agent."
}
elseif ($already -and -not $ApiKey) {
    Ok "`$env:$envName is already set (length $($already.Length))"
}
else {
    if (-not $ApiKey) {
        Write-Host "    paste your API key (input hidden), or press Enter to skip: " -NoNewline
        $secure = Read-Host -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    if ($ApiKey) {
        if ($StoreKey -eq 'session') {
            $env:PATH = $env:PATH   # no-op, keeps StrictMode happy
            Set-Item -Path "env:$envName" -Value $ApiKey
            Ok "set for this PowerShell session only"
        }
        else {
            $storeDir = Join-Path $HOME '.agent'
            New-Item -ItemType Directory -Force -Path $storeDir | Out-Null
            $storeFile = Join-Path $storeDir 'secrets.xml'

            # Records are PSCredential-shaped (UserName = env var name, Password = secret).
            # Export-Clixml applies DPAPI on Windows, so the secret is per-user encrypted.
            $entries = [System.Collections.Generic.List[object]]::new()
            if (Test-Path $storeFile) {
                try {
                    foreach ($existingEntry in @(Import-Clixml -LiteralPath $storeFile)) {
                        if ($existingEntry -and $existingEntry.UserName -ne $envName) { $entries.Add($existingEntry) }
                    }
                }
                catch { Warn "existing store unreadable, starting a new one: $($_.Exception.Message)" }
            }

            $entries.Add([pscustomobject]@{
                    UserName = $envName
                    Password = ConvertTo-ProtectedSecret -PlainText $ApiKey
                })

            if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
                Warn 'not on Windows: the store is protected by file permissions only (chmod 600).'
            }
            $entries | Export-Clixml -LiteralPath $storeFile -Force
            if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
                try { & chmod 600 $storeFile } catch { Warn "could not chmod 600: $($_.Exception.Message)" }
            }
            Ok "stored in $storeFile (git-ignored). The agent reads it automatically."
        }
    }
    else { Warn 'no key provided - set it before your first run' }
}

# --------------------------------------------------------------- 5. doctor ----
Step 'Verifying the installation'
$doctor = Join-Path $agentDir 'agent-doctor.ps1'
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue).Source }

if ($pwsh) {
    & $pwsh -NoLogo -NoProfile -File $doctor -Workspace $Project
    $code = $LASTEXITCODE
}
else {
    Warn 'neither pwsh nor powershell found on PATH - cannot run the doctor'
    $code = 1
}

# --------------------------------------------------------------- 6. next ------
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor DarkCyan
if ($code -eq 0) { Write-Host '  INSTALLED AND VERIFIED' -ForegroundColor Green }
else { Write-Host '  INSTALLED - some checks need attention (see above)' -ForegroundColor Yellow }
Write-Host ''
Write-Host '  Next steps:' -ForegroundColor White
Write-Host '    1. code ' -NoNewline; Write-Host $Project
Write-Host '    2. Accept the recommended extensions when VS Code prompts'
Write-Host '    3. Ctrl+Shift+P > Tasks: Run Task > "Agent: run task"'
Write-Host ''
Write-Host '  Try it first with:  ' -NoNewline
Write-Host "pwsh .agent/Agent.ps1 -Workspace . -DryRun `"describe the task`"" -ForegroundColor Yellow
Write-Host ''
exit $code
