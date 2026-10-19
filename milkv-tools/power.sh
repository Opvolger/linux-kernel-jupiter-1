#!/bin/bash
# Usage: milkv-tools/power.sh on|off|toggle|state
# Board power through the Home Assistant plug. Prefer shutting the board down cleanly
# first (ssh ... sudo poweroff): a hard power cut has corrupted dpkg files before.
set -euo pipefail
HA=${HA_URL:-http://192.168.2.202:8123}
ENTITY=${HA_ENTITY:-switch.zolder_sonoff_plug_1}
TOKEN=${HA_TOKEN:-$(tr -d '[:space:]' < "${HA_TOKEN_FILE:-$HOME/home-assistant.txt}")}

case "${1:-}" in
on|off) service=turn_$1 ;;
toggle) service=toggle ;;
state) service= ;;
*) echo "usage: $0 on|off|toggle|state" >&2; exit 1 ;;
esac

if [ -n "$service" ]; then
	curl -fsS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
		-d "{\"entity_id\":\"$ENTITY\"}" "$HA/api/services/switch/$service" >/dev/null
	sleep 1
fi
curl -fsS -H "Authorization: Bearer $TOKEN" "$HA/api/states/$ENTITY" |
	python3 -I -c 'import json, sys; print(json.load(sys.stdin)["state"])'
