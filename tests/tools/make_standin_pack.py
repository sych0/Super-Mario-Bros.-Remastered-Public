#!/usr/bin/env python3
"""Builds a small *stand-in* resource pack for visual checks of the Battle previews.

The real game art is generated from the user's own ROM into the "BaseAssets" resource pack,
so a fresh checkout (and CI / a cloud sandbox) only has the repository's bright-green
template sprites. This script paints simple, original, flat-colour replacements for just the
cells World 1-1's previews draw, on top of those templates, into
  <userdata>/resource_packs/SandboxStandIn/Sprites/...
so renders of the previews are readable. It is for development captures only: it is not art
for the game and is never loaded unless a pack called SandboxStandIn is added to the list
(see tests/tools/battle_preview_capture.gd, `pack=SandboxStandIn`).

usage: make_standin_pack.py <repo> <userdata dir (e.g. ~/.local/share/SMB1R)>
"""
import os
import sys
from PIL import Image, ImageDraw

repo, userdata = sys.argv[1], sys.argv[2]
SPR = os.path.join(repo, "Assets", "Sprites")
OUT = os.path.join(userdata, "resource_packs", "SandboxStandIn", "Sprites")

BROWN = (200, 76, 12, 255)
DARK = (31, 31, 31, 255)
TAN = (228, 140, 60, 255)
GREEN = (0, 168, 0, 255)
LGREEN = (128, 208, 16, 255)
RED = (216, 40, 0, 255)
BLUE = (0, 88, 248, 255)
SKIN = (252, 188, 176, 255)
HAIR = (112, 52, 0, 255)
WHITE = (252, 252, 252, 255)
YELLOW = (228, 164, 52, 255)


def load(rel):
    return Image.open(os.path.join(SPR, rel)).convert("RGBA")


def save(img, rel):
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)


def rect(d, x0, y0, x1, y1, c):
    d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=c)


def clear_cell(img, x, y, w, h):
    for yy in range(y, y + h):
        for xx in range(x, x + w):
            img.putpixel((xx, yy), (0, 0, 0, 0))


# ---------------------------------------------------------------- terrain
def terrain():
    im = load("Tilesets/Terrain/Overworld.png")
    d = ImageDraw.Draw(im)

    def tile(ax, ay, fill, top=None):
        x, y = ax * 16, ay * 16
        clear_cell(im, x, y, 16, 16)
        rect(d, x, y, x + 16, y + 16, fill)
        rect(d, x + 15, y, x + 16, y + 16, DARK)
        rect(d, x, y + 15, x + 16, y + 16, DARK)
        rect(d, x + 7, y, x + 8, y + 8, DARK)
        rect(d, x, y + 7, x + 16, y + 8, DARK)
        if top:
            rect(d, x, y, x + 16, y + 2, top)

    for ay in range(3):
        for ax in (1, 2, 3):
            tile(ax, ay, BROWN, (252, 188, 176, 255) if ay == 0 else None)
    tile(4, 2, TAN, WHITE)            # hard block
    tile(0, 4, BROWN)                 # brick
    for ax in (8, 9):                 # pipes: body + a bright stripe, outlined
        for ay in range(8):
            x, y = ax * 16, ay * 16
            clear_cell(im, x, y, 16, 16)
            rect(d, x, y, x + 16, y + 16, GREEN)
            rect(d, x + (3 if ax == 8 else 10), y, x + (6 if ax == 8 else 12), y + 16, LGREEN)
            rect(d, x + (0 if ax == 8 else 15), y, x + (1 if ax == 8 else 16), y + 16, DARK)
            rect(d, x, y + 15, x + 16, y + 16, (0, 120, 0, 255))
    save(im, "Tilesets/Terrain/Overworld.png")


def deco():
    im = load("Tilesets/Deco/OverworldDeco.png")
    d = ImageDraw.Draw(im)
    for i in range(3):
        x = i * 16
        clear_cell(im, x, 0, 16, 16)
        rect(d, x + (3 if i == 0 else 0), 5, x + (16 if i < 2 else 13), 16, LGREEN)
        rect(d, x + (3 if i == 0 else 0), 5, x + (16 if i < 2 else 13), 7, GREEN)
    save(im, "Tilesets/Deco/OverworldDeco.png")


def hills():
    im = load("Backgrounds/Hills/Overworld.png")
    clear_cell(im, 0, 400, 512, 112)
    d = ImageDraw.Draw(im)
    for (cx, w, h) in [(80, 80, 64), (300, 120, 96)]:
        for step in range(h // 8):
            half = (w // 2) - step * (w // 2) // (h // 8)
            y = 512 - 8 * (step + 1)
            rect(d, cx - half, y, cx + half, y + 8, GREEN if step % 2 else (0, 140, 0, 255))
    save(im, "Backgrounds/Hills/Overworld.png")


# ---------------------------------------------------------------- Mario
def mario_cell(im, ox, oy, power, pose, k=0):
    """Draws one 32x32 Mario frame, feet on the cell's bottom row."""
    d = ImageDraw.Draw(im)
    clear_cell(im, ox, oy, 32, 32)
    big = power > 0
    top = oy + (0 if big else 16)
    h = 32 if big else 16
    shirt = WHITE if power == 2 else RED
    pants = RED if power == 2 else BLUE
    u = h // 16  # vertical unit scale
    cx = ox + 16
    lean = 2 if pose == "skid" else 0
    # hat + hair + face
    rect(d, cx - 6 + lean, top, cx + 5 + lean, top + 3 * u, RED)
    rect(d, cx + 1 + lean, top + 2 * u, cx + 8 + lean, top + 3 * u, RED)
    rect(d, cx - 5 + lean, top + 3 * u, cx + 7 + lean, top + 6 * u, SKIN)
    rect(d, cx - 6 + lean, top + 3 * u, cx - 3 + lean, top + 5 * u, HAIR)
    rect(d, cx + 2 + lean, top + 5 * u, cx + 7 + lean, top + 6 * u, HAIR)
    # body
    body0, body1 = top + 6 * u, top + h - 3 * u
    rect(d, cx - 5, body0, cx + 5, body1, shirt)
    rect(d, cx - 5, body0 + (body1 - body0) // 2, cx + 5, body1, pants)
    arm = 3 if pose in ("jump", "die", "climb") else 0
    rect(d, cx - 7, body0 - arm * u // 2, cx - 5, body0 + 3 * u - arm * u // 2, SKIN)
    rect(d, cx + 5, body0 - arm * u // 2, cx + 7, body0 + 3 * u - arm * u // 2, SKIN)
    # legs / shoes
    spread = {0: 0, 1: 2, 2: -2}.get(k, 0) if pose == "move" else (3 if pose == "jump" else 0)
    rect(d, cx - 5 - spread, body1, cx - 1 - spread, top + h, HAIR)
    rect(d, cx + 1 + spread, body1, cx + 5 + spread, top + h, HAIR)


def mario():
    for power, name in enumerate(["Small", "Big", "Fire"]):
        im = load(f"Players/Mario/{name}.png")
        mario_cell(im, 0, 0, power, "idle")
        for i, x in enumerate([64, 128, 96]):
            mario_cell(im, x, 0, power, "move", i)
        mario_cell(im, 160, 0, power, "skid")
        mario_cell(im, 192, 0, power, "jump")
        mario_cell(im, 160, 32, power, "climb", 0)
        mario_cell(im, 192, 32, power, "climb", 1)
        if power == 0:
            mario_cell(im, 224, 32, 0, "die")
        mario_cell(im, 0, 64, 0, "idle")                 # mid-grow frame is a small Mario
        mario_cell(im, 0, 0, power, "idle")
        if power == 1:
            mario_cell(im, 32, 64, 1, "die")
        if power == 2:
            mario_cell(im, 96, 64, 2, "die")
        save(im, f"Players/Mario/{name}.png")


# ---------------------------------------------------------------- enemies, goal
def goomba():
    im = load("Enemies/Goomba.png")
    d = ImageDraw.Draw(im)
    for i in range(2):
        x = i * 16
        clear_cell(im, x, 0, 16, 16)
        rect(d, x + 2, 1, x + 14, 10, (160, 80, 20, 255))
        rect(d, x, 5, x + 16, 10, (160, 80, 20, 255))
        rect(d, x + 4, 4, x + 7, 8, WHITE)
        rect(d, x + 9, 4, x + 12, 8, WHITE)
        rect(d, x + 5, 5, x + 6, 7, DARK)
        rect(d, x + 10, 5, x + 11, 7, DARK)
        rect(d, x + 5, 10, x + 11, 13, SKIN)
        rect(d, x + (1 if i == 0 else 3), 12, x + (6 if i == 0 else 8), 16, DARK)
        rect(d, x + (10 if i == 0 else 8), 12, x + (15 if i == 0 else 13), 16, DARK)
    clear_cell(im, 32, 0, 16, 16)
    rect(d, 32 + 1, 9, 32 + 15, 16, (160, 80, 20, 255))
    save(im, "Enemies/Goomba.png")


def koopa():
    im = load("Enemies/KoopaTroopa.png")
    d = ImageDraw.Draw(im)
    for i in range(2):
        x = i * 16
        clear_cell(im, x, 0, 16, 32)
        rect(d, x + 1, 2, x + 7, 10, (120, 200, 60, 255))
        rect(d, x + 2, 3, x + 4, 5, WHITE)
        rect(d, x + 4, 10, x + 14, 24, GREEN)
        rect(d, x + 6, 12, x + 12, 22, LGREEN)
        rect(d, x + 3, 24, x + 13, 32, (230, 200, 90, 255))
        rect(d, x + (3 if i == 0 else 6), 28, x + (8 if i == 0 else 11), 32, DARK)
    clear_cell(im, 32, 16, 16, 16)
    rect(d, 33, 20, 47, 32, GREEN)
    rect(d, 35, 22, 45, 30, LGREEN)
    save(im, "Enemies/KoopaTroopa.png")


def goal():
    im = load("Tilesets/FlagPole.png")
    d = ImageDraw.Draw(im)
    clear_cell(im, 0, 0, 16, 176)
    rect(d, 7, 8, 9, 176, LGREEN)
    rect(d, 4, 2, 12, 10, GREEN)
    save(im, "Tilesets/FlagPole.png")
    fl = load("Tilesets/Flag.png")
    d = ImageDraw.Draw(fl)
    clear_cell(fl, 0, 0, 16, 16)
    for r in range(8):
        rect(d, 8 - r, 2 + r, 16, 3 + r, WHITE)
        rect(d, 8 - r, 13 - r, 16, 14 - r, WHITE)
    save(fl, "Tilesets/Flag.png")
    q = load("Blocks/QuestionBlock.png")
    d = ImageDraw.Draw(q)
    clear_cell(q, 0, 0, 64, 16)
    for i in range(3):
        x = i * 16
        rect(d, x, 0, x + 16, 16, YELLOW)
        rect(d, x, 0, x + 16, 1, DARK)
        rect(d, x, 15, x + 16, 16, DARK)
        rect(d, x + 5, 4, x + 11, 6, DARK)
        rect(d, x + 9, 6, x + 11, 8, DARK)
        rect(d, x + 7, 8, x + 9, 10, DARK)
        rect(d, x + 7, 11, x + 9, 13, DARK)
    save(q, "Blocks/QuestionBlock.png")


for fn in (terrain, deco, hills, mario, goomba, koopa, goal):
    fn()
print("stand-in pack written to", OUT)
