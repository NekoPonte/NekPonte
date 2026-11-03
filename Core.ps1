# Funcoes de configuracao e transporte. Compativel com Windows PowerShell 5.1.
function Normalize-Route([string]$Value) {
    $Value = $Value.Trim().Trim('/')
    if (-not $Value) { return '' }
    if ($Value -notmatch '^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$') {
        throw 'O prefixo deve conter apenas letras, numeros, hifens, sublinhados e barras. Exemplo: /minha-mesa'
    }
    return '/' + $Value
}
function Normalize-FixedUrl([string]$Value) {
    $Value = $Value.Trim()
    if ($Value -notmatch '^https?://') { $Value = 'https://' + $Value }
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { throw 'Informe um endereco valido, como https://mesa.seudominio.com.' }
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or -not $uri.IsDefaultPort -or $uri.AbsolutePath -ne '/') {
        throw 'Use somente o endereco HTTPS do dominio, sem caminho, porta, usuario ou parametros. O prefixo possui um campo separado.'
    }
    $name = $uri.DnsSafeHost.ToLowerInvariant()
    if ($name.Length -gt 253 -or $name -notmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') {
        throw 'Informe um dominio publico valido, como mesa.seudominio.com.'
    }
    return 'https://' + $name
}
function Normalize-TunnelToken([string]$Value) {
    $Value = $Value.Trim()
    # Aceita o token sozinho ou o comando de instalacao copiado do painel.
    if ($Value -match '(?:--token(?:=|\s+)|service\s+install\s+)["'']?([A-Za-z0-9_+/=-]{40,8192})') { $Value = $Matches[1] }
    if ($Value -notmatch '^[A-Za-z0-9_+/=-]{40,8192}$') {
        throw 'Cole o token do tunel Cloudflare. Tambem pode colar o comando de instalacao exibido no painel. Nao use uma chave API da conta.'
    }
    return $Value
}
function Protect-Log([string]$Text, [string]$Token) {
    if ($Token) { $Text = $Text.Replace($Token, '[token oculto]') }
    $Text = [regex]::Replace($Text, '(?i)((?:--token(?:=|\s+)|TUNNEL_TOKEN=|token:))[^\s\],]+', '$1[oculto]')
    return $Text
}
function Get-TunnelArguments([string]$Mode, [string]$ConfigPath, [int]$Port) {
    $common = 'tunnel --config "{0}" --no-autoupdate --protocol http2' -f $ConfigPath
    if ($Mode -eq 'fixed') { return $common + ' run' }
    return $common + (' --url http://127.0.0.1:{0}' -f $Port)
}
function Write-Settings([string]$Path, $Settings) {
    $temp = $Path + '.tmp'
    try {
        $Settings | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}
function Get-ConnectionState([string]$Line) {
    if ($Line -match 'Registered tunnel connection') { return 'connected' }
    if ($Line -match 'Unable to reach the origin service|failed to serve incoming request') { return 'origin-error' }
    if ($Line -match 'connection terminated|Connection terminated|failed to serve tunnel connection|Failed to dial a quic connection|Unable to establish connection|Lost connection with the edge') { return 'reconnecting' }
    return ''
}

# Preparacao em processo separado para manter a interface responsiva.
$script:prepare = {
    param($Root, $Port, $Route)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $temp = $null
    try {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:${Port}${Route}/" -TimeoutSec 6
            if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 400) { throw 'HTTP inesperado' }
        } catch {
            throw "O Foundry nao respondeu em http://127.0.0.1:${Port}${Route}/. Abra o Foundry e confira a porta nas configuracoes. Esta versao espera um servidor HTTP local."
        }
        $exe = Join-Path $Root 'cloudflared.exe'
        $metadata = Join-Path $Root 'download.json'
        $cached = $false
        if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $metadata)) {
            try {
                $saved = Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json
                $actual = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
                $age = [DateTime]::UtcNow - [DateTime]::Parse($saved.downloadedUtc).ToUniversalTime()
                $cached = ($actual -eq $saved.sha256 -and $age.TotalDays -lt 30)
            } catch { $cached = $false }
        }
        if (-not $cached) {
            $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
            $assetName = "cloudflared-windows-$arch.exe"
            $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/cloudflare/cloudflared/releases/latest' -Headers @{'User-Agent'='NekoPonte/2.0.1'} -TimeoutSec 40
            $asset = @($release.assets | Where-Object { $_.name -eq $assetName })
            if ($asset.Count -ne 1) { throw 'O executavel oficial para este Windows nao foi encontrado.' }
            $downloadUrl = [string]$asset[0].browser_download_url
            if ($downloadUrl -notmatch '^https://github\.com/cloudflare/cloudflared/releases/download/') { throw 'Endereco de download oficial inesperado.' }
            $temp = Join-Path $Root ('download-' + [Guid]::NewGuid().ToString('N') + '.exe')
            Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $temp -TimeoutSec 180
            $hash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
            $digest = [string]$asset[0].digest
            if ($digest -match '^sha256:([a-fA-F0-9]{64})$') {
                if ($hash -ne $Matches[1]) { throw 'O download falhou na verificacao SHA-256. Tente novamente.' }
            } else {
                $signature = Get-AuthenticodeSignature -LiteralPath $temp
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Cloudflare') {
                    throw 'Nao foi possivel verificar a autenticidade do componente oficial. Nenhum executavel novo foi iniciado.'
                }
            }
            Move-Item -LiteralPath $temp -Destination $exe -Force
            $temp = $null
            @{sha256=$hash; version=$release.tag_name; downloadedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $metadata -Encoding UTF8
        }
        [pscustomobject]@{Ok=$true; Error=''}
    } catch {
        [pscustomobject]@{Ok=$false; Error=$_.Exception.Message}
    } finally {
        if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}
