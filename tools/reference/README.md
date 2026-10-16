# Measuring the SMB35 reference video, locally

`reference.mp4` is **never** committed, uploaded or sent anywhere, and no frame, screenshot, contact sheet or audio from it may go
into a model's context, a document or a test (doc 47 section 0.1). `measure_reference.py` is the way to get numbers out of it
without breaking that: it decodes the video through a local ffmpeg pipe and prints **derived numbers only** (timestamps, pixel
boxes, durations, counts, speeds). Nothing it does touches the disk except the JSON you ask for with `--out`, and it has no network code.

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

Use clips around the sends listed in `docs/51-battle-send-presentation.md` (section 11). Paste the printed JSON (not any image) back
into the next milestone; every constant of the send animation lives in `BattleSendStyle` (`Scripts/Classes/Battle/BattleSendStyle.gd`)
so it is one edit to apply them.

Ignored by git: `reference.mp4`, `tools/reference/out/`.
