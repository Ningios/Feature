#!/usr/bin/env python3
"""为 Feature 插件自绘一套设置页图标（线性风格，灰阶+透明底），输出 29/58/87 px 三档。"""
import os
from PIL import Image, ImageDraw

OUT = "/var/minis/shared/sbx-split/desktop/prefs/icons"
os.makedirs(OUT, exist_ok=True)
S = 87          # 目标 3x 尺寸
K = 4           # 超采样倍数
P = S * K
INK = (142, 142, 147, 255)      # iOS 次级灰
INK_SOFT = (142, 142, 147, 130)
ACCENT = (10, 132, 255, 255)    # 蓝色点缀

def canvas():
    im = Image.new("RGBA", (P, P), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)

def rrect(d, box, r, fill=None, outline=None, width=None):
    d.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)

def line(d, xy, w=3):
    d.line(xy, fill=INK, width=int(w * K), joint="curve")

def scaled(*v):
    return tuple(x * K for x in v)

# ---------- 各图标 ----------
def ic_clear():
    im, d = canvas()
    d.ellipse(scaled(14, 14, 73, 73), outline=INK, width=int(4 * K))
    line(d, scaled(29, 29, 58, 58), 5)
    line(d, scaled(58, 29, 29, 58), 5)
    return im

def ic_play_keep():
    im, d = canvas()
    d.ellipse(scaled(12, 12, 75, 75), outline=INK, width=int(4 * K))
    d.polygon([scaled(36, 27)[:2] and (36*K, 27*K), (60*K, 43.5*K), (36*K, 60*K)], fill=ACCENT)
    return im

def ic_whitelist():
    im, d = canvas()
    pts = [(43.5*K, 12*K), (71*K, 24*K), (71*K, 46*K), (43.5*K, 76*K), (16*K, 46*K), (16*K, 24*K)]
    d.polygon(pts, outline=INK, width=int(4 * K))
    line(d, scaled(31, 43, 40, 53), 4)
    line(d, scaled(40, 53, 57, 33), 4)
    return im

def ic_font_size():
    im, d = canvas()
    # 字母 A
    line(d, scaled(22, 66, 36, 26), 4)
    line(d, scaled(36, 26, 50, 66), 4)
    line(d, scaled(27, 52, 45, 52), 4)
    # 右侧上下箭头表示字号
    line(d, scaled(62, 30, 62, 62), 3)
    d.polygon([(62*K, 27*K), (57*K, 35*K), (67*K, 35*K)], fill=INK)
    d.polygon([(62*K, 65*K), (57*K, 57*K), (67*K, 57*K)], fill=INK)
    return im

def ic_button_size():
    im, d = canvas()
    rrect(d, scaled(26, 34, 61, 53), int(9 * K), outline=INK, width=int(3 * K))
    line(d, scaled(16, 15, 30, 29), 4)
    line(d, scaled(16, 22, 16, 15), 4)
    line(d, scaled(23, 15, 16, 15), 4)
    line(d, scaled(71, 72, 57, 58), 4)
    line(d, scaled(71, 65, 71, 72), 4)
    line(d, scaled(64, 72, 71, 72), 4)
    return im

def ic_card_switcher():
    im, d = canvas()
    rrect(d, scaled(12, 20, 44, 67), int(6 * K), outline=INK, width=int(3 * K))
    rrect(d, scaled(48, 30, 76, 57), int(5 * K), outline=INK_SOFT, width=int(3 * K))
    return im

def ic_card_scale():
    im, d = canvas()
    rrect(d, scaled(20, 30, 68, 58), int(7 * K), outline=INK, width=int(3 * K))
    line(d, scaled(33, 44, 55, 44), 3)
    return im

def ic_h_spacing():
    im, d = canvas()
    line(d, scaled(26, 22, 26, 65), 3)
    line(d, scaled(61, 22, 61, 65), 3)
    line(d, scaled(34, 43.5, 53, 43.5), 4)
    d.polygon([(34*K, 43.5*K), (41*K, 38*K), (41*K, 49*K)], fill=INK)
    d.polygon([(53*K, 43.5*K), (46*K, 38*K), (46*K, 49*K)], fill=INK)
    return im

def ic_v_spacing():
    im, d = canvas()
    line(d, scaled(22, 26, 65, 26), 3)
    line(d, scaled(22, 61, 65, 61), 3)
    line(d, scaled(43.5, 34, 43.5, 53), 4)
    d.polygon([(43.5*K, 34*K), (38*K, 41*K), (49*K, 41*K)], fill=INK)
    d.polygon([(43.5*K, 53*K), (38*K, 46*K), (49*K, 46*K)], fill=INK)
    return im

def ic_dock():
    im, d = canvas()
    rrect(d, scaled(10, 30, 77, 60), int(15 * K), outline=INK, width=int(3 * K))
    for i, x in enumerate((24, 43.5, 63)):
        r = 6
        d.ellipse((x*K - r*K/2, 45*K - r*K/2, x*K + r*K/2, 45*K + r*K/2),
                  fill=ACCENT if i == 1 else INK_SOFT)
    return im

def ic_show_switcher():
    im, d = canvas()
    rrect(d, scaled(24, 14, 63, 44), int(6 * K), outline=INK_SOFT, width=int(3 * K))
    rrect(d, scaled(14, 28, 53, 58), int(6 * K), outline=INK, width=int(3 * K))
    rrect(d, scaled(34, 42, 73, 72), int(6 * K), outline=INK_SOFT, width=int(3 * K))
    return im

def ic_show_in_apps():
    im, d = canvas()
    rrect(d, scaled(14, 16, 73, 68), int(8 * K), outline=INK, width=int(3 * K))
    rrect(d, scaled(14, 46, 73, 68), int(8 * K), fill=INK_SOFT)
    return im

def ic_right_side():
    im, d = canvas()
    rrect(d, scaled(12, 20, 75, 67), int(8 * K), outline=INK, width=int(3 * K))
    d.rounded_rectangle(scaled(48, 20, 75, 67), radius=int(8 * K), fill=ACCENT)
    return im

def ic_grid_count():
    im, d = canvas()
    for (x, y) in ((16, 16), (47, 16), (16, 47), (47, 47)):
        rrect(d, scaled(x, y, x + 24, y + 24), int(6 * K), outline=INK, width=int(3 * K))
    return im

def ic_recent():
    im, d = canvas()
    d.ellipse(scaled(15, 15, 72, 72), outline=INK, width=int(3.5 * K))
    line(d, scaled(43.5, 28, 43.5, 45), 4)
    line(d, scaled(43.5, 45, 57, 52), 4)
    return im

def ic_hide_line():
    im, d = canvas()
    line(d, scaled(14, 30, 73, 30), 4)
    line(d, scaled(14, 57, 73, 57), 4)
    line(d, scaled(20, 68, 67, 20), 4)
    return im

ICONS = {
    "ic_clear": ic_clear,
    "ic_keep_playing": ic_play_keep,
    "ic_whitelist": ic_whitelist,
    "ic_font_size": ic_font_size,
    "ic_button_size": ic_button_size,
    "ic_card_switcher": ic_card_switcher,
    "ic_card_scale": ic_card_scale,
    "ic_h_spacing": ic_h_spacing,
    "ic_v_spacing": ic_v_spacing,
    "ic_dock": ic_dock,
    "ic_show_switcher": ic_show_switcher,
    "ic_show_in_apps": ic_show_in_apps,
    "ic_right_side": ic_right_side,
    "ic_grid_count": ic_grid_count,
    "ic_recent": ic_recent,
    "ic_hide_line": ic_hide_line,
}

made = 0
for name, fn in ICONS.items():
    im = fn().resize((S, S), Image.LANCZOS)
    for suffix, size in (("", 29), ("@2x", 58), ("@3x", 87)):
        out = im.resize((size, size), Image.LANCZOS)
        out.save(os.path.join(OUT, f"{name}{suffix}.png"))
        made += 1
print(f"生成 {made} 个 PNG（{len(ICONS)} 个图标 × 3 档）-> {OUT}")
