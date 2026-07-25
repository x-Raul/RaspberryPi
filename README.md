# Raspberry Pi Zero 2 W

Documentación del servidor DNS y acceso remoto instalado en un Raspberry Pi Zero 2 W.

Estado registrado: 25 de julio de 2026.

## Servicios

| Servicio | Versión | Función | Estado |
|---|---:|---|---|
| AdGuard Home | 0.107.73 | Filtrado DNS para la red local | Activo y habilitado |
| Unbound | 1.22.0 | Resolución recursiva y validación DNSSEC | Activo y habilitado |
| Tailscale | 1.98.9 | Acceso remoto privado | Activo, autorizado y habilitado |
| OpenSSH | Debian 13 | Administración | Activo |

## Flujo DNS

```mermaid
flowchart LR
    LAN["Clientes LAN"]
    TS["Clientes Tailscale"]
    AGH["AdGuard Home<br/>TCP/UDP 53"]
    UB["Unbound<br/>127.0.0.1:5335"]
    ROOT["Servidores DNS autoritativos"]

    LAN --> AGH
    TS --> AGH
    AGH --> UB
    UB --> ROOT
```

AdGuard Home filtra las consultas. Unbound resuelve desde la raíz de DNS, guarda respuestas en caché y valida DNSSEC.

## Direcciones administrativas

| Interfaz | Dirección |
|---|---|
| LAN Wi-Fi | `192.168.1.81/24` |
| Gateway | `192.168.1.254` |
| Tailscale IPv4 | `100.82.214.23/32` |

El panel de AdGuard usa el puerto `80`. SSH usa el puerto `22`. Unbound solo escucha en loopback.

## Documentos

- [Mapa del sistema](docs/system-map.md)
- [Operación y rollback](docs/operations.md)
- [Recuperación de contraseña](docs/password-recovery.md)

## Configuraciones públicas

- [Unbound para AdGuard Home](configs/unbound/adguard-home.conf)
- [Orden de arranque de AdGuard](configs/systemd/AdGuardHome.service.d/unbound.conf)

Los archivos de provisión, claves, contraseñas y respaldos no pertenecen a este repositorio. `.gitignore` bloquea sus nombres comunes.

## Acción pendiente

La cuenta conserva una contraseña temporal usada durante la recuperación. Ejecuta `passwd` desde SSH y elige una contraseña privada. Después elimina la línea `passwd:` de `/boot/firmware/user-data` sin cambiar el `instance-id`; consulta la [guía de recuperación](docs/password-recovery.md).
