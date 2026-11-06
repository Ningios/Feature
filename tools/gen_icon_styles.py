#!/usr/bin/env python3
"""同一套 16 个图标的三种风格：① 全蓝 ② 实心（加粗） ③ 更圆（大圆角+圆头笔画）
输出：三张对比预览图 + 三套 PNG（29/58/87）。"""
import os
from PIL import Image, ImageDraw, ImageFont

OUTDIR = "/var/minis/shared/sbx-split/desktop/prefs"
PREV = "/var/minis/attachments"
FONT = "/tmp/fonts/PingFang.ttc"
S, K = 87, 4
P = S * K

STYLES = {
    "blue":  dict(ink=(10, 132, 255, 255), accent=(10, 132, 255, 255), wmul=1.0, rmul=1.0, label="① 全蓝"),
    "solid": dict(ink=(66, 70, 78, 255),  accent=(10, 132, 255, 255), wmul=2.1, rmul=1.0, label="② 实心（加粗）"),
    "round": dict(ink=(142, 142, 147, 255), accent=(10, 132, 255, 255), wmul=1.25, rmul=1.45, label="③ 更圆"),
}
cur = STYLES["blue"]

def INK(): return cur["ink"]
def ACC(): return cur["accent"]
def W(base): return max(2, int(base * cur["wmul"] * K))
def R(base): return int(base * cur["rmul"] * K)
def sc(*v): return tuple(x * K for x in v)

def cv():
    im = Image.new("RGBA", (P, P), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)

def ln(d, xy, w=3):
    d.line(sc(*xy), fill=INK(), width=W(w), joint="curve")
    r = W(w) / 2
    for i in (0, 2):
        x, y = xy[i] * K, xy[i + 1] * K
        d.ellipse((x - r, y - r, x + r, y + r), fill=INK())   # 圆头

def ic_clear():
    im, d = cv()
    d.ellipse(sc(14, 14, 73, 73), outline=INK(), width=W(4))
    ln(d, (29, 29, 58, 58), 5); ln(d, (58, 29, 29, 58), 5)
    return im

def ic_play_keep():
    im, d = cv()
    d.ellipse(sc(12, 12, 75, 75), outline=INK(), width=W(4))
    d.polygon([(36 * K, 27 * K), (60 * K, 43.5 * K), (36 * K, 60 * K)], fill=ACC())
    return im

def ic_whitelist():
    im, d = cv()
    pts = [(43.5 * K, 12 * K), (71 * K, 24 * K), (71 * K, 46 * K), (43.5 * K, 76 * K),
           (16 * K, 46 * K), (16 * K, 24 * K)]
    d.polygon(pts, outline=INK(), width=W(4))
    ln(d, (31, 43, 40, 53), 4); ln(d, (40, 53, 57, 33), 4)
    return im

def ic_font_size():
    im, d = cv()
    ln(d, (22, 66, 36, 26), 4); ln(d, (36, 26, 50, 66), 4); ln(d, (27, 52, 45, 52), 4)
    ln(d, (62, 30, 62, 62), 3)
    d.polygon([(62 * K, 26 * K), (57 * K, 34 * K), (67 * K, 34 * K)], fill=INK())
    d.polygon([(62 * K, 66 * K), (57 * K, 58 * K), (67 * K, 58 * K)], fill=INK())
    return im

def ic_button_size():
    im, d = cv()
    d.rounded_rectangle(sc(26, 34, 61, 53), radius=R(9), outline=INK(), width=W(3))
    ln(d, (16, 15, 30, 29), 4); ln(d, (16, 22, 16, 15), 4); ln(d, (23, 15, 16, 15), 4)
    ln(d, (71, 72, 57, 58), 4); ln(d, (71, 65, 71, 72), 4); ln(d, (64, 72, 71, 72), 4)
    return im

def ic_card_switcher():
    im, d = cv()
    d.rounded_rectangle(sc(12, 20, 44, 67), radius=R(6), outline=INK(), width=W(3))
    d.rounded_rectangle(sc(48, 30, 76, 57), radius=R(5), outline=INK(), width=W(3))
    return im

def ic_card_scale():
    im, d = cv()
    d.rounded_rectangle(sc(20, 30, 68, 58), radius=R(7), outline=INK(), width=W(3))
    ln(d, (33, 44, 55, 44), 3)
    return im

def ic_h_spacing():
    im, d = cv()
    ln(d, (26, 22, 26, 65), 3); ln(d, (61, 22, 61, 65), 3)
    ln(d, (34, 43.5, 53, 43.5), 4)
    d.polygon([(34 * K, 43.5 * K), (41 * K, 38 * K), (41 * K, 49 * K)], fill=INK())
    d.polygon([(53 * K, 43.5 * K), (46 * K, 38 * K), (46 * K, 49 * K)], fill=INK())
    return im

def ic_v_spacing():
    im, d = cv()
    ln(d, (22, 26, 65, 26), 3); ln(d, (22, 61, 65, 61), 3)
    ln(d, (43.5, 34, 43.5, 53), 4)
    d.polygon([(43.5 * K, 34 * K), (38 * K, 41 * K), (49 * K, 41 * K)], fill=INK())
    d.polygon([(43.5 * K, 53 * K), (38 * K, 46 * K), (49 * K, 46 * K)], fill=INK())
    return im

def ic_dock():
    im, d = cv()
    d.rounded_rectangle(sc(10, 30, 77, 60), radius=R(15), outline=INK(), width=W(3))
    for i, x in enumerate((24, 43.5, 63)):
        r = 6 * K
        d.ellipse((x * K - r, 45 * K - r, x * K + r, 45 * K + r),
                  fill=(ACC() if i == 1 else INK()))
    return im

def ic_show_switcher():
    im, d = cv()
    d.rounded_rectangle(sc(24, 14, 63, 44), radius=R(6), outline=INK(), width=W(3))
    d.rounded_rectangle(sc(14, 28, 53, 58), radius=R(6), outline=INK(), width=W(3))
    d.rounded_rectangle(sc(34, 42, 73, 72), radius=R(6), outline=INK(), width=W(3))
    return im

def ic_show_in_apps():
    im, d = cv()
    d.rounded_rectangle(sc(14, 16, 73, 68), radius=R(8), outline=INK(), width=W(3))
    d.rounded_rectangle(sc(14, 46, 73, 68), radius=R(8), fill=INK())
    return im

def ic_right_side():
    im, d = cv()
    d.rounded_rectangle(sc(12, 20, 75, 67), radius=R(8), outline=INK(), width=W(3))
    d.rounded_rectangle(sc(48, 20, 75, 67), radius=R(8), fill=ACC())
    return im

def ic_grid_count():
    im, d = cv()
    for (x, y) in ((16, 16), (47, 16), (16, 47), (47, 47)):
        d.rounded_rectangle(sc(x, y, x + 24, y + 24), radius=R(6), outline=INK(), width=W(3))
    return im

def ic_recent():
    im, d = cv()
    d.ellipse(sc(15, 15, 72, 72), outline=INK(), width=W(3.5))
    ln(d, (43.5, 28, 43.5, 45), 4); ln(d, (43.5, 45, 57, 52), 4)
    return im

def ic_hide_line():
    im, d = cv()
    ln(d, (14, 30, 73, 30), 4); ln(d, (14, 57, 73, 57), 4); ln(d, (20, 68, 67, 20), 4)
    return im

ICONS = [("ic_clear", ic_clear), ("ic_keep_playing", ic_play_keep), ("ic_whitelist", ic_whitelist),
         ("ic_font_size", ic_font_size), ("ic_button_size", ic_button_size),
         ("ic_card_switcher", ic_card_switcher), ("ic_card_scale", ic_card_scale),
         ("ic_h_spacing", ic_h_spacing), ("ic_v_spacing", ic_v_spacing),
         ("ic_dock", ic_dock), ("ic_show_switcher", ic_show_switcher),
         ("ic_show_in_apps", ic_show_in_apps), ("ic_right_side", ic_right_side),
         ("ic_grid_count", ic_grid_count), ("ic_recent", ic_recent), ("ic_hide_line", ic_hide_line)]

def F(sz):
    try: return ImageFont.truetype(FONT, sz, index=0)
    except Exception: return ImageFont.load_default()

def render_style(key):
    global cur
    cur = STYLES[key]
    d_out = os.path.join(OUTDIR, f"icons_{key}")
    os.makedirs(d_out, exist_ok=True)
    for name, fn in ICONS:
        im = fn().resize((S, S), Image.LANCZOS)
        for suffix, size in (("", 29), ("@2x", 58), ("@3x", 87)):
            im.resize((size, size), Image.LANCZOS).save(os.path.join(d_out, f"{name}{suffix}.png"))
    # 预览图
    cols, cell = 4, 150
    rows = (len(ICONS) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, rows * cell + 90), (255, 255, 255))
    dr = ImageDraw.Draw(sheet)
    dr.text((24, 22), f"图标风格 {cur['label']}", font=F(30), fill=(28, 28, 30))
    for i, (name, fn) in enumerate(ICONS):
        im = fn().resize((87, 87), Image.LANCZOS)
        bg = Image.new("RGBA", (87, 87), (255, 255, 255, 255)); bg.alpha_composite(im)
        sheet.paste(bg.convert("RGB"), ((i % cols) * cell + 30, (i // cols) * cell + 78))
    p = os.path.join(PREV, f"icons_style_{key}.png")
    sheet.save(p)
    return p

for k in ("blue", "solid", "round"):
    print(render_style(k))