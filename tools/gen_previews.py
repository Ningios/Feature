#!/usr/bin/env python3
"""生成三款功能的预览示意图（纯示意图）。透明元素一律画在独立 RGBA 层再混合。"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 700, 1500
FONT = "/tmp/fonts/PingFang.ttc"
OUT = "/var/minis/attachments"

def F(sz):
    try: return ImageFont.truetype(FONT, sz, index=0)
    except Exception: return ImageFont.load_default()

def base():
    im = Image.new("RGB", (W, H), (18, 24, 38))
    d = ImageDraw.Draw(im)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(20 + 28 * t), int(28 + 24 * t), int(46 + 32 * t)))
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((-220, 100, 520, 860), fill=(74, 100, 156))
    gd.ellipse((300, 600, 990, 1520), fill=(124, 86, 124))
    glow = glow.filter(ImageFilter.GaussianBlur(170))
    return Image.blend(im, glow, 0.55).convert("RGBA")

def layer(im):
    lay = Image.new("RGBA", im.size, (0, 0, 0, 0))
    return lay, ImageDraw.Draw(lay)

def flush(im, lay):
    im.alpha_composite(lay)

def glass(im, box, r, tint=42, rim=170, shadow=110):
    """毛玻璃板：模糊底 + 半透明白 + 亮边 + 投影"""
    x0, y0, x1, y1 = [int(v) for v in box]
    blur = im.crop((x0, y0, x1, y1)).filter(ImageFilter.GaussianBlur(20))
    mask = Image.new("L", blur.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, blur.size[0], blur.size[1]), radius=int(r), fill=255)
    im.paste(blur, (x0, y0), mask)
    lay, d = layer(im)
    d.rounded_rectangle((x0, y0, x1, y1), radius=int(r), fill=(255, 255, 255, tint))
    if shadow:
        d.rounded_rectangle((x0, y0 + 10, x1, y1 + 18), radius=int(r), fill=(0, 0, 0, 0))
    flush(im, lay)
    if shadow:
        sh = Image.new("RGBA", im.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle((x0 + 6, y0 + 12, x1 - 6, y1 + 18), radius=int(r),
                                             fill=(0, 0, 0, shadow))
        im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(16)))
    lay, d = layer(im)
    d.rounded_rectangle((x0, y0, x1, y1), radius=int(r), outline=(255, 255, 255, rim), width=2)
    flush(im, lay)

def wrap(d, text, font, maxw):
    lines, cur = [], ""
    for ch in text:
        if d.textlength(cur + ch, font=font) <= maxw: cur += ch
        else: lines.append(cur); cur = ch
    if cur: lines.append(cur)
    return lines

def header(im, title, sub):
    lay, d = layer(im)
    d.text((48, 50), title, font=F(46), fill=(255, 255, 255, 255))
    f = F(23); y = 118
    for ln in wrap(d, sub, f, W - 110)[:3]:
        d.text((48, y), ln, font=f, fill=(198, 210, 228, 255)); y += 33
    flush(im, lay)

def note(im, txt, size=20, color=(198, 210, 228, 255), y=1432):
    lay, d = layer(im)
    for i, ln in enumerate(wrap(d, txt, F(size), W - 100)):
        d.text((48, y + i * 28), ln, font=F(size), fill=color)
    flush(im, lay)

CARD_COLORS = [(96, 126, 206), (132, 178, 255), (255, 168, 120), (150, 216, 168)]

# ============ 1) 后台一键清除按钮 ============
im1 = base()
# 卡片（半透明毛玻璃）
for i, (x, y, cw, ch) in enumerate([(64, 300, 320, 700), (252, 258, 330, 690), (448, 322, 300, 660)]):
    glass(im1, (x, y, x + cw, y + ch), 42, tint=34, rim=95, shadow=90)
lay, d = layer(im1)
for i, (x, y, cw, ch) in enumerate([(64, 300, 320, 700), (252, 258, 330, 690), (448, 322, 300, 660)]):
    d.rounded_rectangle((x + 26, y + 26, x + 122, y + 122), radius=28, fill=CARD_COLORS[i] + (255,))
flush(im1, lay)
# 清除按钮
bx0, by0, bx1, by1 = W//2 - 92, 1215, W//2 + 92, 1345
glass(im1, (bx0, by0, bx1, by1), 65, tint=150, rim=210, shadow=120)
lay, d = layer(im1)
fbtn = F(38); tw = d.textlength("清除", font=fbtn)
d.text((W//2 - tw/2, by0 + 32), "清除", font=fbtn, fill=(28, 28, 30, 250))
flush(im1, lay)
header(im1, "① 后台一键清除按钮", "应用切换器底部出现玻璃胶囊按钮，一键清空后台（可保留正在播放）")
note(im1, "按钮大小 0.8×0.48 比例 · 底距 60pt · 超薄玻璃材质")
im1.save(f"{OUT}/preview_1_clear_button.png")

# ============ 2) iPad 卡片后台 ============
im2 = base()
cw, ch = 196, 620
for i in range(3):
    x = 52 + i * (cw + 24)
    glass(im2, (x, 320, x + cw, 320 + ch), 34, tint=36, rim=95, shadow=85)
    lay, d = layer(im2)
    d.rounded_rectangle((x + 18, 338, x + 92, 412), radius=22, fill=CARD_COLORS[i] + (255,))
    flush(im2, lay)
lay, d = layer(im2)
# 标注
d.line([(52, 320), (52, 1000)], fill=(150, 210, 255, 190), width=3)
d.text((64, 640), "卡片大小", font=F(22), fill=(150, 210, 255, 255))
d.line([(52 + cw + 6, 1016), (52 + cw + 18, 1016)], fill=(150, 255, 200, 190), width=3)
d.text((52, 1046), "水平间距", font=F(22), fill=(150, 255, 200, 255))
d.line([(52, 1180), (52 + cw, 1180)], fill=(255, 220, 150, 190), width=3)
d.text((52, 1206), "垂直间距", font=F(22), fill=(255, 220, 150, 255))
flush(im2, lay)
header(im2, "② iPad 卡片后台", "后台变成 iPad 式并排卡片，卡片大小与两个方向的间距都可微调")
note(im2, "三个数值都是倍率：1 = 系统原值，范围 0.1–2")
im2.save(f"{OUT}/preview_2_card_switcher.png")

# ============ 3) iPad 悬浮 Dock ============
im3 = base()
lay, d = layer(im3)
for r in range(4):
    for c in range(4):
        x = 66 + c * 168; y = 300 + r * 168
        d.rounded_rectangle((x, y, x + 132, y + 132), radius=34, fill=CARD_COLORS[(r + c) % 4] + (240,))
flush(im3, lay)
# 悬浮 Dock
dx0, dy0, dx1, dy1 = 44, 1215, W - 44, 1375
glass(im3, (dx0, dy0, dx1, dy1), 76, tint=60, rim=175, shadow=130)
lay, d = layer(im3)
icon_w = 84
for i in range(4):
    x = dx0 + 32 + i * (icon_w + 22)
    d.rounded_rectangle((x, dy0 + 28, x + icon_w, dy0 + 132), radius=24, fill=CARD_COLORS[i] + (245,))
# 分隔线 + 最近使用
sx = dx1 - 138
d.line([(sx, dy0 + 38), (sx, dy1 - 38)], fill=(255, 255, 255, 95), width=3)
d.text((sx + 20, dy0 + 52), "最近", font=F(21), fill=(245, 248, 255, 245))
d.text((sx + 20, dy0 + 84), "使用", font=F(21), fill=(245, 248, 255, 245))
flush(im3, lay)
header(im3, "③ iPad 悬浮 Dock", "主屏幕 Dock 变成 iPad 那种悬浮胶囊，可隐藏分隔线、调数量、右侧显示")
note(im3, "分隔线可隐藏 · 常驻/最近数量 1–10 · 右侧显示：最近使用 / 应用库 / 两者 / 都不")
im3.save(f"{OUT}/preview_3_floating_dock.png")

for f in ("preview_1_clear_button.png", "preview_2_card_switcher.png", "preview_3_floating_dock.png"):
    print(" ", os.path.join(OUT, f), os.path.getsize(os.path.join(OUT, f)), "bytes")
