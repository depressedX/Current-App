#!/usr/bin/env python3
"""Current 波形标志的唯一源文件。

原本的图标是 2026-10-19 用 Python 逐像素写出 PNG 的,没有矢量中间产物。
这里保留同一套几何,补上 SVG 和任意尺寸输出。只依赖标准库。

用法:
    python3 Brand/generate.py                  # 生成全部产物到 Brand/
    python3 Brand/generate.py --size 180       # 任意尺寸 PNG
    python3 Brand/generate.py --format svg --out /tmp/logo
    python3 Brand/generate.py --list

改形状改 PARAMS,改色改 PALETTE,不需要碰渲染代码。
"""

from __future__ import annotations

import argparse
import math
import struct
import zlib
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent


@dataclass(frozen=True)
class Params:
    canvas: float = 1024.0
    x_start: float = 220.0
    x_end: float = 805.0
    mid_y: float = 512.0
    amplitude: float = 110.0
    frequency: float = 3.4  # sin(u * pi * frequency - phase)
    phase: float = 0.8
    half_thickness: float = 20.0  # vertical half-height of the band
    edge_softness: float = 2.0


@dataclass(frozen=True)
class Palette:
    wave: tuple[int, int, int] = (236, 73, 73)
    tile_base: tuple[int, int, int] = (13, 20, 22)
    tile_peak: tuple[int, int, int] = (25, 44, 44)
    glow_center: tuple[float, float] = (480.0, 420.0)
    glow_sigma: float = 700.0


PARAMS = Params()
PALETTE = Palette()


def wave_y(x: float, p: Params = PARAMS) -> float:
    """Band center line. u spans the painted range; the envelope tapers both ends."""
    u = (x - p.x_start) / (p.x_end - p.x_start)
    return p.mid_y + p.amplitude * math.sin(u * math.pi * p.frequency - p.phase) * math.sin(
        math.pi * u
    )


def coverage(x: float, y: float, p: Params = PARAMS) -> float:
    if not (p.x_start < x < p.x_end):
        return 0.0
    distance = abs(y - wave_y(x, p))
    return max(0.0, min(1.0, (p.half_thickness - distance) / p.edge_softness))


def glow(x: float, y: float, c: Palette = PALETTE) -> float:
    cx, cy = c.glow_center
    return math.exp(-((x - cx) / c.glow_sigma) ** 2 - ((y - cy) / c.glow_sigma) ** 2)


def _mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(a[i] * (1 - t) + b[i] * t) for i in range(3))


def _png(width: int, height: int, rows: list[bytearray], alpha: bool) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (
            struct.pack("!I", len(data))
            + kind
            + data
            + struct.pack("!I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    header = struct.pack("!2I5B", width, height, 8, 6 if alpha else 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(b"".join(rows)))
        + chunk(b"IEND", b"")
    )


def render_png(size: int, transparent: bool, p: Params = PARAMS, c: Palette = PALETTE) -> bytes:
    scale = size / p.canvas
    rows: list[bytearray] = []
    bounds = [size, size, -1, -1]
    for y in range(size):
        sy = y / scale
        row = bytearray()
        for x in range(size):
            sx = x / scale
            t = coverage(sx, sy, p)
            if transparent:
                alpha = int(round(t * 255))
                row += bytes((*c.wave, alpha))
                if alpha:
                    bounds[0] = min(bounds[0], x)
                    bounds[1] = min(bounds[1], y)
                    bounds[2] = max(bounds[2], x)
                    bounds[3] = max(bounds[3], y)
            else:
                base = _mix(c.tile_base, c.tile_peak, glow(sx, sy, c))
                row += bytes(_mix(base, c.wave, t))
        rows.append(row)

    if transparent:
        left, top, right, bottom = bounds
        if right < 0:
            return _png(size, size, [b"\x00" + r for r in rows], True)
        pad = max(2, size // 64)
        left, top = max(0, left - pad), max(0, top - pad)
        right, bottom = min(size - 1, right + pad), min(size - 1, bottom + pad)
        rows = [r[left * 4 : (right + 1) * 4] for r in rows[top : bottom + 1]]
        width, height = right - left + 1, bottom - top + 1
    else:
        width, height = size, size
    return _png(width, height, [b"\x00" + r for r in rows], transparent)


def _band_path(p: Params = PARAMS) -> str:
    first = math.ceil(p.x_start) + 1
    last = math.floor(p.x_end) - 1
    xs = list(range(first, last + 1))
    upper = [(x, wave_y(x, p) - p.half_thickness) for x in xs]
    lower = [(x, wave_y(x, p) + p.half_thickness) for x in xs]
    points = upper + lower[::-1]
    body = " L".join(f"{x},{y:.2f}" for x, y in points)
    return f"M{body} Z"


def render_mark_svg(p: Params = PARAMS, c: Palette = PALETTE) -> str:
    first, last = math.ceil(p.x_start) + 1, math.floor(p.x_end) - 1
    tops = [wave_y(x, p) - p.half_thickness for x in range(first, last + 1)]
    bottoms = [wave_y(x, p) + p.half_thickness for x in range(first, last + 1)]
    pad = 6.0
    x0 = first - pad
    y0 = min(tops) - pad
    width = last - first + pad * 2
    height = max(bottoms) - min(tops) + pad * 2
    color = "#%02X%02X%02X" % c.wave
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x0:.0f} {y0:.2f} '
        f'{width:.0f} {height:.2f}" width="{width:.0f}" height="{height:.2f}">\n'
        f'  <path d="{_band_path(p)}" fill="{color}"/>\n'
        f"</svg>\n"
    )


def render_icon_svg(p: Params = PARAMS, c: Palette = PALETTE) -> str:
    cx, cy = c.glow_center
    farthest = max(
        math.hypot(px - cx, py - cy)
        for px in (0.0, p.canvas)
        for py in (0.0, p.canvas)
    )
    stops = []
    for i in range(17):
        distance = farthest * i / 16
        color = _mix(c.tile_base, c.tile_peak, math.exp(-((distance / c.glow_sigma) ** 2)))
        stops.append(f'      <stop offset="{i / 16:.4f}" stop-color="#%02X%02X%02X"/>' % color)
    wave = "#%02X%02X%02X" % c.wave
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {p.canvas:.0f} {p.canvas:.0f}" '
        f'width="{p.canvas:.0f}" height="{p.canvas:.0f}">\n'
        f"  <defs>\n"
        f'    <radialGradient id="glow" cx="{cx:.0f}" cy="{cy:.0f}" r="{farthest:.1f}" '
        f'gradientUnits="userSpaceOnUse">\n'
        + "\n".join(stops)
        + "\n    </radialGradient>\n"
        f"  </defs>\n"
        f'  <rect width="{p.canvas:.0f}" height="{p.canvas:.0f}" fill="url(#glow)"/>\n'
        f'  <path d="{_band_path(p)}" fill="{wave}"/>\n'
        f"</svg>\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate the Current wave mark.")
    parser.add_argument("--format", choices=("all", "svg", "png"), default="all")
    parser.add_argument("--size", type=int, default=1024, help="PNG edge length in pixels")
    parser.add_argument("--out", type=Path, default=ROOT)
    parser.add_argument("--list", action="store_true", help="print the geometry instead of rendering")
    args = parser.parse_args()

    if args.list:
        print(f"wave:    y = {PARAMS.mid_y:g} + {PARAMS.amplitude:g} * "
              f"sin(u*pi*{PARAMS.frequency:g} - {PARAMS.phase:g}) * sin(pi*u)")
        print(f"domain:  x in ({PARAMS.x_start:g}, {PARAMS.x_end:g}), u = (x-{PARAMS.x_start:g})"
              f"/{PARAMS.x_end - PARAMS.x_start:g}")
        print(f"band:    +/-{PARAMS.half_thickness:g} vertical, flat caps, "
              f"{PARAMS.edge_softness:g}px soft edge")
        print(f"colors:  wave #{'%02X%02X%02X' % PALETTE.wave}")
        return

    args.out.mkdir(parents=True, exist_ok=True)
    if args.format in ("all", "svg"):
        (args.out / "WaveMark.svg").write_text(render_mark_svg(), encoding="utf-8")
        (args.out / "WaveMark-Icon.svg").write_text(render_icon_svg(), encoding="utf-8")
    if args.format in ("all", "png"):
        (args.out / "WaveMark.png").write_bytes(render_png(args.size, transparent=True))
        (args.out / "AppIcon.png").write_bytes(render_png(args.size, transparent=False))
    print(f"wrote {args.format} to {args.out}")


if __name__ == "__main__":
    main()
