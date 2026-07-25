# Recuperación de contraseña

Esta guía corresponde a Raspberry Pi OS Trixie con cloud-init. La imagen usada se generó el 4 de diciembre de 2025.

## Si todavía puedes entrar

Ejecuta:

```sh
passwd
```

Escribe la contraseña actual. Después escribe la nueva dos veces. La terminal no muestra caracteres mientras escribes.

Mantén la sesión abierta hasta recibir:

```text
passwd: password updated successfully
```

## Si perdiste el acceso SSH

Necesitas acceso físico a la microSD y otra computadora.

### 1. Apaga y respalda

Apaga el Pi. Conecta la microSD a la otra computadora. La partición FAT debe mostrar:

```text
user-data
meta-data
network-config
cmdline.txt
```

Copia `user-data` y `meta-data` antes de editarlos. No cambies `cmdline.txt`.

### 2. Genera una contraseña temporal

Genera un hash SHA-512 en una computadora confiable:

```sh
openssl passwd -6
```

OpenSSL pedirá la contraseña sin dejarla en el historial del shell. Copia el resultado que comienza con `$6$`.

### 3. Edita user-data

Busca el usuario:

```yaml
users:
- name: raul
```

Ajusta estas claves y conserva el resto:

```yaml
  lock_passwd: false
  passwd: "<HASH_SHA512>"

ssh_pwauth: true
ssh_deletekeys: false
```

`ssh_deletekeys: false` conserva la huella SSH del Pi.

### 4. Cambia el instance-id

`meta-data` contiene:

```yaml
instance-id: <VALOR_ANTERIOR>
```

Usa un valor único:

```yaml
instance-id: rpi-password-recovery-AAAAMMDD-NONCE
```

Cloud-init ejecuta los módulos de usuario una vez por `instance-id`. La clave `passwd` se aplica a un usuario existente.

### 5. Arranca y prueba

Expulsa la microSD, colócala en el Pi y espera cinco minutos.

```sh
ssh raul@raspberrypi.local
```

Si mDNS no responde:

```sh
ssh raul@192.168.1.81
```

### 6. Cambia la contraseña temporal

Dentro de SSH:

```sh
passwd
```

Elige una contraseña privada que no aparezca en notas, chats ni scripts.

### 7. Retira el hash de provisión

Respalda `/boot/firmware/user-data` y elimina solo la línea `passwd:` del usuario `raul`. Conserva el nuevo `instance-id`. Revisa la indentación YAML antes de reiniciar.

No restaures el `instance-id` anterior. Cloud-init puede interpretar ese cambio como otra instancia y ejecutar módulos de provisión.

## Diagnóstico

```sh
cloud-init status --long
sudo journalctl -u cloud-init-local -u cloud-init -u cloud-config -u cloud-final \
  --no-pager
systemctl is-active ssh
sudo ss -lntp | grep ':22'
```

## Datos de esta recuperación

- Usuario recuperado: `raul`
- Mecanismo que funcionó: cloud-init NoCloud desde `/boot/firmware`
- Clave SSH conservada: sí
- Contraseña almacenada en este repositorio: no
- Copias temporales de la partición de arranque: eliminadas

Usa cloud-init para esta imagen. El modo `init=/bin/sh` requiere consola local; el generador `systemd.run` no completó el cambio en esta instalación headless.
