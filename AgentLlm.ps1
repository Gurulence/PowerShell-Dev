<#
    AgentLlm.ps1  -  OpenAI-compatible chat completions client with retry/backoff.
    Works against: OpenAI, Azure OpenAI, OpenRouter, Groq, Together, Ollama, LM Studio, vLLM.
#>

function ConvertTo-LlmMessage {
    <#
        Normalises our internal message hashtables into the wire shape. Keeps the
        tool_calls array intact and never sends $null content where the API rejects it.
    #>
    param($Message)

    $out = [ordered]@{ role = $Message.role }
    if ($Message.ContainsKey('content')) { $out.content = $Message.content }
    if ($Message.ContainsKey('tool_calls') -and $Message.tool_calls) {
        $out.tool_calls = @($Message.tool_calls | ForEach-Object {
                [ordered]@{
                    id       = $_.id
                    type     = 'function'
                    function = [ordered]@{ name = $_.function.name; arguments = [string]$_.function.arguments }
                }
            })
        if ($null -eq $out.content) { $out.content = '' }
    }
    if ($Message.ContainsKey('tool_call_id')) { $out.tool_call_id = $Message.tool_call_id }
    return [pscustomobject]$out
}

function Invoke-ChatCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][object[]]$Messages,
        [object[]]$Tools,
        [string]$ApiKey,
        [switch]$DryRun
    )

    $p = $Config.provider
    $endpoint = ($p.baseUrl.TrimEnd('/')) + '/chat/completions'

    $wire = @($Messages | ForEach-Object { ConvertTo-LlmMessage -Message $_ })

    $body = [ordered]@{
        model    = $p.model
        messages = $wire
        stream   = $false
    }
    if ($Tools -and $Tools.Count -gt 0) {
        $body.tools = $Tools
        $body.tool_choice = 'auto'
    }
    # Azure/GPT-5-class endpoints reject 'max_tokens'; config makes this switchable.
    if ($p.maxTokens -gt 0) { $body[$p.maxTokensParam] = [int]$p.maxTokens }
    if ($null -ne $p.temperature -and $p.temperature -ge 0) { $body.temperature = [double]$p.temperature }

    $json = $body | ConvertTo-Json -Depth 30 -Compress

    if ($DryRun) {
        Write-Host "[dry-run] POST $endpoint  ($($json.Length) bytes, $($wire.Count) messages)" -ForegroundColor DarkGray
        return [pscustomobject]@{
            choices = @([pscustomobject]@{
                    message = [pscustomobject]@{
                        content    = '[dry-run] model not called. The agent loop, config, prompt assembly and tool schemas all loaded correctly.'
                        tool_calls = $null
                    }
                })
            usage   = $null
        }
    }

    $headers = @{
        $p.apiKeyHeader = $p.apiKeyPrefix + $ApiKey
        'Content-Type'  = 'application/json'
    }
    foreach ($h in $p.extraHeaders.PSObject.Properties) { $headers[$h.Name] = [string]$h.Value }
    if ($p.name -eq 'azure') { $headers['api-key'] = $ApiKey; $headers.Remove('Authorization') }

    $attempt = 0
    $maxAttempts = [Math]::Max(1, [int]$p.maxRetries)
    $lastError = $null

    while ($attempt -lt $maxAttempts) {
        $attempt++
        try {
            $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $json `
                -ContentType 'application/json' -TimeoutSec ([int]$p.requestTimeoutSec)
            return $resp
        }
        catch {
            $lastError = $_
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }

            # 4xx (except 429) will not fix themselves - surface them immediately.
            $retryable = ($null -eq $status) -or ($status -eq 429) -or ($status -ge 500)
            $detail = ''
            try {
                $stream = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($stream) { $detail = $stream }
            }
            catch { }
            if (-not $detail) { $detail = $_.Exception.Message }

            if (-not $retryable -or $attempt -ge $maxAttempts) {
                throw "LLM request failed (HTTP $status) after $attempt attempt(s): $detail"
            }
            $wait = [Math]::Min(30, [Math]::Pow(2, $attempt)) + (Get-Random -Maximum 3)
            Write-Host "  ! HTTP $status - retry $attempt/$maxAttempts in ${wait}s" -ForegroundColor Yellow
            Start-Sleep -Seconds $wait
        }
    }
    throw "LLM request failed: $($lastError.Exception.Message)"
}
