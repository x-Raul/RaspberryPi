#!/bin/sh
# Self-heal Homebridge + BlitzWolf strip. Run every 2 min by homebridge-watchdog.timer.
# Acts only after 2 consecutive failures, and restarts Homebridge at most every 10 min.
CONFIG=/var/lib/homebridge/config.json
STATE=/run/homebridge-watchdog
GATEWAY=192.168.1.254
mkdir -p "$STATE"
log() { logger -t homebridge-watchdog "$*"; echo "$*"; }

# Consecutive-failure counter per check: fail <name> -> returns 0 when it should act.
fail() { n=$(( $(cat "$STATE/$1" 2>/dev/null || echo 0) + 1 )); echo $n > "$STATE/$1"; [ $n -ge 2 ]; }
ok()   { rm -f "$STATE/$1"; }

restart_homebridge() {
    last=$(cat "$STATE/last_restart" 2>/dev/null || echo 0); now=$(date +%s)
    if [ $((now - last)) -lt 600 ]; then log "skip restart ($1): restarted $((now - last))s ago"; return; fi
    log "restarting homebridge: $1"
    echo "$now" > "$STATE/last_restart"
    rm -f "$STATE"/hap "$STATE"/mdns "$STATE"/strip
    systemctl restart homebridge
}

# 1. Network: can we reach the router?
if ping -c 3 -W 2 "$GATEWAY" >/dev/null 2>&1; then ok net
elif fail net; then
    log "gateway unreachable, reconnecting wlan0"
    nmcli device reconnect wlan0 || true
    ok net; exit 0
else exit 0
fi

# Let Homebridge finish starting before judging it.
[ "$(systemctl show homebridge -p ActiveState --value)" = active ] || exit 0
started=$(date -d "$(systemctl show homebridge -p ActiveEnterTimestamp --value)" +%s)
[ $(( $(date +%s) - started )) -ge 120 ] || exit 0

eval "$(python3 - "$CONFIG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print("PIN='%s' PORT=%s" % (c["bridge"]["pin"], c["bridge"].get("port", 51826)))
ips = [d["ip"] for p in c.get("platforms", []) if p.get("platform") == "TuyaLan" for d in p.get("devices", []) if d.get("ip")]
print("STRIPS='%s'" % " ".join(ips))
PY
)"

# 2. HAP server answers.
if curl -sf -m 10 -o /dev/null -H "Authorization: $PIN" "http://127.0.0.1:$PORT/accessories"; then ok hap
elif fail hap; then restart_homebridge "HAP not answering"; exit 0
fi

# 3. Bridge is advertised over mDNS (what the Home app uses to find it).
if avahi-browse -tpk _hap._tcp 2>/dev/null | grep -q ";wlan0;"; then ok mdns
elif fail mdns; then restart_homebridge "bridge not advertised on mDNS"; exit 0
fi

# 4. Each Tuya device that is powered (answers ping) has a live socket.
for ip in $STRIPS; do
    ping -c 2 -W 2 "$ip" >/dev/null 2>&1 || { ok strip; continue; }   # switched off: nothing to fix
    if ss -tn state established "dst $ip:6668" | grep -q 6668; then ok strip
    elif fail strip; then restart_homebridge "no socket to Tuya device $ip"; exit 0
    fi
done
