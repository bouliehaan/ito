#!/usr/bin/env python3
"""
The ito icon: 糸電話, a string telephone, drawn like an ink comic panel.
A near paper cup you can see into (someone's talking into it), a long taut
thread rising to a small far cup. Black ink on white paper.

Everything is generated from the shapes below, so the Mac icon and the
Android icons can't drift apart:

  tools/icon.py svg      > art/ito-icon.svg          (1024, full bleed; macOS rounds it)
  tools/icon.py fg       > ic_launcher_fg.xml        (adaptive foreground, safe zone)
  tools/icon.py mono     > ic_launcher_mono.xml      (themed icons: ink only)
  tools/icon.py stat     > ic_stat_ito.xml           (status bar: ink only)

tools/icon.sh runs all of it and builds mac/Resources/ito.icns.
"""
import math
import sys

INK, PAPER = "#0b0b0b", "#ffffff"
LW = 30.0                      # main ink weight at 1024
ANG = -34.0                    # the line everything sits on, rising to the right

shapes = []                    # dicts: pts, closed, fill, stroke, width, cap, dx, dy, role


def add(pts, closed=True, fill=None, stroke=None, width=0.0, cap="round", dx=0.0, dy=0.0, role="ink"):
    shapes.append(dict(pts=pts, closed=closed, fill=fill, stroke=stroke, width=width, cap=cap, dx=dx, dy=dy, role=role))


def frame(ox, oy, ang, sc):
    c, s = math.cos(math.radians(ang)), math.sin(math.radians(ang))
    return lambda u, v: (ox + sc * (u * c - v * s), oy + sc * (u * s + v * c))


def ell(F, cu, cv, a, b, t0, t1, n=48):
    return [F(cu + a * math.cos(t), cv + b * math.sin(t)) for t in [t0 + (t1 - t0) * i / n for i in range(n + 1)]]


def cup(F, Rm, Rb, Lc, ew, eb, opening, lw, weight, hatch):
    """A paper cup in profile; local u runs from the mouth (0) to the base (Lc)."""
    sil = ([F(0, -Rm), F(Lc, -Rb)] + ell(F, Lc, 0, eb, Rb, -math.pi / 2, math.pi / 2)
           + [F(0, Rm)] + ell(F, 0, 0, ew, Rm, math.pi / 2, 3 * math.pi / 2))
    # heavier ink on the underside: a black copy, nudged down and right, behind the cup
    add(sil, fill=INK, stroke=INK, width=lw, dx=weight * 0.6, dy=weight, role="shadow")
    add(sil, fill=PAPER, role="paper")
    for k in range(hatch):
        v = Rm * (0.42 + 0.17 * k)
        vb = Rb * (0.42 + 0.17 * k)
        add([F(ew * 1.3, v), F(Lc * 0.86, vb + (v - vb) * 0.14)], closed=False, stroke=INK, width=lw * 0.42)
    add(sil, stroke=INK, width=lw)
    if opening:
        add(ell(F, 0, 0, ew, Rm, 0, 2 * math.pi, 96), fill=PAPER, stroke=INK, width=lw)     # the rim
        add(ell(F, ew * 0.06, 0, ew * 0.72, Rm * 0.84, 0, 2 * math.pi, 96), fill=INK)      # the dark inside
    else:
        add(ell(F, Lc, 0, eb, Rb, 0, 2 * math.pi, 96), fill=PAPER, stroke=INK, width=lw * 0.8)  # closed bottom


# --- the drawing -------------------------------------------------------------
ca, sa = math.cos(math.radians(ANG)), math.sin(math.radians(ANG))
Rm, Rb, Lc, ew, eb = 165.0, 108.0, 300.0, 78.0, 34.0
Fn = frame(210, 720, ANG, 0.74)                         # near cup
nb = Fn(Lc, 0)
fs, SL = 0.38, 380.0                                    # far cup: smaller, a long thread away
fbx, fby = nb[0] + ca * SL, nb[1] + sa * SL
Ff = frame(fbx + ca * fs * Lc, fby + sa * fs * Lc, ANG, fs)
Ffar = lambda u, v: Ff(-u, v)                           # its mouth faces away, its base toward us

cup(Ffar, Rm, Rb, Lc, 40.0, 52.0, False, LW * 0.62, LW * 0.25, 0)

# the thread: base to base, tapering with distance, a little sag
a, b = Fn(Lc + eb * 0.2, 0), Ffar(Lc, 0)
mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2 + 22
pts = [((1 - t) ** 2 * a[0] + 2 * (1 - t) * t * mx + t * t * b[0],
        (1 - t) ** 2 * a[1] + 2 * (1 - t) * t * my + t * t * b[1], t) for t in [i / 40 for i in range(41)]]
top, bot = [], []
for i, (x, y, t) in enumerate(pts):
    x2, y2, _ = pts[min(i + 1, 40)]
    x1, y1, _ = pts[max(i - 1, 0)]
    dx, dy = x2 - x1, y2 - y1
    l = math.hypot(dx, dy)
    nx, ny = -dy / l, dx / l
    w = (LW * 0.55 * (1 - t) + LW * 0.28 * t) / 2
    top.append((x + nx * w, y + ny * w))
    bot.append((x - nx * w, y - ny * w))
add(top + bot[::-1], fill=INK)

cup(Fn, Rm, Rb, Lc, ew, eb, True, LW, LW * 0.45, 3)

# sound: three strokes off the mouth
mc = Fn(-ew, 0)
for k, dang in enumerate([-38, 0, 38]):
    t = math.radians(180 + ANG + dang)
    r0 = 70 + (12 if k == 1 else 0)
    ln = LW * (2.4 if k == 1 else 1.9)
    add([(mc[0] + r0 * math.cos(t), mc[1] + r0 * math.sin(t)),
         (mc[0] + (r0 + ln) * math.cos(t), mc[1] + (r0 + ln) * math.sin(t))], closed=False, stroke=INK, width=LW * 0.8)


# --- placement -----------------------------------------------------------------
def extent():
    """Every inked point, widened by its stroke, in drawing space."""
    out = []
    for s in shapes:
        r = s["width"] / 2
        for x, y in s["pts"]:
            x, y = x + s["dx"], y + s["dy"]
            out += [(x - r, y - r), (x + r, y + r)]
    return out


ext = extent()
x0, x1 = min(p[0] for p in ext), max(p[0] for p in ext)
y0, y1 = min(p[1] for p in ext), max(p[1] for p in ext)
CX, CY = (x0 + x1) / 2, (y0 + y1) / 2
SPAN = max(x1 - x0, y1 - y0)
RADIUS = max(math.hypot(x - CX, y - CY) for x, y in ext)   # for round launcher masks


def emit(target, mode):
    """target: (size, scale, cx, cy) mapping drawing space onto the output canvas."""
    size, k, ox, oy = target
    T = lambda x, y: (ox + (x - CX) * k, oy + (y - CY) * k)
    out = []
    for s in shapes:
        if mode == "ink" and s["role"] in ("shadow", "paper"):
            continue
        pts = [T(x + s["dx"], y + s["dy"]) for x, y in s["pts"]]
        d = "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in pts) + (" Z" if s["closed"] else "")
        fill = s["fill"]
        if mode == "ink" and fill == PAPER:
            fill = None                         # ink only: white areas become see-through
        out.append((d, fill, s["stroke"], s["width"] * k, s["cap"]))
    return out


def svg():
    k = 760 / SPAN                              # inside the macOS rounded tile's safe area
    body = "".join(
        f'<path d="{d}" fill="{f or "none"}"' + (f' stroke="{st}" stroke-width="{w:.2f}" stroke-linecap="{c}" stroke-linejoin="round"' if st else "") + "/>"
        for d, f, st, w, c in emit((1024, k, 512, 512), "color"))
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><rect width="1024" height="1024" fill="{PAPER}"/>{body}</svg>\n'


def vector(mode, viewport, radius_frac, size_dp):
    """VectorDrawable; the drawing's farthest point lands at radius_frac of the viewport."""
    k = viewport * radius_frac / RADIUS
    paths = []
    for d, f, st, w, c in emit((viewport, k, viewport / 2, viewport / 2), mode):
        a = [f'android:pathData="{d}"']
        a.append(f'android:fillColor="{f}"' if f else 'android:fillColor="#00000000"')
        if st:
            a += [f'android:strokeColor="{st}"', f'android:strokeWidth="{w:.3f}"',
                  f'android:strokeLineCap="{c}"', 'android:strokeLineJoin="round"']
        paths.append("    <path " + "\n        ".join(a) + " />")
    tint = ' android:tint="#FFFFFFFF"' if mode == "ink" and size_dp == 24 else ""
    return (f'<?xml version="1.0" encoding="utf-8"?>\n<!-- Generated by tools/icon.py — edit that, not this. -->\n'
            f'<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            f'    android:width="{size_dp}dp" android:height="{size_dp}dp"\n'
            f'    android:viewportWidth="{viewport}" android:viewportHeight="{viewport}"{tint}>\n'
            + "\n".join(paths) + "\n</vector>\n")


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "svg"
    if what == "svg":
        sys.stdout.write(svg())
    elif what == "fg":      # adaptive icon: 108dp, round masks keep a 66dp circle -> radius 33, a hair of air
        sys.stdout.write(vector("color", 108, 32.5 / 108, 108))
    elif what == "mono":
        sys.stdout.write(vector("ink", 108, 32.5 / 108, 108))
    elif what == "stat":    # status bar: 24dp, white silhouette
        sys.stdout.write(vector("ink", 24, 11.5 / 24, 24))
    else:
        sys.exit("usage: icon.py svg|fg|mono|stat")
