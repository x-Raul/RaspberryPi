# Homebridge y tira BlitzWolf

## Componentes

| Elemento | Valor |
|---|---|
| Homebridge | Paquete apt `homebridge` (repo.homebridge.io), panel en `http://raspberrypi.local:8581` |
| Configuración | `/var/lib/homebridge/config.json` (privada, contiene `id`/`key` de Tuya) |
| Núcleo | Homebridge 2.4.0 (lo instala el paquete apt `homebridge`) |
| Plugin Tuya | `homebridge-tuya` 3.1.2-beta.2 (sin mantenimiento), plataforma `TuyaLan`, parcheado para Homebridge 2 |
| Tira LED | BlitzWolf `RGBTWLight`, protocolo Tuya 3.1, MAC `cc:50:e3:14:94:e2` |
| WLED | `homebridge-wled-ws`, controlador en `192.168.1.88` (se apaga a veces; mientras tanto escribe un error cada ~13 s en el log) |

## Falla de octubre de 2026

La tira dejó de responder en HomeKit. Había dos causas:

1. El router le asignó otra IP (`192.168.1.67` → `192.168.1.64`). `TuyaLan` conecta por la IP fija del `config.json`.
2. La tira **no responde solicitudes ARP**, aunque sí emite anuncios UDP (puerto 6666) y contesta tráfico unicast. Sin una entrada ARP estática, el Pi recibe `EHOSTUNREACH`.

## Falla del 14 de octubre de 2026: Homebridge 2

Al actualizar el paquete apt `homebridge` (2.0.15 → 2.0.19), el núcleo pasó de 1.11.4 a 2.4.0. `homebridge-tuya` usa APIs que Homebridge 2 eliminó:

- `Characteristic.Perms` → Homebridge entraba en un ciclo de reinicios (`Cannot read properties of undefined (reading 'WRITE')`).
- `Accessory.Categories` → la tira se descubría pero no se creaba; el plugin lo reportaba como `Failed to parse discovery response`.

[`patch-homebridge-tuya.py`](../configs/blitzwolf/patch-homebridge-tuya.py) vuelve a colgar esos objetos desde `api.hap`. Es idempotente y guarda `index.js.orig-<fecha>`. La unidad [`homebridge-tuya-hb2-compat.conf`](../configs/blitzwolf/homebridge-tuya-hb2-compat.conf) lo ejecuta antes de cada arranque de Homebridge, así sobrevive a una reinstalación del plugin.

Por esta razón `unattended-upgrades` **no** actualiza Homebridge. Antes de actualizarlo a mano, revisa el log tras reiniciar.

Si algún día el plugin cambia y el parche no encuentra su ancla, imprime `anchor not found` y no toca nada. En ese caso evalúa migrar a un plugin Tuya mantenido.

## tuya-arp-watch

[`configs/blitzwolf/tuya-arp-watch.py`](../configs/blitzwolf/tuya-arp-watch.py) escucha los anuncios Tuya. Cuando ve la tira:

- fija una entrada ARP permanente `IP → MAC`;
- si la IP cambió, respalda `config.json` (`config.json.bak-<fecha>`), escribe la nueva IP y reinicia Homebridge.

| Archivo en el Pi | Origen |
|---|---|
| `/usr/local/sbin/tuya-arp-watch.py` | [script](../configs/blitzwolf/tuya-arp-watch.py) |
| `/etc/systemd/system/tuya-arp-watch.service` | [unidad](../configs/blitzwolf/tuya-arp-watch.service) |
| `/etc/default/tuya-arp-watch` | Privado (`0600`): `TUYA_DEVICES=<gwId>=<mac>[,...]` |

Para agregar otro dispositivo Tuya con el mismo problema, añade su par `gwId=mac` a `TUYA_DEVICES` y reinicia el servicio.

## Falla intermitente (18 de octubre de 2026)

Casa mostraba la tira a veces sí y a veces no, aunque Homebridge y la conexión con la tira estaban bien. Hallazgos:

- El Wi-Fi de la Pi tenía **power save activado** y `brcmfmac` registraba timeouts de SDIO casi a diario. La Pi dejaba de responder en la LAN durante ratos.
- WLED (caído) escribía un error cada 10 s. El log de Homebridge se recorta a ~700 KB, así que solo quedaban esos errores.
- avahi anunciaba el bridge también por `tailscale0`.

Cambios:

| Cambio | Archivo |
|---|---|
| Power save del Wi-Fi apagado | `/etc/NetworkManager/conf.d/wifi-powersave-off.conf` ([copia](../configs/homebridge/wifi-powersave-off.conf)) |
| avahi solo en `wlan0` | `allow-interfaces=wlan0` en `/etc/avahi/avahi-daemon.conf` |
| WLED retirado y luego restaurado (el usuario la usa) | respaldos `config.json.bak-*-pre-wled-*` |
| Vigilante cada 2 min | [`homebridge-watchdog.sh`](../configs/homebridge/homebridge-watchdog.sh), `.service` y `.timer` |
| Kernel 6.18 y firmware Wi-Fi nuevos | reinicio aplicado |

El vigilante revisa, en orden: router alcanzable (si no, `nmcli device reconnect wlan0`), HAP responde, el bridge se anuncia por mDNS en `wlan0`, y que exista socket a cada dispositivo Tuya que responde ping. Solo actúa tras dos fallas seguidas y reinicia Homebridge como máximo cada 10 minutos. Si la tira está apagada del interruptor, no hace nada.

```sh
journalctl -t homebridge-watchdog --no-pager | tail
systemctl list-timers homebridge-watchdog.timer
```

Verificación final: con la app Casa abierta, el iPhone (`192.168.1.69`) hizo la consulta mDNS `_hap`, resolvió `192.168.1.1` por ARP y abrió la conexión HAP al puerto `51849`. Recuerda que, sin un concentrador conectado, el iPhone solo se conecta mientras la app Casa está abierta. El equipo `192.168.1.73` anuncia `_homekit`/`_sleep-proxy` pero no respondió ARP ni se conectó a Homebridge durante la prueba.

## Diagnóstico

```sh
systemctl is-active homebridge tuya-arp-watch homebridge-watchdog.timer
/sbin/iw dev wlan0 get power_save   # debe decir off
avahi-browse -tpk _hap._tcp         # debe listar Homebridge en wlan0
journalctl -u tuya-arp-watch -n 20 --no-pager
ip neigh show 192.168.1.64
sudo grep -E 'TuyaLan' /var/lib/homebridge/homebridge.log | tail -20
sudo ss -tnp | grep ':6668'
```

`Connected to LED Strip BlitzWolf` en el log y una conexión `ESTAB` al puerto `6668` indican que funciona.

## Recomendado

Reserva en el DHCP del router la IP `192.168.1.64` para la MAC `cc:50:e3:14:94:e2`, y otra para WLED. El servicio ya tolera cambios de IP, pero la reserva evita el reinicio de Homebridge.
