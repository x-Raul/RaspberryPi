[CmdletBinding()]
param(
    [ValidateSet('prepare', 'finish')]
    [string]$Mode,
    [string]$BootDrive,
    [string]$HostAddress = '192.168.1.81',
    [string]$PrivateKey = "$HOME\.ssh\id_ed25519"
)

$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program termino con codigo $LASTEXITCODE."
    }
}

function Get-VerifiedPublicKey {
    param([string]$PrivatePath)
    $publicPath = "$PrivatePath.pub"
    if (-not (Test-Path -LiteralPath $PrivatePath) -or -not (Test-Path -LiteralPath $publicPath)) {
        throw "Falta $PrivatePath o $publicPath."
    }
    $derived = (& ssh-keygen -y -f $PrivatePath).Trim() -split '\s+'
    if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen no pudo leer la clave privada.' }
    $publishedLine = [IO.File]::ReadAllText($publicPath).Trim()
    $published = $publishedLine -split '\s+'
    if ($published.Count -lt 2 -or $published[0] -ne 'ssh-ed25519') {
        throw 'La clave publica debe ser Ed25519.'
    }
    if ($derived[1] -cne $published[1]) { throw 'La clave privada no corresponde a la publica.' }
    if ($publishedLine.Contains("'")) { throw 'El comentario de la clave publica contiene una comilla simple.' }
    $fingerprint = & ssh-keygen -lf $publicPath
    if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen no pudo calcular la huella.' }
    Write-Host $fingerprint
    return $publishedLine
}

function Get-BootRoot {
    param([string]$RequestedDrive)
    if ($RequestedDrive) {
        $root = $RequestedDrive.TrimEnd('\') + '\'
        if (-not (Test-Path -LiteralPath (Join-Path $root 'user-data'))) {
            throw "$root no contiene user-data."
        }
        return $root
    }
    $matches = Get-Volume | Where-Object {
        $_.DriveLetter -and $_.FileSystemLabel -eq 'bootfs'
    }
    if (@($matches).Count -ne 1) { throw 'Conecta una sola particion bootfs o indica -BootDrive R:.' }
    return "$($matches.DriveLetter):\"
}

function Remove-TopLevelBlock {
    param([string]$Text, [string]$Name)
    return [regex]::Replace($Text, "(?ms)^$([regex]::Escape($Name)):\s*.*?(?=^[A-Za-z_][A-Za-z0-9_]*:|\z)", '')
}

function Prepare-Recovery {
    $root = Get-BootRoot $BootDrive
    $userDataPath = Join-Path $root 'user-data'
    $metaDataPath = Join-Path $root 'meta-data'
    if (-not (Test-Path -LiteralPath $metaDataPath)) { throw 'Falta meta-data.' }
    $publicKey = Get-VerifiedPublicKey $PrivateKey
    $userData = [IO.File]::ReadAllText($userDataPath)
    $metaData = [IO.File]::ReadAllText($metaDataPath)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $env:LOCALAPPDATA "RaspberryPiRecovery\$stamp"
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    [IO.File]::WriteAllText((Join-Path $backup 'user-data'), $userData, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $backup 'meta-data'), $metaData, [Text.UTF8Encoding]::new($false))
    $statePath = Join-Path $env:LOCALAPPDATA 'RaspberryPiRecovery\latest.json'
    [pscustomobject]@{
        BackupPath = $backup
        CreatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

    $updated = Remove-TopLevelBlock $userData 'bootcmd'
    $updated = Remove-TopLevelBlock $updated 'chpasswd'
    if ($updated -notmatch '(?m)^ssh_pwauth:\s*true\s*$') { throw 'user-data no contiene ssh_pwauth: true.' }
    $bootcmd = @"
bootcmd:
- [sh, -c, "id recoveryadmin >/dev/null 2>&1 || useradd -m -s /bin/bash recoveryadmin"]
- [usermod, -aG, sudo, recoveryadmin]
- [passwd, -d, recoveryadmin]
- [install, -d, -o, recoveryadmin, -g, recoveryadmin, -m, "0700", /home/recoveryadmin/.ssh]
- [install, -o, recoveryadmin, -g, recoveryadmin, -m, "0600", /dev/null, /home/recoveryadmin/.ssh/authorized_keys]
- [sh, -c, "echo '$publicKey' > /home/recoveryadmin/.ssh/authorized_keys"]
- [sh, -c, "printf 'recoveryadmin ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/99-recoveryadmin"]
- [chmod, "0440", /etc/sudoers.d/99-recoveryadmin]
- [sh, -c, "printf 'UsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/00-recovery.conf"]
- [sh, -c, "sshd -t && (systemctl try-restart ssh || true)"]
"@
    $updated = [regex]::Replace($updated, '(?m)^ssh_pwauth:\s*true\s*$', "$bootcmd`r`nssh_pwauth: true")
    $instanceId = 'rpi-recovery-admin-' + (Get-Date -Format 'yyyyMMdd') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 12))
    [IO.File]::WriteAllText($userDataPath, $updated, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($metaDataPath, "instance-id: $instanceId`r`n", [Text.UTF8Encoding]::new($false))

    $written = [IO.File]::ReadAllText($userDataPath)
    $blob = ($publicKey -split '\s+')[1]
    foreach ($required in @('recoveryadmin', '00-recovery.conf', '99-recoveryadmin', 'UsePAM no', 'sshd -t')) {
        if (-not $written.Contains($required)) { throw "Fallo la verificacion: falta $required." }
    }
    if ([regex]::Matches($written, [regex]::Escape($blob)).Count -ne 1) {
        throw 'La clave publica no aparece exactamente una vez.'
    }
    Write-Host "MicroSD preparada. Respaldo: $backup" -ForegroundColor Green
    Write-Host 'Expulsa la microSD, arranca el Pi y ejecuta Recover-RaspberryPi.cmd finish.'
}

function Finish-Recovery {
    $null = Get-VerifiedPublicKey $PrivateKey
    $sshBase = @('-4', '-i', $PrivateKey, '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=15')
    $recovery = "recoveryadmin@$HostAddress"
    $raul = "raul@$HostAddress"
    $remotePrepare = 'set -eu; sudo install -d -o raul -g raul -m 0700 /home/raul/.ssh; sudo install -o raul -g raul -m 0600 /home/recoveryadmin/.ssh/authorized_keys /home/raul/.ssh/authorized_keys; sudo chage -E -1 -M 99999 raul; sudo passwd -u raul >/dev/null 2>&1 || true; sudo rm -f /etc/ssh/sshd_config.d/00-recovery.conf; sudo sshd -t; sudo systemctl reload ssh'
    Invoke-Checked ssh ($sshBase + @($recovery, $remotePrepare))
    Invoke-Checked ssh ($sshBase + @('-o', 'BatchMode=yes', $raul, 'id -un'))

    $cleanup = @'
set -eu
user_data=/boot/firmware/user-data
temporary=$(mktemp /tmp/user-data-clean.XXXXXX)
trap 'rm -f "$temporary"' EXIT
awk '
  /^bootcmd:/ { skipping=1; next }
  skipping && /^[A-Za-z_][A-Za-z0-9_]*:/ { skipping=0 }
  !skipping { print }
' "$user_data" > "$temporary"
if grep -q 'recoveryadmin\|00-recovery.conf\|99-recoveryadmin' "$temporary"; then exit 1; fi
sudo install -o root -g root -m 0600 "$temporary" "$user_data"
sudo rm -f /etc/ssh/sshd_config.d/00-recovery.conf /etc/sudoers.d/99-recoveryadmin
sudo sshd -t
sudo systemctl reload ssh
sudo loginctl terminate-user recoveryadmin 2>/dev/null || true
sudo pkill -KILL -u recoveryadmin 2>/dev/null || true
sudo userdel -r -f recoveryadmin 2>/dev/null || true
! getent passwd recoveryadmin >/dev/null
echo CLEANUP_OK
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cleanup))
    $remoteCleanup = "echo $encoded | base64 -d | sudo sh"
    Invoke-Checked ssh ($sshBase + @('-o', 'BatchMode=yes', $raul, $remoteCleanup))
    Write-Host 'Acceso por clave verificado y recoveryadmin eliminado.' -ForegroundColor Green
    Write-Host 'Establece ahora la contrasena definitiva de raul.'
    & ssh @sshBase '-tt' $raul 'sudo passwd raul'
    if ($LASTEXITCODE -ne 0) { throw 'No se completo passwd.' }
    $recoveryRoot = Join-Path $env:LOCALAPPDATA 'RaspberryPiRecovery'
    $statePath = Join-Path $recoveryRoot 'latest.json'
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $rootResolved = [IO.Path]::GetFullPath($recoveryRoot).TrimEnd('\') + '\'
        $backupResolved = [IO.Path]::GetFullPath([string]$state.BackupPath).TrimEnd('\') + '\'
        if (-not $backupResolved.StartsWith($rootResolved, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'La ruta del respaldo local no pertenece a RaspberryPiRecovery.'
        }
        if (Test-Path -LiteralPath ([string]$state.BackupPath)) {
            Remove-Item -LiteralPath ([string]$state.BackupPath) -Recurse -Force
        }
        Remove-Item -LiteralPath $statePath -Force
    }
    Write-Host 'Recuperacion terminada.' -ForegroundColor Green
}

if (-not $Mode) {
    Write-Host '1. prepare: preparar microSD'
    Write-Host '2. finish: terminar con el Pi encendido'
    $choice = Read-Host 'Elige 1 o 2'
    $Mode = switch ($choice) { '1' { 'prepare' } '2' { 'finish' } default { throw 'Opcion invalida.' } }
}

if ($Mode -eq 'prepare') { Prepare-Recovery } else { Finish-Recovery }
