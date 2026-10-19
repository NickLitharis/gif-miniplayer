#!/usr/bin/env bash
# ship.sh -- send the current source to the VM, run the smoke test, report what to fix.
#
#   ./ship.sh                ship once, print the assertion table
#   ./ship.sh --watch        keep watching the source; re-ship on every change
#   ./ship.sh --check        prerequisites only
#
# The guest proves it ran the NEW CODE by reporting the SHA256 of the deployed file;
# this script compares it with the local source and fails loudly on a mismatch.
set -uo pipefail

PROJ="/home/marocos/gif-miniplayer"
VM="/home/marocos/win11-vm"
SERVE="$VM/serve"
UP="$VM/uploads"
HOST_IP=192.168.103.1
PORT=8001
SRC="$PROJ/GifMiniPlayer.ps1"

log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

ensure_server() {
  if [[ $(ss -ltn | grep -c ":$PORT ") -eq 0 ]]; then
    ( cd "$SERVE" && exec python3 "$VM/vm-server.py" ) > "$VM/server.log" 2>&1 &
    sleep 1.5
  fi
}

agent_alive() {
  [[ -f "$UP/agent-ping.txt" ]] || return 1
  local age=$(( $(date +%s) - $(stat -c %Y "$UP/agent-ping.txt") ))
  [[ $age -lt 90 ]]
}

ship_once() {
  [[ -f "$SRC" ]] || die "no source at $SRC"
  local sha_local build
  sha_local=$(sha256sum "$SRC" | awk '{print $1}')
  build=$(date +%m%d-%H%M%S)

  # package exactly what the plan says ships
  ( cd "$PROJ" && rm -f gif-miniplayer.zip && zip -q gif-miniplayer.zip \
      GifMiniPlayer.ps1 Run-GifMiniPlayer.bat README.md demo-a.gif demo-b.gif ) || die "zip failed"
  cp "$PROJ/gif-miniplayer.zip" "$SERVE/gif-miniplayer.zip"

  ensure_server
  agent_alive || die "guest agent is not polling (start it in the VM, see README-pipeline.md)"

  rm -f "$UP/$build-result.json"
  printf '%s build.ps1 %s\n' "$build" "$build" > "$SERVE/cmd.txt"
  log "shipped build $build (local sha ${sha_local:0:12})"

  local i
  for i in $(seq 1 90); do
    [[ -f "$UP/$build-result.json" ]] && break
    sleep 2
  done
  rm -f "$SERVE/cmd.txt"      # don't replay on agent restart

  if [[ ! -f "$UP/$build-result.json" ]]; then
    # the agent always captures stdout: recover the result from there
    local out
    out=$(ls -t "$UP"/agent-out-*.txt 2>/dev/null | head -1)
    if [[ -n "$out" ]] && grep -q 'RESULT_JSON:' "$out"; then
      log "result.json missing — recovered from $out"
      grep -o 'RESULT_JSON:.*' "$out" | tail -1 | sed 's/^RESULT_JSON://' > "$UP/$build-result.json"
    fi
  fi
  [[ -f "$UP/$build-result.json" ]] || die "no result after 180s — check $UP/agent-out-*.txt"
  cp -f "$UP/$build-result.json" "$UP/build-verdict.json" && log "verdict frozen" || log "WARN: verdict not frozen"
  local sha_guest pass
  sha_guest=$(jq -r '.sha256' "$UP/$build-result.json")
  pass=$(jq -r '.pass' "$UP/$build-result.json")

  echo
  printf '%-28s %-6s %s\n' ASSERTION RESULT DETAIL
  printf '%-28s %-6s %s\n' ---------------------------- ------ ------
  jq -r '.assertions | to_entries[] | [.key, (if .value.ok then "PASS" else "FAIL" end), .value.detail] | @tsv' \
    "$UP/$build-result.json" | awk -F'\t' '{printf "%-28s %-6s %s\n", $1, $2, $3}'
  echo

  if [[ -z "$sha_guest" || "$sha_guest" == "null" ]]; then
    log "sha unavailable — deploy did not complete, so nothing ran"
    pass=false
  elif [[ "$sha_guest" == "$sha_local" ]]; then
    log "newest code ran: sha matches (${sha_local:0:12})"
  else
    log "SHA MISMATCH — the VM ran different code!"
    log "  local: $sha_local"
    log "  guest: $sha_guest"
    pass=false
  fi
  log "screenshots + result: $UP/$build-*.png  $UP/$build-result.json"
  [[ -f "$UP/$build-ui.txt" ]] && log "control tree: $UP/$build-ui.txt"
  [[ -f "$UP/$build-error.log" ]] && { log "app error.log:"; sed -n '1,6p' "$UP/$build-error.log"; }

  if [[ "$pass" == "true" ]]; then log "VERDICT: PASS"; return 0; else log "VERDICT: FAIL"; return 1; fi
}

case "${1:-}" in
  --check)
    ensure_server
    agent_alive && log "agent alive" || log "agent NOT polling"
    [[ -f "$SRC" ]] && log "source present" || log "source missing"
    exit 0 ;;
  --watch)
    log "watching $SRC (ctrl-c to stop)"
    last=""
    while true; do
      cur=$(sha256sum "$SRC" 2>/dev/null | awk '{print $1}')
      if [[ "$cur" != "$last" && -n "$cur" ]]; then
        last="$cur"
        log "change detected"
        ship_once || log "build failed — fix and save again"
      fi
      sleep 2
    done ;;
  '')   ship_once ;;
  *)    die "unknown option $1" ;;
esac
