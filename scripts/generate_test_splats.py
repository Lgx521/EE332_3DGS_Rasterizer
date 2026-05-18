#!/usr/bin/env python3
"""
generate_test_splats.py
Generate test splat data for FPGA simulation and initial board testing.

Splat format (64 bits):
  [63:54] center_x  (10 bit, 0..319)
  [53:45] center_y  (9 bit,  0..239)
  [44:38] radius    (7 bit,  0..127)
  [37:34] R         (4 bit,  0..15)
  [33:30] G         (4 bit,  0..15)
  [29:26] B         (4 bit,  0..15)
  [25:18] alpha     (8 bit,  0..255)
  [17:0]  reserved  (18 bit, zeros)
"""

import os


def pack_splat(cx, cy, radius, r, g, b, alpha):
    """Pack splat parameters into a 64-bit integer."""
    cx = max(0, min(319, cx))
    cy = max(0, min(239, cy))
    radius = max(0, min(127, radius))
    r = max(0, min(15, r))
    g = max(0, min(15, g))
    b = max(0, min(15, b))
    alpha = max(0, min(255, alpha))

    val = 0
    val |= (cx & 0x3FF) << 54
    val |= (cy & 0x1FF) << 45
    val |= (radius & 0x7F) << 38
    val |= (r & 0xF) << 34
    val |= (g & 0xF) << 30
    val |= (b & 0xF) << 26
    val |= (alpha & 0xFF) << 18
    # reserved bits [17:0] = 0
    return val


def write_mem_file(splats, filepath):
    """Write splats to .mem file (16-char hex per line for 64-bit values)."""
    with open(filepath, 'w') as f:
        for s in splats:
            f.write(f"{s:016X}\n")
    print(f"Written {len(splats)} splats to {filepath}")


def generate_basic_test():
    """Generate basic test: a few colored circles for visual verification."""
    splats = []

    # Red circle, center of screen
    splats.append(pack_splat(160, 120, 40, 15, 0, 0, 200))

    # Green circle, upper-left
    splats.append(pack_splat(80, 60, 35, 0, 15, 0, 180))

    # Blue circle, lower-right
    splats.append(pack_splat(240, 180, 35, 0, 0, 15, 180))

    # Yellow circle, overlapping with red
    splats.append(pack_splat(140, 100, 30, 15, 15, 0, 150))

    # White circle, small, top-center
    splats.append(pack_splat(160, 40, 20, 15, 15, 15, 220))

    # Cyan circle, right side
    splats.append(pack_splat(260, 120, 25, 0, 15, 15, 160))

    # Magenta circle, bottom-center
    splats.append(pack_splat(160, 200, 30, 15, 0, 15, 170))

    # Orange circle, overlapping green
    splats.append(pack_splat(100, 80, 20, 15, 8, 0, 190))

    return splats


def generate_overlap_test():
    """Generate overlapping circles to test alpha blending."""
    splats = []
    import math

    # Three overlapping circles in a triangle pattern
    cx, cy = 160, 120
    dist = 25
    for i, (r, g, b) in enumerate([(15, 0, 0), (0, 15, 0), (0, 0, 15)]):
        angle = i * 2 * math.pi / 3 - math.pi / 2
        x = int(cx + dist * math.cos(angle))
        y = int(cy + dist * math.sin(angle))
        splats.append(pack_splat(x, y, 35, r, g, b, 160))

    return splats


def generate_gradient_test():
    """Generate a grid of small splats with varying colors."""
    splats = []
    for gy in range(6):
        for gx in range(8):
            cx = 20 + gx * 40
            cy = 20 + gy * 40
            r = int(gx * 15 / 7)
            g = int(gy * 15 / 5)
            b = 15 - r
            splats.append(pack_splat(cx, cy, 18, r, g, b, 200))
    return splats


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    mem_dir = os.path.join(script_dir, "..", "mem")
    os.makedirs(mem_dir, exist_ok=True)

    # Generate and save all test sets
    basic = generate_basic_test()
    write_mem_file(basic, os.path.join(mem_dir, "test_splats.mem"))

    overlap = generate_overlap_test()
    write_mem_file(overlap, os.path.join(mem_dir, "test_overlap.mem"))

    gradient = generate_gradient_test()
    write_mem_file(gradient, os.path.join(mem_dir, "test_gradient.mem"))

    # Print verification info
    print("\nBasic test splats:")
    for i, s in enumerate(basic):
        cx = (s >> 54) & 0x3FF
        cy = (s >> 45) & 0x1FF
        rad = (s >> 38) & 0x7F
        r = (s >> 34) & 0xF
        g = (s >> 30) & 0xF
        b = (s >> 26) & 0xF
        a = (s >> 18) & 0xFF
        print(f"  [{i}] cx={cx}, cy={cy}, r={rad}, "
              f"RGB=({r},{g},{b}), alpha={a}")
