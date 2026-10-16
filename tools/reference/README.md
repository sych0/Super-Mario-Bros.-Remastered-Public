# Looking at and measuring the SMB35 reference video, locally

The SMB35 reference video is **public** (`https://www.youtube.com/watch?v=AUcFTEfFp58`). For that video only, individual frames and short contact sheets may be viewed (and shown to a model) to understand the Battle UI; the video is still **never committed or redistributed** (`*.mp4` and `/reference.mp4` are git-ignored, and `extract_frames.py` refuses to write inside the repository). This says nothing about any ROM, ROM bytes or ROM-derived Nintendo asset, which stay strictly local (doc 47 section 0.1).

Two tools, both decoding through a local ffmpeg pipe:

* `extract_frames.py` — **labelled contact sheets** for the review windows (the sends, the attacker line, the incoming bar, the KO card) or any window you name, tiles stamped with their time. `--list` shows the presets; `--crop` is in canvas units; `--full` also dumps each frame at 1080p.
* `measure_reference.py` — **derived numbers only** (timestamps, pixel boxes, durations, counts, speeds, easing fits); it writes nothing but the JSON you ask for and has no network code.

```
python3 tools/reference/extract_frames.py reference.mp4 --preset all --out /tmp/smb35-sheets
python3 tools/reference/extract_frames.py reference.mp4 --window 526.7 526.9 --name send --crop 100,0,280,240 --tile-width 640 --cols 3
```

Needs `python3`, `numpy`, `ffmpeg` and `ffprobe`. The video is rescaled to 1920x1080 first; all positions are printed in the Battle
screen's canvas units (1080p / 4), so they can be compared directly with `BattleHudLayout`.

```
python3 tools/reference/measure_reference.py reference.mp4 --start 515 --end 530 --mode reticle --out /tmp/sends.json
```

| `--mode` | what it measures | doc 51 question it closes |
|---|---|---|
| `reticle` | every red four-corner bracket per frame, and each **flight** from the pane it leaves to the pane it lands on: frames in the air, the time from the last frame on the old pane to the first on the new one, where the bracket first shows (distance from the window's middle), the size in flight against the pane's, the path's straightness, the per-frame progress and the best-fitting easing, frames of dwell at the start | origin (window centre or the enemy), duration, easing, path, size in flight, whether the bracket is absent for a frame |
| `lines` | thin red lines per frame: end points and the pane / bar / window each touches, length, thickness in device px; red solid blobs (the WATCH OUT pill) | the bot-to-player line: start, end, how long it lasts, whether it grows |
| `bar` | the incoming bar's icons tracked as blobs against the bar's own colours: entry x, speed, release x | bar motion and release timing |
| `panes` | per pane, intervals of white (flash) and blue (KO card) | KO card timing, pane flashes on a send |
| `frame` | the ring just outside the game window: mean colour where it changes | whether a send flashes the window frame |

Use clips around the sends listed in `docs/51-battle-send-presentation.md` (section 11). Paste the printed JSON (or attach the sheets) back
into the next milestone; every constant of the send animation lives in `BattleSendStyle` (`Scripts/Classes/Battle/BattleSendStyle.gd`)
so it is one edit to apply them.

Ignored by git: `reference.mp4`, `tools/reference/out/`.
