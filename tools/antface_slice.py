#!/usr/bin/env python
"""Slice the ant-face parts sheet into labeled part images.

Regions are generous bands around each labeled group from the sheet layout;
within each band, alpha clusters (connected components) become individual
parts, trimmed to their bounding boxes.
Usage: python tools/antface_slice.py
Output: art/sheet_parts/<category>/<category>_NN.png
"""
import os
from PIL import Image
import numpy as np

SHEET = os.path.join(os.path.dirname(__file__), '..', 'art', 'sheet_ant_face.png')
OUT = os.path.join(os.path.dirname(__file__), '..', 'art', 'sheet_parts')

# category -> (x0, y0, x1, y1) generous bands on the 1536x1024 sheet
REGIONS = {
	"head":      (10, 25, 720, 230),
	"eyes":      (10, 255, 720, 465),
	"brows":     (10, 500, 720, 640),
	"mouthexp":  (10, 660, 720, 760),
	"headtop":   (10, 800, 460, 950),
	"faceangle": (460, 800, 960, 1000),
	"antennae":  (760, 25, 1530, 260),
	"mandibles": (760, 285, 1530, 435),
	"cheeks":    (760, 500, 1180, 600),
	"antbase":   (1180, 500, 1530, 610),
	"extra":     (760, 640, 1180, 740),
	"facedet":   (1180, 640, 1530, 740),
	"misc":      (1100, 810, 1530, 960),
}


def clusters(rgba_band, min_pixels=90):
	"""Label alpha clusters on a band, return list of (x0,y0,x1,y1) bboxes."""
	a = np.asarray(rgba_band)
	mask = a[:, :, 3] > 24
	visited = np.zeros_like(mask, dtype=bool)
	h, w = mask.shape
	boxes = []
	for y in range(h):
		for x in range(w):
			if mask[y, x] and not visited[y, x]:
				# BFS flood fill
				stack = [(y, x)]
				visited[y, x] = True
				pix = []
				while stack:
					cy, cx = stack.pop()
					pix.append((cy, cx))
					for dy in (-1, 0, 1):
						for dx in (-1, 0, 1):
							ny, nx = cy + dy, cx + dx
							if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not visited[ny, nx]:
								visited[ny, nx] = True
								stack.append((ny, nx))
				if len(pix) < min_pixels:
					continue
				ys = [p[0] for p in pix]
				xs = [p[1] for p in pix]
				boxes.append((min(xs), min(ys), max(xs) + 1, max(ys) + 1))
	boxes.sort(key=lambda b: (b[1] // 40, b[0]))
	return boxes


def main():
	im = Image.open(SHEET).convert('RGBA')
	for cat, (x0, y0, x1, y1) in REGIONS.items():
		band = im.crop((x0, y0, x1, y1))
		d = os.path.join(OUT, cat)
		os.makedirs(d, exist_ok=True)
		for f in os.listdir(d):
			os.remove(os.path.join(d, f))
		n = 0
		for (bx0, by0, bx1, by1) in clusters(band):
			# pad 2px, clamp
			c = band.crop((max(0, bx0 - 2), max(0, by0 - 2), min(band.width, bx1 + 2),
					min(band.height, by1 + 2)))
			if c.width < 8 or c.height < 8:
				continue
			c.save(os.path.join(d, f"{cat}_{n:02d}.png"))
			n += 1
		print(f"{cat}: {n} parts")


if __name__ == "__main__":
	main()
