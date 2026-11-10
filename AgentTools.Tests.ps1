<#
    tests/AgentTools.Tests.ps1
    Exercises the tool layer the model actually calls: file IO, exact-once editing,
    workspace containment, diff rendering, and the shell runners.
    Run: pwsh -File .agent/tests/AgentTools.Tests.ps1
#>
BeforeAll {
    $script:KitRoot = Split-Path -Parent $PSScriptRoot
    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("agenttools-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $script:Work | Out-Null

    # Minimal globals the tool layer expects.
    $script:Workspace = $script:Work
    $script:CommandTimeout = 120
    $script:Cfg = [pscustomobject]@{
        agent = [pscustomobject]@{
            denyPatterns          = @()
            allowOutsideWorkspace = $false
            approvalGate          = 'all'
            pwshPath              = 'pwsh'
            dotnetPath            = 'dotnet'
            gitPath               = 'git'
            posixShell            = '/bin/bash'
            windowsPowerShellPath = 'powershell'
        }
    }
    $script:AutoApprove = $false

    function Write-UI {
        param([string]$Text, [string]$Color, [switch]$NoNewline)
        $null = $Color   # colour is irrelevant in tests
        Write-Host $Text -NoNewline:$NoNewline
    }

    . (Join-Path $script:KitRoot 'AgentTools.ps1')
    . (Join-Path $script:KitRoot 'AgentApproval.ps1')

    $script:Reg = New-AgentToolRegistry
    # Mirrors Agent.ps1's Invoke-AgentTool: a throwing tool becomes a structured
    # ok=false result so the model receives an error message instead of the run dying.
    $script:Call = {
        param([string]$Name, [hashtable]$Arguments)
        try { & $script:Reg[$Name].Script -ToolArgs $Arguments }
        catch { [pscustomobject]@{ ok = $false; output = "ERROR in tool '$Name': $($_.Exception.Message)" } }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Tool registry' {
    It 'exposes every expected tool' {
        $expected = @('ReadFile', 'WriteFile', 'EditFile', 'ListFiles', 'SearchCode', 'RunCommand',
            'RunBuild', 'RunTests', 'RunPwshAnalysis', 'InspectPowerShell', 'DotnetNew',
            'AddPackage', 'GitInfo', 'UpdateTodo', 'AskUser')
        foreach ($e in $expected) { $script:Reg.Keys | Should -Contain $e }
    }

    It 'describes every tool with a valid JSON schema' {
        foreach ($name in $script:Reg.Keys) {
            $script:Reg[$name].Description | Should -Not -BeNullOrEmpty -Because "$name needs a description"
            $params = $script:Reg[$name].Parameters
            $params.type | Should -Be 'object' -Because "$name schema must be an object"
            $params.Keys | Should -Contain 'properties'
        }
    }
}

Describe 'WriteFile / ReadFile' {
    It 'creates a file and reports its size' {
        $r = & $script:Call 'WriteFile' @{ path = 'src/Mod.psm1'; content = "function Get-A { 1 }`n" }
        $r.ok | Should -BeTrue
        Join-Path $script:Work 'src/Mod.psm1' | Should -Exist
        $r.output | Should -Match '1 lines'
    }

    It 'refuses to overwrite without explicit permission' {
        $r = & $script:Call 'WriteFile' @{ path = 'src/Mod.psm1'; content = 'clobbered' }
        $r.ok | Should -BeFalse
        $r.output | Should -Match 'already exists'
        (Get-Content -Raw (Join-Path $script:Work 'src/Mod.psm1')) | Should -Match 'Get-A'
    }

    It 'overwrites when overwrite=true' {
        $r = & $script:Call 'WriteFile' @{ path = 'src/Mod.psm1'; content = "function Get-B { 2 }`n"; overwrite = $true }
        $r.ok | Should -BeTrue
        (Get-Content -Raw (Join-Path $script:Work 'src/Mod.psm1')) | Should -Match 'Get-B'
    }

    It 'reads back with line numbers' {
        $r = & $script:Call 'ReadFile' @{ path = 'src/Mod.psm1' }
        $r.ok | Should -BeTrue
        $r.output | Should -Match 'total_lines="1"'
        $r.output | Should -Match '    1\| function Get-B'
    }

    It 'returns an error for a missing file' {
        $r = & $script:Call 'ReadFile' @{ path = 'nope.ps1' }
        $r.ok | Should -BeFalse
        $r.output | Should -Match 'not found'
    }
}

Describe 'EditFile' {
    BeforeEach {
        & $script:Call 'WriteFile' @{
            path      = 'src/Edit.ps1'
            overwrite = $true
            content   = "param(`$Name)`nWrite-Output 'a'`nWrite-Output 'b'`n"
        } | Out-Null
    }

    It 'replaces a unique occurrence' {
        $r = & $script:Call 'EditFile' @{ path = 'src/Edit.ps1'; old_text = "Write-Output 'a'"; new_text = "Write-Output 'A'" }
        $r.ok | Should -BeTrue
        $t = Get-Content -Raw (Join-Path $script:Work 'src/Edit.ps1')
        $t | Should -Match "Write-Output 'A'"
        $t | Should -Match "Write-Output 'b'"
        $lines = @($t -split "`n")
        ($lines -ccontains "Write-Output 'A'") | Should -BeTrue
        ($lines -ccontains "Write-Output 'b'") | Should -BeTrue
        ($lines -ccontains "Write-Output 'a'") | Should -BeFalse   # case-sensitive: 'a' must be gone
    }

    It 'refuses an ambiguous edit and names the occurrence count' {
        $r = & $script:Call 'EditFile' @{ path = 'src/Edit.ps1'; old_text = 'Write-Output'; new_text = 'Write-Host' }
        $r.ok | Should -BeFalse
        $r.output | Should -Match 'matches 2 places'
    }

    It 'replaces all occurrences when asked' {
        $r = & $script:Call 'EditFile' @{ path = 'src/Edit.ps1'; old_text = 'Write-Output'; new_text = 'Write-Verbose'; replace_all = $true }
        $r.ok | Should -BeTrue
        (Get-Content -Raw (Join-Path $script:Work 'src/Edit.ps1')) | Should -Not -Match 'Write-Output'
    }

    It 'fails cleanly when the text is absent' {
        $r = & $script:Call 'EditFile' @{ path = 'src/Edit.ps1'; old_text = 'NotThere'; new_text = 'x' }
        $r.ok | Should -BeFalse
        $r.output | Should -Match 'not found'
    }

    It 'tolerates indentation drift in old_text' {
        $r = & $script:Call 'EditFile' @{
            path     = 'src/Edit.ps1'
            old_text = "Write-Output 'a'`n    Write-Output 'b'"
            new_text = "Write-Output 'merged'"
        }
        $r.ok | Should -BeTrue
        (Get-Content -Raw (Join-Path $script:Work 'src/Edit.ps1')) | Should -Match 'merged'
    }
}

Describe 'Workspace containment' {
    It 'blocks paths that escape the workspace' {
        $r = & $script:Call 'ReadFile' @{ path = '../../etc/passwd' }
        $r.ok | Should -BeFalse
        $r.output | Should -Match 'escapes the workspace'
    }

    It 'blocks an absolute path outside the workspace' {
        $outside = if ($IsWindows) { 'C:\Windows\win.ini' } else { '/etc/hostname' }
        $r = & $script:Call 'ReadFile' @{ path = $outside }
        $r.ok | Should -BeFalse
        $r.output | Should -Match 'escapes the workspace'
    }
}

Describe 'ListFiles and SearchCode' {
    BeforeAll {
        & $script:Call 'WriteFile' @{ path = 'src/A.ps1'; content = "function Get-Alpha { 'x' }`n" } | Out-Null
        & $script:Call 'WriteFile' @{ path = 'src/B.ps1'; content = "function Set-Beta { 'y' }`n" } | Out-Null
    }

    It 'lists the tree' {
        $r = & $script:Call 'ListFiles' @{ pattern = '*.ps1' }
        $r.output | Should -Match 'A\.ps1'
        $r.output | Should -Match 'B\.ps1'
    }

    It 'finds a regex match with file and line' {
        $r = & $script:Call 'SearchCode' @{ pattern = 'Get-Alpha'; file_glob = '*.ps1' }
        $r.ok | Should -BeTrue
        $r.output | Should -Match 'src/A\.ps1:1'
    }

    It 'reports no matches without failing' {
        $r = & $script:Call 'SearchCode' @{ pattern = 'NoSuchSymbolAnywhere'; file_glob = '*.ps1' }
        $r.ok | Should -BeTrue
        $r.output | Should -Match 'No matches'
    }
}

Describe 'Diff preview' {
    It 'renders added and removed lines' {
        $d = Format-UnifiedDiff -OldText "a`nb`nc" -NewText "a`nB`nc" -Path 'x.ps1'
        $d | Should -Match '-b'
        $d | Should -Match '\+B'
        $d | Should -Match '1 added, 1 removed'
    }

    It 'shows a pure creation as additions' {
        $d = Format-UnifiedDiff -OldText '' -NewText "one`ntwo" -Path 'new.ps1'
        $d | Should -Match '\+one'
        $d | Should -Match '\+two'
    }
}

Describe 'RunCommand' {
    It 'runs pwsh and returns output with the exit code' {
        $r = & $script:Call 'RunCommand' @{ command = 'Write-Output "hello-agent"'; shell = 'pwsh' }
        $r.ok | Should -BeTrue
        $r.output | Should -Match 'hello-agent'
        $r.output | Should -Match 'exit=0'
    }

    It 'propagates a non-zero exit code as not-ok' {
        $r = & $script:Call 'RunCommand' @{ command = 'exit 7'; shell = 'pwsh' }
        $r.ok | Should -BeFalse
        $r.output | Should -Match 'exit=7'
    }

    It 'honours the working directory' {
        $r = & $script:Call 'RunCommand' @{ command = 'Get-Location | Select-Object -ExpandProperty Path'; shell = 'pwsh'; working_dir = 'src' }
        $r.ok | Should -BeTrue
        $r.output | Should -Match 'src'
    }

    It 'captures stderr from a failing command' {
        $r = & $script:Call 'RunCommand' @{ command = 'Get-Item ./does-not-exist-xyz'; shell = 'pwsh' }
        $r.output | Should -Match 'does-not-exist-xyz'
    }

    It 'kills a command that exceeds its timeout' {
        $r = & $script:Call 'RunCommand' @{ command = 'Start-Sleep -Seconds 30'; shell = 'pwsh'; timeout_sec = 2 }
        $r.ok | Should -BeFalse
        $r.output | Should -Match 'TIMEOUT'
    }
}

Describe 'InspectPowerShell' {
    It 'resolves a real cmdlet (ground truth instead of guessing)' {
        $r = & $script:Call 'InspectPowerShell' @{ query = 'Get-Command Invoke-RestMethod -Syntax' }
        $r.ok | Should -BeTrue
        $r.output | Should -Match 'Invoke-RestMethod'
    }
}

Describe 'UpdateTodo' {
    It 'writes the plan file and counts progress' {
        $script:Cfg.agent | Add-Member -NotePropertyName todoFile -NotePropertyValue '.agent/todo.md' -Force
        $r = & $script:Call 'UpdateTodo' @{ items = @(
                @{ step = 'one'; state = 'done' }
                @{ step = 'two'; state = 'in_progress' }
            )
        }
        $r.ok | Should -BeTrue
        $r.output | Should -Match '1/2 done'
        Join-Path $script:Work '.agent/todo.md' | Should -Exist
        (Get-Content -Raw (Join-Path $script:Work '.agent/todo.md')) | Should -Match '\[x\] one'
    }
}
