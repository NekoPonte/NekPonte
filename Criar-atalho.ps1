$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'NekoPonte.lnk'))
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'NekoPonte.ps1') + '"'
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.IconLocation = (Join-Path $PSScriptRoot 'assets\NekoPonte.ico') + ',0'
    $shortcut.Description = 'NekoPonte - uma ponte para a sua proxima aventura'
    $shortcut.Save()
    [Windows.MessageBox]::Show('Atalho NekoPonte criado na area de trabalho com o icone da personagem. Mantenha esta pasta no mesmo lugar.', 'NekoPonte') | Out-Null
} catch {
    [Windows.MessageBox]::Show($_.Exception.Message, 'Nao foi possivel criar o atalho') | Out-Null
    exit 1
}
