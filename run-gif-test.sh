#!/usr/bin/env bash
# Drives the GifMiniPlayer self-test inside the Win11 VM, without needing the VM password.
#
#   ./run-gif-test.sh --check     # prerequisites only, changes nothing
#   ./run-gif-test.sh             # VM already booted at the unlocked desktop
#
# Requires: the VMware window visible on :0 (same constraint as the Aegis harness),
# and workspace/vmctl.py able to inject keystrokes.
set -uo pipefail

VMX="/mnt/Storage/vmware/Windows 11 x64/Windows 11 x64.vmx"
AEGIS="/home/marocos/vmware/aegis-lab"
HERE="/home/marocos/win11-vm"
SERVE="$HERE/serve"
UP="$HERE/uploads"
HOST_IP=192.168.103.1     # vmnet8 host address: the only route into the guest
PORT=8001
export DISPLAY="${DISPLAY:-:0}"

CHECK_ONLY=0
TEST="probe4"
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  '')      ;;
  *)       TEST="$1" ;;   # e.g. probe5 for the playlist/switching test
esac

log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

case "$TEST" in
  probe4|probe5|probe6) ;;
  *) die "unknown test '$TEST' (probe4 = pause/resume, probe5 = launch-with-playlist, probe6 = live switching)" ;;
esac

# ---- prerequisites -------------------------------------------------------
for tool in vmrun python3 curl ss; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done
[[ -f "$SERVE/$TEST.ps1" ]]            || die "missing $SERVE/$TEST.ps1"
[[ -f "$SERVE/gif-miniplayer.zip" ]]   || die "missing $SERVE/gif-miniplayer.zip"
[[ -f "$AEGIS/vmctl.py" ]]             || die "missing $AEGIS/vmctl.py"
log "files ok"

# vmnet8 must own the address the guest dials
if ! ip -4 -o addr show | grep -q " $HOST_IP/"; then
  die "$HOST_IP is not up. vmnet8 is down: the guest has no route to the host."
fi
log "host address $HOST_IP up"

# modules (they are what make VMware able to power anything on)
# NB: not `lsmod | grep -q` -- with pipefail, grep -q exits early, lsmod dies of SIGPIPE
# and the pipeline reports failure even when the pattern matched.
if [[ $(lsmod | grep -c '^vmmon') -eq 0 ]]; then
  log "WARN vmmon not loaded -> sudo modprobe vmmon vmnet"
fi

# VM running?
if [[ $(vmrun -T ws list 2>/dev/null | grep -cF "$VMX") -gt 0 ]]; then
  log "VM running"
  VM_UP=1
else
  log "VM not running"
  VM_UP=0
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
  python3 -c "import Xlib" 2>/dev/null && log "python Xlib ok (keystroke injection possible)" \
                                        || log "WARN python Xlib missing: sudo apt install python3-xlib"
  [[ $VM_UP -eq 1 ]] || log "NOTE start the VM: open $VMX in VMware and unlock it with the passphrase"
  exit 0
fi

[[ $VM_UP -eq 1 ]] || die "VM is not running. Start it from the VMware GUI (it is partially encrypted, so vmrun needs the passphrase you have), log in, and leave the desktop unlocked."

# ---- serve the bundle ----------------------------------------------------
mkdir -p "$UP"
if [[ $(ss -ltn | grep -c ":$PORT ") -eq 0 ]]; then
  log "starting file/upload server on $HOST_IP:$PORT"
  ( cd "$SERVE" && exec python3 "$HERE/vm-server.py" ) >"$HERE/server.log" 2>&1 &
  sleep 1
fi
curl -sS -o /dev/null -w 'self-check: bundle GET -> %{http_code}\n' "http://$HOST_IP:$PORT/gif-miniplayer.zip" \
  || die "server not answering on $HOST_IP:$PORT"

# ---- inject the bootstrap ------------------------------------------------
# stale results from a previous run must not be mistaken for this run's
rm -f "$UP/$TEST-summary.txt" "$UP/$TEST.log"
# Two hard-won details:
#  * vmctl.py's focus_vm() clicks a hardcoded (500,400), which on this layout is the LEFT
#    monitor, not the VM. Focus the VMware window at its real geometry instead, and click
#    INSIDE the guest surface or VMware will not grab the keyboard (VMCTL_NOFOCUS then).
#  * The guest must type `curl` to a local file and run it with -File. Never iex(irm ...):
#    Defender's AMSI flags that pattern.
VM_CENTER=$(python3 - <<'PY'
from Xlib import display
d = display.Display(':0'); root = d.screen().root
def walk(w):
    try:
        n = w.get_wm_name()
        if n and 'VMware' in str(n):
            g = w.get_geometry(); t = w.translate_coords(root, 0, 0)
            x, y = -t.x, -t.y
            print(f'{x + g.width // 2} {y + g.height // 2}')
            return True
        for c in w.query_tree().children:
            if walk(c): return True
    except Exception:
        pass
    return False
walk(root)
PY
)
[[ -n "$VM_CENTER" ]] || die "could not locate the VMware window on :0 (is it visible?)"
log "focusing the guest at $VM_CENTER"
python3 "$AEGIS/vmctl.py" click $VM_CENTER || die "click failed"
sleep 1
VMCTL_NOFOCUS=1 python3 "$AEGIS/vmctl.py" key meta+r || die "could not send Win+R"
sleep 2
BOOT="powershell -NoProfile -ExecutionPolicy Bypass -Command \"curl.exe -s -o \$env:USERPROFILE\\$TEST.ps1 http://192.168.103.1:8001/$TEST.ps1; & \$env:USERPROFILE\\$TEST.ps1\""
VMCTL_NOFOCUS=1 python3 "$AEGIS/vmctl.py" run "$BOOT" || die "could not type the bootstrap command"

# ---- wait for the results ------------------------------------------------
log "waiting for uploads in $UP (up to 4 min)"
for i in $(seq 1 120); do
  if [[ -f "$UP/$TEST-summary.txt" ]]; then
    log "results arrived after $((i*2))s"
    break
  fi
  sleep 2
done

echo "----- verdict -----"
cat "$UP/$TEST-summary.txt" 2>/dev/null || log "no verdict -> the guest never reported back"
echo "----- log -----"
cat "$UP/$TEST.log" 2>/dev/null
echo "----- files -----"
ls -lh "$UP" 2>/dev/null | grep -viE '^total' | tail -12
