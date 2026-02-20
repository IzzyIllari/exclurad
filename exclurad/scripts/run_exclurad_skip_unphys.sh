#!/bin/bash
# run_exclurad_skip_unphys.sh
#
# Runner for exclurad.exe with automatic detection and skipping of
# unphysical kinematics. Use this script instead of run_exclurad_grid.sh
# when running near kinematic edges: the η+p threshold (W ≈ 1.486 GeV),
# large |cos θ*| values, or any region where the Fortran integration
# may hang indefinitely.
#
# Two detection mechanisms:
#   1. Timeout: if exclurad.exe runs longer than --timeout-sec, the
#      kinematics are almost certainly unphysical and the job is killed.
#   2. Output check: even when exclurad exits cleanly (rc=0), if no
#      "tai:" line appears in stdout the calculation produced no results
#      (silent failure on unphysical kinematics) and the file is skipped.
#
# Usage:
#   ./run_exclurad_skip_unphys.sh \
#     --input-dir  /path/to/input_directory \
#     --work-dir   /path/to/exclurad          \
#     [--results-root /path/for/output]        \
#     [--timeout-sec N]                        \
#     [--resume] [--limit N] [--skip-env]
#
# The skip log is saved to results/skipped_files.log.

set -Euo pipefail
IFS=$'\n\t'

# --------------------------
# Defaults
# --------------------------
SETUP_SCRIPT="/group/clas12/packages/setup.sh"
LOAD_MODULES=("clas12" "cmake")

INPUT_DIR=""
WORK_DIR=""
RESULTS_ROOT=""
EXE_REL="build/exclurad.exe"

TIMEOUT_SEC=900    # 15 min; tune to your typical run time
RESUME=0
LIMIT=0
SKIP_ENV=0

# --------------------------
# Logging helpers
# --------------------------
ts()   { date +"%Y-%m-%d %H:%M:%S"; }
log()  { echo "[$(ts)] $*"; }
step() { echo -e "[$(ts)] \e[1m$*\e[0m"; }
warn() { echo -e "[$(ts)] \e[33mWARN:\e[0m $*" >&2; }
err()  { echo -e "[$(ts)] \e[31mERROR:\e[0m $*" >&2; }

# --------------------------
# Usage
# --------------------------
usage() {
  cat <<EOF
Usage: $0 [options]

Required:
  -i, --input-dir DIR       Directory containing input .dat files
  -w, --work-dir  DIR       Exclurad working directory (must contain build/exclurad.exe)

Optional:
  -o, --results-root DIR    Where to create the results directory (default: WORK_DIR)
      --timeout-sec N       Kill exclurad if it runs longer than N seconds (default: 900)
                            Set based on your typical run time; unphysical inputs hang
                            indefinitely without this.
      --resume              Skip inputs whose outputs already exist in results
      --limit N             Process at most N input files (0 = no limit)
      --skip-env            Do not source setup.sh or load environment modules
  -h, --help                Show this help

Examples:
  # Grid run near η threshold with 10-minute timeout
  $0 --input-dir ./inputs_grid --work-dir /path/to/exclurad --timeout-sec 600

  # Resume an interrupted run
  $0 --input-dir ./inputs_grid --work-dir /path/to/exclurad --resume

Notes:
  - The skip log is written to results/skipped_files.log.
  - Skipping summary is printed at the end; a warning is shown if >10% skipped.
  - For runs away from kinematic edges, run_exclurad_grid.sh is simpler.
EOF
}

# --------------------------
# Parse CLI
# --------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input-dir)    INPUT_DIR="$2";        shift 2 ;;
    -w|--work-dir)     WORK_DIR="$2";         shift 2 ;;
    -o|--results-root) RESULTS_ROOT="$2";     shift 2 ;;
    --timeout-sec)     TIMEOUT_SEC="${2:-900}"; shift 2 ;;
    --resume)          RESUME=1;              shift   ;;
    --limit)           LIMIT="${2:-0}";       shift 2 ;;
    --skip-env)        SKIP_ENV=1;            shift   ;;
    -h|--help)         usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# --------------------------
# Validate
# --------------------------
if [[ -z "$WORK_DIR" ]]; then
  err "--work-dir is required"; usage; exit 1
fi
if [[ ! -d "$WORK_DIR" ]]; then
  err "work-dir does not exist or is not a directory: '$WORK_DIR'"; exit 1
fi
if [[ -z "$INPUT_DIR" ]]; then
  err "--input-dir is required"; usage; exit 1
fi
if [[ ! -d "$INPUT_DIR" ]]; then
  err "input-dir does not exist or is not a directory: '$INPUT_DIR'"; exit 1
fi
[[ -z "$RESULTS_ROOT" ]] && RESULTS_ROOT="$WORK_DIR"

EXE_PATH="${WORK_DIR}/${EXE_REL}"
if [[ ! -x "$EXE_PATH" ]]; then
  err "Executable not found or not executable: $EXE_PATH"
  err "Build first: cd $WORK_DIR && make  (or: scons)"
  exit 1
fi

step "Starting run (unphysical-skip mode)"
log  "Work dir      : $WORK_DIR"
log  "Input dir     : $INPUT_DIR"
log  "Results root  : $RESULTS_ROOT"
log  "Executable    : $EXE_PATH"
log  "Timeout (sec) : $TIMEOUT_SEC"
log  "Resume        : $RESUME"
log  "Limit         : $LIMIT (0 = no limit)"
log  "Env setup     : $([[ $SKIP_ENV -eq 0 ]] && echo enabled || echo skipped)"

# --------------------------
# Environment setup
# --------------------------
if [[ $SKIP_ENV -eq 0 ]]; then
  step "Sourcing environment: $SETUP_SCRIPT"
  # shellcheck disable=SC1090
  if source "$SETUP_SCRIPT"; then log "Sourced $SETUP_SCRIPT"
  else warn "Failed to source $SETUP_SCRIPT (continuing)"; fi

  if command -v module >/dev/null 2>&1; then
    step "Loading modules: ${LOAD_MODULES[*]}"
    for m in "${LOAD_MODULES[@]}"; do
      if module load "$m"; then log "Loaded module: $m"
      else warn "module load $m failed"; fi
    done
    module list || true
  else
    warn "'module' command not found; proceeding without modules."
  fi
else
  step "Skipping environment setup (--skip-env)"
fi

# --------------------------
# Results directory
# --------------------------
INPUT_BASENAME="$(basename "$INPUT_DIR")"
STAMP="$(date +%Y%m%d_%H%M%S)"
RESULTS_DIR="${RESULTS_ROOT}/results_${INPUT_BASENAME}_${STAMP}"

step "Creating results dir: $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"/logs

SKIP_LOG="$RESULTS_DIR/skipped_files.log"
touch "$SKIP_LOG"
log "Skip log: $SKIP_LOG"

# Copy manifest if present
[[ -f "$INPUT_DIR/manifest.csv" ]] && \
  cp "$INPUT_DIR/manifest.csv" "$RESULTS_DIR/input_manifest.csv" && \
  log "Copied manifest.csv"

# --------------------------
# Collect input files
# --------------------------
declare -a INPUT_FILES=()
while IFS= read -r -d '' f; do INPUT_FILES+=("$f"); done \
  < <(find "$INPUT_DIR" -maxdepth 1 -type f -name '*.dat' -print0 | sort -z 2>/dev/null \
      || find "$INPUT_DIR" -maxdepth 1 -type f -name '*.dat' -print0)

TOTAL=${#INPUT_FILES[@]}
if [[ $TOTAL -eq 0 ]]; then
  err "No .dat files found in: $INPUT_DIR"; exit 1
fi

step "Discovered $TOTAL input files"
[[ $LIMIT -gt 0 ]] && log "Processing at most $LIMIT file(s)"

# --------------------------
# Progress display
# --------------------------
LAST_PERCENT=0
show_progress() {
  local current=$1 total=$2
  local percent=$(( current * 100 / total ))
  if [[ $(( percent / 5 )) -gt $(( LAST_PERCENT / 5 )) ]]; then
    echo ""
    echo "  Progress: ${percent}% (${current}/${total})  OK: $ok  Skipped: $SKIPPED"
    echo ""
    LAST_PERCENT=$percent
  fi
}

# --------------------------
# Main loop
# --------------------------
OUT_KEYS=(all allu radasm radcor radsigmi radsigpl radtot)
processed=0; ok=0; SKIPPED=0; failed=0

for input_path in "${INPUT_FILES[@]}"; do
  base="$(basename "$input_path" .dat)"
  ((processed++))

  show_progress $processed $TOTAL

  # Resume check
  if [[ $RESUME -eq 1 ]]; then
    already_done=1
    for key in "${OUT_KEYS[@]}"; do
      [[ -f "$RESULTS_DIR/$key/${base}.dat" ]] || { already_done=0; break; }
    done
    if [[ $already_done -eq 1 ]]; then
      log "[skip/resume] $base"
      ((SKIPPED++)); continue
    fi
  fi

  log "--- Processing ($processed/$TOTAL): $base ---"
  cp -f "$input_path" "$WORK_DIR/input.dat"

  pushd "$WORK_DIR" >/dev/null
  logfile="$RESULTS_DIR/logs/${base}.txt"

  # Run with timeout; capture stdout to logfile and display it
  timeout "$TIMEOUT_SEC" "$EXE_PATH" 2>&1 | tee "$logfile"
  EXIT_CODE=${PIPESTATUS[0]}
  popd >/dev/null

  # --- Detection logic ---
  if [[ $EXIT_CODE -eq 124 ]]; then
    warn "SKIPPED (timeout after ${TIMEOUT_SEC}s — likely unphysical): $base"
    echo "$(date -Iseconds) TIMEOUT     $base" >> "$SKIP_LOG"
    rm -f "$WORK_DIR"/{all,allu,radasm,radcor,radsigmi,radsigpl,radtot}.dat
    ((SKIPPED++)); continue

  elif [[ $EXIT_CODE -ne 0 ]]; then
    warn "SKIPPED (exit code $EXIT_CODE): $base"
    echo "$(date -Iseconds) EXIT=$EXIT_CODE  $base" >> "$SKIP_LOG"
    ((SKIPPED++)); continue

  elif ! grep -q "tai:" "$logfile" 2>/dev/null; then
    warn "SKIPPED (no 'tai:' output — silent unphysical): $base"
    echo "$(date -Iseconds) NO_TAI      $base" >> "$SKIP_LOG"
    rm -f "$WORK_DIR"/{all,allu,radasm,radcor,radsigmi,radsigpl,radtot}.dat
    ((SKIPPED++)); continue
  fi

  # --- Success: collect outputs ---
  mkdir -p "$RESULTS_DIR"/{all,allu,radasm,radcor,radsigmi,radsigpl,radtot,inputs}
  moved_any=0
  for key in "${OUT_KEYS[@]}"; do
    src="$WORK_DIR/${key}.dat"
    [[ -f "$src" ]] && mv -f "$src" "$RESULTS_DIR/$key/${base}.dat" && moved_any=1
  done
  cp -f "$input_path" "$RESULTS_DIR/inputs/${base}.dat"

  if [[ $moved_any -eq 1 ]]; then
    log "OK: $base"
    ((ok++))
  else
    warn "No output files found after successful exit for $base"
    echo "$(date -Iseconds) NO_OUTPUT   $base" >> "$SKIP_LOG"
    ((SKIPPED++))
  fi

  if [[ $LIMIT -gt 0 && $processed -ge $LIMIT ]]; then
    step "Limit reached ($LIMIT). Stopping."; break
  fi
done

# --------------------------
# Summary
# --------------------------
echo ""
step "Processing complete"
log  "Total     : $TOTAL"
log  "OK        : $ok"
log  "Skipped   : $SKIPPED"
log  "Failed    : $failed"
log  "Skip log  : $SKIP_LOG"
step "Results   : $RESULTS_DIR"

if [[ $SKIPPED -gt 0 && $TOTAL -gt 0 ]]; then
  SKIP_PCT=$(( SKIPPED * 100 / TOTAL ))
  if [[ $SKIP_PCT -gt 10 ]]; then
    warn "${SKIP_PCT}% of files were skipped — check $SKIP_LOG for details."
  fi
fi
