# NekoPonte 2.0.1 - aplicacao Windows portatil, sem Python ou Node.js.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
trap {
    [System.Windows.MessageBox]::Show($_.Exception.Message, 'NekoPonte - nao foi possivel continuar', 'OK', 'Error') | Out-Null
    exit 1
}
. (Join-Path $PSScriptRoot 'Core.ps1')
Add-Type -Path (Join-Path $PSScriptRoot 'ProcessLifetime.cs')
[NekoPonte.ProcessLifetime]::SetApplicationIdentity()
$created = $false
# Compartilhado com a versao antiga para impedir duas pontes simultaneas.
$mutex = New-Object System.Threading.Mutex($true, 'Local\FoundryPonteGuiV1', [ref]$created)
if (-not $created) {
    [System.Windows.MessageBox]::Show('A NekoPonte ou a versao antiga ja esta aberta. Feche-a antes de abrir outra.', 'NekoPonte') | Out-Null
    $mutex.Dispose()
    exit 0
}
$script:root = Join-Path $env:LOCALAPPDATA 'NekoPonte'
[IO.Directory]::CreateDirectory($script:root) | Out-Null
$script:exe = Join-Path $script:root 'cloudflared.exe'
$script:settingsPath = Join-Path $script:root 'configuracao.json'
$script:logPath = Join-Path $script:root 'ponte.log'
$script:state = 'idle'
$script:worker = $null
$script:tunnel = $null
$script:lifetime = $null
$script:reads = @{}
$script:url = ''
$script:secret = ''
$script:active = $null
$script:started = $null
$script:lastConnected = $null
$script:connectionIds = @{}
$script:session = $null
$script:publicCheck = $null
$script:publicCheckStarted = $null
$script:publicCheckDone = $false
$script:lastOriginError = $null

[xml]$xml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Interface.xaml') -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader($xml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$reader.Close()
$controls = @('Backdrop','Avatar','TemporaryMode','FixedMode','ModeHint','FixedPanel','FixedUrl','TokenBox','SaveConfig','ForgetToken','PortBox','RouteBox','StartButton','StopButton','StatusDot','StatusText','StatusDetail','PublicLink','CopyButton','OpenButton','LogBox','LogsButton','HelpButton')
foreach ($name in $controls) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }
$imagePath = Join-Path $PSScriptRoot 'assets\neko-original.png'
$bitmap = New-Object Windows.Media.Imaging.BitmapImage
$bitmap.BeginInit()
$bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$bitmap.UriSource = New-Object Uri($imagePath, [UriKind]::Absolute)
$bitmap.EndInit()
$bitmap.Freeze()
$Backdrop.Source = $bitmap
# Recorte de visualizacao, mantendo a imagem original intacta.
$crop = New-Object Windows.Media.Imaging.CroppedBitmap($bitmap, (New-Object Windows.Int32Rect(300, 35, 670, 570)))
$crop.Freeze()
$Avatar.Source = $crop
$iconPath = Join-Path $PSScriptRoot 'assets\NekoPonte.ico'
$window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri($iconPath, [UriKind]::Absolute)))

function Set-Status([string]$Title, [string]$Detail, [string]$Color = '#B997CA') {
    $StatusText.Text = $Title
    $StatusDetail.Text = $Detail
    $StatusDot.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}
function Add-Log([string]$Text) {
    $Text = Protect-Log $Text $script:secret
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Text
    if ($LogBox.Text.Length -gt 42000) { $LogBox.Text = $LogBox.Text.Substring($LogBox.Text.Length - 21000) }
    $LogBox.AppendText($line + [Environment]::NewLine)
    $LogBox.ScrollToEnd()
    try {
        if ((Test-Path -LiteralPath $script:logPath) -and (Get-Item -LiteralPath $script:logPath).Length -gt 2MB) {
            Move-Item -LiteralPath $script:logPath -Destination ($script:logPath + '.anterior') -Force
        }
        [IO.File]::AppendAllText($script:logPath, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    } catch { }
}
function Update-Mode {
    if ($FixedMode.IsChecked) {
        $FixedPanel.Visibility = 'Visible'
        $ModeHint.Text = 'O mesmo endereco em todas as sessoes. Requer dominio e tunel configurados na sua conta Cloudflare.'
    } else {
        $FixedPanel.Visibility = 'Collapsed'
        $ModeHint.Text = 'Sem conta. A Cloudflare escolhe um endereco diferente a cada inicio.'
    }
}
function Get-Options {
    $number = 0
    if (-not [int]::TryParse($PortBox.Text.Trim(), [ref]$number) -or $number -lt 1 -or $number -gt 65535) { throw 'A porta do Foundry deve ser um numero de 1 a 65535.' }
    $route = Normalize-Route $RouteBox.Text
    $mode = if ($FixedMode.IsChecked) { 'fixed' } else { 'temporary' }
    $address = ''
    $token = ''
    if ($mode -eq 'fixed') {
        $address = Normalize-FixedUrl $FixedUrl.Text
        $token = Normalize-TunnelToken $TokenBox.Password
    }
    return [pscustomobject]@{Mode=$mode; Port=$number; Route=$route; Address=$address; Token=$token}
}
function Save-Options($Options) {
    $encrypted = ''
    # O DPAPI usado por ConvertFrom-SecureString sem -Key protege no Windows.
    if ($Options.Mode -eq 'fixed' -and $TokenBox.Password) {
        $token = Normalize-TunnelToken $TokenBox.Password
        $encrypted = ConvertFrom-SecureString (ConvertTo-SecureString $token -AsPlainText -Force)
    } elseif (Test-Path -LiteralPath $script:settingsPath) {
        try { $encrypted = (Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json).encryptedToken }
        catch { $encrypted = '' }
    }
    $settings = @{version=2; mode=$Options.Mode; port=$Options.Port; route=$Options.Route; address=$FixedUrl.Text.Trim(); encryptedToken=$encrypted}
    Write-Settings $script:settingsPath $settings
}
function Set-Busy([bool]$Busy) {
    foreach ($control in @($TemporaryMode,$FixedMode,$FixedUrl,$TokenBox,$SaveConfig,$ForgetToken,$PortBox,$RouteBox,$StartButton)) { $control.IsEnabled = -not $Busy }
    $StopButton.IsEnabled = $Busy
}
function Remove-Worker([ref]$Job) {
    if ($Job.Value) {
        Stop-Job -Job $Job.Value -ErrorAction SilentlyContinue
        Remove-Job -Job $Job.Value -Force -ErrorAction SilentlyContinue
        $Job.Value = $null
    }
}
function Stop-Bridge {
    Remove-Worker ([ref]$script:worker)
    Remove-Worker ([ref]$script:publicCheck)
    if ($script:lifetime) { $script:lifetime.Dispose(); $script:lifetime = $null }
    if ($script:tunnel) {
        try {
            if (-not $script:tunnel.HasExited) { $script:tunnel.Kill() }
            $script:tunnel.WaitForExit(1500) | Out-Null
        } catch { }
        $script:tunnel.Dispose()
        $script:tunnel = $null
    }
    $script:reads = @{}
    $script:state = 'idle'
    $script:url = ''
    $script:secret = ''
    $script:active = $null
    $script:connectionIds = @{}
    $script:publicCheckDone = $false
    $script:lastOriginError = $null
    $PublicLink.Text = ''
    $CopyButton.IsEnabled = $false
    $OpenButton.IsEnabled = $false
    Set-Busy $false
    if ($script:session -and (Test-Path -LiteralPath $script:session)) {
        Remove-Item -LiteralPath $script:session -Recurse -Force -ErrorAction SilentlyContinue
        $script:session = $null
    }
}
function Start-PublicCheck {
    if ($script:publicCheck -or $script:publicCheckDone -or -not $script:url) { return }
    $script:publicCheckStarted = [DateTime]::UtcNow
    $script:publicCheck = Start-Job -ArgumentList $script:url -ScriptBlock {
        param($Address)
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        for ($attempt=0; $attempt -lt 3; $attempt++) {
            try {
                $r = Invoke-WebRequest -UseBasicParsing -Uri $Address -TimeoutSec 8
                return [pscustomobject]@{Ok=$true; Code=[int]$r.StatusCode}
            } catch {
                # Uma rota protegida tambem confirma resposta HTTP do destino.
                $code = 0
                if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                if ($code -eq 401 -or $code -eq 403) { return [pscustomobject]@{Ok=$true; Code=$code} }
            }
            if ($attempt -lt 2) { Start-Sleep -Seconds 2 }
        }
        return [pscustomobject]@{Ok=$false; Code=$code}
    }
}
function Launch-Tunnel {
    $script:session = Join-Path $script:root ('session-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($script:session) | Out-Null
    $config = Join-Path $script:session 'empty.yml'
    [IO.File]::WriteAllText($config, '{}')
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:exe
    $info.Arguments = Get-TunnelArguments $script:active.Mode $config $script:active.Port
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # Elimina credenciais herdadas. O token e passado apenas ao processo filho.
    foreach ($key in @('TUNNEL_TOKEN','TUNNEL_TOKEN_FILE','TUNNEL_URL','TUNNEL_CONFIG','TUNNEL_ORIGIN_CERT')) { $info.EnvironmentVariables.Remove($key) }
    if ($script:active.Mode -eq 'fixed') {
        $info.EnvironmentVariables['TUNNEL_TOKEN'] = $script:active.Token
        $script:url = $script:active.Address + $script:active.Route + '/'
    }
    $script:tunnel = New-Object Diagnostics.Process
    $script:tunnel.StartInfo = $info
    $script:tunnel.Start() | Out-Null
    try { $script:lifetime = New-Object NekoPonte.ProcessLifetime($script:tunnel) }
    catch {
        # Nao deixa tunel solto se o Windows recusar o controle de ciclo de vida.
        $script:tunnel.Kill()
        throw 'O Windows recusou o controle do processo de tunel. A ponte foi encerrada. Feche outras versoes e tente abrir novamente.'
    }
    # Remove a copia do token na descricao local depois de iniciar o filho.
    $info.EnvironmentVariables.Remove('TUNNEL_TOKEN')
    $script:reads = @{Out=$script:tunnel.StandardOutput.ReadLineAsync(); Err=$script:tunnel.StandardError.ReadLineAsync()}
    $script:state = 'connecting'
    $script:started = [DateTime]::UtcNow
    Set-Status 'Construindo sua ponte...' 'Aguardando a conexao com a Cloudflare.' '#C997CF'
    Add-Log ('Componente iniciado no modo ' + $script:active.Mode + '. Aguardando conexao.')
}
function Handle-Line([string]$Line) {
    if (-not $Line) { return }
    Add-Log $Line
    if ($script:active.Mode -eq 'temporary' -and $Line -match 'https://[a-z0-9]+(?:-[a-z0-9]+)*\.trycloudflare\.com\b') {
        $script:url = $Matches[0] + $script:active.Route + '/'
    }
    $event = Get-ConnectionState $Line
    if ($event -eq 'connected') {
        if ($Line -match 'connIndex=(\d+)') { $script:connectionIds[$Matches[1]] = $true }
        $script:lastConnected = [DateTime]::UtcNow
        $script:state = 'connected'
        Set-Status 'Sua ponte está pronta!' 'Conexão com a Cloudflare ativa. Teste tambem pelo celular usando dados moveis.' '#79AD9C'
    } elseif ($event -eq 'reconnecting') {
        if ($Line -match 'connIndex=(\d+)') { $script:connectionIds.Remove($Matches[1]) }
        else { $script:connectionIds.Clear() }
        if ($script:connectionIds.Count -eq 0) {
            $script:state = 'reconnecting'
            Set-Status 'Reconectando a ponte...' 'O link foi preservado. Aguardando a internet e a Cloudflare.' '#D6AA65'
        }
    } elseif ($event -eq 'origin-error') {
        $script:lastOriginError = [DateTime]::UtcNow
        Set-Status 'A ponte está ativa, mas o Foundry não respondeu.' 'Confira se o Foundry continua aberto e se a porta esta correta.' '#D6AA65'
    }
    if ($script:state -eq 'connected' -and $script:url) {
        $PublicLink.Text = $script:url
        $CopyButton.IsEnabled = $true
        $OpenButton.IsEnabled = $true
        Start-PublicCheck
    }
}

$TemporaryMode.Add_Checked({ Update-Mode })
$FixedMode.Add_Checked({ Update-Mode })
$SaveConfig.Add_Click({
    try { $options = Get-Options; Save-Options $options; Set-Status 'Configuração salva.' 'O endereco e o token estarao disponiveis na proxima abertura.'; Add-Log 'Configuracao salva; token protegido pelo Windows.' }
    catch { [Windows.MessageBox]::Show($_.Exception.Message, 'Confira a configuracao') | Out-Null }
})
$ForgetToken.Add_Click({
    try {
        $TokenBox.Clear()
        if (Test-Path -LiteralPath $script:settingsPath) {
            $settings = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json
            $settings.encryptedToken = ''
            Write-Settings $script:settingsPath $settings
        }
        Set-Status 'Token removido deste computador.' 'Seu tunel na Cloudflare continua existindo; cole o token novamente para usa-lo.'
    } catch { [Windows.MessageBox]::Show($_.Exception.Message, 'NekoPonte') | Out-Null }
})
$StartButton.Add_Click({
    try {
        $script:active = Get-Options
        $script:secret = $script:active.Token
        Save-Options $script:active
        Set-Busy $true
        $script:state = 'preparing'
        $script:started = [DateTime]::UtcNow
        $script:lastOriginError = $null
        Set-Status 'Preparando a aventura...' 'Conferindo Foundry e componente oficial. No primeiro uso, aguarde o download.'
        Add-Log 'Conferindo o Foundry local e a integridade do componente.'
        $script:worker = Start-Job -ScriptBlock $script:prepare -ArgumentList $script:root, $script:active.Port, $script:active.Route
    } catch {
        $message = $_.Exception.Message
        Stop-Bridge
        Set-Status 'Precisamos ajustar um detalhe.' $message '#D6AA65'
    }
})
$StopButton.Add_Click({ Stop-Bridge; Set-Status 'A ponte está descansando.' 'O túnel foi encerrado. Seu Foundry continua aberto.'; Add-Log 'Ponte encerrada pelo usuario.' })
$CopyButton.Add_Click({
    try { [Windows.Clipboard]::SetText($script:url); Add-Log 'Link copiado. Pronto para enviar aos jogadores.' }
    catch { Add-Log 'Selecione o link e pressione Ctrl+C para copiar.' }
})
$OpenButton.Add_Click({
    try { Start-Process -FilePath $script:url | Out-Null }
    catch { Add-Log 'Nao foi possivel abrir o navegador. Copie o link manualmente.' }
})
$LogsButton.Add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $script:root + '"') | Out-Null })
$HelpButton.Add_Click({ Start-Process notepad.exe -ArgumentList ('"' + (Join-Path $PSScriptRoot 'GUIA-LINK-FIXO.txt') + '"') | Out-Null })

try {
    if (Test-Path -LiteralPath $script:settingsPath) {
        $settings = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json
        $PortBox.Text = [string]$settings.port
        $RouteBox.Text = [string]$settings.route
        $FixedUrl.Text = [string]$settings.address
        if ($settings.encryptedToken) {
            try {
                $secure = ConvertTo-SecureString $settings.encryptedToken
                $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                try { $TokenBox.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
                finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $secure.Dispose() }
            } catch { Add-Log 'Nao foi possivel recuperar o token salvo. Cole novamente no modo fixo.' }
        }
        if ($settings.mode -eq 'fixed') { $FixedMode.IsChecked = $true }
    }
} catch { Add-Log 'A configuracao salva nao pode ser lida. Os campos podem ser preenchidos novamente.' }
Update-Mode
Add-Log 'Bem-vindo a NekoPonte 2.0.1.'

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({
    try {
        if ($script:state -eq 'preparing') {
            if ($script:worker.State -in @('Completed','Failed','Stopped')) {
                $result = @(Receive-Job -Job $script:worker -ErrorAction SilentlyContinue)
                Remove-Job -Job $script:worker -Force
                $script:worker = $null
                if (-not $result.Count -or -not $result[-1].Ok) {
                    $reason = if ($result.Count) { $result[-1].Error } else { 'O processo de preparacao falhou.' }
                    Stop-Bridge
                    Set-Status 'Nao foi possivel construir a ponte.' $reason '#D6AA65'
                    Add-Log $reason
                    return
                }
                Launch-Tunnel
            } elseif (([DateTime]::UtcNow - $script:started).TotalSeconds -gt 300) {
                Stop-Bridge
                Set-Status 'A preparacao demorou demais.' 'Confira sua internet e tente novamente.' '#D6AA65'
            }
            return
        }
        if (-not $script:tunnel) { return }
        # Leitura assincrona sem callbacks PowerShell em threads sem runspace.
        foreach ($key in @('Out','Err')) {
            $count = 0
            while ($script:reads[$key] -and $script:reads[$key].IsCompleted -and $count -lt 100) {
                $task = $script:reads[$key]
                if ($task.IsFaulted -or $task.IsCanceled) { $script:reads[$key] = $null; break }
                $line = $task.Result
                if ($null -eq $line) { $script:reads[$key] = $null; break }
                Handle-Line $line
                $stream = if ($key -eq 'Out') { $script:tunnel.StandardOutput } else { $script:tunnel.StandardError }
                $script:reads[$key] = $stream.ReadLineAsync()
                $count++
            }
        }
        if ($script:tunnel.HasExited) {
            $code = $script:tunnel.ExitCode
            Stop-Bridge
            Set-Status 'A ponte foi encerrada.' 'Veja o diario abaixo. Voce pode iniciar novamente.' '#D6AA65'
            Add-Log "Componente encerrou com codigo $code."
            return
        }
        if ($script:state -eq 'connecting' -and ([DateTime]::UtcNow - $script:started).TotalSeconds -gt 100) {
            Stop-Bridge
            Set-Status 'A conexao demorou demais.' 'Confira sua internet, o token (modo fixo) e o diario da ponte.' '#D6AA65'
            return
        }
        if ($script:publicCheck) {
            if ($script:publicCheck.State -in @('Completed','Failed','Stopped')) {
                $results = @(Receive-Job $script:publicCheck -ErrorAction SilentlyContinue)
                Remove-Job $script:publicCheck -Force
                $script:publicCheck = $null
                $script:publicCheckDone = $true
                if ($script:state -eq 'connected' -and -not $script:lastOriginError) {
                    if ($results.Count -and $results[-1].Ok) {
                        Set-Status 'Sua ponte está pronta!' 'O endereço público respondeu. Envie o link e mantenha esta janela aberta.' '#79AD9C'
                        Add-Log 'O endereco publico respondeu ao teste HTTP. Confira tambem com um jogador de fora da rede.'
                    } else {
                        Set-Status 'Tunel conectado. Confira o endereco.' 'O teste publico nao confirmou a pagina. Abra o link; no modo fixo, confira dominio e rota na Cloudflare.' '#D6AA65'
                    }
                }
            } elseif (([DateTime]::UtcNow - $script:publicCheckStarted).TotalSeconds -gt 40) {
                Remove-Worker ([ref]$script:publicCheck)
                $script:publicCheckDone = $true
                Add-Log 'O teste do endereco publico demorou demais. Confira o link no navegador.'
            }
        }
    } catch {
        $message = Protect-Log $_.Exception.Message $script:secret
        Stop-Bridge
        Set-Status 'A ponte encontrou um problema.' $message '#D6AA65'
        Add-Log $message
    }
})
$window.Add_Closing({ $timer.Stop(); Stop-Bridge })
try {
    $timer.Start()
    $window.ShowDialog() | Out-Null
} finally {
    $timer.Stop()
    Stop-Bridge
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
