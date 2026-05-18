#!/usr/bin/env python3
"""
reference_renderer.py
Software reference renderer that mimics the FPGA pipeline exactly.
Reads .mem files and renders to PNG using the same fixed-point logic.
Used to validate FPGA output.
"""

import math
import os
import struct

# Screen resolution
WIDTH = 320
HEIGHT = 240

# Gaussian LUT parameters (must match generate_gaussian_lut.py)
SIGMA_FACTOR = 3.0


def generate_gaussian_lut(entries=256):
    """Generate the same LUT as the FPGA uses."""
    lut = []
    for i in range(entries):
        w = 255.0 * math.exp(-SIGMA_FACTOR * i / 255.0)
        lut.append(max(0, min(255, int(round(w)))))
    return lut


def parse_splat(hex_str):
    """Parse a 64-bit hex string into splat parameters."""
    val = int(hex_str.strip(), 16)
    cx = (val >> 54) & 0x3FF
    cy = (val >> 45) & 0x1FF
    radius = (val >> 38) & 0x7F
    r = (val >> 34) & 0xF
    g = (val >> 30) & 0xF
    b = (val >> 26) & 0xF
    alpha = (val >> 18) & 0xFF
    return cx, cy, radius, r, g, b, alpha


def load_splats(mem_file):
    """Load splats from a .mem file."""
    splats = []
    with open(mem_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('//'):
                splats.append(parse_splat(line))
    return splats


def render(splats, lut):
    """
    Render splats to a framebuffer using the same algorithm as the FPGA:
    - Back-to-front order (list order assumed pre-sorted)
    - Circular splats
    - d2_norm = d2 * 255 / r_sq (integer)
    - weight from LUT
    - eff_alpha = alpha * weight >> 8
    - blend: C_new = C_old * (256 - eff_alpha)/256 + color * eff_alpha/256
    - All channels 4-bit (0..15)
    """
    # Framebuffer: 4-bit per channel
    fb = [[[0, 0, 0] for _ in range(WIDTH)] for _ in range(HEIGHT)]

    for cx, cy, radius, sr, sg, sb, alpha in splats:
        if radius == 0:
            continue
        r_sq = radius * radius
        # inv_r_sq for normalization (same as FPGA LUT)
        inv_r_sq = min(65535, (255 * 256) // r_sq)

        # Bounding box clamped to screen
        x_min = max(0, cx - radius)
        x_max = min(WIDTH - 1, cx + radius)
        y_min = max(0, cy - radius)
        y_max = min(HEIGHT - 1, cy + radius)

        for py in range(y_min, y_max + 1):
            for px in range(x_min, x_max + 1):
                dx = px - cx
                dy = py - cy
                d2 = dx * dx + dy * dy

                # Circle test
                if d2 > r_sq:
                    continue

                # Normalize d2 (same as FPGA)
                d2_norm = (d2 * inv_r_sq) >> 8
                d2_norm = min(255, d2_norm)

                # LUT lookup
                weight = lut[d2_norm]

                # Effective alpha
                eff_alpha = (alpha * weight) >> 8

                if eff_alpha == 0:
                    continue

                # Blend (4-bit channels, 8-bit intermediate)
                old_r, old_g, old_b = fb[py][px]
                # Expand to ~8-bit for arithmetic
                old_r8 = old_r * 17
                old_g8 = old_g * 17
                old_b8 = old_b * 17
                new_r8 = sr * 17
                new_g8 = sg * 17
                new_b8 = sb * 17

                inv_alpha = 256 - eff_alpha
                blend_r = (old_r8 * inv_alpha + new_r8 * eff_alpha) >> 8
                blend_g = (old_g8 * inv_alpha + new_g8 * eff_alpha) >> 8
                blend_b = (old_b8 * inv_alpha + new_b8 * eff_alpha) >> 8

                # Back to 4-bit
                fb[py][px] = [
                    min(15, blend_r >> 4),
                    min(15, blend_g >> 4),
                    min(15, blend_b >> 4)
                ]

    return fb


def save_ppm(fb, filepath):
    """Save framebuffer as PPM image (simple, no dependencies)."""
    with open(filepath, 'w') as f:
        f.write(f"P3\n{WIDTH} {HEIGHT}\n255\n")
        for row in fb:
            for r, g, b in row:
                # Expand 4-bit to 8-bit
                f.write(f"{r*17} {g*17} {b*17} ")
            f.write("\n")
    print(f"Written {filepath}")


def save_png(fb, filepath):
    """Save framebuffer as PNG (requires Pillow)."""
    try:
        from PIL import Image
        img = Image.new('RGB', (WIDTH, HEIGHT))
        for y in range(HEIGHT):
            for x in range(WIDTH):
                r, g, b = fb[y][x]
                img.putpixel((x, y), (r * 17, g * 17, b * 17))
        img.save(filepath)
        print(f"Written {filepath}")
    except ImportError:
        print("Pillow not installed, saving as PPM instead.")
        save_ppm(fb, filepath.replace('.png', '.ppm'))


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    mem_dir = os.path.join(script_dir, "..", "mem")
    out_dir = os.path.join(script_dir, "..", "output")
    os.makedirs(out_dir, exist_ok=True)

    lut = generate_gaussian_lut()

    # Render all test files
    test_files = ["test_splats.mem", "test_overlap.mem", "test_gradient.mem"]
    for tf in test_files:
        mem_path = os.path.join(mem_dir, tf)
        if os.path.exists(mem_path):
            print(f"\nRendering {tf}...")
            splats = load_splats(mem_path)
            print(f"  Loaded {len(splats)} splats")
            fb = render(splats, lut)
            out_name = tf.replace('.mem', '.png')
            save_png(fb, os.path.join(out_dir, out_name))
        else:
            print(f"  {tf} not found, run generate_test_splats.py first")
