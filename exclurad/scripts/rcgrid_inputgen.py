#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Generate input files for the radiative-corrections Fortran program (ExcluRad).

Key points
----------
- Defaults target the full 4D grid with safe edges:
  W [GeV]  : 1.486 → 2.000 (20 points)
  Q^2      : 0.3   → 5.0   (20 points)
  cos(θ*)  : -0.999 → 0.999 (20 points)  [avoid ±1.0]
  φ* [deg] : 0 → 360 inclusive, 19 points (20° steps)
- **infile-var** controls which dimension varies within the N points *inside each file*:
    * 'cos' (recommended; mirrors known-good input)
    * 'phi' (legacy style)
- Fortran quirk: keep **≤10 points per file**; the script auto-chunks.
- Layout mirrors your working inputs, including **two blank lines** before the points block.

Directory names are compact and quoteless by default.
"""

import argparse
import os
import csv
from datetime import datetime


# ---------- helpers ----------

def linspace(start, stop, num, include_endpoint=True):
    if num <= 0:
        return []
    if num == 1:
        return [start]
    if include_endpoint:
        step = (stop - start) / (num - 1)
        return [start + i * step for i in range(num)]
    else:
        step = (stop - start) / num
        return [start + i * step for i in range(num)]

def mid(a, b): return 0.5 * (a + b)

def chunk(lst, size):
    for i in range(0, len(lst), size):
        yield lst[i:i + size], (i // size)

def fmt_w(x):   return f"{x:.4f}"
def fmt_q2(x):  return f"{x:.4f}"
def fmt_cos(x): return f"{x:.6f}"   # keep precision to avoid rounding to ±1.000
def fmt_phi(x): return f"{x:.1f}"

def slug_f(x, places=4): return f"{x:.{places}f}"

def ensure_dir(p): os.makedirs(p, exist_ok=True)

def write_one_file(path, header, w, q2, cos_list, phi_list, include_trailer):
    """
    Write one input file. Length of cos_list and phi_list must match (N).
    """
    assert len(cos_list) == len(phi_list)
    N = len(cos_list)
    with open(path, "w") as f:
        f.write(f"{header['model']}       !  1: AO 2: maid98  3: maid2000\n")
        f.write(f"{header['rc_mode']}       !  0: Full, 1: Factorizable and Leading log\n")
        f.write(f"{header['bmom']}    !  bmom - lepton momentum\n")
        f.write(f"{header['tmom']}     !  tmom - momentum per nucleon\n")
        f.write(f"{header['lepton']}       !  lepton - 1 electron, 2 muon\n")
        f.write(f"{header['ivec']}       !  ivec - detected hadron (1) p, (2) pi+\n")
        f.write(f"{header['vcut']}   !  vcut - cut on inelasticity (0.) if no cut, negative -- v\n")
        # match working inputs: two blank lines before the N block
        f.write("\n\n")
        f.write(f"{N} ! no. of points\n")
        f.write((" ".join(fmt_w(w)   for _ in range(N))) + " ! W values\n")
        f.write((" ".join(fmt_q2(q2) for _ in range(N))) + " ! Q^2 values\n")
        f.write((" ".join(fmt_cos(c) for c in cos_list)) + " ! Cos(Theta) values\n")
        f.write((" ".join(fmt_phi(p) for p in phi_list)) + " ! phi values\n")
        f.write("\n")
        if include_trailer:
            f.write("0error detected by nag library routine   d01fce - ifail =     2\n")


# ---------- directory naming (compact/minimal/rich) ----------

def build_outdir_name(args, maxN):
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    mode_tag = {"phi_sweep_grid": "grid",
                "sweeps_by_axis": "axis",
                "single_point_phi_sweep": "single"}[args.mode]
    phi_tag = "phi360" if args.phi_include_endpoint else "phi0-360e"
    tag_prefix = (args.tag.strip() + "_") if args.tag else ""
    if args.dir_style == "minimal":
        return f"{tag_prefix}rcgrid-{mode_tag}_n{args.n_w}x4_by{maxN}_{stamp}"
    if args.dir_style == "rich":
        return (
            f"{tag_prefix}rcgrid-{mode_tag}"
            f"_W{args.w_min:.3f}-{args.w_max:.3f}"
            f"_Q2{args.q2_min:.2f}-{args.q2_max:.2f}"
            f"_cos{args.cos_min:.3f}-{args.cos_max:.3f}"
            f"_{phi_tag}"
            f"_N(W,Q2,cos,phi)=({args.n_w},{args.n_q2},{args.n_cos},{args.n_phi})"
            f"_by{maxN}_{stamp}"
        )
    # compact (default)
    return (
        f"{tag_prefix}rcgrid-{mode_tag}"
        f"_w{args.w_min:.3f}-{args.w_max:.3f}"
        f"_q2_{args.q2_min:.2f}-{args.q2_max:.2f}"
        f"_c{args.cos_min:.3f}-{args.cos_max:.3f}"
        f"_{phi_tag}"
        f"_n{args.n_w}x{args.n_q2}x{args.n_cos}x{args.n_phi}"
        f"_by{maxN}_{stamp}"
    )


# ---------- generator core ----------

def generate(
    outdir, mode, infile_var,
    w_min, w_max, n_w,
    q2_min, q2_max, n_q2,
    cos_min, cos_max, n_cos,
    phi_start, phi_end, n_phi, phi_include_endpoint,
    max_points_per_file,
    header, include_trailer
):
    # grids (endpoints included; φ* endpoint per flag)
    W_grid   = linspace(w_min,   w_max,   n_w,   include_endpoint=True)
    Q2_grid  = linspace(q2_min,  q2_max,  n_q2,  include_endpoint=True)
    COS_grid = linspace(cos_min, cos_max, n_cos, include_endpoint=True)
    PHI_grid = linspace(phi_start, phi_end, n_phi, include_endpoint=phi_include_endpoint)

    ensure_dir(outdir)
    manifest_rows = []

    def write_phi_chunks_const_cos(w, q2, c_const, phi_list, label_prefix):
        files_written = 0
        for phi_chunk, part_idx in chunk(phi_list, max_points_per_file):
            N = len(phi_chunk)
            cos_list = [c_const] * N
            w_s   = slug_f(w, 4)
            q2_s  = slug_f(q2, 4)
            cos_s = slug_f(c_const, 3)
            phi_lo = fmt_phi(phi_chunk[0]); phi_hi = fmt_phi(phi_chunk[-1])
            fname = f"{label_prefix}_W{w_s}_Q2{q2_s}_cos{cos_s}_phi{phi_lo}-{phi_hi}_p{part_idx+1:02d}.dat"
            fpath = os.path.join(outdir, fname)
            write_one_file(fpath, header, w, q2, cos_list, phi_chunk, include_trailer)
            manifest_rows.append([fname, f"{w:.6f}", f"{q2:.6f}", f"{c_const:.6f}", phi_lo, phi_hi, str(N)])
            files_written += 1
        return files_written

    def write_cos_chunks_const_phi(w, q2, phi_const, cos_list_full, label_prefix):
        files_written = 0
        for cos_chunk, part_idx in chunk(cos_list_full, max_points_per_file):
            N = len(cos_chunk)
            phi_list = [phi_const] * N
            w_s   = slug_f(w, 4)
            q2_s  = slug_f(q2, 4)
            phi_s = fmt_phi(phi_const)
            cos_lo = slug_f(cos_chunk[0], 3); cos_hi = slug_f(cos_chunk[-1], 3)
            fname = f"{label_prefix}_W{w_s}_Q2{q2_s}_phi{phi_s}_cos{cos_lo}-{cos_hi}_p{part_idx+1:02d}.dat"
            fpath = os.path.join(outdir, fname)
            write_one_file(fpath, header, w, q2, cos_chunk, phi_list, include_trailer)
            manifest_rows.append([fname, f"{w:.6f}", f"{q2:.6f}", f"{cos_chunk[0]:.6f}..{cos_chunk[-1]:.6f}", phi_s, phi_s, str(N)])
            files_written += 1
        return files_written

    total_files = 0

    if mode == "phi_sweep_grid":
        if infile_var == "phi":
            # every (W, Q2, cos) point gets a φ* sweep inside the file(s)
            for iw, w in enumerate(W_grid):
                for iq, q2 in enumerate(Q2_grid):
                    for ic, c in enumerate(COS_grid):
                        label = f"grid_{iw:02d}-{iq:02d}-{ic:02d}"
                        total_files += write_phi_chunks_const_cos(w, q2, c, PHI_grid, label)
        else:
            # every (W, Q2, φ) point gets a cos sweep inside the file(s)
            for iw, w in enumerate(W_grid):
                for iq, q2 in enumerate(Q2_grid):
                    for ip, phi in enumerate(PHI_grid):
                        label = f"grid_{iw:02d}-{iq:02d}-{ip:02d}"
                        total_files += write_cos_chunks_const_phi(w, q2, phi, COS_grid, label)

    elif mode == "sweeps_by_axis":
        # Sweep W-only, Q2-only, φ-only at mid of the others; inside files vary per infile_var
        w_mid   = mid(w_min, w_max)
        q2_mid  = mid(q2_min, q2_max)
        cos_mid = mid(cos_min, cos_max)
        phi_mid = mid(phi_start, phi_end)

        # W sweep
        for iw, w in enumerate(W_grid):
            label = f"W_sweep_{iw:02d}"
            if infile_var == "phi":
                total_files += write_phi_chunks_const_cos(w, q2_mid, cos_mid, PHI_grid, label)
            else:
                total_files += write_cos_chunks_const_phi(w, q2_mid, phi_mid, COS_grid, label)

        # Q2 sweep
        for iq, q2 in enumerate(Q2_grid):
            label = f"Q2_sweep_{iq:02d}"
            if infile_var == "phi":
                total_files += write_phi_chunks_const_cos(w_mid, q2, cos_mid, PHI_grid, label)
            else:
                total_files += write_cos_chunks_const_phi(w_mid, q2, phi_mid, COS_grid, label)

        # φ sweep (hold cos mid)
        label = "phi_only_midpoint"
        if infile_var == "phi":
            total_files += write_phi_chunks_const_cos(w_mid, q2_mid, cos_mid, PHI_grid, label)
        else:
            # when infile_var=cos, keep φ as a separate scan across files (cos varies within files)
            for ip, phi in enumerate(PHI_grid):
                total_files += write_cos_chunks_const_phi(w_mid, q2_mid, phi, COS_grid, f"phi_scan_{ip:02d}")

    elif mode == "single_point_phi_sweep":
        w_mid   = mid(w_min,  w_max)
        q2_mid  = mid(q2_min, q2_max)
        cos_mid = mid(cos_min, cos_max)
        phi_mid = mid(phi_start, phi_end)
        label = "single_point"
        if infile_var == "phi":
            total_files += write_phi_chunks_const_cos(w_mid, q2_mid, cos_mid, PHI_grid, label)
        else:
            total_files += write_cos_chunks_const_phi(w_mid, q2_mid, phi_mid, COS_grid, label)

    else:
        raise ValueError(f"Unknown mode: {mode}")

    # Manifest
    manifest_path = os.path.join(outdir, "manifest.csv")
    with open(manifest_path, "w", newline="") as mf:
        wcsv = csv.writer(mf)
        # Note: for cos-var files, the 'cos_theta' column shows "lo..hi" range
        wcsv.writerow(["file", "W_GeV", "Q2_GeV2", "cos_theta(or range)", "phi_deg_first", "phi_deg_last", "N_points"])
        wcsv.writerows(manifest_rows)

    print(f"Done. Wrote {total_files} input files to: {outdir}")
    print(f"Manifest: {manifest_path}")


# ---------- CLI ----------

def main():
    parser = argparse.ArgumentParser(
        description="Generate input files for ExcluRad (radiative corrections)."
    )

    # Ranges & counts (defaults: 20 per axis; φ uses 19 to include 0 & 360 with 20° steps)
    parser.add_argument("--w-min", type=float, default=1.486, help="W min [GeV] (eta + p threshold ≈ 1.486 GeV)")
    parser.add_argument("--w-max", type=float, default=2.000, help="W max [GeV]")
    parser.add_argument("--n-w",   type=int,   default=20,     help="number of W points")

    parser.add_argument("--q2-min", type=float, default=0.3, help="Q^2 min [GeV^2]")
    parser.add_argument("--q2-max", type=float, default=5.0, help="Q^2 max [GeV^2]")
    parser.add_argument("--n-q2",   type=int,   default=20,   help="number of Q^2 points")

    # SAFER defaults for cos edges
    parser.add_argument("--cos-min", type=float, default=-0.999, help="cos(theta*) min (avoid ±1.0)")
    parser.add_argument("--cos-max", type=float, default= 0.999, help="cos(theta*) max")
    parser.add_argument("--n-cos",   type=int,   default=20,     help="number of cos(theta*) points")

    parser.add_argument("--phi-start", type=float, default=0.0,   help="phi* start [deg]")
    parser.add_argument("--phi-end",   type=float, default=360.0, help="phi* end [deg]")
    parser.add_argument("--n-phi",     type=int,   default=19,    help="number of phi* points; "
                                                                       "choose N s.t. (N-1) divides 360 for integer-degree steps.")

    # φ endpoint control: default is to include 360°
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--phi-include-endpoint", dest="phi_include_endpoint", action="store_true",
                       help="Include phi_end as the final point (default).")
    group.add_argument("--phi-exclude-endpoint", dest="phi_include_endpoint", action="store_false",
                       help="Exclude phi_end.")
    parser.set_defaults(phi_include_endpoint=True)

    # File/format controls
    parser.add_argument("--max-points-per-file", type=int, default=10,
                        help="max points per input file (Fortran reader limit).")

    parser.add_argument("--mode",
        choices=["phi_sweep_grid", "sweeps_by_axis", "single_point_phi_sweep"],
        default="phi_sweep_grid",
        help="How to generate sets. 'phi_sweep_grid' = full 4D grid (default).")

    # NEW: which dimension varies inside each file
    parser.add_argument("--infile-var", choices=["phi", "cos"], default="cos",
                        help="Which dimension varies within the N points of each file. "
                             "'cos' (recommended) mirrors your known-good inputs; 'phi' is legacy style.")

    parser.add_argument("--outdir", type=str, default=None, help="Output directory (default is auto-named).")
    parser.add_argument("--no-trailer", action="store_true", help="Omit the odd trailing '0error...' line.")

    # Header controls (legacy-compatible defaults)
    parser.add_argument("--model",   type=int,  default=3,      help="1: AO, 2: maid98, 3: maid2000")
    parser.add_argument("--rc-mode", type=int,  default=0,      help="0: Full, 1: Factorizable+LL")
    parser.add_argument("--bmom",    type=str,  default="6.53", help="lepton momentum")
    parser.add_argument("--tmom",    type=str,  default="0.0",  help="momentum per nucleon")
    parser.add_argument("--lepton",  type=int,  default=1,      help="1: electron, 2: muon")
    parser.add_argument("--ivec",    type=int,  default=1,      help="1: p, 2: pi+")
    parser.add_argument("--vcut",    type=str,  default="0.166",help="inelasticity cut")

    # Directory naming (default compact)
    parser.add_argument("--dir-style", choices=["compact", "minimal", "rich"], default="compact",
                        help="Directory naming style.")
    parser.add_argument("--tag", type=str, default="", help="Optional label to prefix the directory name.")

    args = parser.parse_args()

    # Safety: clamp max points per file to 10
    maxN = max(1, min(10, args.max_points_per_file))

    # Default output directory
    if args.outdir is None:
        args.outdir = build_outdir_name(args, maxN)

    header = {
        "model":   args.model,
        "rc_mode": args.rc_mode,
        "bmom":    args.bmom,
        "tmom":    args.tmom,
        "lepton":  args.lepton,
        "ivec":    args.ivec,
        "vcut":    args.vcut,
    }

    generate(
        outdir=args.outdir,
        mode=args.mode, infile_var=args.infile_var,
        w_min=args.w_min, w_max=args.w_max, n_w=args.n_w,
        q2_min=args.q2_min, q2_max=args.q2_max, n_q2=args.n_q2,
        cos_min=args.cos_min, cos_max=args.cos_max, n_cos=args.n_cos,
        phi_start=args.phi_start, phi_end=args.phi_end,
        n_phi=args.n_phi, phi_include_endpoint=args.phi_include_endpoint,
        max_points_per_file=maxN,
        header=header,
        include_trailer=(not args.no_trailer),
    )

if __name__ == "__main__":
    main()

