# Shipping to the VM and getting a verdict back

```
you edit  GifMiniPlayer.ps1          (repo root)
   └─ ./pipeline/ship.sh    (or --watch)
        ├─ zips exactly what ships, drops it on the host file server
        ├─ queues "build.ps1 <build-id>" for the guest
        ├─ guest: deploy -> kill old instances -> launch -> smoke test -> upload evidence
        └─ prints 21 PASS/FAIL assertions, the SHA check, and the screenshot paths
```

## Files

| File | Runs on | Role |
|---|---|---|
| `pipeline/ship.sh` | host | build · queue · wait · report · `--watch` on source hash · `--check` |
| `pipeline/serve/agent.ps1` | guest | polls for commands; `-Install` registers it at logon (survives reboot); self-updates |
| `pipeline/serve/build.ps1` | guest | the ONE smoke test: deploy, launch, assert, screenshot, upload, clean up |
| `pipeline/serve/userflow.ps1` | guest | the user's path: launcher, first-run picker, their own GIF, add more, restart, resize, single instance |
| `pipeline/serve/win.ps1` | guest | the window helpers both tests share (one compiled copy) |
| `pipeline/serve/desktop.ps1` | guest | copies the current bundle to the guest's Desktop with a shortcut (for clicking it by hand) |
| `pipeline/vm-server.py` | host | serves the bundle on `192.168.103.1:8001`, receives uploads into `uploads/` |

## The one-time setup (already done)

Run once in the VM; it writes a Startup shortcut so the poller returns after every reboot:

```
curl.exe -o a.bat http://192.168.103.1:8001/a.bat
a.bat
```

## What is asserted every build

deploy · window exists · owner process alive · window visible · room for the bar
(height >= width + 28) · eight buttons · no zero-height buttons · buttons ordered
transport-first · every button drew its glyph (owner-drawn icons) · window focused ·
animation runs · screenshots captured · pause holds · pause button located · next button
located · switch changes gif · starts in Hello Kitty · peaks button switches the theme ·
bow button switches back · no unhandled error · cleaned up

Behaviour is driven by **clicking the real buttons** at their own coordinates, so the test
covers the buttons themselves rather than the keyboard shortcuts.

Evidence per build, in `uploads/`:
`<id>-result.json`, `<id>-shot-*.png` (window-scoped captures), `<id>-ui.txt` (control tree),
`<id>-error.log` when the app crashed.

## The anti-stale guarantee

The guest reports the SHA256 of the file it actually executed; `ship.sh` compares it with the
local source. A mismatch fails the run — a stale build can never be mistaken for a new one.

## The user-flow test

The smoke test clicks the app's own buttons; it never touches the file picker. That path is
covered by a second test, which `ship.sh` runs automatically after the smoke test passes, on
the same bundle:

```
./pipeline/ship.sh                # smoke test, then the user flow
./pipeline/gmp.sh userflow        # just the user flow, against the last shipped bundle
```

It deletes the config to get a genuine first run, generates two GIFs on the guest (different
sizes, in a folder with a space), and asserts the whole journey: **`Run-GifMiniPlayer.bat`
starts the app** and the picker appears, the user's own GIF is what gets drawn (centre pixel),
the window fits its shape, `+` adds a second, both are saved to config, closing exits cleanly
and reopening restores them without asking again, the wheel keeps the aspect, and a second
launch stacks no second window. It also switches theme with `T` and checks that the choice
survives the restart.

The summary starts with the SHA256 of the file it actually ran; `ship.sh` compares that with
the local source, so a standalone run cannot pass by testing yesterday's zip. The config is
backed up before the test and restored in a `finally`, even if the test throws.

The picker is driven through its real controls (`WM_SETTEXT` on the file-name box, then
`BM_CLICK` on Open) rather than keystrokes, because typing goes to whichever window owns the
keyboard and the VM desktop has other apps on it.

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

## Requirements

- **Host:** `git`, `python3`, `jq`, `curl`, `zip`, and PowerShell 7 for the static gate
  (`~/.local/share/pwsh/pwsh -NoProfile -File check.ps1`).
- **Guest:** the poller running (`a.bat` once; it reinstalls itself at logon) and VMware Tools.
- **One server per machine:** the guest's agent talks to `192.168.103.1:8001`, so only one
  checkout may run `vm-server.py` at a time. A second checkout's `ship.sh` will reuse the
  running server rather than start a competing one.
