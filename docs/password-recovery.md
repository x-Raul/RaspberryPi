# Recuperación de acceso SSH

Procedimiento validado el 13 de agosto de 2026 en Raspberry Pi OS Trixie con cloud-init y OpenSSH 10.0p2.

## Resultado actual

La cuenta `raul` acepta la clave Ed25519 de esta computadora. SSH entra sin pedir la contraseña de la cuenta porque prueba primero la clave pública.

```powershell
ssh -4 -i "$HOME\.ssh\id_ed25519" -o IdentitiesOnly=yes raul@192.168.1.81
```

La contraseña de `raul` sigue activa para `sudo`, consola local y servicios que usen PAM. Cámbiala dentro del Pi con:

```sh
passwd
```

## Corrección de la receta anterior

No uses `users[].passwd` para recuperar una cuenta existente:

```yaml
users:
- name: raul
  passwd: "$6$..."
```

Cloud-init aplica `passwd` al crear el usuario. Si `raul` ya existe, usa `hashed_passwd` o `chpasswd.users`. Durante la recuperación de agosto de 2026, cloud-init ejecutó `chpasswd -e` y `/etc/shadow` recibió el hash esperado. OpenSSH cerró la sesión durante la validación de la cuenta, por lo que la recuperación continuó mediante una clave pública.

La vía reproducible consiste en instalar una clave pública, entrar con un administrador temporal y retirar ese administrador al terminar.

## Recuperación automática

Windows incluye un lanzador:

```text
scripts\Recover-RaspberryPi.cmd
```

El lanzador pide una fase:

- `prepare`: prepara la microSD desde Windows.
- `finish`: termina la recuperación cuando el Pi vuelve a estar encendido.

También puedes indicar la fase en el mismo comando:

```powershell
.\scripts\Recover-RaspberryPi.cmd prepare
.\scripts\Recover-RaspberryPi.cmd finish
```

### Fase prepare

1. Apaga el Pi y conecta la microSD.
2. Ejecuta:

   ```powershell
   .\scripts\Recover-RaspberryPi.cmd prepare
   ```

3. El script localiza el volumen `bootfs`, valida el par `id_ed25519`/`id_ed25519.pub`, respalda `user-data` y `meta-data` en `%LOCALAPPDATA%\RaspberryPiRecovery`, y escribe una provisión temporal.
4. Expulsa la microSD cuando el script lo indique. Colócala en el Pi y espera tres minutos.

La provisión crea `recoveryadmin`, instala la clave pública, concede sudo temporal y escribe `/etc/ssh/sshd_config.d/00-recovery.conf` con `UsePAM no`. Ese ajuste permite entrar aunque PAM cierre la sesión de `raul` después de aceptar su clave.

### Fase finish

Con el Pi encendido, ejecuta:

```powershell
.\scripts\Recover-RaspberryPi.cmd finish
```

El script:

1. Entra como `recoveryadmin` con la clave local.
2. Instala `authorized_keys` para `raul` con permisos `0700`/`0600`.
3. Retira `UsePAM no` y recarga SSH después de ejecutar `sshd -t`.
4. Comprueba una sesión nueva como `raul`.
5. Elimina `recoveryadmin`, su regla sudo y el bloque temporal de `user-data`.
6. Abre `sudo passwd raul` para establecer la contraseña definitiva y elimina el respaldo local creado por `prepare`.

No cierres la primera sesión de recuperación hasta que el script confirme una sesión nueva como `raul`.

## Clave privada y clave pública

La computadora conserva el par:

```text
C:\Users\x-Rau\.ssh\id_ed25519      clave privada
C:\Users\x-Rau\.ssh\id_ed25519.pub  clave pública
```

El Raspberry Pi recibe solo el contenido de `id_ed25519.pub` en:

```text
/home/raul/.ssh/authorized_keys
```

La clave privada no se copió al Pi, a la microSD ni al repositorio. El cliente SSH usa la privada para firmar un desafío; el servidor verifica la firma con la pública.

Comprueba que ambas pertenecen al mismo par:

```powershell
ssh-keygen -y -f "$HOME\.ssh\id_ed25519"
ssh-keygen -lf "$HOME\.ssh\id_ed25519.pub"
```

La huella registrada durante esta recuperación fue:

```text
SHA256:Yw70Cd1ROhVe8bmkpoYprFW/TQ0FPo+31wQSFMWy20k
```

Si `ssh raul@...` no pide contraseña, la clave funciona. Fuerza una prueba de contraseña con:

```powershell
ssh -4 -o PubkeyAuthentication=no -o PreferredAuthentications=password raul@192.168.1.81
```

## Diagnóstico

Desde una sesión que funcione:

```sh
passwd -S raul
sudo chage -l raul
sudo sshd -t
sudo sshd -T | grep -E 'usepam|passwordauthentication|pubkeyauthentication'
sudo journalctl -u ssh -n 100 --no-pager
cloud-init status --long
sudo journalctl -u cloud-init-local -u cloud-init -u cloud-config -u cloud-final --no-pager
```

En esta recuperación, `ssh -vvv` mostró:

```text
Server accepts key: ... id_ed25519
signing using ssh-ed25519
Connection closed
```

Ese patrón confirmó que `authorized_keys` era correcto y que PAM cerraba la cuenta después de validar la firma.

## Limpieza esperada

Al finalizar:

- `recoveryadmin` no existe.
- `/etc/sudoers.d/99-recoveryadmin` no existe.
- `/etc/ssh/sshd_config.d/00-recovery.conf` no existe.
- `user-data` no contiene `bootcmd`, claves SSH ni hashes de recuperación.
- `/home/raul/.ssh/authorized_keys` conserva la clave pública permanente.
- La computadora no conserva imágenes de la partición ni archivos con hashes temporales.

Verifica:

```sh
! getent passwd recoveryadmin
sudo test ! -e /etc/sudoers.d/99-recoveryadmin
sudo test ! -e /etc/ssh/sshd_config.d/00-recovery.conf
sudo grep -En 'recoveryadmin|bootcmd:|ssh-ed25519|chpasswd:' /boot/firmware/user-data
stat -c '%U:%G %a %n' /home/raul/.ssh /home/raul/.ssh/authorized_keys
```

El último `grep` no debe imprimir líneas. Los permisos esperados son `700` para `.ssh` y `600` para `authorized_keys`.
