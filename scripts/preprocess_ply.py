#!/usr/bin/env python3
"""
preprocess_ply.py
Preprocesses a trained 3D Gaussian Splatting .ply file for FPGA rendering.

Pipeline:
  1. Read .ply file (3DGS format with SH coefficients)
  2. Filter by opacity (keep top-K most opaque Gaussians)
  3. Extract SH degree=0 color -> fixed RGB
  4. Project 3D Gaussians to 2D given camera parameters
  5. Simplify 2D covariance to circular splat (radius = max eigenvalue)
  6. Quantize all parameters to FPGA-friendly fixed-point
  7. Sort by depth (back-to-front for over-blending)
  8. Export as .mem file

Usage:
  python preprocess_ply.py --input scene.ply --output scene_splats.mem
                           --max-splats 5000
                           --cam-pos 0,0,3 --cam-target 0,0,0
"""

import argparse
import math
import os
import struct
import sys
import numpy as np


# Screen dimensions
SCREEN_W = 320
SCREEN_H = 240


def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def read_ply(filepath):
    """
    Read a 3DGS .ply file. Returns dict with arrays:
      positions: (N, 3)
      scales: (N, 3)
      rotations: (N, 4) quaternions
      opacities: (N,) raw (pre-sigmoid)
      sh_dc: (N, 3) DC spherical harmonics (degree 0)
    """
    with open(filepath, 'rb') as f:
        # Parse header
        header_lines = []
        while True:
            line = f.readline().decode('ascii').strip()
            header_lines.append(line)
            if line == 'end_header':
                break

        # Find vertex count
        n_vertices = 0
        properties = []
        for line in header_lines:
            if line.startswith('element vertex'):
                n_vertices = int(line.split()[-1])
            elif line.startswith('property'):
                parts = line.split()
                properties.append((parts[1], parts[2]))

        print(f"PLY: {n_vertices} vertices, {len(properties)} properties")

        # Build property name -> index mapping
        prop_names = [p[1] for p in properties]
        prop_types = [p[0] for p in properties]

        # Read binary data
        # Each vertex: all properties as float32
        dtype_list = []
        for ptype, pname in properties:
            if ptype == 'float':
                dtype_list.append((pname, '<f4'))
            elif ptype == 'double':
                dtype_list.append((pname, '<f8'))
            elif ptype == 'int':
                dtype_list.append((pname, '<i4'))
            elif ptype == 'uchar':
                dtype_list.append((pname, '<u1'))
            else:
                dtype_list.append((pname, '<f4'))

        data = np.fromfile(f, dtype=np.dtype(dtype_list), count=n_vertices)

    # Extract fields
    positions = np.column_stack([data['x'], data['y'], data['z']])

    # Scales (log scale in 3DGS)
    if 'scale_0' in data.dtype.names:
        scales = np.column_stack([data['scale_0'], data['scale_1'], data['scale_2']])
    else:
        scales = np.ones((n_vertices, 3)) * 0.01

    # Rotations (quaternion)
    if 'rot_0' in data.dtype.names:
        rotations = np.column_stack([
            data['rot_0'], data['rot_1'], data['rot_2'], data['rot_3']
        ])
    else:
        rotations = np.tile([1, 0, 0, 0], (n_vertices, 1)).astype(np.float32)

    # Opacity (raw, pre-sigmoid)
    if 'opacity' in data.dtype.names:
        opacities = data['opacity'].astype(np.float64)
    else:
        opacities = np.ones(n_vertices) * 2.0  # high opacity default

    # SH DC (degree 0 color)
    if 'f_dc_0' in data.dtype.names:
        sh_dc = np.column_stack([data['f_dc_0'], data['f_dc_1'], data['f_dc_2']])
    else:
        sh_dc = np.ones((n_vertices, 3)) * 0.5

    return {
        'positions': positions,
        'scales': scales,
        'rotations': rotations,
        'opacities': opacities,
        'sh_dc': sh_dc,
        'count': n_vertices
    }


def quat_to_rotation(q):
    """Quaternion [w,x,y,z] -> 3x3 rotation matrix (vectorised, q shape (N,4))."""
    w, x, y, z = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
    R = np.stack([
        1-2*(y*y+z*z),   2*(x*y-w*z),   2*(x*z+w*y),
          2*(x*y+w*z), 1-2*(x*x+z*z),   2*(y*z-w*x),
          2*(x*z-w*y),   2*(y*z+w*x), 1-2*(x*x+y*y)
    ], axis=-1).reshape(-1, 3, 3)
    return R  # (N, 3, 3)


def compute_2d_radii(pos, scales_log, quats, view, K):
    """
    Compute proper 2D projected radius for each Gaussian using full 3DGS math.
    Returns r_major (pixels) for each Gaussian.

    Steps per Gaussian:
      1. Build 3D covariance: Sigma3d = R * diag(s^2) * R^T
      2. Project to 2D:  Sigma2d = J * W * Sigma3d * W^T * J^T
         where J = perspective Jacobian, W = view rotation
      3. max eigenvalue of Sigma2d -> radius = 3*sqrt(lambda_max)
    """
    n = len(pos)
    # Normalise quaternions and build rotation matrices (N,3,3)
    q = quats / np.linalg.norm(quats, axis=1, keepdims=True)
    R = quat_to_rotation(q)  # (N,3,3)
    s = np.exp(scales_log)   # (N,3)

    # 3D covariance: Sigma3d = R * diag(s^2) * R^T  (N,3,3)
    RS = R * s[:, None, :]           # (N,3,3) each column scaled
    Sigma3d = RS @ RS.transpose(0, 2, 1)  # (N,3,3)

    # Camera-space positions
    ones = np.ones((n, 1))
    p_world = np.hstack([pos, ones])              # (N,4)
    p_cam   = (view @ p_world.T).T                # (N,4)
    z = p_cam[:, 2]                               # (N,) negative in front

    fx, fy = K[0, 0], K[1, 1]
    tx, ty = p_cam[:, 0], p_cam[:, 1]

    # Perspective Jacobian J per Gaussian (N,2,3)
    J = np.zeros((n, 2, 3))
    J[:, 0, 0] = fx / z
    J[:, 0, 2] = -fx * tx / (z * z)
    J[:, 1, 1] = fy / z
    J[:, 1, 2] = -fy * ty / (z * z)

    # View rotation (3x3)
    W = view[:3, :3]  # (3,3)

    # T = J * W  (N,2,3)
    T = J @ W[None, :, :]  # (N,2,3)

    # 2D covariance Sigma2d = T * Sigma3d * T^T  (N,2,2)
    Sigma2d = T @ Sigma3d @ T.transpose(0, 2, 1)  # (N,2,2)
    # Add small regularisation (anti-aliasing low-pass filter)
    Sigma2d[:, 0, 0] += 0.3
    Sigma2d[:, 1, 1] += 0.3

    # Max eigenvalue via trace/det formula for 2x2
    a  = Sigma2d[:, 0, 0]
    d  = Sigma2d[:, 1, 1]
    b  = Sigma2d[:, 0, 1]
    tr = a + d
    det = a * d - b * b
    disc = np.sqrt(np.maximum(tr * tr / 4 - det, 0))
    lam_max = tr / 2 + disc  # larger eigenvalue

    # 3-sigma radius in pixels
    r_major = 3.0 * np.sqrt(np.maximum(lam_max, 0))
    return r_major  # (N,)


def sh_dc_to_rgb(sh_dc):
    """Convert SH degree-0 DC component to RGB [0,1]."""
    # SH DC normalization constant: C0 = 0.28209479177
    C0 = 0.28209479177387814
    rgb = 0.5 + C0 * sh_dc
    return np.clip(rgb, 0.0, 1.0)


def build_camera_matrix(cam_pos, cam_target, cam_up=None, fov_y=60.0):
    """
    Build view and projection matrices.
    Returns: view_matrix (4x4), proj_matrix (3x3 intrinsic-like)
    """
    cam_pos = np.array(cam_pos, dtype=np.float64)
    cam_target = np.array(cam_target, dtype=np.float64)
    if cam_up is None:
        cam_up = np.array([0, 1, 0], dtype=np.float64)
    else:
        cam_up = np.array(cam_up, dtype=np.float64)

    # View matrix (look-at)
    forward = cam_target - cam_pos
    forward = forward / np.linalg.norm(forward)
    right = np.cross(forward, cam_up)
    right = right / np.linalg.norm(right)
    up = np.cross(right, forward)

    view = np.eye(4)
    view[0, :3] = right
    view[1, :3] = up
    view[2, :3] = -forward
    view[0, 3] = -np.dot(right, cam_pos)
    view[1, 3] = -np.dot(up, cam_pos)
    view[2, 3] = np.dot(forward, cam_pos)

    # Intrinsic matrix (pinhole)
    fov_rad = math.radians(fov_y)
    fy = SCREEN_H / (2.0 * math.tan(fov_rad / 2.0))
    fx = fy  # square pixels
    cx = SCREEN_W / 2.0
    cy = SCREEN_H / 2.0

    K = np.array([
        [fx, 0, cx],
        [0, fy, cy],
        [0,  0,  1]
    ])

    return view, K


def project_gaussians(gaussians, view, K, max_splats=5000,
                      radius_scale=1.0, min_opacity=0.05, alpha_scale=1.0):
    """
    Project 3D Gaussians to 2D splats.
    Uses proper 2D covariance projection (full 3DGS math) for accurate radii.
    Filters by visual importance (opacity * radius^2).
    Returns list of (cx, cy, radius, r, g, b, alpha, depth).
    """
    pos = gaussians['positions']
    scales = gaussians['scales']
    rotations = gaussians['rotations']
    opacities = gaussians['opacities']
    sh_dc = gaussians['sh_dc']

    # Compute activated opacity
    opacity_activated = sigmoid(opacities)

    # Pre-filter: drop nearly transparent gaussians
    keep = opacity_activated >= min_opacity
    pos = pos[keep]; scales = scales[keep]
    rotations = rotations[keep]
    opacity_activated = opacity_activated[keep]; sh_dc = sh_dc[keep]
    print(f"After opacity pre-filter (>= {min_opacity}): {len(opacity_activated)} gaussians")

    # Convert SH to RGB
    rgb = sh_dc_to_rgb(sh_dc)

    # Project all remaining gaussians to screen
    n = len(opacity_activated)
    # Batch transform to camera space
    ones = np.ones((n, 1))
    p_world = np.hstack([pos, ones])          # (N, 4)
    p_cam = (view @ p_world.T).T              # (N, 4)
    depths = -p_cam[:, 2]                     # positive in front of camera

    # Vectorised screen projection
    valid = depths > 0.1
    safe_d = np.where(valid, depths, 1.0)
    cx_arr = np.where(valid, K[0, 0] * p_cam[:, 0] / safe_d + K[0, 2], -9999)
    cy_arr = np.where(valid, K[1, 1] * p_cam[:, 1] / safe_d + K[1, 2], -9999)

    # Proper 2D covariance radius (3-sigma of projected Gaussian)
    print("Computing 2D covariance projection...")
    r2d = compute_2d_radii(pos, scales, rotations, view, K)  # (N,)
    radius_arr = np.where(valid, r2d * radius_scale, 0)
    radius_arr = np.maximum(radius_arr, 1.0)  # at least 1 pixel

    # On-screen mask
    on_screen = (valid
                 & (cx_arr >= -radius_arr) & (cx_arr <= SCREEN_W + radius_arr)
                 & (cy_arr >= -radius_arr) & (cy_arr <= SCREEN_H + radius_arr))

    # Visual importance: opacity * pixel area covered
    importance = opacity_activated * (radius_arr ** 2)
    importance = np.where(on_screen, importance, 0.0)

    # Keep top max_splats by importance
    top_idx = np.argsort(-importance)
    if max_splats < n:
        top_idx = top_idx[:max_splats]
    top_idx = top_idx[on_screen[top_idx]]

    splats = []
    for i in top_idx:
        r_out, g_out, b_out = rgb[i]
        a_out = min(float(opacity_activated[i]) * alpha_scale, 1.0)
        splats.append((
            float(cx_arr[i]), float(cy_arr[i]), float(radius_arr[i]),
            float(r_out), float(g_out), float(b_out),
            a_out, float(depths[i])
        ))

    print(f"Selected {len(splats)} splats by importance "
          f"(radius_scale={radius_scale:.1f})")
    if splats:
        radii = [s[2] for s in splats]
        print(f"  radius: min={min(radii):.1f}  mean={sum(radii)/len(radii):.1f}  max={max(radii):.1f}")
    return splats


def quantize_and_sort(splats):
    """
    Quantize splat parameters to FPGA format and sort back-to-front.
    """
    # Sort by depth: back-to-front (largest depth first)
    splats.sort(key=lambda s: -s[7])

    packed = []
    for cx, cy, radius, r, g, b, alpha, depth in splats:
        # Quantize
        cx_q = max(0, min(319, int(round(cx))))
        cy_q = max(0, min(239, int(round(cy))))
        rad_q = max(1, min(127, int(round(radius))))
        r_q = max(0, min(15, int(round(r * 15))))
        g_q = max(0, min(15, int(round(g * 15))))
        b_q = max(0, min(15, int(round(b * 15))))
        alpha_q = max(0, min(255, int(round(alpha * 255))))

        # Pack into 64-bit
        val = 0
        val |= (cx_q & 0x3FF) << 54
        val |= (cy_q & 0x1FF) << 45
        val |= (rad_q & 0x7F) << 38
        val |= (r_q & 0xF) << 34
        val |= (g_q & 0xF) << 30
        val |= (b_q & 0xF) << 26
        val |= (alpha_q & 0xFF) << 18

        packed.append(val)

    return packed


def write_mem_file(packed_splats, filepath):
    """Write packed splats to .mem file."""
    with open(filepath, 'w') as f:
        for val in packed_splats:
            f.write(f"{val:016X}\n")
    print(f"Written {len(packed_splats)} splats to {filepath}")


def main():
    parser = argparse.ArgumentParser(
        description='Preprocess 3DGS .ply for FPGA rendering')
    parser.add_argument('--input', '-i', required=True,
                        help='Input .ply file')
    parser.add_argument('--output', '-o', default=None,
                        help='Output .mem file')
    parser.add_argument('--max-splats', type=int, default=5000,
                        help='Maximum number of splats to keep')
    parser.add_argument('--radius-scale', type=float, default=1.0,
                        help='Multiply projected radius by this factor (default 1.0, proper 2D cov used)')
    parser.add_argument('--min-opacity', type=float, default=0.05,
                        help='Discard gaussians below this opacity (default 0.05)')
    parser.add_argument('--alpha-scale', type=float, default=1.0,
                        help='Multiply opacity by this factor before quantising (default 1.0)')
    parser.add_argument('--cam-pos', default='0,0,3',
                        help='Camera position (x,y,z)')
    parser.add_argument('--cam-target', default='0,0,0',
                        help='Camera target (x,y,z)')
    parser.add_argument('--fov', type=float, default=60.0,
                        help='Vertical field of view in degrees')
    args = parser.parse_args()

    # Parse camera parameters
    cam_pos = [float(x) for x in args.cam_pos.split(',')]
    cam_target = [float(x) for x in args.cam_target.split(',')]

    # Default output path
    if args.output is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        args.output = os.path.join(script_dir, '..', 'mem', 'scene_splats.mem')

    # Read PLY
    print(f"Reading {args.input}...")
    gaussians = read_ply(args.input)
    print(f"Loaded {gaussians['count']} Gaussians")

    # Build camera
    view, K = build_camera_matrix(cam_pos, cam_target, fov_y=args.fov)

    # Project
    splats = project_gaussians(gaussians, view, K,
                               max_splats=args.max_splats,
                               radius_scale=args.radius_scale,
                               min_opacity=args.min_opacity,
                               alpha_scale=args.alpha_scale)

    # Quantize and sort
    packed = quantize_and_sort(splats)

    # Write output
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    write_mem_file(packed, args.output)

    print(f"\nDone! {len(packed)} splats written.")
    print(f"Set NUM_SPLATS generic in splat_rom.vhd to {len(packed)}")


if __name__ == "__main__":
    main()
