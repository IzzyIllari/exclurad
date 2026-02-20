#!/usr/bin/env bash
#SBATCH --job-name=exclu-one
#SBATCH --account=clas12
#SBATCH --partition=production
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=500M
#SBATCH --time=01:00:00
#SBATCH --output=/farm_out/%u/%x-%j-%N.out
#SBATCH --error=/farm_out/%u/%x-%j-%N.err

# exclurad_one_input.sbatch
#
# Run exclurad on a single input .dat file via a job-private work area.
# A good starting point for testing a new build or a specific kinematic point
# before launching a large array job.
#
# This script delegates to run_exclurad_grid.sh (with --limit 1), so all of
# that script's output organisation, logging, and resume logic applies.
#
# Typical submit:
#   sbatch exclurad_one_input.sbatch \
#     --input-file   /path/to/input.dat        \
#     --exe-src-dir  /path/to/exclurad          \
#     --runner       /path/to/exclurad/scripts/run_exclurad_grid.sh \
#     --results-root /path/for/results
#
# See slurm/README.md for a full walkthrough.

set -euo pipefail
IFS=$'\n\t'

# ---------- Defaults ----------
INPUT_FILE=""
EXE_SRC_DIR=""
RUNNER_SCRIPT=""
RESULTS_ROOT=""
STAGE_MODE="copy"  # copy | link
TIMEOUT_SEC=0
LIVE=0

usage() {
  cat <<EOF
Usage: sbatch $0 --input-file FILE --exe-src-dir DIR --runner PATH --results-root DIR [options]

Required:
  --input-file FILE      The .dat input file to run
  --exe-src-dir DIR      Exclurad source dir (contains build/exclurad.exe and tables)
  --runner PATH          Path to run_exclurad_grid.sh
  --results-root DIR     Where results_* directories are created

Optional:
  --stage-mode copy|link How to stage the source tree (default: copy)
  --timeout-sec N        Kill exclurad after N seconds (0 = off)
  --live                 Stream output to console in addition to logs
  -h|--help              Show help
EOF
}

# ---------- Parse CLI ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input-file)   INPUT_FILE="$2";    shift 2 ;;
    --exe-src-dir)  EXE_SRC_DIR="$2";  shift 2 ;;
    --runner)       RUNNER_SCRIPT="$2"; shift 2 ;;
    --results-root) RESULTS_ROOT="$2";  shift 2 ;;
    --stage-mode)   STAGE_MODE="$2";    shift 2 ;;
    --timeout-sec)  TIMEOUT_SEC="${2:-0}"; shift 2 ;;
    --live)         LIVE=1;             shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ---------- Validate ----------
[[ -n "$INPUT_FILE" ]]    || { echo "ERROR: --input-file is required";    usage; exit 2; }
[[ -n "$EXE_SRC_DIR" ]]   || { echo "ERROR: --exe-src-dir is required";   usage; exit 2; }
[[ -n "$RUNNER_SCRIPT" ]] || { echo "ERROR: --runner is required";        usage; exit 2; }
[[ -n "$RESULTS_ROOT" ]]  || { echo "ERROR: --results-root is required";  usage; exit 2; }
[[ -f "$INPUT_FILE" ]]    || { echo "ERROR: input file not found: $INPUT_FILE"; exit 3; }
[[ -x "${EXE_SRC_DIR}/build/exclurad.exe" ]] || \
  { echo "ERROR: missing exe: ${EXE_SRC_DIR}/build/exclurad.exe"; exit 4; }
[[ -x "$RUNNER_SCRIPT" ]] || { echo "ERROR: runner not found/executable: $RUNNER_SCRIPT"; exit 5; }

# ---------- Environment (modules) ----------
if ! command -v module >/dev/null 2>&1; then
  [[ -f /etc/profile.d/modules.sh ]] && source /etc/profile.d/modules.sh || true
  [[ -f /etc/profile.d/lmod.sh    ]] && source /etc/profile.d/lmod.sh    || true
fi
if command -v module >/dev/null 2>&1; then
  if [[ -d /cvmfs/oasis.opensciencegrid.org/jlab/hallb/clas12/sw/modulefiles ]]; then
    module use /cvmfs/oasis.opensciencegrid.org/jlab/hallb/clas12/sw/modulefiles
  fi
  module load clas12 || echo "[warn] 'module load clas12' failed; continuing"
  module load cmake  || true
else
  echo "[warn] 'module' command not available; proceeding without CLAS12 modules"
fi

# ---------- Scratch & staging ----------
JOB_TAG="${SLURM_JOB_ID:-$$}"
SCRATCH_BASE="${SLURM_TMPDIR:-${TMPDIR:-$PWD/_scratch}}"
JOB_SCRATCH="${SCRATCH_BASE}/exclurad_${JOB_TAG}"
mkdir -p "$JOB_SCRATCH"

INPUT_BASE="$(basename "$INPUT_FILE" .dat)"
ONE_INPUT_DIR="${JOB_SCRATCH}/one_${INPUT_BASE}"
mkdir -p "$ONE_INPUT_DIR"
cp -f "$INPUT_FILE" "$ONE_INPUT_DIR/"

JOB_WORK_DIR="${JOB_SCRATCH}/work"
mkdir -p "$JOB_WORK_DIR"

if [[ "$STAGE_MODE" == "link" ]]; then
  ln -s "${EXE_SRC_DIR}" "${JOB_WORK_DIR}/exclurad_src"
  WORK_DIR="${JOB_WORK_DIR}/exclurad_src"
else
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude 'results_*' --exclude 'logs' --exclude 'inputs' \
      "${EXE_SRC_DIR}/" "${JOB_WORK_DIR}/exclurad_src/"
  else
    cp -a "${EXE_SRC_DIR}/." "${JOB_WORK_DIR}/exclurad_src/"
    rm -rf "${JOB_WORK_DIR}/exclurad_src/results_"* \
           "${JOB_WORK_DIR}/exclurad_src/logs"       \
           "${JOB_WORK_DIR}/exclurad_src/inputs"     2>/dev/null || true
  fi
  WORK_DIR="${JOB_WORK_DIR}/exclurad_src"
fi

echo "[info] Scratch:      $JOB_SCRATCH"
echo "[info] Work dir:     $WORK_DIR"
echo "[info] Input dir:    $ONE_INPUT_DIR"
echo "[info] Results root: $RESULTS_ROOT"

# ---------- Run via the grid runner (limit 1, env already loaded) ----------
RUN_OPTS=(
  --input-dir    "$ONE_INPUT_DIR"
  --work-dir     "$WORK_DIR"
  --results-root "$RESULTS_ROOT"
  --limit 1
  --skip-env
)
(( LIVE == 1 ))         && RUN_OPTS+=( --live )
(( TIMEOUT_SEC > 0 ))   && RUN_OPTS+=( --timeout-sec "$TIMEOUT_SEC" )

echo "[info] Calling: $RUNNER_SCRIPT ${RUN_OPTS[*]}"
bash "$RUNNER_SCRIPT" "${RUN_OPTS[@]}"

echo "[done] Finished for: $INPUT_BASE"
