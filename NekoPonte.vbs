Option Explicit
Dim shell, fs, folder, scriptPath, powershell
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
folder = fs.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fs.BuildPath(folder, "NekoPonte.ps1")
If Not fs.FileExists(scriptPath) Then
  MsgBox "Extraia todos os arquivos do ZIP antes de abrir a NekoPonte.", 48, "NekoPonte"
  WScript.Quit 1
End If
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
shell.Run """" & powershell & """ -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File """ & scriptPath & """", 0, False
