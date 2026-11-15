#!/usr/bin/env python
"""Ant face generator — composes deterministic ant faces from the sliced
parts sheet (art/sheet_parts/). Seed = soul name; the same name always
yields the same face.

Usage:
  python tools/antface_gen.py --name "Qwen3.5" --out avatar.png
  python tools/antface_gen.py --pool 24          # art/avatars/ant_00..23.png
  python tools/antface_gen.py --grid 12          # preview grid builds/grid.png
"""
import argparse
import glob
import hashlib
import os
import random

from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(__file__), '..')
PARTS = os.path.join(ROOT, 'art', 'sheet_parts')
CANVAS = 320

# parts that are actually the sheet's category label text
LABELS = {('head', 1), ('eyes', 0), ('antennae', 1), ('mandibles', 0),
          ('mouthexp', 0), ('brows', 0)}


def load(cat):
    files = sorted(glob.glob(os.path.join(PARTS, cat, f'{cat}_*.png')))
    out = []
    for i, f in enumerate(files):
        if (cat, i) in LABELS:
            continue
        out.append(Image.open(f).convert('RGBA'))
    return out


HEADS = load('head')
EYES = load('eyes')
BROWS = load('brows')
ANTENNAE = load('antennae')
MANDIBLES = load('mandibles')
MOUTHS = load('mouthexp')
CHEEKS = load('cheeks')
HEADTOPS = load('headtop')
DETAILS = load('facedet')

# single-piece categories where the part must be mirrored for the pair
ANTENNAE_SINGLE = {2, 3, 4, 5, 6, 7, 12, 13, 14}
MANDIBLE_SINGLE = {1, 2, 4, 5, 6, 7}
BROW_SINGLE = set(range(len(BROWS)))

CX = CANVAS / 2


def tint(im, amp):
    """Subtle per-seed lightness jitter on a part (keeps the canon red)."""
    r, g, b, a = im.split()
    r = r.point(lambda v: max(0, min(255, int(v + amp))))
    g = g.point(lambda v: max(0, min(255, int(v + amp * 0.4))))
    return Image.merge('RGBA', (r, g, b, a))


def paste_center(base, im, cx, cy, scale=1.0, mirror=False):
    if scale != 1.0:
        im = im.resize((max(1, int(im.width * scale)), max(1, int(im.height * scale))))
    if mirror:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    base.alpha_composite(im, (int(cx - im.width / 2), int(cy - im.height / 2)))


def gen_face(seed_text: str) -> Image.Image:
    h = hashlib.sha1(seed_text.encode('utf-8')).digest()
    rng = random.Random(h)
    canvas = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))

    head = HEADS[rng.randrange(len(HEADS))].copy()
    scale = 240.0 / head.width
    paste_center(canvas, tint(head, rng.randint(-14, 10)), CX, 170, scale)

    # antennae rise from the head top
    ai = rng.randrange(len(ANTENNAE))
    ant = ANTENNAE[ai]
    ant_scale = 78.0 / max(ant.height, 1)
    spread = rng.choice((64, 76, 88))
    if ai in ANTENNAE_SINGLE:
        paste_center(canvas, ant, CX - spread, 52, ant_scale)
        paste_center(canvas, ant, CX + spread, 52, ant_scale, mirror=True)
    else:
        paste_center(canvas, ant, CX, 46, ant_scale)

    # eyes at mid-face
    ei = rng.randrange(len(EYES))
    eye = EYES[ei]
    eye_scale = rng.choice((0.62, 0.7, 0.78)) * 88.0 / max(eye.height, 1)
    eye_y = 165 + rng.randint(-8, 10)
    gap = rng.choice((46, 54, 62))
    paste_center(canvas, eye, CX - gap, eye_y, eye_scale)
    paste_center(canvas, eye, CX + gap, eye_y, eye_scale, mirror=True)

    # brows above the eyes (30% skip)
    if rng.random() < 0.7:
        bi = rng.randrange(len(BROWS))
        brow = BROWS[bi]
        brow_scale = 46.0 / max(brow.width, 1)
        by = eye_y - int(34 * eye_scale) - 8
        paste_center(canvas, brow, CX - gap, by, brow_scale)
        paste_center(canvas, brow, CX + gap, by, brow_scale, mirror=True)

    # mouth: mandibles (with or without an expression) or a bare expression
    if rng.random() < 0.6:
        mi = rng.randrange(len(MANDIBLES))
        mand = MANDIBLES[mi]
        # clamp both dimensions so tall hooks don't swallow the face
        mand_scale = min(132.0 / max(mand.width, 1), 96.0 / max(mand.height, 1))
        my = 244 + rng.randint(-4, 4)
        if mi in MANDIBLE_SINGLE:
            paste_center(canvas, mand, CX - 30, my, mand_scale)
            paste_center(canvas, mand, CX + 30, my, mand_scale, mirror=True)
        else:
            paste_center(canvas, mand, CX, my, mand_scale)
    if rng.random() < 0.55:
        mo = MOUTHS[rng.randrange(len(MOUTHS))]
        paste_center(canvas, mo, CX, 250, 0.8)

    # cheeks and details, mostly absent
    if rng.random() < 0.3:
        ch = CHEEKS[rng.randrange(len(CHEEKS))]
        paste_center(canvas, ch, CX - 96, 205, 0.6)
        paste_center(canvas, ch, CX + 96, 205, 0.6, mirror=True)
    if rng.random() < 0.3:
        de = DETAILS[rng.randrange(len(DETAILS))]
        paste_center(canvas, de, CX + rng.randint(-40, 40), 110 + rng.randint(-8, 8), 0.5)

    return canvas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--name')
    ap.add_argument('--out')
    ap.add_argument('--pool', type=int, default=0)
    ap.add_argument('--grid', type=int, default=0)
    args = ap.parse_args()

    if args.name and args.out:
        gen_face(args.name).save(args.out)
        print('saved', args.out)
        return
    if args.pool:
        os.makedirs(os.path.join(ROOT, 'art', 'avatars'), exist_ok=True)
        for i in range(args.pool):
            gen_face('ant-pool-%d' % i).save(
                os.path.join(ROOT, 'art', 'avatars', 'ant_%02d.png' % i))
        print('pool of', args.pool, '->', os.path.join(ROOT, 'art', 'avatars'))
        return
    if args.grid:
        n = args.grid
        cols = 4
        rows = (n + cols - 1) // cols
        grid = Image.new('RGBA', (cols * 200, rows * 210), (20, 16, 30, 255))
        d = ImageDraw.Draw(grid)
        for i in range(n):
            face = gen_face('grid-%d' % i)
            face = face.resize((190, 190))
            x = (i % cols) * 200 + 5
            y = (i // cols) * 210 + 5
            grid.alpha_composite(face, (x, y))
            d.text((x + 4, y + 168), 'grid-%d' % i, fill=(220, 220, 230, 255))
        grid.save(os.path.join(ROOT, 'builds', 'antface_grid.png'))
        print('grid ->', os.path.join(ROOT, 'builds', 'antface_grid.png'))
        return
    ap.print_help()


if __name__ == '__main__':
    main()
