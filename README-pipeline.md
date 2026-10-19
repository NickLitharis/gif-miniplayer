# Shipping to the VM and getting a verdict back

```
you edit  ~/gif-miniplayer/GifMiniPlayer.ps1
   └─ ./ship.sh            (or ./ship.sh --watch)
        ├─ zips exactly what ships, drops it on the host file server
        ├─ queues "build.ps1 <build-id>" for the guest
        ├─ guest: deploy -> kill old instances -> launch -> smoke test -> upload evidence
        └─ prints 21 PASS/FAIL assertions, the SHA check, and the screenshot paths
```

## Files

| File | Runs on | Role |
|---|---|---|
| `ship.sh` | host | build · queue · wait · report · `--watch` on source hash · `--check` |
| `serve/agent.ps1` | guest | polls for commands; `-Install` registers it at logon (survives reboot); self-updates |
| `serve/build.ps1` | guest | the ONE smoke test: deploy, launch, assert, screenshot, upload, clean up |
| `vm-server.py` | host | serves the bundle on `192.168.103.1:8001`, receives uploads into `uploads/` |

## The one-time setup (already done)

Run once in the VM; it writes a Startup shortcut so the poller returns after every reboot:

```
curl.exe -o a.bat http://192.168.103.1:8001/a.bat
a.bat
```

## What is asserted every build

deploy · window exists · owner process alive · window visible · room for the bar
(height >= width + 28) · five buttons · no zero-height buttons · prev/next/hide/add present
· window focused · animation runs · screenshots captured · pause holds · pause button located
· next button located · switch changes gif · no unhandled error · cleaned up

Behaviour is driven by **clicking the real buttons** at their own coordinates, so the test
covers the buttons themselves rather than the keyboard shortcuts.

Evidence per build, in `uploads/`:
`<id>-result.json`, `<id>-shot-*.png` (window-scoped captures), `<id>-ui.txt` (control tree),
`<id>-error.log` when the app crashed.

## The anti-stale guarantee

The guest reports the SHA256 of the file it actually executed; `ship.sh` compares it with the
local source. A mismatch fails the run — a stale build can never be mistaken for a new one.

## Traps worth remembering

- **A stale elevated instance blocks everything.** If a player was ever started from an
  elevated shell, an unelevated agent cannot kill it (`Access is denied`), cannot close it
  (`WM_CLOSE` blocked by UIPI) and cannot focus past it, because it holds the single-instance
  mutex. The build now detects this and aborts with that message instead of producing a dozen
  confusing failures. Fix: close that window by hand, or reboot the VM.
- **Never trust a folder.** Every launch should re-download the bundle; a stale folder is how
  the old mojibake build kept reappearing.
- **`createdNew` is the wrong question for single-instance.** A named mutex outlives its owner
  and `createdNew` then reports false forever, silently blocking every start. Take ownership
  with `WaitOne(0)` and treat `AbandonedMutexException` as success.
