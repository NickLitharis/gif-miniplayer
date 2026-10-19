#!/usr/bin/env bash
# Queue a script for the guest-side poller (gmp-agent.ps1) and wait for its results.
# No mouse, no keyboard, no XTEST: the guest pulls the command and uploads its own results.
#
#   ./gmp.sh probe7 att        # run serve/probe7.ps1 with argument "att"
#   ./gmp.sh probe4            # run serve/probe4.ps1 with no argument
set -uo pipefail

HERE="/home/marocos/win11-vm"
SERVE="$HERE/serve"
UP="$HERE/uploads"
HOST_IP=192.168.103.1
PORT=8001
WAIT="${WAIT:-300}"

SCRIPT="${1:-}"
shift || true
[[ -n "$SCRIPT" ]] || { echo "usage: ./gmp.sh <script-name> [args...]" >&2; exit 2; }
[[ -f "$SERVE/$SCRIPT.ps1" ]] || { echo "FAIL: no such script ${SCRIPT}.ps1" >&2; exit 2; }

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

# server up?
if [[ $(ss -ltn | grep -c ":$PORT ") -eq 0 ]]; then
  ( cd "$SERVE" && exec python3 "$HERE/vm-server.py" ) > "$HERE/server.log" 2>&1 &
  sleep 1.5
  log "started file server on $HOST_IP:$PORT"
fi

# the poller must be running in the guest; it pings every ~20s
if [[ -f "$UP/agent-ping.txt" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$UP/agent-ping.txt") ))
  log "agent last ping ${age}s ago"
else
  log "WARN no agent-ping.txt yet: is gmp-agent.ps1 running in the guest?"
fi

EXPECT="$SCRIPT-summary.txt"
[[ "${1:-}" == old || "${1:-}" == new ]] && EXPECT="$SCRIPT-summary-$1.txt"
rm -f "$UP/$EXPECT" "$UP/$SCRIPT.log" "$UP/$SCRIPT-summary.txt"
ID=$(date +%H%M%S)
printf '%s %s.ps1 %s\n' "$ID" "$SCRIPT" "$*" > "$SERVE/cmd.txt"
log "queued $ID -> $SCRIPT.ps1 $*"

for i in $(seq 1 $((WAIT / 2))); do
  [[ -f "$UP/$EXPECT" ]] && { log "results after $((i*2))s"; break; }
  sleep 2
done

rm -f "$SERVE/cmd.txt"   # so a restarted poller does not replay it
echo "----- verdict -----"
cat "$UP/$EXPECT" 2>/dev/null || log "no verdict (agent not running, or the script failed)"
echo "----- log -----"
cat "$UP/$SCRIPT.log" 2>/dev/null
[[ -f "$UP/agent-err-$ID.txt" ]] && { echo "----- agent error -----"; cat "$UP/agent-err-$ID.txt"; }
