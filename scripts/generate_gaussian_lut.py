#!/usr/bin/env python3
"""
generate_gaussian_lut.py
Generate Gaussian weight LUT for FPGA.
weight[i] = round(255 * exp(-3.0 * i / 255))
The factor 3.0 controls the Gaussian falloff steepness:
  - d2_norm=0   -> weight=255 (center)
  - d2_norm=85  -> weight~=95  (~1 sigma)
  - d2_norm=255 -> weight~=1   (edge)
"""

import math
import os

ENTRIES = 256
SIGMA_FACTOR = 3.0  # controls steepness of Gaussian falloff


def generate_lut(entries=ENTRIES, sigma_factor=SIGMA_FACTOR):
    """Generate Gaussian weight LUT values."""
    lut = []
    for i in range(entries):
        w = 255.0 * math.exp(-sigma_factor * i / 255.0)
        lut.append(max(0, min(255, int(round(w)))))
    return lut


def write_mem_file(lut, filepath):
    """Write LUT as .mem file (hex, one value per line) for Vivado $readmemh."""
    with open(filepath, 'w') as f:
        for val in lut:
            f.write(f"{val:02X}\n")
    print(f"Written {len(lut)} entries to {filepath}")


def write_vhdl_init(lut):
    """Print VHDL array initializer for copy-paste."""
    print("signal lut : lut_type := (")
    for i in range(0, len(lut), 8):
        chunk = lut[i:i+8]
        line = ", ".join(f'X"{v:02X}"' for v in chunk)
        if i + 8 >= len(lut):
            print(f"    {line}")
        else:
            print(f"    {line},")
    print(");")


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    mem_dir = os.path.join(script_dir, "..", "mem")
    os.makedirs(mem_dir, exist_ok=True)

    lut = generate_lut()

    # Write .mem file
    mem_path = os.path.join(mem_dir, "gaussian_lut.mem")
    write_mem_file(lut, mem_path)

    # Print VHDL initializer
    print("\nVHDL initializer:")
    write_vhdl_init(lut)

    # Print summary
    print(f"\nLUT summary:")
    print(f"  d2_norm=0   -> weight={lut[0]}")
    print(f"  d2_norm=64  -> weight={lut[64]}")
    print(f"  d2_norm=128 -> weight={lut[128]}")
    print(f"  d2_norm=192 -> weight={lut[192]}")
    print(f"  d2_norm=255 -> weight={lut[255]}")
