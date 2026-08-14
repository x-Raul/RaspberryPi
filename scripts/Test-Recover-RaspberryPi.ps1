$ErrorActionPreference = 'Stop'
$errors = $null
$tokens = $null
$path = Join-Path $PSScriptRoot 'Recover-RaspberryPi.ps1'
[void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) {
    $errors | Format-List
    throw 'Recover-RaspberryPi.ps1 contiene errores de sintaxis.'
}
Write-Output 'POWERSHELL_PARSE_PASS'

$cmdPath = Join-Path $PSScriptRoot 'Recover-RaspberryPi.cmd'
$cmd = [IO.File]::ReadAllText($cmdPath)
if ($cmd -notmatch 'Recover-RaspberryPi\.ps1') { throw 'El CMD no llama al script PowerShell.' }
Write-Output 'CMD_LAUNCHER_PASS'

$source = [IO.File]::ReadAllText($path)
if ($source -notmatch 'base64 -d \| sudo sh') {
    throw 'El bloque de limpieza remota no se ejecuta con sudo.'
}
Write-Output 'REMOTE_CLEANUP_SUDO_PASS'
if ($source -match 'Invoke-Checked ssh-keygen') {
    throw 'Get-VerifiedPublicKey mezcla la huella con el valor devuelto.'
}
Write-Output 'PUBLIC_KEY_OUTPUT_PASS'
