<#
    AgentTools.ps1  -  the tool registry.

    Every capability the model has lives here. A tool is:
        name        = the function name the model calls
        description = when to use it (behavioural guidance, not docs)
        parameters  = JSON Schema
        script      = scriptblock receiving -Args (hashtable) and returning
                      @{ ok = [bool]; output = [string]; preview = [string] (optional) }

    'preview' is what the human sees in the approval prompt. If a tool returns a
    preview, it is produced BEFORE execution - so approval is always informed.
#>

# ------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------

function Resolve-AgentPath {
    param([string]$Path, [switch]$AllowMissing)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path is required' }
    $root = $script:Workspace

    if ([System.IO.Path]::IsPathRooted($Path)) {
        $full = [System.IO.Path]::GetFullPath($Path)
    }
    else {
        $full = [System.IO.Path]::GetFullPath((Join-Path $root $Path))
    }

    $normRoot = [System.IO.Path]::GetFullPath($root).TrimEnd('/', '\')
    if (-not $full.StartsWith($normRoot, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not $script:Cfg.agent.allowOutsideWorkspace) {
            throw "Path escapes the workspace: $Path (workspace guard is on; set agent.allowOutsideWorkspace=true to permit)"
        }
    }
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $full)) {
        throw "Path not found: $Path"
    }
    return $full
}

function Get-Arg {
    param($Args, [string]$Name, $Default = $null)
    if (-not $Args) { return $Default }
    $has = $false
    try { $has = $Args.Keys -contains $Name } catch { $has = $false }
    if ($has -and $null -ne $Args[$Name]) { return $Args[$Name] }
    return $Default
}

function Format-UnifiedDiff {
    <# Line diff with LCS so approval prompts show exactly what changes. #>
    param([string]$OldText = '', [string]$NewText = '', [string]$Path = 'file', [int]$Context = 3)

    $a = @($OldText -split "`r?`n")
    $b = @($NewText -split "`r?`n")
    $n = $a.Count; $m = $b.Count

    # LCS table (bounded - these are source files, not genomes)
    if ($n * $m -gt 4000000) {
        return "--- $Path`n+++ $Path`n(file too large for inline diff: $n -> $m lines)"
    }
    $lcs = New-Object 'int[,]' ($n + 1), ($m + 1)
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) {
            if ($a[$i] -ceq $b[$j]) { $lcs[$i, $j] = $lcs[($i + 1), ($j + 1)] + 1 }
            else { $lcs[$i, $j] = [Math]::Max($lcs[($i + 1), $j], $lcs[$i, ($j + 1)]) }
        }
    }
    $ops = [System.Collections.Generic.List[object]]::new()
    $x = 0; $y = 0
    while ($x -lt $n -and $y -lt $m) {
        if ($a[$x] -ceq $b[$y]) { $ops.Add([pscustomobject]@{ t = ' '; line = $a[$x] }); $x++; $y++ }
        elseif ($lcs[($x + 1), $y] -ge $lcs[$x, ($y + 1)]) { $ops.Add([pscustomobject]@{ t = '-'; line = $a[$x] }); $x++ }
        else { $ops.Add([pscustomobject]@{ t = '+'; line = $b[$y] }); $y++ }
    }
    while ($x -lt $n) { $ops.Add([pscustomobject]@{ t = '-'; line = $a[$x] }); $x++ }
    while ($y -lt $m) { $ops.Add([pscustomobject]@{ t = '+'; line = $b[$y] }); $y++ }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("--- $Path (current)")
    [void]$sb.AppendLine("+++ $Path (proposed)")

    $added = @($ops | Where-Object t -eq '+').Count
    $removed = @($ops | Where-Object t -eq '-').Count
    [void]$sb.AppendLine("@@ $added added, $removed removed @@")

    # collapse long runs of unchanged context
    $skipUntil = -1
    for ($k = 0; $k -lt $ops.Count; $k++) {
        $op = $ops[$k]
        if ($op.t -ne ' ') { [void]$sb.AppendLine($op.t + $op.line); continue }
        $nearChange = $false
        for ($d = [Math]::Max(0, $k - $Context); $d -lt [Math]::Min($ops.Count, $k + $Context + 1); $d++) {
            if ($ops[$d].t -ne ' ') { $nearChange = $true; break }
        }
        if ($nearChange) { [void]$sb.AppendLine(' ' + $op.line) }
        elseif ($k -gt $skipUntil) { [void]$sb.AppendLine(' ...'); $skipUntil = $k + 1 }
    }
    return $sb.ToString()
}

function Resolve-PwshPath {
    $candidates = @($script:Cfg.agent.pwshPath)
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $candidates += @('C:\Program Files\PowerShell\7\pwsh.exe', 'pwsh.exe')
    }
    else {
        $candidates += @('/usr/bin/pwsh', '/usr/local/bin/pwsh', '/opt/microsoft/powershell/7/pwsh', (Join-Path $HOME '.local/pwsh/pwsh'))
    }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Resolve-DotnetPath {
    $c = Get-Command $script:Cfg.agent.dotnetPath -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $fallback = if ($IsWindows) { 'dotnet.exe' } else { Join-Path $HOME '.local/dotnet/dotnet' }
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $script:Cfg.agent.dotnetPath
}

function Invoke-CapturedProcess {
    <#
        Runs an executable with args, captures stdout+stderr, enforces a timeout,
        never uses a shell unless $Shell is given (so quoting can't be injected).
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [int]$TimeoutSec = 300,
        [hashtable]$Environment = @{}
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add([string]$a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $false
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { $script:Workspace }
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    foreach ($k in $Environment.Keys) { $psi.Environment[$k] = [string]$Environment[$k] }

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$p.Start()

    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    $finished = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        try { $p.Kill($true) } catch { }
        $sw.Stop()
        return [pscustomobject]@{
            exitCode = 124
            output   = ($outTask.Result + "`n" + $errTask.Result) + "`n[agent] TIMEOUT after ${TimeoutSec}s - process killed."
            duration = $sw.Elapsed.TotalSeconds
            timedOut = $true
        }
    }
    $p.WaitForExit()
    $sw.Stop()

    $stdout = $outTask.Result
    $stderr = $errTask.Result
    $combined = $stdout
    if ($stderr) { $combined = ($stdout + "`n" + $stderr).Trim() }

    return [pscustomobject]@{
        exitCode = $p.ExitCode
        output   = $combined
        duration = $sw.Elapsed.TotalSeconds
        timedOut = $false
    }
}

# ------------------------------------------------------------------------------
# registry
# ------------------------------------------------------------------------------

function New-AgentToolRegistry {
    $reg = [ordered]@{}

    # ---------------------------------------------------------------- read ----
    $reg['ReadFile'] = @{
        Description = 'Read a text file from the workspace. Use before editing anything. Returns lines with 1-based line numbers.'
        Parameters  = @{
            type = 'object'; required = @('path')
            properties = @{
                path       = @{ type = 'string'; description = 'Workspace-relative or absolute path.' }
                start_line = @{ type = 'integer'; description = 'First line (1-based). Optional.' }
                max_lines  = @{ type = 'integer'; description = 'Max lines to return. Default 400.' }
            }
        }
        Script      = {
            param($Args)
            $p = Resolve-AgentPath -Path (Get-Arg $Args 'path')
            $start = [int](Get-Arg $Args 'start_line' 1)
            $max = [int](Get-Arg $Args 'max_lines' 400)
            $all = [System.IO.File]::ReadAllLines($p)
            $total = $all.Count
            $slice = $all | Select-Object -Skip ($start - 1) -First $max
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine("<file path=""$($p.Substring($script:Workspace.Length).TrimStart('/','\'))"" total_lines=""$total"" showing_from=""$start"">")
            $i = $start
            foreach ($l in $slice) { [void]$sb.AppendLine(('{0,5}| {1}' -f $i, $l)); $i++ }
            [void]$sb.AppendLine('</file>')
            [pscustomobject]@{ ok = $true; output = $sb.ToString() }
        }
    }

    # --------------------------------------------------------------- write ----
    $reg['WriteFile'] = @{
        Description = 'Create a file or replace its entire contents. Use for new files. For edits to existing files prefer EditFile so the change stays minimal.'
        Parameters  = @{
            type = 'object'; required = @('path', 'content')
            properties = @{
                path       = @{ type = 'string' }
                content    = @{ type = 'string'; description = 'Full file content. Use \n newlines; do not include line numbers.' }
                overwrite  = @{ type = 'boolean'; description = 'Required true to replace an existing file. Default false.' }
            }
        }
        Script      = {
            param($Args)
            $raw = Get-Arg $Args 'path'
            $p = Resolve-AgentPath -Path $raw -AllowMissing
            $content = [string](Get-Arg $Args 'content' '')
            $exists = Test-Path -LiteralPath $p
            if ($exists -and -not (Get-Arg $Args 'overwrite' $false)) {
                return [pscustomobject]@{ ok = $false; output = "ERROR: '$raw' already exists. Use EditFile for changes, or pass overwrite=true to replace it wholesale." }
            }
            $content = $content -replace "`r`n", "`n"
            $dir = Split-Path -Parent $p
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [System.IO.File]::WriteAllText($p, $content, [System.Text.UTF8Encoding]::new($false))
            $lines = ($content -split "`n").Count
            [pscustomobject]@{ ok = $true; output = "Wrote $raw ($lines lines, $($content.Length) chars)." }
        }
    }

    # ---------------------------------------------------------------- edit ----
    $reg['EditFile'] = @{
        Description = 'Replace exactly one occurrence of old_text with new_text in a file. old_text must be unique enough to identify the spot - include 2-4 lines of surrounding context. This is the preferred editing tool.'
        Parameters  = @{
            type = 'object'; required = @('path', 'old_text', 'new_text')
            properties = @{
                path     = @{ type = 'string' }
                old_text = @{ type = 'string'; description = 'Exact existing text, including indentation.' }
                new_text = @{ type = 'string'; description = 'Replacement text.' }
                replace_all = @{ type = 'boolean'; description = 'Replace every occurrence. Default false.' }
            }
        }
        Script      = {
            param($Args)
            $raw = Get-Arg $Args 'path'
            $p = Resolve-AgentPath -Path $raw
            $old = [string](Get-Arg $Args 'old_text' '')
            $new = [string](Get-Arg $Args 'new_text' '')
            $all = [bool](Get-Arg $Args 'replace_all' $false)

            if ([string]::IsNullOrEmpty($old)) { return [pscustomobject]@{ ok = $false; output = 'ERROR: old_text is empty.' } }

            $text = [System.IO.File]::ReadAllText($p)
            $crlf = $text.Contains("`r`n")
            $norm = $text -replace "`r`n", "`n"
            $oldN = $old -replace "`r`n", "`n"
            $newN = $new -replace "`r`n", "`n"

            $count = ([regex]::Matches($norm, [regex]::Escape($oldN))).Count
            if ($count -eq 0) {
                # Try whitespace-tolerant match so trailing spaces don't block the agent.
                $pattern = ($oldN -split "`n" | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '\s*\n\s*'
                $m = [regex]::Match($norm, $pattern)
                if (-not $m.Success) {
                    return [pscustomobject]@{ ok = $false; output = "ERROR: old_text not found in $raw. Read the file again and copy the exact text." }
                }
                $norm = $norm.Remove($m.Index, $m.Length).Insert($m.Index, $newN)
                $count = 1
            }
            elseif ($count -gt 1 -and -not $all) {
                return [pscustomobject]@{ ok = $false; output = "ERROR: old_text matches $count places in $raw. Add surrounding context, or pass replace_all=true." }
            }
            else {
                if ($all) { $norm = $norm.Replace($oldN, $newN) }
                else { $idx = $norm.IndexOf($oldN, [StringComparison]::Ordinal); $norm = $norm.Remove($idx, $oldN.Length).Insert($idx, $newN) }
            }

            if ($crlf) { $norm = $norm -replace "`n", "`r`n" }
            [System.IO.File]::WriteAllText($p, $norm, [System.Text.UTF8Encoding]::new($false))
            [pscustomobject]@{ ok = $true; output = "Edited $raw ($count replacement(s))." }
        }
    }

    # ---------------------------------------------------------------- list ----
    $reg['ListFiles'] = @{
        Description = 'List files and directories in the workspace as a tree. Use to orient yourself before planning.'
        Parameters  = @{
            type = 'object'
            properties = @{
                path      = @{ type = 'string'; description = 'Directory, default workspace root.' }
                pattern   = @{ type = 'string'; description = 'Wildcard filter, e.g. *.ps1 or *.cs. Default *.' }
                max_depth = @{ type = 'integer'; description = 'Default 3.' }
                max_items = @{ type = 'integer'; description = 'Default 300.' }
            }
        }
        Script      = {
            param($Args)
            $root = if (Get-Arg $Args 'path') { Resolve-AgentPath -Path (Get-Arg $Args 'path') } else { $script:Workspace }
            $pattern = [string](Get-Arg $Args 'pattern' '*')
            $depth = [int](Get-Arg $Args 'max_depth' 3)
            $maxItems = [int](Get-Arg $Args 'max_items' 300)
            $skip = @('node_modules', 'bin', 'obj', '.git', '.vs', 'packages', 'TestResults', '.agent')

            $results = [System.Collections.Generic.List[string]]::new()
            $walk = $null
            $walk = {
                param($dir, $level)
                if ($level -gt $depth) { return }
                $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
                    Where-Object { $skip -notcontains $_.Name } |
                    Sort-Object { -not $_.PSIsContainer }, Name
                foreach ($it in $items) {
                    if ($results.Count -ge $maxItems) { return }
                    $rel = $it.FullName.Substring($script:Workspace.Length).TrimStart('/', '\')
                    if ($it.PSIsContainer) {
                        $results.Add(('  ' * $level) + $it.Name + '/')
                        & $walk $it.FullName ($level + 1)
                    }
                    elseif ($pattern -eq '*' -or $it.Name -like $pattern) {
                        $results.Add(('  ' * $level) + ('{0}  ({1} B)' -f $it.Name, $it.Length))
                    }
                }
            }
            & $walk $root 0
            $out = if ($results.Count) { $results -join "`n" } else { '(no matching files)' }
            if ($results.Count -ge $maxItems) { $out += "`n...[capped at $maxItems items]" }
            [pscustomobject]@{ ok = $true; output = $out }
        }
    }

    # -------------------------------------------------------------- search ----
    $reg['SearchCode'] = @{
        Description = 'Regex search across workspace files. Returns file:line:match. Use to find usages before changing an API.'
        Parameters  = @{
            type = 'object'; required = @('pattern')
            properties = @{
                pattern    = @{ type = 'string'; description = '.NET regex.' }
                path       = @{ type = 'string'; description = 'Subdirectory to search. Default workspace.' }
                file_glob  = @{ type = 'string'; description = 'e.g. *.ps1,*.psm1,*.cs' }
                max_results = @{ type = 'integer'; description = 'Default 100.' }
                ignore_case = @{ type = 'boolean'; description = 'Default true.' }
            }
        }
        Script      = {
            param($Args)
            $pat = [string](Get-Arg $Args 'pattern')
            if (-not $pat) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pattern required' } }
            $root = if (Get-Arg $Args 'path') { Resolve-AgentPath -Path (Get-Arg $Args 'path') } else { $script:Workspace }
            $globs = @(([string](Get-Arg $Args 'file_glob' '*.ps1,*.psm1,*.psd1,*.cs,*.csproj,*.json,*.md,*.ps1xml')) -split ',' | ForEach-Object { $_.Trim() })
            $max = [int](Get-Arg $Args 'max_results' 100)
            $opts = if (Get-Arg $Args 'ignore_case' $true) { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase } else { 'None' }
            $rx = [regex]::new($pat, $opts)
            $skip = @('node_modules', 'bin', 'obj', '.git', '.vs', '.agent', 'TestResults')

            $hits = [System.Collections.Generic.List[string]]::new()
            $files = Get-ChildItem -LiteralPath $root -Recurse -File -Include $globs -ErrorAction SilentlyContinue |
                Where-Object { $skip -notcontains $_.Directory.Name -and $_.Length -lt 2MB }
            foreach ($f in $files) {
                $lineNo = 0
                foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
                    $lineNo++
                    if ($rx.IsMatch($line)) {
                        $rel = $f.FullName.Substring($script:Workspace.Length).TrimStart('/', '\')
                        $hits.Add(('{0}:{1}: {2}' -f $rel, $lineNo, $line.Trim()))
                        if ($hits.Count -ge $max) { break }
                    }
                }
                if ($hits.Count -ge $max) { break }
            }
            $out = if ($hits.Count) { $hits -join "`n" } else { 'No matches.' }
            [pscustomobject]@{ ok = $true; output = $out }
        }
    }

    # ------------------------------------------------------- execute a shell ----
    $reg['RunCommand'] = @{
        Description = 'Run a shell command in the workspace. Prefer the specific tools (RunBuild, RunTests, RunPwshAnalysis) when they apply. Use pwsh for PowerShell 7 scripts, powershell for Windows PowerShell 5.1 compatibility checks, bash for POSIX.'
        Parameters  = @{
            type = 'object'; required = @('command')
            properties = @{
                command     = @{ type = 'string'; description = 'The command line to execute.' }
                shell       = @{ type = 'string'; enum = @('pwsh', 'powershell', 'bash', 'cmd'); description = 'Default pwsh.' }
                working_dir = @{ type = 'string'; description = 'Relative to workspace. Default workspace root.' }
                timeout_sec = @{ type = 'integer'; description = 'Default from config.' }
                purpose     = @{ type = 'string'; description = 'One sentence: why this command is needed. Shown to the human at approval time.' }
            }
        }
        Script      = {
            param($Args)
            $cmd = [string](Get-Arg $Args 'command')
            $shell = [string](Get-Arg $Args 'shell' 'pwsh')
            $wd = if (Get-Arg $Args 'working_dir') { Resolve-AgentPath -Path (Get-Arg $Args 'working_dir') } else { $script:Workspace }
            $timeout = [int](Get-Arg $Args 'timeout_sec' $script:CommandTimeout)

            switch ($shell) {
                'pwsh' {
                    $exe = Resolve-PwshPath
                    if (-not $exe) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pwsh not found on this machine. Install PowerShell 7 or set agent.pwshPath in the config.' } }
                    $r = Invoke-CapturedProcess -FilePath $exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $cmd) -WorkingDirectory $wd -TimeoutSec $timeout
                }
                'powershell' {
                    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
                        return [pscustomobject]@{ ok = $false; output = 'ERROR: Windows PowerShell 5.1 is only available on Windows. Use pwsh for cross-version code, and validate 5.1 compatibility with RunPwshAnalysis -Target PowerShell51 (PSScriptAnalyzer flags 7-only syntax).' }
                    }
                    $exe = (Get-Command $script:Cfg.agent.windowsPowerShellPath -ErrorAction SilentlyContinue).Source
                    $r = Invoke-CapturedProcess -FilePath $exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $cmd) -WorkingDirectory $wd -TimeoutSec $timeout
                }
                'bash' {
                    $exe = if (Test-Path $script:Cfg.agent.posixShell) { $script:Cfg.agent.posixShell } else { '/bin/sh' }
                    $r = Invoke-CapturedProcess -FilePath $exe -ArgumentList @('-c', $cmd) -WorkingDirectory $wd -TimeoutSec $timeout
                }
                'cmd' {
                    $r = Invoke-CapturedProcess -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd) -WorkingDirectory $wd -TimeoutSec $timeout
                }
                default { return [pscustomobject]@{ ok = $false; output = "ERROR: unsupported shell '$shell'" } }
            }

            $ok = ($r.exitCode -eq 0)
            [pscustomobject]@{
                ok     = $ok
                output = ("exit=$($r.exitCode) time=$([math]::Round($r.duration,1))s`n$($r.output)")
            }
        }
    }

    # ---------------------------------------------------------------- build ----
    $reg['RunBuild'] = @{
        Description = 'Build a .NET project or solution with the dotnet CLI. Returns compiler diagnostics verbatim. Run this after any C# change.'
        Parameters  = @{
            type = 'object'
            properties = @{
                project    = @{ type = 'string'; description = 'Path to .csproj/.sln/dir. Default: current directory.' }
                configuration = @{ type = 'string'; enum = @('Debug', 'Release'); description = 'Default Debug.' }
                extra_args = @{ type = 'string'; description = 'Extra msbuild args, e.g. "-p:LangVersion=latest".' }
                restore    = @{ type = 'boolean'; description = 'Run restore first. Default true.' }
                no_incremental = @{ type = 'boolean'; description = 'Force a full rebuild. Default false.' }
            }
        }
        Script      = {
            param($Args)
            $dotnet = Resolve-DotnetPath
            $args_ = [System.Collections.Generic.List[string]]::new()
            $args_.Add('build')
            if (Get-Arg $Args 'project') { $args_.Add((Resolve-AgentPath -Path (Get-Arg $Args 'project') -AllowMissing)) }
            $args_.Add('-c'); $args_.Add([string](Get-Arg $Args 'configuration' 'Debug'))
            if (Get-Arg $Args 'no_incremental' $false) { $args_.Add('--no-incremental') }
            if (-not (Get-Arg $Args 'restore' $true)) { $args_.Add('--no-restore') }
            $args_.Add('-v'); $args_.Add('minimal')
            $args_.Add('-nologo')
            if (Get-Arg $Args 'extra_args') { foreach ($x in ([string](Get-Arg $Args 'extra_args')) -split ' ') { if ($x) { $args_.Add($x) } } }

            $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList $args_.ToArray() -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            [pscustomobject]@{
                ok     = ($r.exitCode -eq 0)
                output = ("dotnet $($args_ -join ' ')`nexit=$($r.exitCode)`n$($r.output)")
            }
        }
    }

    # ---------------------------------------------------------------- tests ----
    $reg['RunTests'] = @{
        Description = 'Run tests. kind=pester runs Invoke-Pester on the given path; kind=dotnet runs dotnet test.'
        Parameters  = @{
            type = 'object'
            properties = @{
                kind      = @{ type = 'string'; enum = @('pester', 'dotnet'); description = 'Default pester.' }
                path      = @{ type = 'string'; description = 'Test file/dir (pester) or project (dotnet). Default the tests/ folder or workspace.' }
                filter    = @{ type = 'string'; description = 'Pester -FullNameFilter / dotnet --filter expression.' }
                coverage  = @{ type = 'boolean'; description = 'Pester: enable CodeCoverage on the module. Default false.' }
            }
        }
        Script      = {
            param($Args)
            $kind = [string](Get-Arg $Args 'kind' 'pester')

            if ($kind -eq 'dotnet') {
                $dotnet = Resolve-DotnetPath
                $a = [System.Collections.Generic.List[string]]::new()
                $a.Add('test')
                if (Get-Arg $Args 'path') { $a.Add((Resolve-AgentPath -Path (Get-Arg $Args 'path') -AllowMissing)) }
                $a.Add('--nologo')
                $a.Add('-v'); $a.Add('minimal')
                if (Get-Arg $Args 'filter') { $a.Add('--filter'); $a.Add([string](Get-Arg $Args 'filter')) }
                $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList $a.ToArray() -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
                return [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("dotnet $($a -join ' ')`nexit=$($r.exitCode)`n$($r.output)") }
            }

            $pwsh = Resolve-PwshPath
            if (-not $pwsh) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pwsh not found.' } }
            $target = if (Get-Arg $Args 'path') { Resolve-AgentPath -Path (Get-Arg $Args 'path') } else {
                $t = Join-Path $script:Workspace 'tests'
                if (Test-Path $t) { $t } else { $script:Workspace }
            }
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine("Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop")
            $invoke = "`$config = New-PesterConfiguration; `$config.Run.Path = @('" + ($target -replace "'", "''") + "'); `$config.Output.Verbosity = 'Normal'; `$config.Run.PassThru = `$true"
            [void]$sb.AppendLine($invoke)
            if (Get-Arg $Args 'filter') { [void]$sb.AppendLine("`$config.Filter.FullName = @('" + ([string](Get-Arg $Args 'filter')) + "')") }
            if (Get-Arg $Args 'coverage' $false) {
                $src = Join-Path $script:Workspace 'src'
                if (Test-Path $src) {
                    [void]$sb.AppendLine("`$config.CodeCoverage.Enabled = `$true")
                    [void]$sb.AppendLine("`$config.CodeCoverage.Path = @('" + ($src -replace "'", "''") + "')")
                }
            }
            [void]$sb.AppendLine('$res = Invoke-Pester -Configuration $config')
            [void]$sb.AppendLine('"PASSED=$($res.PassedCount) FAILED=$($res.FailedCount) SKIPPED=$($res.SkippedCount)"')
            [void]$sb.AppendLine('if ($res.FailedCount -gt 0) { exit 1 }')

            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-" + [guid]::NewGuid() + ".ps1")
            [System.IO.File]::WriteAllText($tmp, $sb.ToString())
            try {
                $r = Invoke-CapturedProcess -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $tmp) -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            }
            finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }

            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("Invoke-Pester -Path '$target'`nexit=$($r.exitCode)`n$($r.output)") }
        }
    }

    # ------------------------------------------------------------- analysis ----
    $reg['RunPwshAnalysis'] = @{
        Description = 'Run PSScriptAnalyzer against a script/module and report rule violations. With target=PowerShell51 it additionally flags syntax that breaks Windows PowerShell 5.1 (ternary, ??, ?., -Parallel, &&/||).'
        Parameters  = @{
            type = 'object'; required = @('path')
            properties = @{
                path   = @{ type = 'string'; description = 'File or directory to analyse.' }
                target = @{ type = 'string'; enum = @('PowerShell51', 'PowerShell7', 'Both'); description = 'Compatibility target. Default Both.' }
                severity = @{ type = 'string'; enum = @('Error', 'Warning', 'Information', 'ParseError'); description = 'Minimum severity. Default Warning.' }
            }
        }
        Script      = {
            param($Args)
            $p = Resolve-AgentPath -Path (Get-Arg $Args 'path')
            $target = [string](Get-Arg $Args 'target' 'Both')
            $sev = [string](Get-Arg $Args 'severity' 'Warning')
            $pwsh = Resolve-PwshPath
            if (-not $pwsh) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pwsh not found.' } }

            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine(@"
`$ErrorActionPreference='Stop'
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
  try { Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop }
  catch { Write-Output "ERROR: PSScriptAnalyzer unavailable: `$(`$_.Exception.Message)"; exit 2 }
}
Import-Module PSScriptAnalyzer
`$settings = @{ IncludeRules = @('PSUseCompatibleSyntax','PSUseCompatibleCommands','PSUseCompatibleTypes','PSAvoidUsingWriteHost','PSUseApprovedVerbs','PSAvoidUsingInvokeExpression','PSAvoidGlobalVars','PSUseSingularNouns','PSAvoidUsingPositionalParameters','PSAvoidAssignmentToAutomaticVariable') ; Severity = @('Error','Warning','Information','ParseError') }
`$r = Invoke-ScriptAnalyzer -Path '$($p -replace "'", "''")' -Recurse -Severity '$sev' -Settings `$settings
"@)
            if ($target -in @('PowerShell51', 'Both')) {
                [void]$sb.AppendLine(@"
`$compat = Invoke-ScriptAnalyzer -Path '$($p -replace "'", "''")' -Recurse -Settings @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = `$true; TargetVersions = @('5.1','7.0') } } } -ErrorAction SilentlyContinue
`$r = @(`$r) + @(`$compat)
"@)
            }
            [void]$sb.AppendLine(@'
$r = @($r | Where-Object { $_ } | Sort-Object ScriptName, Line -Unique)
if ($r.Count -eq 0) { Write-Output 'CLEAN: no violations.'; exit 0 }
$errs = @($r | Where-Object Severity -eq 'Error').Count
$r | ForEach-Object { "{0}:{1} [{2}] {3} - {4}" -f ($_.ScriptName -replace [regex]::Escape($PWD.Path + [IO.Path]::DirectorySeparatorChar), ''), $_.Line, $_.Severity, $_.RuleName, $_.Message }
Write-Output ""
Write-Output "TOTAL=$($r.Count) ERRORS=$errs"
if ($errs -gt 0) { exit 1 }
'@)

            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("psa-" + [guid]::NewGuid() + ".ps1")
            [System.IO.File]::WriteAllText($tmp, $sb.ToString())
            try {
                $r = Invoke-CapturedProcess -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $tmp) -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            }
            finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("PSScriptAnalyzer target=$target path=$p`n$($r.output)") }
        }
    }

    # -------------------------------------------------------------- inspect ----
    $reg['InspectPowerShell'] = @{
        Description = 'Ask the local PowerShell for ground truth: resolve a command, its parameters, type members, or see available modules. Use this instead of guessing an API.'
        Parameters  = @{
            type = 'object'; required = @('query')
            properties = @{
                query = @{ type = 'string'; description = 'PowerShell expression to evaluate read-only, e.g. "Get-Command Invoke-RestMethod -Syntax" or "[System.IO.File]::ReadAllLines | Get-Member -Static".' }
            }
        }
        Script      = {
            param($Args)
            $q = [string](Get-Arg $Args 'query')
            $pwsh = Resolve-PwshPath
            if (-not $pwsh) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pwsh not found.' } }
            $r = Invoke-CapturedProcess -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $q) -WorkingDirectory $script:Workspace -TimeoutSec 120
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = $r.output }
        }
    }

    # ----------------------------------------------------------- scaffolds ----
    $reg['DotnetNew'] = @{
        Description = 'Scaffold a new .NET project with dotnet new. Templates: classlib, console, xunit, nunit, mstest, web, webapi, worker, sln, gitignore, editorconfig, nugetconfig.'
        Parameters  = @{
            type = 'object'; required = @('template', 'name')
            properties = @{
                template  = @{ type = 'string' }
                name      = @{ type = 'string' }
                output    = @{ type = 'string'; description = 'Output directory. Default ./src/<name>.' }
                framework = @{ type = 'string'; description = 'e.g. net9.0, net8.0, netstandard2.0' }
                extra_args = @{ type = 'string' }
            }
        }
        Script      = {
            param($Args)
            $tpl = [string](Get-Arg $Args 'template')
            $name = [string](Get-Arg $Args 'name')
            $out = [string](Get-Arg $Args 'output' (Join-Path 'src' $name))
            $dotnet = Resolve-DotnetPath
            $a = [System.Collections.Generic.List[string]]::new()
            $a.Add('new'); $a.Add($tpl); $a.Add('-n'); $a.Add($name); $a.Add('-o'); $a.Add((Resolve-AgentPath -Path $out -AllowMissing))
            if (Get-Arg $Args 'framework') { $a.Add('-f'); $a.Add([string](Get-Arg $Args 'framework')) }
            foreach ($x in ([string](Get-Arg $Args 'extra_args' '')) -split ' ') { if ($x) { $a.Add($x) } }
            $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList $a.ToArray() -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("dotnet $($a -join ' ')`nexit=$($r.exitCode)`n$($r.output)") }
        }
    }

    $reg['AddPackage'] = @{
        Description = 'Add a NuGet package reference to a project.'
        Parameters  = @{
            type = 'object'; required = @('project', 'package')
            properties = @{
                project = @{ type = 'string' }
                package = @{ type = 'string' }
                version = @{ type = 'string' }
            }
        }
        Script      = {
            param($Args)
            $dotnet = Resolve-DotnetPath
            $a = @('add', (Resolve-AgentPath -Path (Get-Arg $Args 'project')), 'package', [string](Get-Arg $Args 'package'))
            if (Get-Arg $Args 'version') { $a += @('--version', [string](Get-Arg $Args 'version')) }
            $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList $a -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("dotnet $($a -join ' ')`nexit=$($r.exitCode)`n$($r.output)") }
        }
    }

    # ----------------------------------------------------------------- git ----
    $reg['GitInfo'] = @{
        Description = 'Read-only git inspection: status, diff, log, branch, show. Never mutates the repository.'
        Parameters  = @{
            type = 'object'; required = @('op')
            properties = @{
                op     = @{ type = 'string'; enum = @('status', 'diff', 'diff-staged', 'log', 'branch', 'show') }
                target = @{ type = 'string'; description = 'Pathspec or revision. Optional.' }
                count  = @{ type = 'integer'; description = 'For log: number of commits. Default 10.' }
            }
        }
        Script      = {
            param($Args)
            $git = $script:Cfg.agent.gitPath
            $op = [string](Get-Arg $Args 'op')
            $a = switch ($op) {
                'status' { @('status', '--short', '--branch') }
                'diff' { @('diff', '--stat', '--patch') + @(if (Get-Arg $Args 'target') { Get-Arg $Args 'target' }) }
                'diff-staged' { @('diff', '--cached', '--stat', '--patch') }
                'log' { @('log', "--max-count=$([int](Get-Arg $Args 'count' 10))", '--pretty=format:%h %ad %s', '--date=short') }
                'branch' { @('branch', '--all', '-vv') }
                'show' { @('show', '--stat', '--patch', [string](Get-Arg $Args 'target' 'HEAD')) }
                default { @('status') }
            }
            $r = Invoke-CapturedProcess -FilePath $git -ArgumentList $a -WorkingDirectory $script:Workspace -TimeoutSec 60
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = $r.output }
        }
    }

    # ---------------------------------------------------------------- todo ----
    $reg['UpdateTodo'] = @{
        Description = 'Publish your plan/checklist to the human. Call this first for anything non-trivial, and again whenever a step completes. States: pending, in_progress, done.'
        Parameters  = @{
            type = 'object'; required = @('items')
            properties = @{
                items = @{
                    type  = 'array'
                    items = @{
                        type = 'object'; required = @('step', 'state')
                        properties = @{
                            step  = @{ type = 'string' }
                            state = @{ type = 'string'; enum = @('pending', 'in_progress', 'done') }
                        }
                    }
                }
            }
        }
        Script      = {
            param($Args)
            $items = @(Get-Arg $Args 'items' @())
            $icon = @{ done = '[x]'; in_progress = '[~]'; pending = '[ ]' }
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine('# Agent plan')
            [void]$sb.AppendLine("_updated $(Get-Date -Format 'u')_")
            [void]$sb.AppendLine('')
            foreach ($i in $items) { [void]$sb.AppendLine(('{0} {1}' -f $icon[[string]$i.state], $i.step)) }
            $path = Join-Path $script:Workspace $script:Cfg.agent.todoFile
            $dir = Split-Path -Parent $path
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [System.IO.File]::WriteAllText($path, $sb.ToString())
            $done = @($items | Where-Object state -eq 'done').Count
            [pscustomobject]@{ ok = $true; output = ("Plan updated ($done/$($items.Count) done).`n" + ($items | ForEach-Object { '{0} {1}' -f $icon[[string]$_.state], $_.step }) -join "`n") }
        }
    }

    # --------------------------------------------------------- ask a human ----
    $reg['AskUser'] = @{
        Description = 'Ask the human a question and wait for the answer. Use when the task is genuinely ambiguous (target framework, naming, breaking-change policy). Do not use it to ask permission for tool calls - that is automatic.'
        Parameters  = @{
            type = 'object'; required = @('question')
            properties = @{
                question = @{ type = 'string' }
                options  = @{ type = 'array'; items = @{ type = 'string' }; description = 'Optional suggested answers.' }
            }
        }
        Script      = {
            param($Args)
            $q = [string](Get-Arg $Args 'question')
            $opts = @(Get-Arg $Args 'options' @())
            Write-Host ''
            Write-Host '  AGENT ASKS: ' -ForegroundColor Magenta -NoNewline
            Write-Host $q -ForegroundColor White
            if ($opts.Count) { for ($i = 0; $i -lt $opts.Count; $i++) { Write-Host "    $($i+1)) $($opts[$i])" -ForegroundColor DarkGray } }
            $answer = Read-Host '  your answer'
            [pscustomobject]@{ ok = $true; output = "USER ANSWER: $answer" }
        }
    }

    return $reg
}
