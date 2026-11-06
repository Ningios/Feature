#!/usr/bin/env python3
"""为插件 Feature 生成 Sileo 图标候选（5 种风格），输出 512/256/128 三档 + 对比预览。"""
import os, math
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = "/var/minis/shared/sbx-split/desktop/plugins_icons"
PREV = "/var/minis/attachments"
FONT = "/tmp/fonts/PingFang.ttc"
os.makedirs(OUT, exist_ok=True)
S = 512
K = 2                      # 超采样
P = S * K

def F(sz):
    try: return ImageFont.truetype(FONT, sz, index=0)
    except Exception: return ImageFont.load_default()

def squircle_mask(size, radius_ratio=0.225):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1),
                                        radius=int(size * radius_ratio), fill=255)
    return m

def vgrad(size, top, bottom):
    im = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        im.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return im.resize((size, size))

def dgrad(size, c1, c2, ang=45):
    """对角线性渐变"""
    a = math.radians(ang)
    base = Image.new("RGB", (size, size))
    px = base.load()
    for y in range(size):
        for x in range(size):
            t = (x * math.cos(a) + y * math.sin(a)) / (size * (abs(math.cos(a)) + abs(math.sin(a))))
            t = max(0.0, min(1.0, t))
            px[x, y] = tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
    return base

def finish(im, name):
    im = im.resize((S, S), Image.LANCZOS)
    m = squircle_mask(S, 0.225)
    im.putalpha(Image.composite(im.getchannel("A"), Image.new("L", (S, S), 0), m))
    for suffix, size in (("", 512), ("-256", 256), ("-128", 128)):
        im.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, f"{name}{suffix}.png"))
    return im

def gloss(im, strength=70, h=0.46):
    """顶部高光"""
    lay = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    d.ellipse((-im.size[0]*0.25, -im.size[0]*0.85, im.size[0]*1.25, im.size[0]*h),
              fill=(255, 255, 255, strength))
    lay = lay.filter(ImageFilter.GaussianBlur(im.size[0]*0.06))
    im.alpha_composite(lay)
    return im

# ---------- A：F 字母（蓝紫玻璃）----------
def icon_a():
    bg = dgrad(P, (88, 132, 255), (150, 96, 255), 55).convert("RGBA")
    d = ImageDraw.Draw(bg)
    d.text((P*0.5, P*0.5), "F", font=F(int(P*0.60)), fill=(255, 255, 255, 250), anchor="mm")
    bg = gloss(bg, 80)
    return finish(bg, "icon_A_F")

# ---------- B：悬浮 Dock 胶囊 ----------
def icon_b():
    bg = vgrad(P, (26, 34, 56), (52, 74, 120)).convert("RGBA")
    d = ImageDraw.Draw(bg)
    w, h = P*0.72, P*0.30
    x0, y0 = (P-w)/2, P*0.60
    # 胶囊玻璃
    cap = Image.new("RGBA", (int(w), int(h)), (0, 0, 0, 0))
    dd = ImageDraw.Draw(cap)
    dd.rounded_rectangle((0, 0, w-1, h-1), radius=h/2, fill=(255, 255, 255, 96),
                         outline=(255, 255, 255, 200), width=int(P*0.008))
    bg.alpha_composite(cap, (int(x0), int(y0)))
    d = ImageDraw.Draw(bg)
    for i, x in enumerate((0.24, 0.5, 0.76)):
        cx, cy, r = x0 + w*x, y0 + h/2, P*0.045
        d.ellipse((cx-r, cy-r, cx+r, cy+r), fill=(255, 255, 255, 70) if i != 1 else (90, 190, 255, 255))
    # 上方小图标
    for i in range(3):
        cw = P*0.14
        cx = P*0.22 + i*P*0.22
        d.rounded_rectangle((cx, P*0.22, cx+cw, P*0.22+cw), radius=P*0.035,
                            fill=[(96, 126, 206), (132, 178, 255), (255, 168, 120)][i] + (255,))
    return finish(bg, "icon_B_dock")

# ---------- C：卡片堆叠 ----------
def icon_c():
    bg = vgrad(P, (32, 36, 46), (18, 20, 26)).convert("RGBA")
    lay = Image.new("RGBA", (P, P), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    for i, (dx, dy, col) in enumerate([(0.16, 0.20, (96, 126, 206)), (0.30, 0.30, (132, 178, 255)),
                                       (0.44, 0.40, (255, 168, 120))]):
        x, y, w, h = P*dx, P*dy, P*0.34, P*0.44
        d.rounded_rectangle((x, y, x+w, y+h), radius=P*0.06,
                            fill=col + (255,), outline=(255, 255, 255, 60), width=int(P*0.006))
    bg.alpha_composite(lay)
    return finish(bg, "icon_C_cards")

# ---------- D：桌面网格 + 玻璃覆盖 ----------
def icon_d():
    bg = vgrad(P, (58, 96, 190), (128, 86, 200)).convert("RGBA")
    d = ImageDraw.Draw(bg)
    s, gap = P*0.17, P*0.055
    x0, y0 = (P - (3*s + 2*gap))/2, (P - (3*s + 2*gap))/2
    for r in range(3):
        for c in range(3):
            x, y = x0 + c*(s+gap), y0 + r*(s+gap)
            d.rounded_rectangle((x, y, x+s, y+s), radius=P*0.045, fill=(255, 255, 255, 165))
    # 底部玻璃横条
    lay = Image.new("RGBA", (P, P), (0, 0, 0, 0))
    dd = ImageDraw.Draw(lay)
    dd.rounded_rectangle((P*0.10, P*0.70, P*0.90, P*0.86), radius=P*0.08,
                         fill=(255, 255, 255, 110), outline=(255, 255, 255, 210), width=int(P*0.008))
    bg.alpha_composite(lay)
    bg = gloss(bg, 55)
    return finish(bg, "icon_D_grid")

# ---------- E：液态玻璃球 ----------
def icon_e():
    bg = vgrad(P, (18, 22, 32), (40, 52, 84)).convert("RGBA")
    r = P*0.32
    cx, cy = P/2, P/2
    # 球体：蓝色径向渐变
    ball = Image.new("RGBA", (P, P), (0, 0, 0, 0))
    px = ball.load()
    for y in range(int(cy-r), int(cy+r)):
        for x in range(int(cx-r), int(cx+r)):
            dx, dy = x-cx, y-cy
            dist = math.hypot(dx, dy)
            if dist <= r:
                t = dist/r
                lit = max(0.0, 1.0 - math.hypot(dx + r*0.35, dy + r*0.45)/(r*1.7))
                edge = 1.0 - t
                col = (int(60 + 120*lit + 70*edge), int(110 + 110*lit + 60*edge),
                       int(200 + 55*lit))
                a = 255 if t < 0.985 else int(255*(1-(t-0.985)/0.015))
                px[x, y] = (min(col[0],255), min(col[1],255), min(col[2],255), a)
    bg.alpha_composite(ball)
    # 高光点
    lay = Image.new("RGBA", (P, P), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    d.ellipse((cx-r*0.55, cy-r*0.72, cx-r*0.05, cy-r*0.32), fill=(255, 255, 255, 200))
    d.ellipse((cx+r*0.22, cy+r*0.34, cx+r*0.46, cy+r*0.58), fill=(255, 255, 255, 90))
    lay = lay.filter(ImageFilter.GaussianBlur(P*0.012))
    bg.alpha_composite(lay)
    return finish(bg, "icon_E_liquid")

names = []
for fn in (icon_a, icon_b, icon_c, icon_d, icon_e):
    names.append(fn())

# 对比预览（一行 5 个，白底 + 深底各一行）
cell = 300
TOP = 120
sheet = Image.new("RGB", (cell*5, cell*2 + TOP), (255, 255, 255))
d = ImageDraw.Draw(sheet)
d.text((30, 20), "插件图标候选（上排：白底 / 下排：深底）", font=F(32), fill=(28, 28, 30))
for i, im in enumerate(names):
    dk = Image.new("RGB", (cell, cell), (18, 20, 26))
    for row, back in ((0, None), (1, dk)):
        bgc = Image.new("RGB", (cell, cell), (255, 255, 255)) if back is None else back
        thumb = im.resize((200, 200), Image.LANCZOS)
        bgc.paste(thumb, ((cell-200)//2, (cell-200)//2), thumb if thumb.mode == "RGBA" else None)
        sheet.paste(bgc, (i*cell, TOP + row*cell))
# 标签
labels = ["A 字母 F", "B 悬浮 Dock", "C 卡片堆叠", "D 桌面网格", "E 液态玻璃球"]
d = ImageDraw.Draw(sheet)
for i, t in enumerate(labels):
    d.text((i*cell + cell//2, 78), t, font=F(28), fill=(60, 64, 72), anchor="mm")
sheet.save(os.path.join(PREV, "plugin_icon_candidates.png"))

print("候选图标：")
for tag in ("icon_A_F", "icon_B_dock", "icon_C_cards", "icon_D_grid", "icon_E_liquid"):
    print("  ", os.path.join(OUT, tag + "{,-256,-128}.png"))
print("预览：", os.path.join(PREV, "plugin_icon_candidates.png"))