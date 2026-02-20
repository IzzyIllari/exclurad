# slurm/

Slurm batch scripts for running exclurad on the JLab farm. Two patterns
are covered: running a pre-generated input grid in parallel chunks, and
self-contained array jobs that generate their own inputs at runtime.

## When to use which script

| Script | Pattern | When to use |
|---|---|---|
| `exclurad_one_input.sbatch` | Single file | Testing a build or a specific kinematic point |
| `exclurad_run_chunk.sbatch` | Chunk array | Running a large pre-generated grid from `rcgrid_inputgen.py` |
| `exclu_30x30_WQ2scan_array.sbatch` | Self-contained array | Full W×Q² scan; each task generates and runs its own 30×30 angular grid |
| `exclu_vcut_scan.sbatch` | ν_cut scan | Scanning ν_cut at fixed kinematics (single job, ~50–200 calls) |

---

## Pattern A: chunk array (pre-generated inputs)

Use this when you have already generated a grid with `scripts/rcgrid_inputgen.py`.
It gives you the most control over the kinematic grid and is the recommended
workflow for production runs.

### Step 1: generate inputs

```bash
python3 scripts/rcgrid_inputgen.py \
  --w-min 1.487 --w-max 1.999 --n-w 30 \
  --q2-min 0.3  --q2-max 4.0  --n-q2 30 \
  --cos-min -0.9 --cos-max 0.9 --n-cos 30 \
  --n-phi 19 \
  --tag prod_run
# Output: rcgrid-phi_sweep_grid_prod_run_..._<timestamp>/
```

### Step 2: build an index (recommended for large campaigns)

```bash
INPUT_DIR="rcgrid-phi_sweep_grid_prod_run_..."
find "$INPUT_DIR" -maxdepth 1 -name '*.dat' | LC_ALL=C sort > inputs.index
wc -l inputs.index   # total files
```

### Step 3: submit the array

```bash
TOTAL=$(wc -l < inputs.index)
N_PER_JOB=100
N_TASKS=$(( (TOTAL + N_PER_JOB - 1) / N_PER_JOB - 1 ))  # 0-based last index

sbatch --array=0-${N_TASKS}%50 slurm/exclurad_run_chunk.sbatch \
  --index-file   $(pwd)/inputs.index                              \
  --exe-path     /path/to/exclurad/build/exclurad.exe             \
  --results-root /volatile/clas12/$USER/exclurad/results          \
  --count        $N_PER_JOB
```

Each task processes files `[task * COUNT, (task+1) * COUNT)` from the index,
writing results to a timestamped `results_sbatch_N*_grp*_off*_...` directory
under `RESULTS_ROOT`.

### Monitoring

```bash
# Check array status
squeue -u $USER

# Check a specific task's output
cat /farm_out/$USER/exclu-chunk-<JOBID>_<TASK>-<NODE>.out

# Count completed output files
ls /volatile/.../results_*/all/ | wc -l

# Check for failures
grep -r "FAIL\|rc=[^0]" /volatile/.../results_*/manifest.csv
```

---

## Pattern B: self-contained array (W×Q² scan)

Use this when you want to scan a W×Q² grid and run a full 30×30 angular
grid at each point, without pre-generating input files. Each array task
stages the build and tables into node-local scratch, generates inputs
internally, runs all 90 exclurad calls, and tars results to `RESULTS_ROOT`.

### Submit

```bash
# 18 W points × 20 Q² points = 360 tasks
sbatch --array=0-359%50 slurm/exclu_30x30_WQ2scan_array.sbatch \
  --src-dir      /path/to/exclurad                               \
  --results-root /volatile/clas12/$USER/exclurad/wq2scan
```

Override the grid:
```bash
sbatch --array=0-899%100 slurm/exclu_30x30_WQ2scan_array.sbatch \
  --src-dir /path/to/exclurad  --results-root /volatile/...      \
  --w-min 1.487 --w-max 1.999 --n-w 30                           \
  --q2-min 0.3  --q2-max 5.0  --n-q2 30
```

Single-point test (no `--array`):
```bash
sbatch slurm/exclu_30x30_WQ2scan_array.sbatch \
  --src-dir /path/to/exclurad  --results-root /volatile/...      \
  --W 1.6639 --Q2 0.4276
```

Each task writes a gzip-compressed tarball named:
`results_W<W>_Q2<Q2>_30x30_<stamp>_J<jobid>_T<task>.tar.gz`

Unpack all results:
```bash
cd /volatile/...
for f in results_W*.tar.gz; do tar -xzf "$f"; done
```

---

## exclurad_one_input.sbatch

Single-file convenience wrapper around `run_exclurad_grid.sh`. Good for
testing a new build or a single kinematic point before launching an array.

```bash
sbatch slurm/exclurad_one_input.sbatch \
  --input-file   examples/input_single_chunk.dat               \
  --exe-src-dir  /path/to/exclurad                              \
  --runner       /path/to/exclurad/scripts/run_exclurad_grid.sh \
  --results-root /path/for/results
```

---

## exclu_vcut_scan.sbatch

Scans ν_cut at fixed (W, Q², cos θ*, φ*). Runs as a single job (~50–200
sequential exclurad calls). The kinematic maximum
v_m(W) = (W − m_p)² − m_η² is computed automatically if `--vcut-max` is
not provided.

A vcut column is appended to each `radtot` output line for easy
post-processing across vcut values.

```bash
sbatch slurm/exclu_vcut_scan.sbatch \
  --src-dir      /path/to/exclurad              \
  --results-root /volatile/...                  \
  --W 1.9000 --Q2 0.4105 --n-vcut 50
```

Override the fixed angles or scan range:
```bash
sbatch slurm/exclu_vcut_scan.sbatch \
  --src-dir /path/to/exclurad --results-root /volatile/...   \
  --W 1.700 --Q2 0.683 --cos -0.5 --phi 228                 \
  --vcut-min 0.0 --vcut-max 0.4 --n-vcut 40
```

Output is a tarball: `results_vcut_scan_W<W>_Q2<Q2>_cos<cos>_phi<phi>_<stamp>_J<jobid>.tar.gz`

---

## JLab farm notes

**Scratch directories:**  These scripts use `$SLURM_TMPDIR` (node-local NVMe
scratch, fastest I/O) when available. If not set, they fall back to
`/scratch/slurm/<jobid>` or `$RESULTS_ROOT/_scratch`. Node-local scratch is
cleaned automatically after the job ends.

**Output file locations:** Slurm stdout/stderr go to `/farm_out/$USER/`.
Exclurad results go to `$RESULTS_ROOT`.

**Filesystem choice for `--results-root`:**

| Filesystem | Use for | Notes |
|---|---|---|
| `/volatile/clas12/$USER/` | Large result tarballs | Fast, not backed up, purged after ~6 months |
| `/work/clas12/$USER/` | Source code, index files | Backed up, slower for heavy I/O |
| `/farm_out/$USER/` | Slurm job logs only | Managed by the system |

**Time limits:** The default `--time` values in each script are conservative
estimates. Adjust based on your benchmarks (run `exclurad_one_input.sbatch`
on a representative input first to measure wall time per file).

**Memory:** Exclurad is single-threaded and memory-light (~100–200 MB per
process). The defaults (`--mem-per-cpu`) include a buffer; reduce if you
need to fit more tasks per node.

**Concurrency limit (`%N` in `--array`):** The `%50` suffix caps concurrent
tasks at 50. Increase for larger campaigns once you have confirmed the
per-task behaviour; JLab's fair-share policy means very large concurrent
submissions may queue for longer.
