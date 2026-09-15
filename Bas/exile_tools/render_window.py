"""render_window.py - a 320 x 240 view of the planet from the generated tiles, as the board should draw it.

    python render_window.py listing x0 y0 out.png     (x0, y0 in squares, hex accepted)
"""
import sys, os, json
from exile6502 import load_listing
from gen_tiles import Sheet, render_square, save_png

WATER_X = [0, 0x54, 0x74, 0xA0, 256]
WATER_Y = [0xCE, 0xDF, 0xC1, 0xC1]

def main():
    listing, x0, y0, out = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0), sys.argv[4]
    here = os.path.dirname(os.path.abspath(__file__))
    mem = load_listing(listing)
    sheet = Sheet(mem)
    variants = json.load(open(os.path.join(here, 'out', 'variants.json')))
    tiles = {v['index']: [[px for px in row for _ in (0, 1)] for row in render_square(sheet, v)] for v in variants}
    lines = open(os.path.join(here, 'out', 'world.map')).read().split('\n')
    cells = [int(v) for line in lines[3:259] for v in line.split(',')]
    img = [[0] * 320 for _ in range(240)]
    for sy in range(240):
        for sx in range(320):
            x, y = x0 * 32 + sx, y0 * 32 + sy
            r = max(i for i in range(4) if x // 32 >= WATER_X[i])
            if y // 32 >= WATER_Y[r]:
                img[sy][sx] = 4                       # blue below the waterline
                if y == WATER_Y[r] * 32:
                    img[sy][sx] = 6                   # cyan surface line
    for ty in range(8):
        for tx in range(10):
            c = cells[(y0 + ty) * 256 + x0 + tx]
            if not c:
                continue
            t = tiles[c]
            for j in range(32):
                sy = ty * 32 + j
                if sy >= 240:
                    break
                for i in range(32):
                    if t[j][i]:
                        img[sy][tx * 32 + i] = t[j][i]
    save_png(out, 320, 240, img)
    print("wrote", out)

if __name__ == '__main__':
    main()
