<#
    AgentApproval.ps1  -  the human-in-the-loop gate.

    Nothing the model asks for reaches the OS without passing through here.
    Decisions: approve (y), deny (n), feedback (f<text>), abort (q), always (a - session allow).
#>

$script:SessionAllowList = @()   # tool names the human approved with 'a'

function Get-CallSummary {
    <#
        Produce the human-facing description of a tool call:
        a command preview, a file diff, or a short argument dump.
    #>
    param([string]$ToolName, $Args)

    $sb = [System.Text.StringBuilder]::new()

    switch ($ToolName) {
        'RunCommand' {
            $shell = [string](Get-Arg $Args 'shell' 'pwsh')
            $wd = [string](Get-Arg $Args 'working_dir' '')
            [void]$sb.AppendLine(('  shell : {0}' -f $shell))
            if ($wd) { [void]$sb.AppendLine(('  cwd   : {0}' -f $wd)) }
            if (Get-Arg $Args 'purpose') { [void]$sb.AppendLine(('  why   : {0}' -f (Get-Arg $Args 'purpose'))) }
            [void]$sb.AppendLine('  ---- command ----')
            foreach ($line in ([string](Get-Arg $Args 'command')).Split("`n")) { [void]$sb.AppendLine('  | ' + $line) }
        }
        { $_ -in @('RunBuild', 'RunTests', 'DotnetNew', 'AddPackage', 'RunPwshAnalysis', 'InspectPowerShell') } {
            foreach ($k in $Args.Keys) { if ($Args[$k]) { [void]$sb.AppendLine(('  {0,-12}: {1}' -f $k, $Args[$k])) } }
        }
        'WriteFile' {
            $path = [string](Get-Arg $Args 'path')
            $content = [string](Get-Arg $Args 'content' '')
            $old = ''
            try { $full = Resolve-AgentPath -Path $path -AllowMissing; if (Test-Path -LiteralPath $full) { $old = [System.IO.File]::ReadAllText($full) } } catch { }
            [void]$sb.AppendLine((Format-UnifiedDiff -OldText $old -NewText $content -Path $path))
        }
        'EditFile' {
            $path = [string](Get-Arg $Args 'path')
            $oldText = [string](Get-Arg $Args 'old_text')
            $newText = [string](Get-Arg $Args 'new_text')
            $current = ''
            try { $full = Resolve-AgentPath -Path $path; $current = [System.IO.File]::ReadAllText($full) } catch { }
            $proposed = $current
            if ($current) {
                $norm = $current -replace "`r`n", "`n"
                $idx = $norm.IndexOf(($oldText -replace "`r`n", "`n"), [StringComparison]::Ordinal)
                if ($idx -ge 0) { $proposed = $norm.Remove($idx, ($oldText -replace "`r`n", "`n").Length).Insert($idx, ($newText -replace "`r`n", "`n")) }
                else { $proposed = $norm -replace [regex]::Escape(($oldText -replace "`r`n", "`n")), ($newText -replace "`r`n", "`n") }
            }
            [void]$sb.AppendLine((Format-UnifiedDiff -OldText $current -NewText $proposed -Path $path))
        }
        default {
            if ($Args -and $Args.Count -gt 0) {
                foreach ($k in $Args.Keys) {
                    $v = [string]$Args[$k]
                    if ($v.Length -gt 400) { $v = $v.Substring(0, 400) + '...' }
                    [void]$sb.AppendLine(('  {0}: {1}' -f $k, ($v -replace "`r?`n", "`n  ")))
                }
            }
            else { [void]$sb.AppendLine('  (no arguments)') }
        }
    }
    return $sb.ToString().TrimEnd()
}

function Test-DenyPattern {
    param([string]$Text)
    if (-not $Text) { return $null }
    foreach ($pat in $script:Cfg.agent.denyPatterns) {
        if ([string]::IsNullOrWhiteSpace($pat)) { continue }
        try { if ([regex]::IsMatch($Text, $pat, 'IgnoreCase')) { return $pat } } catch { }
    }
    return $null
}

function Get-CallSummary {
    <#
        Human-facing preview of a tool call: a command preview, a file diff,
        or a short argument dump. Built BEFORE execution, so approval is informed.
    #>
    param([string]$ToolName, $ToolArgs)

    $sb = [System.Text.StringBuilder]::new()

    switch ($ToolName) {
        'RunCommand' {
            $shell = [string](Get-Arg $ToolArgs 'shell' 'pwsh')
            $wd = [string](Get-Arg $ToolArgs 'working_dir' '')
            [void]$sb.AppendLine(('  shell : {0}' -f $shell))
            if ($wd) { [void]$sb.AppendLine(('  cwd   : {0}' -f $wd)) }
            if (Get-Arg $ToolArgs 'purpose') { [void]$sb.AppendLine(('  why   : {0}' -f (Get-Arg $ToolArgs 'purpose'))) }
            [void]$sb.AppendLine('  ---- command ----')
            foreach ($line in ([string](Get-Arg $ToolArgs 'command')).Split("`n")) { [void]$sb.AppendLine('  | ' + $line) }
        }
        { $_ -in @('RunBuild', 'RunTests', 'DotnetNew', 'AddPackage', 'RunPwshAnalysis', 'InspectPowerShell') } {
            foreach ($k in $ToolArgs.Keys) { if ($ToolArgs[$k]) { [void]$sb.AppendLine(('  {0,-12}: {1}' -f $k, $ToolArgs[$k])) } }
        }
        'WriteFile' {
            $path = [string](Get-Arg $ToolArgs 'path')
            $content = [string](Get-Arg $ToolArgs 'content' '')
            $old = ''
            try {
                $full = Resolve-AgentPath -Path $path -AllowMissing
                if (Test-Path -LiteralPath $full) { $old = [System.IO.File]::ReadAllText($full) }
            }
            catch { }
            [void]$sb.AppendLine((Format-UnifiedDiff -OldText $old -NewText $content -Path $path))
        }
        'EditFile' {
            $path = [string](Get-Arg $ToolArgs 'path')
            $oldText = [string](Get-Arg $ToolArgs 'old_text')
            $newText = [string](Get-Arg $ToolArgs 'new_text')
            $current = ''
            try { $full = Resolve-AgentPath -Path $path; $current = [System.IO.File]::ReadAllText($full) } catch { }
            $proposed = $current
            if ($current) {
                $norm = $current -replace "`r`n", "`n"
                $needle = $oldText -replace "`r`n", "`n"
                $idx = $norm.IndexOf($needle, [StringComparison]::Ordinal)
                if ($idx -ge 0) { $proposed = $norm.Remove($idx, $needle.Length).Insert($idx, ($newText -replace "`r`n", "`n")) }
                else { $proposed = $norm -replace [regex]::Escape($needle), ($newText -replace "`r`n", "`n") }
            }
            [void]$sb.AppendLine((Format-UnifiedDiff -OldText $current -NewText $proposed -Path $path))
        }
        default {
            if ($ToolArgs -and $ToolArgs.Count -gt 0) {
                foreach ($k in $ToolArgs.Keys) {
                    $v = [string]$ToolArgs[$k]
                    if ($v.Length -gt 400) { $v = $v.Substring(0, 400) + '...' }
                    [void]$sb.AppendLine(('  {0}: {1}' -f $k, ($v -replace "`r?`n", "`n  ")))
                }
            }
            else { [void]$sb.AppendLine('  (no arguments)') }
        }
    }
    return $sb.ToString().TrimEnd()
}

function Read-KeyChoice {
    <# Single-keystroke prompt with a default. #>
    param([string]$Prompt, [char[]]$Allowed, [char]$Default)

    Write-UI $Prompt 'Yellow' -NoNewline
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Enter) { return [char]::ToLower($Default) }
        if ($k.Key -eq [ConsoleKey]::Escape) { return [char]'q' }
        $c = [char]::ToLower($k.KeyChar)
        if ($Allowed -contains $c) { Write-UI "$c`n" 'Yellow'; return $c }
    }
}

function Request-Approval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [string]$ArgumentsJson,
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$Workspace
    )

    $argsObj = @{}
    if ($ArgumentsJson -and $ArgumentsJson.Trim()) {
        try { $argsObj = $ArgumentsJson | ConvertFrom-Json -AsHashtable -Depth 12 } catch { }
    }

    # -------- tier 0: read-only tools never need approval -----------------
    $readOnly = @('ReadFile', 'ListFiles', 'SearchCode', 'GitInfo', 'InspectPowerShell', 'AskUser', 'UpdateTodo')
    if ($script:Cfg.agent.approvalGate -eq 'readonly-auto' -and $readOnly -contains $ToolName) {
        return [pscustomobject]@{ Decision = 'approve'; Note = 'auto (read-only)' }
    }
    if ($script:SessionAllowList -contains $ToolName) {
        Write-UI "   auto-approved (you allowed '$ToolName' for this session)" 'DarkGray'
        return [pscustomobject]@{ Decision = 'approve'; Note = 'session-allow' }
    }

    # -------- hard deny: never prompt, just refuse ------------------------
    $haystack = $ToolName + ' ' + $(if ($argsObj['command']) { [string]$argsObj['command'] } else { '' })
    $hit = Test-DenyPattern -Text $haystack
    if ($hit) {
        Write-UI "   BLOCKED by deny pattern: $hit" 'Red'
        return [pscustomobject]@{ Decision = 'deny'; Note = "deny-pattern: $hit" }
    }

    # -------- show what will happen ---------------------------------------
    $sep = '-' * 74
    Write-UI $sep 'DarkGray'
    try {
        $summary = Get-CallSummary -ToolName $ToolName -Args $argsObj
        Write-Host $summary
    }
    catch { Write-UI "  (could not build preview: $($_.Exception.Message))" 'DarkRed' }
    Write-UI $sep 'DarkGray'

    $choice = Read-KeyChoice -Prompt '  [Y]es / [N]o / [A]lways this tool / [F]eedback / [Q]uit ? ' `
        -Allowed ([char[]]@('y', 'n', 'a', 'f', 'q')) -Default ([char]'y')

    switch ($choice) {
        'y' { return [pscustomobject]@{ Decision = 'approve'; Note = 'user-approved' } }
        'a' {
            $script:SessionAllowList += $ToolName
            Write-UI "   '$ToolName' auto-approved for the rest of this session." 'DarkGray'
            return [pscustomobject]@{ Decision = 'approve'; Note = 'session-allow-new' }
        }
        'n' { return [pscustomobject]@{ Decision = 'deny'; Note = 'user-denied' } }
        'q' { return [pscustomobject]@{ Decision = 'abort'; Note = 'user-aborted' } }
        'f' {
            Write-UI '  feedback > ' 'Magenta' -NoNewline
            $fb = Read-Host
            if (-not $fb) { $fb = 'Try a different approach.' }
            return [pscustomobject]@{ Decision = 'feedback'; Note = $fb }
        }
    }
    return [pscustomobject]@{ Decision = 'deny'; Note = 'unknown-choice' }
}
