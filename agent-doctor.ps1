<#
.SYNOPSIS
    Diagnoses everything the agent depends on and tells you exactly how to fix gaps.
.DESCRIPTION
    Checks PowerShell 7, Windows PowerShell 5.1, the .NET SDK, Pester, PSScriptAnalyzer,
    the config file, the API key, and the VS Code extensions from .vscode/extensions.json.
    Exit code 0 = ready, 1 = something needs attention.
.PARAMETER Workspace
    The project the agent will work on. Defaults to the current directory.
.PARAMETER VerifyModule
    Optional path to a .psd1 manifest; the doctor will test that it imports cleanly.
.EXAMPLE
    pwsh -File .agent/agent-doctor.ps1
.EXAMPLE
    pwsh -File .agent/agent-doctor.ps1 -Workspace C:\src\MyLib
#>
[CmdletBinding()]
param(
    [string]$Workspace,
    [string]$VerifyModule
)

$ErrorActionPreference = 'Continue'
$script:Fail = 0
$script:Warn = 0

function Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "== $Title " -ForegroundColor Cyan -NoNewline
    Write-Host ('=' * [Math]::Max(0, 60 - $Title.Length)) -ForegroundColor DarkCyan
}
function Check {
    param([string]$Name, [scriptblock]$Test, [string]$Fix, [switch]$Optional)
    Write-Host ('  {0,-42}' -f $Name) -NoNewline
    try {
        $detail = & $Test
        if ($detail -eq $false) { throw 'failed' }
        Write-Host ' OK' -ForegroundColor Green -NoNewline
        if ($detail -is [string] -and $detail -ne 'true') { Write-Host "  $detail" -ForegroundColor DarkGray }
        else { Write-Host '' }
    }
    catch {
        if ($Optional) {
            Write-Host ' MISSING (optional)' -ForegroundColor Yellow
            $script:Warn++
        }
        else {
            Write-Host ' FAIL' -ForegroundColor Red
            $script:Fail++
        }
        if ($Fix) { Write-Host "      fix: $Fix" -ForegroundColor Yellow }
        if ($_.Exception.Message -and $_.Exception.Message -ne 'failed') {
            Write-Host "      detail: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Workspace) { $Workspace = (Get-Location).Path }
$Workspace = (Resolve-Path -LiteralPath $Workspace).Path

Write-Host ''
Write-Host 'PS/.NET AGENT - ENVIRONMENT DOCTOR' -ForegroundColor White
Write-Host "workspace: $Workspace" -ForegroundColor DarkGray
Write-Host "agent    : $root" -ForegroundColor DarkGray

# --------------------------------------------------------------- runtimes ----
Section 'Runtimes'

$pwshExe = $null
Check 'PowerShell 7 (pwsh)' {
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $c) {
        $candidates = @(
            (Join-Path $HOME '.local/pwsh/pwsh')
            '/usr/bin/pwsh', '/usr/local/bin/pwsh', '/opt/microsoft/powershell/7/pwsh'
            'C:\Program Files\PowerShell\7\pwsh.exe'
        )
        foreach ($cand in $candidates) { if (Test-Path -LiteralPath $cand) { $c = [pscustomobject]@{ Source = $cand }; break } }
    }
    if (-not $c) { throw 'pwsh not found on PATH' }
    $script:pwshExe = $c.Source
    if ($PSVersionTable.PSVersion.Major -ge 7) { "v$($PSVersionTable.PSVersion) ($($c.Source))" }
    else {
        $v = & $c.Source -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
        "v$v ($($c.Source))"
    }
} -Fix 'winget install Microsoft.PowerShell | brew install --cask powershell | apt install powershell'

if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    Check 'Windows PowerShell 5.1' {
        $c = Get-Command powershell.exe -ErrorAction SilentlyContinue
        if (-not $c) { throw 'powershell.exe not found' }
        $v = & $c.Source -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
        "v$v"
    } -Fix 'Enable via Windows Features > Windows PowerShell 2.0 Engine, or install WMF 5.1'
}
else {
    Write-Host ('  {0,-42}' -f 'Windows PowerShell 5.1') -NoNewline
    Write-Host ' N/A (not Windows)' -ForegroundColor DarkGray
    Write-Host '      5.1 compatibility is still checked statically: PSScriptAnalyzer PSUseCompatibleSyntax.' -ForegroundColor DarkGray
}

Check '.NET SDK' {
    $c = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $c) {
        $fb = if ($IsWindows) { 'C:\Program Files\dotnet\dotnet.exe' } else { Join-Path $HOME '.local/dotnet/dotnet' }
        if (Test-Path -LiteralPath $fb) { $c = [pscustomobject]@{ Source = $fb } } else { throw 'dotnet not found' }
    }
    $v = & $c.Source --version
    $sdks = (& $c.Source --list-sdks) -join '; '
    "v$v  [$sdks]"
} -Fix 'https://dot.net/download or: winget install Microsoft.DotNet.SDK.9'

Check 'git' {
    $c = Get-Command git -ErrorAction SilentlyContinue
    if (-not $c) { throw 'git not found' }
    (git --version)
} -Fix 'https://git-scm.com/downloads'

# ------------------------------------------------------------ PS modules ----
Section 'PowerShell modules'

Check 'PSScriptAnalyzer' {
    $m = Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version | Select-Object -Last 1
    if (-not $m) { throw 'not installed' }
    "v$($m.Version)"
} -Fix 'Install-Module PSScriptAnalyzer -Scope CurrentUser -Force'

Check 'Pester (>= 5.0)' {
    $m = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0.0' } | Sort-Object Version | Select-Object -Last 1
    if (-not $m) { throw 'Pester 5+ not installed' }
    "v$($m.Version)"
} -Fix 'Install-Module Pester -MinimumVersion 5.3 -Scope CurrentUser -Force'

Check 'PSReadLine' {
    $m = Get-Module -ListAvailable PSReadLine | Sort-Object Version | Select-Object -Last 1
    if (-not $m) { throw 'not installed' }
    "v$($m.Version)"
} -Optional -Fix 'Install-Module PSReadLine -Scope CurrentUser -Force'

Check 'platyPS (help generation)' {
    $m = Get-Module -ListAvailable platyPS | Sort-Object Version | Select-Object -Last 1
    if (-not $m) { throw 'not installed' }
    "v$($m.Version)"
} -Optional -Fix 'Install-Module platyPS -Scope CurrentUser -Force'

Check 'PSScriptAnalyzer rule: PSUseCompatibleSyntax works' {
    $null = Invoke-ScriptAnalyzer -ScriptDefinition 'Get-ChildItem -Path .' `
        -Settings @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } } } -ErrorAction Stop
    'rule loaded'
}

Check '5.1 incompatibility is actually detected' {
    # ternary operator is PowerShell 7 only; the rule must flag it.
    $probe = Invoke-ScriptAnalyzer -ScriptDefinition '$x = $true ? 1 : 2' `
        -Settings @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } } } -ErrorAction Stop
    if (-not $probe) { throw 'the compatibility rule did not flag a ternary operator' }
    'detects 7-only syntax'
}

# ---------------------------------------------------------------- config ----
Section 'Agent configuration'

$cfgPath = Join-Path $root 'config/agent.config.json'
Check 'config/agent.config.json exists' {
    if (-not (Test-Path $cfgPath)) { throw "missing $cfgPath" }
    'found'
} -Fix 'restore it from the kit'

$cfg = $null
Check 'config parses' {
    $script:cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    "model=$($script:cfg.provider.model)"
}

$cfg = $script:cfg
$envName = if ($cfg) { $cfg.provider.apiKeyEnv } else { 'OPENAI_API_KEY' }
Check "API key available ($envName)" {
    . (Join-Path $root 'AgentConfig.ps1')
    $v = Get-AgentSecret -EnvName $envName
    if (-not $v) { throw "not found in `$env:$envName nor in the credential store" }
    $from = if ([Environment]::GetEnvironmentVariable($envName)) { 'environment' } else { "store (~/.agent/secrets.xml)" }
    "length=$($v.Length) from=$from"
} -Fix "./Install-Agent.ps1 -Project $Workspace   (stores the key securely for you)"

Check 'agent files present (Agent.ps1, prompts, tools)' {
    $need = @('Agent.ps1', 'AgentTools.ps1', 'AgentApproval.ps1', 'AgentLlm.ps1', 'AgentConfig.ps1', 'prompts/modes/hybrid.md')
    $missing = @($need | Where-Object { -not (Test-Path (Join-Path $root $_)) })
    if ($missing) { throw "missing: $($missing -join ', ')" }
    'all present'
}

Check 'Agent.ps1 starts in dry-run' {
    if (-not $script:pwshExe) { throw 'pwsh unavailable' }
    $out = & $script:pwshExe -NoLogo -NoProfile -File (Join-Path $root 'Agent.ps1') -DryRun -NoColor -Workspace $Workspace 'doctor smoke test' 2>&1
    $joined = ($out | Out-String)
    if ($joined -notmatch 'model not called') { throw "unexpected output: $($joined.Substring(0,[Math]::Min(200,$joined.Length)))" }
    'loop, config, prompt assembly OK'
}

# ------------------------------------------------------------- workspace ----
Section 'Workspace'

Check 'workspace is writable' {
    $probe = Join-Path $Workspace ".agent/doctor-$([guid]::NewGuid().ToString('N').Substring(0,6)).tmp"
    New-Item -ItemType Directory -Force -Path (Split-Path $probe) | Out-Null
    Set-Content -LiteralPath $probe -Value 'ok'
    Remove-Item -LiteralPath $probe -Force
    'ok'
}

Check 'git repository' {
    Push-Location $Workspace
    try {
        $r = git rev-parse --is-inside-work-tree 2>$null
        if ($r -ne 'true') { throw 'not a git repo' }
        $branch = git rev-parse --abbrev-ref HEAD
        "branch=$branch"
    }
    finally { Pop-Location }
} -Fix 'git init  (strongly recommended: the agent reports diffs through git)'

Check '.editorconfig present' {
    if (-not (Test-Path (Join-Path $Workspace '.editorconfig'))) { throw 'missing' }
    'ok'
} -Optional -Fix 'copy .editorconfig from the kit'

Check '.vscode/settings.json present' {
    if (-not (Test-Path (Join-Path $Workspace '.vscode/settings.json'))) { throw 'missing' }
    'ok'
} -Optional -Fix 'copy .vscode/* from the kit'

if ($VerifyModule) {
    Section 'Module verification'
    Check "import $VerifyModule" {
        $file = Resolve-Path -LiteralPath $VerifyModule
        $m = Test-ModuleManifest -Path $file
        Import-Module $file -Force -ErrorAction Stop
        $cmds = (Get-Command -Module $m.Name).Count
        "name=$($m.Name) v$($m.Version) exported=$cmds"
    } -Fix 'fix the manifest errors above'
}

# ------------------------------------------------------------ vscode ext ----
Section 'VS Code extensions'
$extFile = Join-Path $Workspace '.vscode/extensions.json'
if (Test-Path $extFile) {
    $code = Get-Command code -ErrorAction SilentlyContinue
    if (-not $code) {
        Write-Host '  code CLI not on PATH - skipping live extension check.' -ForegroundColor Yellow
        Write-Host '  Install each recommendation from .vscode/extensions.json,' -ForegroundColor DarkGray
        Write-Host '  or run: code --install-extension <id>' -ForegroundColor DarkGray
        $script:Warn++
    }
    else {
        $installed = @(& $code --list-extensions 2>$null)
        $rec = (Get-Content -Raw $extFile | ConvertFrom-Json).recommendations
        $missing = @($rec | Where-Object { $installed -notcontains $_ })
        Check "all $($rec.Count) recommended extensions installed" {
            if ($missing.Count -gt 0) { throw "missing: $($missing -join ', ')" }
            'ok'
        } -Fix ("code --install-extension " + ($missing -join ' --install-extension '))
    }
}
else {
    Write-Host '  .vscode/extensions.json not found in the workspace - skipped.' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- result ----
Section 'Result'
if ($script:Fail -eq 0 -and $script:Warn -eq 0) {
    Write-Host '  Everything checks out. You are ready.' -ForegroundColor Green
    exit 0
}
if ($script:Fail -eq 0) {
    Write-Host "  Ready, with $($script:Warn) optional item(s) missing." -ForegroundColor Yellow
    exit 0
}
Write-Host "  $($script:Fail) blocking issue(s), $($script:Warn) warning(s). Fix the items marked FAIL." -ForegroundColor Red
exit 1
