# scripts/

Helper scripts for generating input files and running exclurad over large grids.

## Overview

There are three user workflows, each building on the last:

| Workflow | When to use | Scripts |
|---|---|---|
| Single run | Testing, one kinematic point | *(none — see main README)* |
| Grid run | Bulk production away from kinematic edges | `rcgrid_inputgen.py` + `run_exclurad_grid.sh` |
| Grid run with unphysical-skip | Near η threshold or large \|cos θ*\| | `rcgrid_inputgen.py` + `run_exclurad_skip_unphys.sh` |

---

## rcgrid_inputgen.py

Generates a directory of input `.dat` files spanning a 4D kinematic grid in
W, Q², cos(θ*), and φ*. Each file contains ≤10 points (the Fortran reader
limit); the script chunks automatically and writes a `manifest.csv` for
bookkeeping.

### Quick start

```bash
# Default grid: 20×20×20×19 points, cos varies within each file
python3 rcgrid_inputgen.py

# Custom ranges and point counts
python3 rcgrid_inputgen.py \
  --w-min 1.487 --w-max 1.999 --n-w 30 \
  --q2-min 0.3  --q2-max 4.0  --n-q2 30 \
  --cos-min -0.9 --cos-max 0.9 --n-cos 30 \
  --n-phi 19 \
  --tag my_run
```

### Key flags

| Flag | Default | Description |
|---|---|---|
| `--w-min/max`, `--n-w` | 1.486–2.000, 20 | W range [GeV] and point count |
| `--q2-min/max`, `--n-q2` | 0.3–5.0, 20 | Q² range [GeV²] and point count |
| `--cos-min/max`, `--n-cos` | −0.999–0.999, 20 | cos(θ*) range and point count |
| `--n-phi` | 19 | φ* points (0–360°, 19 gives 20° steps) |
| `--infile-var` | `cos` | Which dimension varies within each file (`cos` or `phi`) |
| `--rc-mode` | `0` | 0 = full; 1 = factorizable + leading-log |
| `--bmom` | `6.53` | Beam momentum [GeV] (CLAS12 default) |
| `--vcut` | `0.166` | Inelasticity cut [GeV²] |
| `--tag` | *(empty)* | Label prepended to the output directory name |
| `--outdir` | *(auto)* | Override auto-generated directory name |
| `--mode` | `phi_sweep_grid` | `phi_sweep_grid` (full 4D), `sweeps_by_axis`, or `single_point_phi_sweep` |
| `--dir-style` | `compact` | Directory naming: `compact`, `minimal`, or `rich` |

### Notes

- Keep `--cos-min/max` away from ±1.0; the script defaults to ±0.999 to
  avoid numerical issues at the poles.
- The η+p threshold is W ≈ 1.486 GeV. Points below this will be unphysical;
  start your grid at or above this value.
- The auto-named output directory encodes all key parameters and a timestamp,
  making it easy to track runs without overwriting previous results.

---

## run_exclurad_grid.sh

Runs exclurad.exe sequentially over every `.dat` file in an input directory,
with timestamped logging, optional resume, and an optional per-file timeout.

### Usage

```bash
./run_exclurad_grid.sh \
  --input-dir /path/to/rcgrid-... \
  --work-dir  /path/to/exclurad
```

```bash
# Full options
./run_exclurad_grid.sh \
  --input-dir  /path/to/input_dir   \   # required
  --work-dir   /path/to/exclurad    \   # required
  --results-root /path/for/output   \   # default: work-dir
  --resume                          \   # skip files already in results
  --limit 10                        \   # process at most N files
  --live                            \   # stream output to console + logs
  --timeout-sec 600                 \   # kill jobs that exceed N seconds
  --skip-env                        \   # skip module loading
  --dry-run                             # print actions, do not execute
```

### Outputs

Results are collected into a timestamped directory:

```
results_<input_dir_name>_<YYYYMMDD_HHMMSS>/
├── all/         radcor/       radsigpl/
├── allu/        radsigmi/     radtot/
├── radasm/
├── inputs/      # copy of each input file used
├── logs/        # per-file stdout and stderr
│   ├── <file>.out
│   └── <file>.err
├── input_manifest.csv   # copied from input dir if present
└── run_info.txt         # metadata for the run
```

Each output type (e.g. `all/`) contains one file per input: `<input_basename>.dat`.

### Tips

- Use `--resume` to restart interrupted runs without reprocessing completed files.
- Monitor a running job with `tail -f results_.../logs/<file>.out`.
- For runs near kinematic edges, use `run_exclurad_skip_unphys.sh` instead.

---

## run_exclurad_skip_unphys.sh

Same as `run_exclurad_grid.sh` but adds automatic detection and skipping of
unphysical kinematics. Recommended when running near the η+p threshold,
large |cos θ*| values, or any region where exclurad may hang.

### What counts as "unphysical"

Two failure modes are caught:

1. **Timeout**: exclurad runs beyond `--timeout-sec` seconds. At unphysical
   kinematics the Fortran integration loops indefinitely; a timeout is the
   only way to detect this.
2. **Silent failure**: exclurad exits cleanly (rc=0) but produces no `tai:`
   line in stdout. This indicates the code entered a kinematic guard branch
   and returned without computing anything.

Both cases are logged to `results/skipped_files.log` with a reason tag
(`TIMEOUT`, `EXIT=N`, or `NO_TAI`).

### Usage

```bash
./run_exclurad_skip_unphys.sh \
  --input-dir /path/to/rcgrid-... \
  --work-dir  /path/to/exclurad   \
  --timeout-sec 600               # tune to your typical run time
```

```bash
# Full options
./run_exclurad_skip_unphys.sh \
  --input-dir   /path/to/input_dir   \   # required
  --work-dir    /path/to/exclurad    \   # required
  --results-root /path/for/output    \   # default: work-dir
  --timeout-sec  900                 \   # default: 900 s (15 min)
  --resume                           \   # skip already-completed files
  --limit 10                         \   # process at most N files
  --skip-env                             # skip module loading
```

### Choosing a timeout

Set `--timeout-sec` to roughly 2–3× your typical successful run time. A run
that completes normally at a given kinematics will always finish well within
this window; a run that hangs on unphysical kinematics will never finish.
Check `results/skipped_files.log` after the run — if most skips are `TIMEOUT`
rather than `NO_TAI`, consider reducing the timeout.

---

## Typical end-to-end workflow

```bash
cd /path/to/exclurad

# 1. Generate inputs
python3 scripts/rcgrid_inputgen.py \
  --w-min 1.487 --w-max 1.999 --n-w 30 \
  --q2-min 0.3  --q2-max 4.0  --n-q2 30 \
  --cos-min -0.9 --cos-max 0.9 --n-cos 30 \
  --n-phi 19 --tag prod_run

# 2. Run (use skip_unphys near threshold)
./scripts/run_exclurad_skip_unphys.sh \
  --input-dir rcgrid-phi_sweep_grid_prod_run_...  \
  --work-dir  .                                    \
  --timeout-sec 600

# 3. Check results
ls results_rcgrid-.../all/ | wc -l
cat results_rcgrid-.../skipped_files.log
```

For production runs across many thousands of files, see the `slurm/` directory
for Slurm array job scripts that parallelize the grid across farm nodes.
