"""Draw the CatXP tier portraits as 32x32 pixel art, export 64x64 TGA files for the game
and a labelled PNG contact sheet for checking them by eye.

Usage: make_cats.py <CatXP addon dir> [<preview png>]
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

S = 32  # working canvas

# base, dark (pattern/outline), light (muzzle/chest), eye colour
CATS = [
    dict(key="napping",  name="Napping Kitten", base=(150, 150, 155), dark=(85, 85, 92),   light=(215, 215, 220), eye=(90, 160, 90),  kitten=True, eyes="closed", zzz=True),
    dict(key="sleepy",   name="Sleepy Kitten",  base=(165, 160, 150), dark=(95, 90, 85),   light=(225, 220, 210), eye=(200, 160, 60), kitten=True, eyes="half"),
    dict(key="playful",  name="Playful Kitten", base=(245, 240, 228), dark=(150, 140, 125), light=(255, 255, 250), eye=(70, 170, 90),  kitten=True, eyes="wide", yarn=True),
    dict(key="housecat", name="House Cat",      base=(232, 145, 60),  dark=(150, 80, 30),  light=(250, 225, 190), eye=(80, 170, 80),  pattern="tabby", collar=True, chest=True),
    dict(key="alley",    name="Alley Cat",      base=(112, 112, 122), dark=(55, 55, 65),   light=(185, 185, 195), eye=(220, 190, 60), pattern="tabby", notch=True, chest=True),
    dict(key="wildcat",  name="Wildcat",        base=(145, 125, 95),  dark=(70, 55, 40),   light=(205, 190, 165), eye=(120, 180, 70), pattern="tabby", strong=True, chest=True),
    dict(key="bobcat",   name="Bobcat",         base=(195, 155, 105), dark=(90, 65, 40),   light=(240, 232, 215), eye=(210, 170, 60), pattern="spots", tufts=1, ruff=True, chest=True),
    dict(key="lynx",     name="Lynx",           base=(205, 200, 190), dark=(70, 65, 60),   light=(245, 245, 240), eye=(90, 150, 210), pattern="spots", faint=True, tufts=2, ruff=True, chest=True),
    dict(key="ocelot",   name="Ocelot",         base=(208, 165, 95),  dark=(60, 40, 25),   light=(245, 235, 210), eye=(200, 150, 50), pattern="rosettes", chest=True),
    dict(key="serval",   name="Serval",         base=(218, 180, 115), dark=(50, 35, 25),   light=(245, 238, 215), eye=(190, 150, 60), pattern="spots", bigears=True, chest=True),
    dict(key="caracal",  name="Caracal",        base=(195, 125, 80),  dark=(45, 30, 25),   light=(240, 220, 195), eye=(200, 170, 70), tufts=3, eyeline=True, chest=True),
    dict(key="puma",     name="Puma",           base=(180, 145, 105), dark=(60, 45, 35),   light=(240, 232, 215), eye=(190, 160, 70), mustache=True, chest=True),
    dict(key="leopard",  name="Leopard",        base=(228, 185, 85),  dark=(55, 35, 20),   light=(248, 240, 215), eye=(170, 200, 90), pattern="rosettes", chest=True),
    dict(key="jaguar",   name="Jaguar",         base=(218, 160, 60),  dark=(45, 30, 20),   light=(245, 235, 205), eye=(200, 170, 60), pattern="rosettes", big=True, wide=True, chest=True),
    dict(key="tiger",    name="Tiger",          base=(238, 130, 40),  dark=(30, 25, 25),   light=(250, 245, 235), eye=(210, 180, 60), pattern="stripes", whiteface=True, chest=True),
    dict(key="cheetah",  name="Cheetah",        base=(228, 192, 122), dark=(45, 35, 25),   light=(250, 245, 230), eye=(190, 150, 60), pattern="dots", tears=True, smallears=True, chest=True),
    dict(key="nyan",     name="Nyan Cat",       special="nyan"),
]

BLACK = (20, 20, 24)
WHITE = (255, 255, 255)
PINK = (240, 140, 160)
NOSE = (225, 110, 130)


def mirror(x):
    return S - 1 - x


def put(img, x, y, color):
    if 0 <= x < S and 0 <= y < S:
        img.putpixel((x, y), color + (255,))


def put_sym(img, x, y, color):
    put(img, x, y, color)
    put(img, mirror(x), y, color)


def shade(c, f):
    return tuple(max(0, min(255, int(v * f))) for v in c)


def draw_cat(spec):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    base, dark, light, eye = spec["base"], spec["dark"], spec["light"], spec["eye"]
    outline = shade(dark, 0.8)
    kitten = spec.get("kitten", False)

    # chest / shoulders behind the head
    if spec.get("chest") or kitten:
        d.ellipse((7, 24, 24, 33), fill=base + (255,), outline=outline + (255,))
        d.ellipse((11, 26, 20, 32), fill=light + (255,))
    if spec.get("yarn"):
        d.ellipse((0, 23, 7, 30), fill=(205, 50, 60, 255), outline=(130, 25, 35, 255))
        for (x, y) in [(2, 25), (3, 27), (5, 26), (4, 28), (2, 28)]:
            put(img, x, y, (150, 30, 40))

    # head
    if kitten:
        head = (7, 12, 24, 28)
    elif spec.get("wide"):
        head = (5, 10, 26, 28)
    else:
        head = (6, 10, 25, 28)

    # ears (drawn before the head so the head overlaps their base)
    if spec.get("bigears"):
        ears = [(6, 15), (8, 2), (15, 12)]
    elif spec.get("smallears"):
        ears = [(7, 14), (9, 7), (14, 12)]
    elif kitten:
        ears = [(7, 15), (8, 5), (14, 13)]
    else:
        ears = [(7, 14), (9, 4), (15, 12)]
    for pts in (ears, [(mirror(x), y) for (x, y) in ears]):
        d.polygon(pts, fill=base + (255,), outline=outline + (255,))
        # inner ear: the same triangle shrunk towards its centre
        (ax, ay), (bx, by), (cx, cy) = pts
        gx, gy = (ax + bx + cx) / 3.0, (ay + by + cy) / 3.0

        def towards(px, py, t):
            return (round(px + (gx - px) * t), round(py + (gy - py) * t))

        inner = [towards(ax, ay, 0.45), towards(bx, by, 0.3), towards(cx, cy, 0.45)]
        d.polygon(inner, fill=PINK + (255,))
    tufts = spec.get("tufts", 0)
    if tufts:
        tipx, tipy = ears[1]
        for i in range(tufts):
            put_sym(img, tipx + (i // 2), tipy - 1 - i, BLACK)

    d.ellipse(head, fill=base + (255,), outline=outline + (255,))

    # cheek ruffs (lynx, bobcat)
    if spec.get("ruff"):
        for (x, y) in [(6, 18), (6, 19), (6, 20), (6, 21), (7, 17), (7, 18), (7, 19), (7, 20), (7, 21), (7, 22), (8, 19), (8, 20), (8, 21), (8, 22), (8, 23), (7, 23), (9, 22), (9, 23), (9, 24)]:
            put_sym(img, x, y, light)
        for (x, y) in [(6, 19), (7, 21), (8, 23)]:
            put_sym(img, x, y, dark)
    if spec.get("whiteface"):
        for (x, y) in [(8, 18), (8, 19), (8, 20), (9, 17), (9, 18), (9, 19), (9, 20), (9, 21), (10, 19), (10, 20), (10, 21)]:
            put_sym(img, x, y, light)

    # fur patterns
    pattern = spec.get("pattern")
    strong = spec.get("strong", False)
    pat = dark if not spec.get("faint") else shade(base, 0.72)
    if pattern == "tabby":
        for (x, y) in [(11, 12), (11, 13), (11, 14), (12, 11), (15, 11), (16, 11), (15, 12), (16, 12), (15, 13), (16, 13)]:
            put_sym(img, x, y, pat)
        for (x, y) in [(7, 18), (8, 18), (7, 20), (8, 20), (7, 22), (8, 22)]:
            put_sym(img, x, y, pat)
        if strong:
            for (x, y) in [(13, 12), (13, 13), (9, 16), (9, 18), (9, 20), (10, 24), (11, 25)]:
                put_sym(img, x, y, pat)
    elif pattern == "stripes":
        for (x, y) in [(11, 11), (11, 12), (11, 13), (13, 11), (13, 12), (14, 13), (15, 11), (15, 12), (15, 13), (15, 14), (16, 11), (16, 12), (16, 13), (16, 14),
                       (7, 17), (8, 17), (7, 19), (8, 19), (7, 21), (8, 21), (7, 23), (8, 23), (12, 10), (10, 15)]:
            put_sym(img, x, y, dark)
    elif pattern == "spots":
        for (x, y) in [(11, 12), (14, 11), (17, 13), (12, 15), (9, 18), (8, 21), (9, 24), (12, 25), (10, 16), (22, 17)]:
            put_sym(img, x, y, pat)
    elif pattern == "dots":
        for (x, y) in [(10, 12), (12, 11), (14, 12), (12, 14), (16, 10), (8, 17), (9, 19), (8, 22), (10, 24), (13, 26), (10, 21), (14, 15)]:
            put_sym(img, x, y, dark)
    elif pattern == "rosettes":
        big = spec.get("big", False)
        centers = [(11, 13), (16, 11), (8, 19), (9, 24), (13, 26)] if not big else [(11, 13), (16, 11), (8, 19), (9, 24), (13, 26), (7, 16)]
        for (cx, cy) in centers:
            for (x, y) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)]:
                put_sym(img, x, y, dark)
            put_sym(img, cx, cy, shade(base, 0.85) if not big else dark)

    # muzzle, nose, mouth
    d.ellipse((12, 20, 19, 25), fill=light + (255,))
    for (x, y) in [(15, 21), (16, 21)]:
        put(img, x, y, NOSE)
    put(img, 15, 22, outline)
    put(img, 16, 22, outline)
    put(img, 14, 23, outline)
    put(img, 17, 23, outline)
    if spec.get("mustache"):
        for (x, y) in [(12, 21), (12, 22), (13, 20), (14, 19), (17, 19), (18, 20), (19, 21), (19, 22)]:
            put(img, x, y, dark)
    if spec.get("tears"):
        for (x, y) in [(12, 20), (12, 21), (13, 22), (13, 23)]:
            put_sym(img, x, y, dark)
    if spec.get("eyeline"):
        for (x, y) in [(13, 20), (14, 21)]:
            put_sym(img, x, y, dark)

    # whiskers
    wcol = shade(light, 0.85) if sum(base) < 500 else shade(base, 0.7)
    for (x, y) in [(6, 22), (7, 22), (8, 22), (6, 24), (7, 24), (8, 23)]:
        put_sym(img, x, y, wcol)

    # eyes
    eyes = spec.get("eyes", "open")
    ex, ey = (11, 16) if kitten else (11, 17)
    if eyes == "closed":
        for x in (ex, ex + 1, ex + 2):
            put_sym(img, x, ey + 1, outline)
        put_sym(img, ex + 3, ey, outline)
    else:
        h = 4 if eyes == "wide" else 3
        for yy in range(ey, ey + h):
            for xx in range(ex, ex + 3):
                put_sym(img, xx, yy, eye)
        if eyes == "half":
            for xx in range(ex, ex + 3):
                put_sym(img, xx, ey, outline)
            put_sym(img, ex + 1, ey + 1, BLACK)
            put_sym(img, ex + 1, ey + 2, BLACK)
        elif eyes == "wide":
            for yy in range(ey + 1, ey + h):
                put_sym(img, ex + 1, yy, BLACK)
            put_sym(img, ex + 2, ey + 1, BLACK)
            put_sym(img, ex, ey, WHITE)
        else:
            for yy in range(ey, ey + h):
                put_sym(img, ex + 1, yy, BLACK)
            put_sym(img, ex, ey, WHITE)

    # alley cat: a bite out of the right ear
    if spec.get("notch"):
        for (x, y) in [(23, 8), (24, 8), (22, 9), (23, 9), (24, 9), (23, 10), (24, 10), (24, 11)]:
            img.putpixel((x, y), (0, 0, 0, 0))
    if spec.get("collar"):
        d.rectangle((9, 27, 22, 28), fill=(200, 40, 50, 255))
        put(img, 15, 29, (240, 200, 60))
        put(img, 16, 29, (240, 200, 60))
    if spec.get("zzz"):
        for (x, y) in [(25, 4), (26, 4), (27, 4), (26, 5), (25, 6), (26, 6), (27, 6), (29, 1), (30, 1), (29, 2), (30, 2)]:
            put(img, x, y, (235, 235, 245))
    return img


def draw_nyan():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rainbow = [(255, 60, 60), (255, 160, 40), (255, 240, 60), (80, 220, 80), (70, 150, 255), (170, 80, 220)]
    for i, c in enumerate(rainbow):
        y = 13 + i * 2
        d.rectangle((0, y, 7, y + 1), fill=c + (255,))
    # pop-tart body
    d.rectangle((7, 11, 22, 26), fill=(230, 190, 130, 255), outline=(120, 80, 50, 255))
    d.rectangle((9, 13, 20, 24), fill=(250, 150, 200, 255))
    for (x, y) in [(11, 15), (14, 14), (17, 16), (12, 19), (16, 20), (18, 22), (10, 22), (14, 23)]:
        put(img, x, y, (200, 60, 130))
    # feet
    for x in (8, 12, 17, 21):
        d.rectangle((x, 27, x + 1, 28), fill=(150, 150, 160, 255), outline=(60, 60, 70, 255))
    # head
    grey, dark = (158, 158, 168), (60, 60, 70)
    d.polygon([(19, 13), (20, 7), (24, 12)], fill=grey + (255,), outline=dark + (255,))
    d.polygon([(30, 13), (29, 7), (25, 12)], fill=grey + (255,), outline=dark + (255,))
    d.ellipse((18, 10, 31, 22), fill=grey + (255,), outline=dark + (255,))
    for (x, y) in [(22, 14), (23, 14), (22, 15), (23, 15), (27, 14), (28, 14), (27, 15), (28, 15)]:
        put(img, x, y, BLACK)
    put(img, 22, 14, WHITE)
    put(img, 27, 14, WHITE)
    for (x, y) in [(20, 17), (21, 17), (29, 17), (30, 17)]:
        put(img, x, y, (255, 150, 170))
    for (x, y) in [(23, 18), (24, 19), (25, 19), (26, 19), (27, 18), (25, 17)]:
        put(img, x, y, dark)
    return img


def main():
    addon = sys.argv[1]
    preview = sys.argv[2] if len(sys.argv) > 2 else None
    media = os.path.join(addon, "Media")
    os.makedirs(media, exist_ok=True)
    tiles = []
    for spec in CATS:
        img = draw_nyan() if spec.get("special") == "nyan" else draw_cat(spec)
        big = img.resize((64, 64), Image.NEAREST)
        big.save(os.path.join(media, f"cat_{spec['key']}.tga"), format="TGA")
        tiles.append((spec["name"], img))
    if preview:
        cols, cell, scale = 6, 150, 4
        rows = (len(tiles) + cols - 1) // cols
        sheet = Image.new("RGBA", (cols * cell, rows * (cell + 20)), (40, 40, 48, 255))
        try:
            font = ImageFont.truetype("arial.ttf", 14)
        except OSError:
            font = ImageFont.load_default()
        d = ImageDraw.Draw(sheet)
        for i, (name, img) in enumerate(tiles):
            x, y = (i % cols) * cell, (i // cols) * (cell + 20)
            sheet.alpha_composite(img.resize((S * scale, S * scale), Image.NEAREST), (x + 11, y + 6))
            d.text((x + 10, y + cell + 2), name, fill=(230, 230, 230, 255), font=font)
        sheet.save(preview)
    print(f"wrote {len(tiles)} portraits to {media}")


if __name__ == "__main__":
    main()
