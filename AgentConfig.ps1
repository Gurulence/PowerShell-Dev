<#
    AgentConfig.ps1  -  config loading + merge with sensible defaults.
#>

function Read-AgentConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $user = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json

    # Defaults first, user file overrides, so a partial config still works.
    $defaults = [pscustomobject]@{
        provider = [pscustomobject]@{
            name              = 'openai'
            baseUrl           = 'https://api.openai.com/v1'
            model             = 'gpt-4.1'
            apiKeyEnv         = 'OPENAI_API_KEY'
            apiKeyHeader      = 'Authorization'
            apiKeyPrefix      = 'Bearer '
            extraHeaders      = @{}
            temperature       = 0.2
            maxTokens         = 4096
            maxTokensParam    = 'max_tokens'
            requestTimeoutSec = 240
            maxRetries        = 3
        }
        agent    = [pscustomobject]@{
            mode                   = 'hybrid'
            maxTurns               = 40
            maxContextChars        = 120000
            approvalGate           = 'all'
            allowOutsideWorkspace  = $false
            commandTimeoutSec      = 300
            maxToolOutputChars     = 12000
            logDir                 = '.agent/logs'
            sessionDir             = '.agent/sessions'
            todoFile               = '.agent/todo.md'
            pwshPath               = 'pwsh'
            windowsPowerShellPath  = 'powershell'
            posixShell             = '/bin/bash'
            dotnetPath             = 'dotnet'
            gitPath                = 'git'
            denyPatterns           = @()
        }
    }

    $cfg = [pscustomobject]@{}
    foreach ($section in @('provider', 'agent')) {
        $merged = [ordered]@{}
        foreach ($prop in $defaults.$section.PSObject.Properties) { $merged[$prop.Name] = $prop.Value }
        if ($user.PSObject.Properties.Name -contains $section -and $user.$section) {
            foreach ($prop in $user.$section.PSObject.Properties) { $merged[$prop.Name] = $prop.Value }
        }
        $cfg | Add-Member -NotePropertyName $section -NotePropertyValue ([pscustomobject]$merged)
    }

    if ([string]::IsNullOrWhiteSpace($cfg.agent.denyPatterns -join '')) { $cfg.agent.denyPatterns = @() }
    return $cfg
}

function Get-AgentSecret {
    <#
        Keep secrets out of config files. Reads the env var named in the config;
        falls back to Windows Credential Manager / DPAPI-protected file if present.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EnvName)

    $v = [Environment]::GetEnvironmentVariable($EnvName)
    if ($v) { return $v }

    $store = Join-Path $HOME '.agent/secrets.xml'
    if (Test-Path $store) {
        try {
            $all = Import-Clixml -LiteralPath $store
            if ($all.ContainsKey($EnvName)) { return $all[$EnvName] }
        }
        catch { }
    }
    return $null
}
