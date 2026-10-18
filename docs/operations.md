# Operación y rollback

## Comprobación diaria

```sh
systemctl is-active AdGuardHome unbound tailscaled homebridge tuya-arp-watch homebridge-watchdog.timer dns-watchdog.timer
tailscale status
free -h
df -h /
```

Las siete unidades deben devolver `active`. Tailscale debe mostrar el nodo como online.

## Pruebas DNS

Consulta a través de AdGuard y Unbound:

```sh
dig @127.0.0.1 example.com A
```

Prueba de DNSSEC válida:

```sh
dig @127.0.0.1 cloudflare.com A +dnssec
```

La cabecera debe incluir la bandera `ad`.

Prueba de firma rota:

```sh
dig @127.0.0.1 dnssec-failed.org A +dnssec
```

El resultado esperado es `SERVFAIL`.

Consulta directa a Unbound:

```sh
dig @127.0.0.1 -p 5335 example.com A
```

Estadísticas:

```sh
sudo unbound-control stats_noreset |
  grep -E 'total.num.queries=|total.num.cachehits=|total.num.cachemiss='
```

## Resiliencia del DNS

| Medida | Archivo |
|---|---|
| `Restart=always` y `OOMScoreAdjust=-900` en AdGuard y Unbound | `/etc/systemd/system/{AdGuardHome,unbound}.service.d/resilience.conf` ([copias](../configs/dns)) |
| Vigilante cada minuto: reinicia Unbound o AdGuard tras 2 fallas seguidas (máx. 1 vez cada 5 min) | [`dns-watchdog.sh`](../configs/dns/dns-watchdog.sh), `.service`, `.timer` |
| Registro de consultas de AdGuard a 7 días (antes 90) | `querylog.interval` en `AdGuardHome.yaml`; respaldo en `/var/backups/AdGuardHome.yaml.bak-*` |

El Pi Zero 2 W tiene 416 MiB de RAM. No ejecutes análisis pesados sobre `querylog.json` en el propio Pi: el 18 de octubre de 2026 uno de ellos agotó la memoria y AdGuard dejó de responder durante varios minutos. Cópialo a otra máquina.

El Pi es un punto único de falla. Los clientes que usen `192.168.1.1` como DNS deben tener un DNS secundario público para no perder internet si el Pi se apaga.

```sh
journalctl -t dns-watchdog --no-pager | tail
```

## Tailscale

```sh
tailscale status
tailscale ip -4
sudo tailscale debug prefs |
  grep -E 'RouteAll|CorpDNS|RunSSH|WantRunning|AdvertiseRoutes'
```

Valores esperados:

```text
RouteAll: false
CorpDNS: false
RunSSH: false
WantRunning: true
AdvertiseRoutes: null
```

No actives Funnel para SSH, DNS ni el panel de AdGuard. Usa las ACL del tailnet para limitar qué usuarios y dispositivos alcanzan los puertos `22`, `53` y `80`.

## Logs

```sh
journalctl -u AdGuardHome -n 100 --no-pager
journalctl -u unbound -n 100 --no-pager
journalctl -u tailscaled -n 100 --no-pager
```

AdGuard tarda cerca de ocho segundos en abrir el puerto 53 después de un reinicio. Espera diez segundos antes de declarar una falla.

## Actualizaciones

`unattended-upgrades` instala a diario las actualizaciones de Debian (stable, updates, security), Raspberry Pi, Tailscale y Homebridge. Si un paquete requiere reinicio, el Pi se reinicia solo a las 04:30.

Archivos (copia en [configs/apt](../configs/apt)):

```text
/etc/apt/apt.conf.d/20auto-upgrades
/etc/apt/apt.conf.d/52unattended-upgrades-local
```

Comprobar:

```sh
sudo unattended-upgrade --dry-run --debug 2>&1 | grep -E 'Allowed origins|Packages that will be upgraded'
systemctl list-timers 'apt-daily*'
less /var/log/unattended-upgrades/unattended-upgrades.log
```

No cubre los plugins de Homebridge (`/var/lib/homebridge/node_modules`) ni AdGuard Home (binario en `/opt`). Actualízalos desde sus paneles.

Actualización manual:

```sh
sudo apt update
apt list --upgradable
sudo apt full-upgrade
```

## Rollback de Unbound

El YAML original está en `/var/backups/rgzz-pi-20260725-pre-tailscale-unbound/AdGuardHome.yaml`.

```sh
sudo install -o root -g root -m 0600 \
  /var/backups/rgzz-pi-20260725-pre-tailscale-unbound/AdGuardHome.yaml \
  /opt/AdGuardHome/AdGuardHome.yaml

sudo rm -f /etc/systemd/system/AdGuardHome.service.d/unbound.conf
sudo systemctl daemon-reload
sudo systemctl restart AdGuardHome
```

Espera diez segundos. Comprueba DNS y luego detén Unbound:

```sh
sudo ss -lntup | grep ':53'
dig @127.0.0.1 example.com A
sudo systemctl disable --now unbound
```

## Retirar Tailscale

```sh
sudo tailscale logout
sudo systemctl disable --now tailscaled
sudo apt purge tailscale tailscale-archive-keyring
sudo rm -f /etc/apt/sources.list.d/tailscale.list
sudo rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg
sudo apt update
```

No ejecutes `apt autoremove` sin revisar la lista propuesta.

## Archivos temporales

La instalación usó:

```text
/tmp/adguard-unbound.conf
/tmp/AdGuardHome.yaml.codex
/tmp/tailscale-archive-keyring.gpg
/tmp/tailscale.list
```

Puedes eliminarlos después de verificar el repositorio y cambiar la contraseña.
