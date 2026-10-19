# GIF Mini Player

A tiny always-on-top GIF window that lives in the Windows system tray. Spotify-mini-player
feel, but for animated GIFs. Two files, no install, no admin, no build step.

```
gif-miniplayer/
├── pipeline/              the VM test harness (see pipeline/README-pipeline.md)
├── GifMiniPlayer.ps1      the whole app
├── Run-GifMiniPlayer.bat  double-click launcher
├── demo-a.gif             }
├── demo-b.gif             } two 10-frame demo GIFs to flip between
├── check.ps1              static invariants (run after every edit)
└── README.md
```

## Run it

Double-click `Run-GifMiniPlayer.bat`. The first time it will ask you to pick a GIF.

Or from a terminal:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\GifMiniPlayer.ps1 "C:\path\to\your.gif"
```

Requires Windows PowerShell 5.1 (built into Windows 10/11) or PowerShell 7. Nothing to install.

## Controls

## Look

A Spotify-mini-player style card: near-black rounded window, the GIF filling the top, a thin
green **loop-progress line** under it, then one control row — dim grey transport icons that
brighten on hover, the file name in white with `n of m` beneath it in grey, and quiet
`+` / `x` at the far right. Window is `gif width x (gif height + 47)` (3 px progress line +
44 px control row).

The window has a **visible control bar** — no hidden controls:

| Button | Does |
|---|---|
| `◀` | previous GIF in the playlist |
| `❙❙` / `▶` | pause / resume |
| `▶` | next GIF in the playlist |
| `+` | add GIFs (multi-select) |
| `—` | minimize to the taskbar (restore from there) |
| `×` | hide to tray |

Glyphs are built with `[char]0x25C0`-style escapes, not typed literally, so the file stays pure
ASCII and PowerShell 5.1's Windows-1252 reading of a BOM-less `.ps1` cannot mangle them.

Keyboard and mouse:

### Keyboard and mouse

| Action | What it does |
|---|---|
| Drag the window | Move it |
| Mouse wheel | Resize (keeps the GIF's aspect ratio) |
| Double-click / `Space` | Play / pause (holds the exact frame) |
| `Right` / `Down` / `PageDown` | Next GIF in the playlist |
| `Left` / `Up` / `PageUp` | Previous GIF in the playlist |
| `Delete` | Remove the current GIF from the playlist |
| Right-click | Menu |
| `Ctrl+O` | Add one or more GIFs to the playlist |
| `Esc` | Hide to tray |
| Drop files on it | Add them to the playlist and show the first |
| Tray icon: double-click | Show / hide |
| Tray icon: right-click | Full menu, including Exit |

Menu options: Open GIF (multi-select), Pause, Previous, Next, **Playlist** (tick marks the current
one, click any entry to jump to it), Remove this from playlist, Always on top,
**Start with Windows** (adds a shortcut to your Startup folder), Hide to tray, Exit.

## Single instance

Launching the player again does **not** stack a second window: it focuses the running one and
exits. If the running one is hidden in the tray, double-click the tray icon.

## The playlist

Open several GIFs and flip between them — the list survives restarts.

```powershell
# start with a playlist straight from the command line
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\GifMiniPlayer.ps1 a.gif b.gif c.gif
```

Duplicate paths are ignored, the index is remembered, and files that no longer exist are
skipped on load.

## What it remembers

`%APPDATA%\GifMiniPlayer\config.json` — the playlist (`Paths`), which one was showing (`Index`),
window position, width, always-on-top. Delete that file to reset.

## Performance

Measured inside the Windows 11 VM (2 vCPU), same GIF, same window size, interleaved A/B —
three 6 s samples per build, alternating to cancel host noise:

| State | Before | After |
|---|---|---|
| Playing | 5.73 % mean (3.52 / 8.98 / 4.69 — jittery) | **3.21 %** (2.99 / 3.52 / 3.12 — stable) |
| Paused | 0 % | 0 % |
| Hidden in tray | 3.44 % | **0 %** |
| Working set | ~104 MB | ~106 MB |

What made the difference:

- **No per-frame allocation.** One `Bitmap` + one `Graphics` per GIF, reused for every frame
  (`Clear` + `DrawImage` + `Invalidate`). The old code built a new bitmap and graphics object
  every frame — 20+ GDI objects per second, which is where the jitter and the CPU went.
- **Hidden costs nothing.** `VisibleChanged` stops the frame clock, so a tray-idle player
  used to keep ticking ~17 times a second for no visible reason.
- **`Timer.Interval` written only when the frame delay changes** — assigning it restarts the timer.
- The whole app allocates exactly **two** bitmaps ever: the 32×32 tray icon and the frame buffer.


- Playback is driven by the app itself: it reads the GIF's per-frame delays (`PropertyTagFrameDelay`)
  and steps frames on a timer, drawing each frame to a static bitmap. That is what makes pause exact,
  and why frame timings are honoured instead of guessed.
- `PictureBox` cannot pause an image it animates: `ImageAnimator.StopAnimate` needs the handler
  `PictureBox` creates privately. So the GIF is never handed to `PictureBox` as an animated image.
- Frames are loaded into memory, so the original `.gif` is never locked — you can overwrite
  or replace the file while it is playing.
- APNG and WebP animation are **not** supported; only GIF has frame metadata this reads.
- If anything throws, `%APPDATA%\GifMiniPlayer\error.log` records it — both script-level failures
  and exceptions thrown inside UI event handlers (those never reach a PowerShell `trap`).
