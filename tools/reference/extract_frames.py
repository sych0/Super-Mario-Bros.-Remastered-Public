#!/usr/bin/env python3
"""Labelled frame sheets from the PUBLIC SMB35 reference video, for looking at the Battle UI's animations (doc 51).

Only for the public SMB35 gameplay video (https://www.youtube.com/watch?v=AUcFTEfFp58). The sheets are for inspection: they stay
OUTSIDE the repository (the default output folder is under the system temp dir; `*.mp4` and `tools/reference/out/` are git-ignored)
and neither the video nor its frames are ever committed. This policy covers that video only; it says nothing about any ROM or
ROM-derived asset, which never leave the machine they are on.

Each requested window is decoded with a local ffmpeg pipe and tiled into PNG contact sheets, every tile labelled with its time in
seconds (the first tile is the first frame at or after the window's start; later ones are start + n / fps). Needs python3, numpy,
Pillow, ffmpeg + ffprobe.

  python3 tools/reference/extract_frames.py reference.mp4 --list
  python3 tools/reference/extract_frames.py reference.mp4 --preset sends
  python3 tools/reference/extract_frames.py reference.mp4 --preset all --out /tmp/smb35-sheets
  python3 tools/reference/extract_frames.py reference.mp4 --window 515.8 516.1 --name first-send
  python3 tools/reference/extract_frames.py reference.mp4 --window 526.7 526.9 --crop 100,0,280,240 --tile-width 640 --cols 3 --full

The video is rescaled to 1920x1080 first. `--crop x,y,w,h` is in the Battle screen's canvas units (480x270 = 1080p / 4), so a
crop can be written straight from `BattleHudLayout`. `--fps` samples at that rate (default: every source frame, which is what a
200 ms flight needs); `--full` also writes every frame of the window as its own 1080p PNG.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H, U = 1920, 1080, 4.0
MAX_FRAMES = 600  # per window, a guard against a typo'd end time

# The windows named for the send / attacker / bar / KO review. (name, start, end, options). A single instant gets a window around it.
AROUND = (0.35, 0.55)  # seconds before / after a single instant
BAR_VIEW = {"crop": (104, 228, 272, 40), "tile_width": 544, "cols": 2, "per_sheet": 24}
PRESETS = {
    "sends": [
        ("send-515.8", 515.8, 516.1, {}),
        ("send-526.7", 526.7, 526.9, {}),
        ("send-527.6", 527.6, 527.9, {}),
        ("send-528.5", 528.5, 528.7, {}),
    ]
    + [("instant-%s" % t, t - AROUND[0], t + AROUND[1], {}) for t in (536.7, 537.6, 548.7, 561.9, 607.7, 618.7)],
    "attacker": [("attacker-517.6", 517.1, 518.6, {})],
    "bar": [
        ("bar-512-523", 512.0, 523.0, dict(BAR_VIEW, fps=10.0)),
        ("bar-746-754", 746.0, 754.0, dict(BAR_VIEW, fps=10.0)),
    ],
    "ko": [("ko-524.4-527.3", 524.4, 527.3, {})],
}


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=avg_frame_rate,r_frame_rate,width,height",
         "-of", "json", path], capture_output=True, text=True, check=True).stdout
    s = json.loads(out)["streams"][0]
    num, den = (s.get("avg_frame_rate") or s["r_frame_rate"]).split("/")
    return float(num) / float(den or 1), int(s["width"]), int(s["height"])


def frames(path, start, end, fps, crop, tile_w):
    """Yield (time, HxWx3 uint8) for [start, end] at `fps`, cropped (canvas units) and scaled to `tile_w` wide."""
    vf = ["scale=%d:%d:flags=area" % (W, H)]
    cw, ch = W, H
    if crop:
        x, y, w, h = [int(round(v * U)) for v in crop]
        vf.append("crop=%d:%d:%d:%d" % (w, h, x, y))
        cw, ch = w, h
    th = max(2, int(round(tile_w * ch / cw)) // 2 * 2)
    vf.append("scale=%d:%d:flags=area" % (tile_w, th))
    cmd = ["ffmpeg", "-v", "error", "-ss", "%.3f" % start, "-i", path, "-t", "%.3f" % (end - start)]
    if fps:
        vf.insert(0, "fps=%g" % fps)
    cmd += ["-vf", ",".join(vf), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    n = 0
    size = tile_w * th * 3
    while n < MAX_FRAMES:
        buf = p.stdout.read(size)
        if len(buf) < size:
            break
        yield n, np.frombuffer(buf, np.uint8).reshape(th, tile_w, 3)
        n += 1
    p.stdout.close()
    p.kill()
    p.wait()


def label(img, text):
    d = ImageDraw.Draw(img)
    font = ImageFont.load_default(size=max(12, img.width // 28))
    box = d.textbbox((2, 2), text, font=font)
    d.rectangle((0, 0, box[2] + 3, box[3] + 3), fill=(0, 0, 0))
    d.text((2, 2), text, fill=(255, 255, 0), font=font)


def sheet(tiles, cols, pad=3):
    tw, th = tiles[0].size
    rows = (len(tiles) + cols - 1) // cols
    out = Image.new("RGB", (cols * (tw + pad) + pad, rows * (th + pad) + pad), (40, 40, 48))
    for i, t in enumerate(tiles):
        out.paste(t, (pad + (i % cols) * (tw + pad), pad + (i // cols) * (th + pad)))
    return out


def run_window(path, out_dir, name, start, end, opts, args, src_fps, index):
    fps = args.fps if args.fps else opts.get("fps")
    rate = fps if fps else src_fps
    crop = args.crop if args.crop else opts.get("crop")
    tile_w = args.tile_width if args.tile_width else opts.get("tile_width", 384)
    cols = args.cols if args.cols else opts.get("cols", 5)
    per_sheet = args.per_sheet if args.per_sheet else opts.get("per_sheet", 20)
    tiles, times, sheets = [], [], []

    def flush():
        if not tiles:
            return
        fn = os.path.join(out_dir, "%s_%02d.png" % (name, len(sheets) + 1))
        sheet(tiles, cols).save(fn)
        sheets.append(fn)
        index.append("%s  t=%.3f..%.3f  %d frames" % (os.path.basename(fn), times[0], times[-1], len(tiles)))
        tiles.clear()
        times.clear()

    for n, arr in frames(path, start, end, fps, crop, tile_w):
        t = start + n / rate
        im = Image.fromarray(arr)
        label(im, "%.3f" % t)
        tiles.append(im)
        times.append(t)
        if len(tiles) >= per_sheet:
            flush()
    flush()
    if args.full:
        dump_full(path, out_dir, name, start, end, fps, crop)
    return sheets


def dump_full(path, out_dir, name, start, end, fps, crop):
    """Every frame of the window as its own PNG at 1080p (cropped), named <name>_f0000.png ... in order."""
    vf = ["scale=%d:%d:flags=area" % (W, H)]
    if fps:
        vf.insert(0, "fps=%g" % fps)
    if crop:
        x, y, w, h = [int(round(v * U)) for v in crop]
        vf.append("crop=%d:%d:%d:%d" % (w, h, x, y))
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "%.3f" % start, "-i", path, "-t", "%.3f" % (end - start),
                    "-vf", ",".join(vf), "-frames:v", str(MAX_FRAMES), os.path.join(out_dir, "%s_f%%04d.png" % name)], check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video")
    ap.add_argument("--preset", choices=sorted(PRESETS) + ["all"], help="the review windows (see --list)")
    ap.add_argument("--window", nargs=2, type=float, metavar=("START", "END"), action="append", help="a window in seconds")
    ap.add_argument("--name", default="window", help="file name stem for --window")
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "smb35-sheets"), help="output folder (keep it out of the repo)")
    ap.add_argument("--fps", type=float, help="sample rate (default: every source frame)")
    ap.add_argument("--crop", type=lambda s: tuple(float(v) for v in s.split(",")), help="x,y,w,h in canvas units (480x270)")
    ap.add_argument("--tile-width", type=int, help="tile width in px (default 384)")
    ap.add_argument("--cols", type=int, help="tiles per row (default 5)")
    ap.add_argument("--per-sheet", type=int, help="tiles per sheet (default 20)")
    ap.add_argument("--full", action="store_true", help="also write each frame at full (cropped) resolution")
    ap.add_argument("--list", action="store_true", help="print the preset windows and exit")
    args = ap.parse_args()

    if args.list:
        for k, v in PRESETS.items():
            for name, a, b, o in v:
                print("%-8s %-18s %.3f-%.3f %s" % (k, name, a, b, o or ""))
        return 0
    src_fps, w, h = probe(args.video)
    windows = []
    if args.preset:
        for k in (sorted(PRESETS) if args.preset == "all" else [args.preset]):
            windows += PRESETS[k]
    for a, b in args.window or []:
        windows.append((args.name, a, b, {}))
    if not windows:
        ap.error("give --preset or --window")
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    out_dir = os.path.abspath(args.out)
    if out_dir == repo or out_dir.startswith(repo + os.sep):
        ap.error("--out must be outside the repository (frames are never committed): %s" % out_dir)
    os.makedirs(out_dir, exist_ok=True)
    print("video %dx%d @ %.3f fps -> %s" % (w, h, src_fps, out_dir))
    index = []
    for name, a, b, o in windows:
        made = run_window(args.video, out_dir, name, a, b, o, args, src_fps, index)
        print("%-18s %.3f-%.3f -> %d sheet(s)" % (name, a, b, len(made)))
    with open(os.path.join(out_dir, "index.txt"), "w") as f:
        f.write("\n".join(index) + "\n")
    print("index:", os.path.join(out_dir, "index.txt"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
