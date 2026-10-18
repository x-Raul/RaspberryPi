#!/bin/sh
# Keep DNS alive: restart AdGuard Home / Unbound when they stop answering.
# Runs every minute (dns-watchdog.timer). Acts after 2 consecutive failures,
# at most once every 5 minutes per service.
STATE=/run/dns-watchdog
mkdir -p "$STATE"
log() { logger -t dns-watchdog "$*"; echo "$*"; }
fail() { n=$(( $(cat "$STATE/$1" 2>/dev/null || echo 0) + 1 )); echo $n > "$STATE/$1"; [ $n -ge 2 ]; }
ok()   { rm -f "$STATE/$1"; }
answers() { dig +time=3 +tries=2 "@127.0.0.1" -p "$1" example.com A +short 2>/dev/null | grep -qE '^[0-9.]+$'; }

restart() {
    last=$(cat "$STATE/last_$1" 2>/dev/null || echo 0); now=$(date +%s)
    [ $((now - last)) -lt 300 ] && { log "skip restart $1: restarted $((now - last))s ago"; return; }
    log "restarting $1: $2"
    echo "$now" > "$STATE/last_$1"
    systemctl restart "$1"
}

# Give a freshly (re)started AdGuard time to open port 53 (it can take ~1 min on a Pi Zero).
up_for() { echo $(( $(date +%s) - $(date -d "$(systemctl show "$1" -p ActiveEnterTimestamp --value)" +%s) )); }

if answers 5335; then ok unbound
elif fail unbound; then restart unbound "no answer on 127.0.0.1:5335"
fi

[ "$(up_for AdGuardHome)" -ge 90 ] || exit 0
if answers 53; then ok adguard
elif answers 5335 && fail adguard; then restart AdGuardHome "no answer on 127.0.0.1:53"
fi
