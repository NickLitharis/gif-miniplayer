# GIF Mini Player

A tiny always-on-top GIF window that lives in the Windows system tray. Spotify-mini-player
feel, but for animated GIFs. Two files, no install, no admin, no build step.

```
gif-miniplayer/
├── GifMiniPlayer.ps1      the whole app
├── Run-GifMiniPlayer.bat  double-click launcher
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

| Action | What it does |
|---|---|
| Drag the window | Move it |
| Mouse wheel | Resize (keeps the GIF's aspect ratio) |
| Double-click / `Space` | Play / pause (holds the exact frame) |
| Right-click | Menu |
| `Ctrl+O` | Open another GIF |
| `Esc` | Hide to tray |
| Drop a file on it | Load that GIF |
| Tray icon: double-click | Show / hide |
| Tray icon: right-click | Full menu, including Exit |

Menu options: Open GIF, Pause, Always on top, **Start with Windows** (adds a shortcut to your
Startup folder), Hide to tray, Exit.

## What it remembers

`%APPDATA%\GifMiniPlayer\config.json` — last GIF, window position, width, always-on-top.
Delete that file to reset.

## Notes

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
