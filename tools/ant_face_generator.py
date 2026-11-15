#!/usr/bin/env python3
"""
Ant Face Generator — built for the supplied 1536x1024 ant-parts sheet.
(owner-supplied script; paths adapted for Ant's)

Install:
    py -m pip install pillow opencv-python numpy

Run:
    python tools/ant_face_generator.py --sheet art/sheet_ant_face.png
    python tools/ant_face_generator.py --sheet art/sheet_ant_face.png --count 100 --seed 42
    python tools/ant_face_generator.py --sheet art/sheet_ant_face.png --one --seed 7

Outputs:
    art/ant_faces/ant_0001.png ...
    art/ant_faces/contact_sheet.png

The crop rectangles below are coordinates on the exact supplied sprite sheet.
If you replace the sheet with a differently sized image, keep the same artwork
and scale the rectangles proportionally or edit the crop coordinates.
"""
from __future__ import annotations

import argparse
import random
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw

# ---------------------------------------------------------------------------
# Source sheet and sprite crop rectangles: (left, top, right, bottom)
# ---------------------------------------------------------------------------
HEADS = [
    (18, 42, 184, 226),
    (190, 42, 356, 226),
    (360, 38, 538, 224),
    (545, 40, 730, 224),
]

# Eye sprites, one eye per crop. The generator mirrors/positions them as a pair.
EYES = [
    (18, 282, 105, 383), (130, 282, 216, 383),
    (248, 300, 319, 382), (347, 300, 418, 382),
    (440, 300, 512, 382), (532, 300, 621, 382),
    (642, 300, 720, 382),
    (17, 410, 116, 481), (132, 410, 224, 481),
    (247, 410, 288, 481), (303, 410, 355, 481),
    (373, 410, 423, 481), (438, 410, 490, 481),
    (510, 410, 615, 489), (632, 410, 726, 489),
]

# Eyebrow/expressive line pieces. These are mirrored to form a pair.
BROWS = [
    (13, 546, 105, 592), (112, 546, 220, 592),
    (238, 548, 294, 589), (304, 548, 352, 589),
    (360, 544, 440, 597), (448, 551, 495, 591),
    (499, 548, 548, 592), (548, 548, 627, 593),
    (628, 548, 718, 592),
    (13, 608, 105, 650), (112, 608, 218, 650),
    (238, 610, 318, 650), (324, 610, 390, 650),
    (398, 610, 454, 650), (458, 610, 516, 650),
    (526, 610, 607, 650), (615, 610, 718, 650),
]

# Mandibles / jaw shapes from the top-right section.
MANDIBLES = [
    (772, 318, 852, 439), (850, 318, 928, 439),
    (920, 318, 1022, 439), (1010, 318, 1124, 439),
    (1120, 318, 1200, 439), (1192, 318, 1288, 439),
    (1280, 318, 1397, 439), (1390, 318, 1518, 439),
]

MOUTHS = [
    (12, 728, 118, 782), (137, 724, 232, 783),
    (249, 724, 316, 789), (337, 724, 412, 789),
    (421, 727, 509, 782), (536, 727, 621, 782),
]

# Individual antenna stalks, cropped from the antenna section.
ANTENNAE = [
    (768, 39, 860, 164), (868, 39, 968, 164),
    (968, 38, 1096, 166), (1088, 38, 1215, 178),
    (1210, 38, 1350, 166), (1348, 40, 1470, 172),
    (1490, 60, 1520, 166),
    (770, 154, 866, 270), (870, 154, 968, 270),
    (970, 178, 1070, 272), (1080, 178, 1185, 272),
    (1208, 188, 1290, 270), (1348, 184, 1450, 275),
]

# Small decorative face markings; optional and subtle.
CHEEKS = [
    (750, 548, 815, 596), (830, 548, 893, 596),
    (900, 548, 947, 594), (958, 548, 990, 586),
    (997, 548, 1044, 594), (1050, 548, 1095, 598),
    (1110, 548, 1150, 596),
    (750, 610, 815, 653), (820, 610, 888, 653),
    (895, 610, 936, 652), (940, 610, 980, 652),
    (985, 610, 1032, 653), (1040, 610, 1085, 653),
    (1090, 610, 1138, 653),
]

def extract_sprite(sheet: Image.Image, box: tuple[int, int, int, int]) -> Image.Image:
    """Crop a sheet cell and remove only background connected to its border."""
    crop = sheet.crop(box).convert("RGB")
    arr = np.array(crop)
    h, w = arr.shape[:2]

    # OpenCV flood-fill from the crop edges. Floating-range tolerance follows
    # the gentle gradient in the sheet background while black outlines stop it.
    mask = np.zeros((h + 2, w + 2), np.uint8)
    work = arr.copy()
    flags = 4 | cv2.FLOODFILL_MASK_ONLY | (255 << 8)
    tolerance = (20, 20, 20)
    seeds = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1),
             (w // 2, 0), (w // 2, h - 1), (0, h // 2), (w - 1, h // 2)]
    for sx, sy in seeds:
        if mask[sy + 1, sx + 1] == 0:
            cv2.floodFill(work, mask, (sx, sy), (0, 0, 0),
                          loDiff=tolerance, upDiff=tolerance, flags=flags)

    bg = mask[1:-1, 1:-1] == 255
    alpha = np.where(bg, 0, 255).astype(np.uint8)

    # Slightly soften the extracted edge without eroding the dark outline.
    rgba = np.dstack((arr, alpha))
    sprite = Image.fromarray(rgba, "RGBA")
    bbox = sprite.getbbox()
    if bbox:
        sprite = sprite.crop(bbox)
    return sprite

def fit(sprite: Image.Image, size: tuple[int, int]) -> Image.Image:
    sprite = sprite.copy()
    sprite.thumbnail(size, Image.Resampling.LANCZOS)
    return sprite

def paste_center(canvas: Image.Image, sprite: Image.Image, center: tuple[int, int],
                 max_size: tuple[int, int], mirror: bool = False) -> None:
    if mirror:
        sprite = sprite.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    sprite = fit(sprite, max_size)
    x = int(center[0] - sprite.width / 2)
    y = int(center[1] - sprite.height / 2)
    canvas.alpha_composite(sprite, (x, y))

def generate_face(sheet: Image.Image, rng: random.Random, size: int = 512) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    head = extract_sprite(sheet, rng.choice(HEADS))
    head = fit(head, (340, 360))
    hx = (size - head.width) // 2
    hy = 112
    canvas.alpha_composite(head, (hx, hy))

    # Antennae sit behind the head and are independently mirrored.
    antenna = extract_sprite(sheet, rng.choice(ANTENNAE))
    antenna = fit(antenna, (105, 125))
    left_ant = antenna
    right_ant = antenna.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    canvas.alpha_composite(left_ant, (105, 20))
    canvas.alpha_composite(right_ant, (size - 105 - right_ant.width, 20))

    # Eye pair: same style with small random size/height variation.
    eye = extract_sprite(sheet, rng.choice(EYES))
    eye_w = rng.randint(66, 88)
    eye_h = rng.randint(66, 88)
    left_eye = fit(eye, (eye_w, eye_h))
    right_eye = left_eye.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    eye_y = rng.randint(255, 278)
    canvas.alpha_composite(left_eye, (160 - left_eye.width // 2, eye_y))
    canvas.alpha_composite(right_eye, (352 - right_eye.width // 2, eye_y))

    # Brows above each eye.
    brow = extract_sprite(sheet, rng.choice(BROWS))
    brow = fit(brow, (110, 42))
    canvas.alpha_composite(brow, (105, eye_y - 43))
    canvas.alpha_composite(brow.transpose(Image.Transpose.FLIP_LEFT_RIGHT),
                           (297, eye_y - 43))

    # Jaw/mandible or a simple mouth expression.
    if rng.random() < 0.68:
        jaw = extract_sprite(sheet, rng.choice(MANDIBLES))
        jaw = fit(jaw, (190, 125))
        canvas.alpha_composite(jaw, ((size - jaw.width) // 2, 345))
    else:
        mouth = extract_sprite(sheet, rng.choice(MOUTHS))
        mouth = fit(mouth, (125, 70))
        canvas.alpha_composite(mouth, ((size - mouth.width) // 2, 360))

    # Optional cheek marks, mirrored.
    if rng.random() < 0.65:
        mark = extract_sprite(sheet, rng.choice(CHEEKS))
        mark = fit(mark, (42, 30))
        canvas.alpha_composite(mark, (105, 335))
        canvas.alpha_composite(mark.transpose(Image.Transpose.FLIP_LEFT_RIGHT),
                               (365, 335))

    return canvas

def make_contact_sheet(files: list[Path], output: Path, columns: int = 5) -> None:
    thumbs = []
    for path in files:
        im = Image.open(path).convert("RGBA")
        im.thumbnail((160, 160), Image.Resampling.LANCZOS)
        tile = Image.new("RGBA", (180, 190), (45, 45, 45, 255))
        tile.alpha_composite(im, ((180 - im.width) // 2, 4))
        ImageDraw.Draw(tile).text((8, 168), path.stem, fill="white")
        thumbs.append(tile)
    rows = (len(thumbs) + columns - 1) // columns
    board = Image.new("RGBA", (columns * 180, rows * 190), (28, 28, 28, 255))
    for i, tile in enumerate(thumbs):
        board.alpha_composite(tile, ((i % columns) * 180, (i // columns) * 190))
    board.convert("RGB").save(output, quality=92)

def main() -> None:
    parser = argparse.ArgumentParser(description="Generate mix-and-match ant faces.")
    parser.add_argument("--sheet", default="art/sheet_ant_face.png")
    parser.add_argument("--out", default="art/ant_faces")
    parser.add_argument("--count", type=int, default=30)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--one", action="store_true", help="Generate one face only.")
    args = parser.parse_args()

    sheet_path = Path(args.sheet)
    if not sheet_path.exists():
        raise SystemExit(f"Cannot find sprite sheet: {sheet_path.resolve()}")
    sheet = Image.open(sheet_path).convert("RGB")
    if sheet.size != (1536, 1024):
        print(f"Note: expected 1536x1024 sheet, found {sheet.size}; crop coordinates may need scaling.")

    rng = random.Random(args.seed)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    count = 1 if args.one else max(1, args.count)
    outputs = []
    for i in range(count):
        face = generate_face(sheet, rng)
        path = out_dir / f"ant_{i + 1:04d}.png"
        face.save(path)
        outputs.append(path)

    make_contact_sheet(outputs, out_dir / "contact_sheet.png")
    print(f"Generated {len(outputs)} ant faces in: {out_dir.resolve()}")
    print(f"Contact sheet: {(out_dir / 'contact_sheet.png').resolve()}")

if __name__ == "__main__":
    main()
