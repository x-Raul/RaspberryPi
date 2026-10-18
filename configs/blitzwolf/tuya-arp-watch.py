#!/usr/bin/env python3
"""Keep Homebridge connected to Tuya devices that ignore ARP requests.

Listens for Tuya LAN broadcasts (UDP 6666/6667). For each device listed in
TUYA_DEVICES (gwId=mac pairs), it:
  * pins a permanent ARP entry for the device's current IP, and
  * rewrites the IP in Homebridge's TuyaLan config and restarts Homebridge
    when the device moves to a new address.
"""
import json, os, re, select, socket, subprocess, syslog, time

CONFIG = os.environ.get("HB_CONFIG", "/var/lib/homebridge/config.json")
IFACE = os.environ.get("IFACE", "wlan0")
# "gwId=mac,gwId=mac"
DEVICES = dict(p.split("=", 1) for p in os.environ["TUYA_DEVICES"].split(",") if p)


def log(msg):
    syslog.syslog(syslog.LOG_INFO, msg)
    print(msg, flush=True)


def pin_arp(ip, mac):
    subprocess.run(["ip", "neigh", "replace", ip, "lladdr", mac, "dev", IFACE,
                    "nud", "permanent"], check=False)


def sync_config(gw_id, ip):
    """Return True if Homebridge config changed."""
    with open(CONFIG) as f:
        cfg = json.load(f)
    changed = False
    for plat in cfg.get("platforms", []):
        if plat.get("platform") != "TuyaLan":
            continue
        for dev in plat.get("devices", []):
            if dev.get("id") == gw_id and dev.get("ip") != ip:
                log(f"{dev.get('name')}: IP {dev.get('ip')} -> {ip}")
                dev["ip"] = ip
                changed = True
    if changed:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        subprocess.run(["cp", "-p", CONFIG, f"{CONFIG}.bak-{stamp}"], check=True)
        tmp = CONFIG + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cfg, f, indent=4)
        st = os.stat(CONFIG)
        os.chown(tmp, st.st_uid, st.st_gid)
        os.chmod(tmp, st.st_mode)
        os.replace(tmp, CONFIG)
    return changed


def listener(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.bind(("", port))
    return s


def main():
    socks = [listener(6666), listener(6667)]
    pinned = {}  # gwId -> ip
    log(f"watching {len(DEVICES)} Tuya device(s) on {IFACE}")
    while True:
        ready, _, _ = select.select(socks, [], [])
        for s in ready:
            data, (src, _) = s.recvfrom(4096)
            m = re.search(rb"\{.*\}", data)  # v3.1 broadcasts are plain JSON
            try:
                gw_id = json.loads(m.group()).get("gwId") if m else None
            except ValueError:
                gw_id = None
            if gw_id not in DEVICES or pinned.get(gw_id) == src:
                continue
            pin_arp(src, DEVICES[gw_id])
            log(f"pinned ARP {src} -> {DEVICES[gw_id]} ({gw_id[-6:]})")
            if sync_config(gw_id, src):
                subprocess.run(["systemctl", "restart", "homebridge"], check=False)
            pinned[gw_id] = src


if __name__ == "__main__":
    main()
