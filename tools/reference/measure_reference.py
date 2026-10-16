#!/usr/bin/env python3
"""Local measurement of the SMB35 reference video, for the Battle UI milestones (doc 51).

reference.mp4 must stay on this machine. This tool decodes it with a local ffmpeg pipe, one frame at a time, and prints or
writes DERIVED NUMBERS ONLY: timestamps, pixel coordinates, boxes, colours of single pixels, durations, counts, speeds. It never
saves, copies, displays or sends a frame (nothing is written to disk but the JSON/CSV you ask for), and it has no network code.

Needs: python3, numpy, ffmpeg + ffprobe on the PATH.

  python3 tools/reference/measure_reference.py reference.mp4 --start 515 --end 530 --mode reticle --out sends.json
  python3 tools/reference/measure_reference.py reference.mp4 --start 517 --end 530 --mode lines
  python3 tools/reference/measure_reference.py reference.mp4 --start 746 --end 756 --mode bar
  python3 tools/reference/measure_reference.py reference.mp4 --start 524 --end 528 --mode panes
  python3 tools/reference/measure_reference.py reference.mp4 --start 515 --end 530 --mode frame

Modes (all positions are in the 480x270 canvas units of the Battle screen = 1080p / 4; the video is rescaled to 1920x1080 first):
  reticle  every red four-corner bracket per frame (box, size, thickness, which pane it is on or "air"), and the FLIGHTS between
           panes: start, end, frame count, duration, path, straightness, per-frame progress and speed, the best-fitting easing,
           dwell at the start, size change. This is what the send animation (doc 47 B35-TARGET-003) needs.
  lines    thin red lines per frame (end points, length, thickness, the pane / bar / window each end touches) and the WATCH OUT pill.
  bar      the incoming bar (strip A): icons as blobs against the bar's own colours, tracked over time: entry x, speed, release x.
  panes    per pane: white-flash and blue-card intervals (the KO animation), with frame counts.
  frame    the ring just outside the game window: mean colour per frame (a frame flash), reported only where it changes.
"""
import argparse
import json
import subprocess
import sys
from collections import defaultdict

import numpy as np

W, H = 1920, 1080
U = 4.0  # device px per canvas unit at 1080p

# ---- the layout of doc 47 / BattleHudLayout, in canvas units ----------------------------------------------------------
WINDOW = (112.0, 8.0, 256.0, 224.0)
BAR = (111.5, 236.0, 257.0, 12.0)
CELL = (32.75, 41.5)
COLS_L = (1.25, 35.25, 69.25)
COLS_R = (377.25, 411.25, 445.25)
ROWS = (10.5, 53.5, 96.5, 139.5, 182.5, 225.5)


def panes():
    """[(id, x, y, w, h)] in canvas units: ids 1..17 left panel, 18..34 right, as the game numbers them."""
    out = []
    for side, cols in ((0, COLS_L), (1, COLS_R)):
        badge = 2 if side == 0 else 0
        for k in range(18):
            col, row = k % 3, k // 3
            if col == badge and row == 0:
                continue
            out.append((len(out) + 1, cols[col], ROWS[row], CELL[0], CELL[1]))
    return out


PANES = panes()


def pane_at(cx, cy, margin=3.0):
    """The pane whose rect (grown by `margin`) holds (cx, cy), or None."""
    for pid, x, y, w, h in PANES:
        if x - margin <= cx <= x + w + margin and y - margin <= cy <= y + h + margin:
            return pid
    return None


def region_of(x, y):
    p = pane_at(x, y, 2.0)
    if p is not None:
        return "pane%d" % p
    if BAR[0] - 2 <= x <= BAR[0] + BAR[2] + 2 and BAR[1] - 2 <= y <= BAR[1] + BAR[3] + 2:
        return "bar"
    if WINDOW[0] <= x <= WINDOW[0] + WINDOW[2] and WINDOW[1] <= y <= WINDOW[1] + WINDOW[3]:
        return "window"
    return "other"


# ---- video ------------------------------------------------------------------------------------------------------------

def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=r_frame_rate,width,height,duration",
                        "-of", "json", path], capture_output=True, text=True, check=True)
    s = json.loads(r.stdout)["streams"][0]
    num, den = s["r_frame_rate"].split("/")
    return {"fps": float(num) / float(den), "width": int(s["width"]), "height": int(s["height"])}


def frames(path, start, end, fps=None):
    """Yields (t_seconds, ndarray H x W x 3 uint8) at 1920x1080, straight from an ffmpeg pipe (nothing touches the disk)."""
    info = probe(path)
    rate = fps or info["fps"]
    cmd = ["ffmpeg", "-v", "error", "-ss", str(start), "-t", str(end - start), "-i", path, "-vf", "fps=%f,scale=%d:%d:flags=neighbor" % (rate, W, H),
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    size = W * H * 3
    i = 0
    while True:
        buf = p.stdout.read(size)
        if len(buf) < size:
            break
        yield start + i / rate, np.frombuffer(buf, np.uint8).reshape(H, W, 3)
        i += 1
    p.stdout.close()
    p.wait()


# ---- connected components (block-wise, then exact) -----------------------------------------------------------------------

def components(mask, block=2):
    """Components of a boolean mask: dicts with n (pixels), box (x0, y0, x1, y1 in px), pts (an N x 2 array of x, y)."""
    bh, bw = mask.shape[0] // block, mask.shape[1] // block
    mb = mask[:bh * block, :bw * block].reshape(bh, block, bw, block).any(axis=(1, 3))
    ys, xs = np.nonzero(mb)
    if len(ys) == 0:
        return []
    index = {(int(y), int(x)): i for i, (y, x) in enumerate(zip(ys, xs))}
    parent = list(range(len(index)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for (y, x), i in index.items():
        for dy, dx in ((0, 1), (1, 0), (1, 1), (1, -1)):
            j = index.get((y + dy, x + dx))
            if j is not None:
                ri, rj = find(i), find(j)
                if ri != rj:
                    parent[ri] = rj
    groups = defaultdict(list)
    for (y, x), i in index.items():
        groups[find(i)].append((y, x))
    out = []
    for g in groups.values():
        gy = np.array([b[0] for b in g])
        gx = np.array([b[1] for b in g])
        y0, y1 = gy.min() * block, (gy.max() + 1) * block
        x0, x1 = gx.min() * block, (gx.max() + 1) * block
        member = np.zeros((gy.max() - gy.min() + 1, gx.max() - gx.min() + 1), bool)
        member[gy - gy.min(), gx - gx.min()] = True
        py, px = np.nonzero(mask[y0:y1, x0:x1])
        keep = member[py // block, px // block]
        py, px = py[keep] + y0, px[keep] + x0
        if len(px) == 0:
            continue
        out.append({"n": int(len(px)), "box": (int(px.min()), int(py.min()), int(px.max()) + 1, int(py.max()) + 1),
                    "pts": np.stack([px, py], axis=1)})
    return out


def red_mask(frame, lo_r=225, hi_g=50, hi_b=70):
    return (frame[:, :, 0] > lo_r) & (frame[:, :, 1] < hi_g) & (frame[:, :, 2] < hi_b)


def to_units(v):
    return round(float(v) / U, 3)


def box_units(box):
    return [to_units(b) for b in box]


# ---- reticle ------------------------------------------------------------------------------------------------------------------

BRACKET_MAX = (CELL[0] * U * 1.6, CELL[1] * U * 1.6)  # corners of one bracket lie within this box (px)


def brackets(comps):
    """Groups the corner-shaped red blobs of one frame into brackets (four L-shaped corners round a rectangle)."""
    corners = []
    for c in comps:
        x0, y0, x1, y1 = c["box"]
        w, h = x1 - x0, y1 - y0
        fill = c["n"] / float(w * h)
        if 6 <= w <= 90 and 6 <= h <= 90 and fill <= 0.7:
            corners.append(c)
    groups = []
    for c in sorted(corners, key=lambda c: (c["box"][1], c["box"][0])):
        for g in groups:
            ux0 = min(g["box"][0], c["box"][0])
            uy0 = min(g["box"][1], c["box"][1])
            ux1 = max(g["box"][2], c["box"][2])
            uy1 = max(g["box"][3], c["box"][3])
            if ux1 - ux0 <= BRACKET_MAX[0] and uy1 - uy0 <= BRACKET_MAX[1]:
                g["box"] = (ux0, uy0, ux1, uy1)
                g["blobs"].append(c)
                break
        else:
            groups.append({"box": c["box"], "blobs": [c]})
    out = []
    for g in groups:
        if len(g["blobs"]) < 2:
            continue  # a stray red thing, not a bracket
        x0, y0, x1, y1 = g["box"]
        thick = np.median([min(b["box"][2] - b["box"][0], b["box"][3] - b["box"][1]) for b in g["blobs"]])
        arm = np.median([max(b["box"][2] - b["box"][0], b["box"][3] - b["box"][1]) for b in g["blobs"]])
        cx, cy = (x0 + x1) / 2.0 / U, (y0 + y1) / 2.0 / U
        pane = None
        for pid, px_, py_, pw, ph in PANES:
            # a bracket sits 0.5..1.5 units outside its pane: its box is the pane grown by about 1.25
            if abs(x0 / U - (px_ - 1.25)) < 1.0 and abs(y0 / U - (py_ - 1.25)) < 1.0 and abs(x1 / U - (px_ + pw + 1.25)) < 1.0 and abs(y1 / U - (py_ + ph + 1.25)) < 1.0:
                pane = pid
        out.append({"box": box_units(g["box"]), "center": [round(cx, 3), round(cy, 3)], "size": [to_units(x1 - x0), to_units(y1 - y0)],
                    "blobs": len(g["blobs"]), "thickness_units": to_units(thick), "arm_units": to_units(arm),
                    "on_pane": pane, "where": ("pane%d" % pane) if pane else region_of(cx, cy)})
    return out


EASINGS = {
    "linear": lambda t: t,
    "ease_out_quad": lambda t: 1 - (1 - t) ** 2,
    "ease_in_quad": lambda t: t * t,
    "ease_in_out_quad": lambda t: 2 * t * t if t < 0.5 else 1 - 2 * (1 - t) ** 2,
    "ease_out_cubic": lambda t: 1 - (1 - t) ** 3,
    "ease_in_out_cubic": lambda t: 4 * t ** 3 if t < 0.5 else 1 - 4 * (1 - t) ** 3,
    "smoothstep": lambda t: t * t * (3 - 2 * t),
}


def fit_easing(progress, times):
    """Best easing for per-frame progress values, with the offset (frames) and RMS error of each candidate. `times` is 0..1."""
    best = []
    for name, f in EASINGS.items():
        err = float(np.sqrt(np.mean([(p - f(t)) ** 2 for p, t in zip(progress, times)])))
        best.append((err, name))
    best.sort()
    return [{"easing": n, "rms": round(e, 4)} for e, n in best[:3]]


def flights(track, fps):
    """From a per-frame list of the main bracket ({t, center, size, on_pane}), cuts the runs where it is in the air."""
    out = []
    i = 0
    n = len(track)
    while i < n:
        if track[i]["bracket"] is None or track[i]["bracket"]["on_pane"] is not None:
            i += 1
            continue
        j = i
        while j < n and (track[j]["bracket"] is None or track[j]["bracket"]["on_pane"] is None):
            j += 1
        before = next((k for k in range(i - 1, -1, -1) if track[k]["bracket"] is not None), None)
        after = j if j < n and track[j]["bracket"] is not None else None
        seg = [(k, track[k]["bracket"]) for k in range(i, j) if track[k]["bracket"] is not None]
        gap_frames = (j - i) - len(seg)
        if len(seg) >= 1:
            start_t = track[before]["t"] if before is not None else track[i]["t"]
            f = {"leaves_pane": track[before]["bracket"]["on_pane"] if before is not None else None,
                 "last_on_pane_t": round(start_t, 4), "first_air_t": round(track[i]["t"], 4),
                 "lands_on_pane": track[after]["bracket"]["on_pane"] if after is not None else None,
                 "landed_t": round(track[after]["t"], 4) if after is not None else None,
                 "air_frames": j - i, "air_frames_with_bracket": len(seg), "air_frames_without_bracket": gap_frames,
                 "air_duration_s": round((j - i) / fps, 4),
                 "leave_to_land_s": round(track[after]["t"] - start_t, 4) if after is not None else None,
                 "frame_period_s": round(1.0 / fps, 5)}
            pts = np.array([b["center"] for _, b in seg])
            f["path"] = [{"t": round(track[k]["t"], 4), "center": b["center"], "size": b["size"], "thickness_units": b["thickness_units"]} for k, b in seg]
            f["start_center"] = [round(float(pts[0][0]), 3), round(float(pts[0][1]), 3)]
            f["window_center"] = [WINDOW[0] + WINDOW[2] / 2, WINDOW[1] + WINDOW[3] / 2]
            if after is not None:
                end = np.array(track[after]["bracket"]["center"])
                start = pts[0]  # a flight starts where the bracket first shows in the air, not at the pane it left
                d = end - start
                dd = float(d @ d)
                if dd > 1e-6:
                    prog = [float((np.array(b["center"]) - start) @ d) / dd for _, b in seg]
                    u = d / np.sqrt(dd)
                    perp = [abs(float(u[0] * (b["center"][1] - start[1]) - u[1] * (b["center"][0] - start[0]))) for _, b in seg]
                    f["straight_path_max_deviation_units"] = round(max(perp), 3)
                    f["progress_per_air_frame"] = [round(p, 3) for p in prog]
                    steps = np.diff([0.0] + prog + [1.0])
                    f["max_step_fraction"] = round(float(steps.max()), 3)
                    times = [(k - i) / float(j - i) for k, _ in seg]  # 0 at the first air frame, 1 at the first frame back on a pane
                    still = 0
                    for p_ in prog:
                        if abs(p_) < 0.02:
                            still += 1
                        else:
                            break
                    f["dwell_air_frames_at_start"] = still
                    f["easing_fit"] = fit_easing(prog, times)
                    f["travel_units"] = round(float(np.sqrt(dd)), 2)
                    f["start_to_window_center_units"] = round(float(np.linalg.norm(pts[0] - np.array(f["window_center"]))), 2)
                    sizes = [b["size"] for _, b in seg]
                    f["size_first_last"] = [sizes[0], sizes[-1]]
                    f["size_end_pane"] = track[after]["bracket"]["size"]
            out.append(f)
        i = j
    return out


def mode_reticle(path, a, fps_arg):
    info = probe(path)
    fps = fps_arg or info["fps"]
    track = []
    for t, fr in frames(path, a.start, a.end, fps_arg):
        comps = components(red_mask(fr))
        bs = brackets(comps)
        # the main bracket: the biggest by number of blobs, then by size
        bs.sort(key=lambda b: (-b["blobs"], -(b["size"][0] * b["size"][1])))
        track.append({"t": t, "bracket": bs[0] if bs else None, "all": bs})
    return {"mode": "reticle", "fps": fps, "frames": [{"t": round(x["t"], 4), "brackets": x["all"]} for x in track if x["all"]],
            "flights": flights(track, fps), "frames_without_any_bracket": sum(1 for x in track if x["bracket"] is None), "frame_count": len(track)}


# ---- lines -------------------------------------------------------------------------------------------------------------------

def mode_lines(path, a, fps_arg):
    info = probe(path)
    fps = fps_arg or info["fps"]
    out = []
    for t, fr in frames(path, a.start, a.end, fps_arg):
        comps = components(red_mask(fr))
        lines, pills = [], []
        for c in comps:
            x0, y0, x1, y1 = c["box"]
            w, h = x1 - x0, y1 - y0
            fill = c["n"] / float(w * h)
            if max(w, h) >= 70 and fill < 0.2:
                pts = c["pts"].astype(float)
                ctr = pts.mean(axis=0)
                u, s, vt = np.linalg.svd(pts - ctr, full_matrices=False)
                axis = vt[0]
                proj = (pts - ctr) @ axis
                a_pt, b_pt = pts[int(proj.argmin())], pts[int(proj.argmax())]
                length = float(proj.max() - proj.min())
                lines.append({"from": [to_units(a_pt[0]), to_units(a_pt[1])], "to": [to_units(b_pt[0]), to_units(b_pt[1])],
                              "from_region": region_of(a_pt[0] / U, a_pt[1] / U), "to_region": region_of(b_pt[0] / U, b_pt[1] / U),
                              "length_units": round(length / U, 2), "thickness_device_px": round(c["n"] / max(length, 1.0), 2)})
            elif c["n"] >= 600 and fill >= 0.5:
                pills.append({"box": box_units(c["box"]), "where": region_of((x0 + x1) / 2 / U, (y0 + y1) / 2 / U)})
        if lines or pills:
            out.append({"t": round(t, 4), "lines": lines, "red_solids": pills})
    return {"mode": "lines", "fps": fps, "frames": out}


# ---- bar ---------------------------------------------------------------------------------------------------------------------

def mode_bar(path, a, fps_arg):
    info = probe(path)
    fps = fps_arg or info["fps"]
    bx, by, bw, bh = [int(round(v * U)) for v in BAR]
    stack = []
    times = []
    for t, fr in frames(path, a.start, a.end, fps_arg):
        stack.append(fr[by + 6:by + bh - 6, bx:bx + bw].astype(np.int16).copy())  # a thin band through the bar's middle
        times.append(t)
    if not stack:
        return {"mode": "bar", "frames": []}
    s = np.stack(stack)
    bg = np.median(s, axis=0)  # the bar's own zone colours (icons move, so the median drops them)
    out = []
    for t, fr in zip(times, s):
        diff = np.abs(fr - bg).max(axis=2) > 40
        cols = diff.any(axis=0)
        xs = np.nonzero(cols)[0]
        blobs = []
        if len(xs):
            start = xs[0]
            prev = xs[0]
            for x in xs[1:]:
                if x - prev > 6:
                    blobs.append((start, prev))
                    start = x
                prev = x
            blobs.append((start, prev))
        out.append({"t": round(t, 4), "icons": [{"x0": round(b0 / U, 2), "x1": round((b1 + 1) / U, 2), "center": round((b0 + b1 + 1) / 2 / U, 2)} for b0, b1 in blobs if b1 - b0 >= 12]})
    # tracks: nearest-neighbour association frame to frame
    tracks = []
    for fr in out:
        for icon in fr["icons"]:
            best = None
            for tr in tracks:
                last = tr[-1]
                if last[0] == fr["t"]:
                    continue
                if abs(last[1] - icon["center"]) < 12 and fr["t"] - last[0] < 0.25:
                    if best is None or abs(last[1] - icon["center"]) < abs(best[-1][1] - icon["center"]):
                        best = tr
            if best is None:
                tracks.append([(fr["t"], icon["center"])])
            else:
                best.append((fr["t"], icon["center"]))
    summary = []
    for tr in tracks:
        if len(tr) < 4:
            continue
        ts = np.array([p[0] for p in tr])
        xs_ = np.array([p[1] for p in tr])
        slope = float(np.polyfit(ts, xs_, 1)[0])
        summary.append({"first_t": round(float(ts[0]), 3), "last_t": round(float(ts[-1]), 3), "x_first": round(float(xs_[0]), 2), "x_last": round(float(xs_[-1]), 2),
                        "mean_speed_units_per_s": round(slope, 2), "frames": len(tr)})
    return {"mode": "bar", "fps": fps, "bar": list(BAR), "icon_tracks": summary, "frames": [f for f in out if f["icons"]]}


# ---- panes ---------------------------------------------------------------------------------------------------------------------

def mode_panes(path, a, fps_arg):
    info = probe(path)
    fps = fps_arg or info["fps"]
    state = {pid: {"white": [], "blue": []} for pid, *_ in PANES}
    for t, fr in frames(path, a.start, a.end, fps_arg):
        for pid, px_, py_, pw, ph in PANES:
            x0, y0 = int(px_ * U) + 2, int(py_ * U) + 2
            x1, y1 = int((px_ + pw) * U) - 2, int((py_ + ph) * U) - 2
            sub = fr[y0:y1:3, x0:x1:3]
            white = float(((sub > 235).all(axis=2)).mean())
            blue = float(((sub[:, :, 2] > 170) & (sub[:, :, 0] < 90) & (sub[:, :, 1] < 140)).mean())
            state[pid]["white"].append((t, white))
            state[pid]["blue"].append((t, blue))
    events = {}
    for pid, d in state.items():
        ev = []
        for key, thresh in (("white", 0.85), ("blue", 0.35)):
            run = None
            for t, v in d[key]:
                if v >= thresh and run is None:
                    run = [t, t, 1]
                elif v >= thresh:
                    run[1], run[2] = t, run[2] + 1
                elif run is not None:
                    ev.append({"kind": key + "_%d" % int(thresh * 100), "from": round(run[0], 4), "to": round(run[1], 4), "frames": run[2]})
                    run = None
            if run is not None:
                ev.append({"kind": key + "_%d" % int(thresh * 100), "from": round(run[0], 4), "to": round(run[1], 4), "frames": run[2], "open": True})
        if ev:
            events[str(pid)] = ev
    return {"mode": "panes", "fps": fps, "pane_events": events}


# ---- frame -------------------------------------------------------------------------------------------------------------------------

def mode_frame(path, a, fps_arg):
    info = probe(path)
    fps = fps_arg or info["fps"]
    x0, y0, w, h = [int(round(v * U)) for v in WINDOW]
    out = []
    last = None
    for t, fr in frames(path, a.start, a.end, fps_arg):
        ring = np.concatenate([fr[y0 - 8:y0 - 2, x0:x0 + w].reshape(-1, 3), fr[y0 + h + 2:y0 + h + 8, x0:x0 + w].reshape(-1, 3),
                               fr[y0:y0 + h, x0 - 8:x0 - 2].reshape(-1, 3), fr[y0:y0 + h, x0 + w + 2:x0 + w + 8].reshape(-1, 3)])
        mean = [round(float(v), 1) for v in ring.mean(axis=0)]
        if last is None or max(abs(mean[i] - last[i]) for i in range(3)) > 6:
            out.append({"t": round(t, 4), "ring_mean_rgb": mean})
        last = mean
    return {"mode": "frame", "fps": fps, "changes": out}


MODES = {"reticle": mode_reticle, "lines": mode_lines, "bar": mode_bar, "panes": mode_panes, "frame": mode_frame}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video")
    ap.add_argument("--start", type=float, required=True, help="seconds into the video")
    ap.add_argument("--end", type=float, required=True)
    ap.add_argument("--mode", choices=sorted(MODES), default="reticle")
    ap.add_argument("--fps", type=float, default=None, help="analyse at this rate (default: the video's own)")
    ap.add_argument("--out", help="write the JSON here (derived numbers only); default: print it")
    a = ap.parse_args()
    result = MODES[a.mode](a.video, a, a.fps)
    result["window_seconds"] = [a.start, a.end]
    text = json.dumps(result, indent=1)
    if a.out:
        with open(a.out, "w") as f:
            f.write(text)
        print("wrote", a.out, "(derived numbers only)", file=sys.stderr)
    else:
        print(text)


if __name__ == "__main__":
    main()
