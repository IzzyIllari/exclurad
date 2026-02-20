#!/bin/bash
# run_exclurad_grid.sh
#
# Verbose runner for exclurad.exe over a directory of input .dat files.
# Adds timestamped logging at each step with options to resume, limit,
# stream live output, and apply a per-file timeout.
#
# Usage:
#   ./run_exclurad_grid.sh \
#     --input-dir  /path/to/input_directory \
#     --work-dir   /path/to/exclurad          \
#     [--results-root /path/for/output]        \
#     [--resume] [--limit N] [--skip-env]      \
#     [--live] [--timeout-sec N] [--dry-run]
#
# Notes:
#   - exclurad.exe expects WORK_DIR/input.dat at runtime; this script
#     stages each input file there before each call.
#   - Outputs (all.dat, allu.dat, radasm.dat, radcor.dat, radsigmi.dat,
#     radsigpl.dat, radtot.dat) are collected into a timestamped results
#     directory; per-file logs are saved under results/logs/.
#   - Use --resume to skip files whose outputs already exist (useful for
#     restarting interrupted runs).
#   - For runs near kinematic edges (η threshold, large |cos θ*|), consider
#     run_exclurad_skip_unphys.sh instead, which adds timeout-based detection
#     of unphysical kinematics.

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

RESUME=0
LIMIT=0
SKIP_ENV=0
DRY_RUN=0
LIVE=0
TIMEOUT_SEC=0

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
      --resume              Skip inputs whose outputs already exist in results
      --limit N             Process at most N input files (0 = no limit)
      --skip-env            Do not source setup.sh or load environment modules
      --live                Stream exclurad stdout/stderr to console and to logs
      --timeout-sec N       Kill exclurad if it runs longer than N seconds (0 = off)
      --dry-run             Print actions without executing
  -h, --help                Show this help

Examples:
  # Full grid run
  $0 --input-dir ./inputs_grid --work-dir /path/to/exclurad

  # Resume an interrupted run, streaming output live
  $0 --input-dir ./inputs_grid --work-dir /path/to/exclurad --resume --live

  # Test with the first 5 files only
  $0 --input-dir ./inputs_grid --work-dir /path/to/exclurad --limit 5 --dry-run

Tips:
  * Without --live, exclurad output goes only to logs/. Monitor with:
        tail -f results_.../logs/<file>.out
  * For runs near kinematic edges or η threshold, use run_exclurad_skip_unphys.sh
    to automatically skip files where exclurad hangs on unphysical kinematics.
EOF
}

supports_sort_z() { sort -z </dev/null &>/dev/null; }
have_timeout()    { command -v timeout >/dev/null 2>&1; }

# --------------------------
# Parse CLI
# --------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input-dir)    INPUT_DIR="$2";    shift 2 ;;
    -w|--work-dir)     WORK_DIR="$2";     shift 2 ;;
    -o|--results-root) RESULTS_ROOT="$2"; shift 2 ;;
    --resume)          RESUME=1;          shift   ;;
    --limit)           LIMIT="${2:-0}";   shift 2 ;;
    --skip-env)        SKIP_ENV=1;        shift   ;;
    --dry-run)         DRY_RUN=1;         shift   ;;
    --live)            LIVE=1;            shift   ;;
    --timeout-sec)     TIMEOUT_SEC="${2:-0}"; shift 2 ;;
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

step "Starting run"
log  "Work dir        : $WORK_DIR"
log  "Input dir       : $INPUT_DIR"
log  "Results root    : $RESULTS_ROOT"
log  "Executable      : $EXE_PATH"
log  "Resume          : $RESUME"
log  "Limit           : $LIMIT (0 = no limit)"
log  "Env setup       : $([[ $SKIP_ENV -eq 0 ]] && echo enabled || echo skipped)"
log  "Live streaming  : $LIVE"
log  "Timeout (sec)   : $TIMEOUT_SEC (0 = off)"

# --------------------------
# Environment setup
# --------------------------
if [[ $SKIP_ENV -eq 0 ]]; then
  step "Sourcing environment: $SETUP_SCRIPT"
  # shellcheck disable=SC1090
  if source "$SETUP_SCRIPT"; then
    log "Sourced $SETUP_SCRIPT"
  else
    warn "Failed to source $SETUP_SCRIPT (continuing)"
  fi

  if command -v module >/dev/null 2>&1; then
    step "Loading modules: ${LOAD_MODULES[*]}"
    for m in "${LOAD_MODULES[@]}"; do
      if module load "$m"; then log "Loaded module: $m"
      else warn "module load $m failed"; fi
    done
    log "Module list:"; module list || true
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

if [[ $DRY_RUN -eq 1 ]]; then
  step "[DRY-RUN] Would create results dir: $RESULTS_DIR"
else
  step "Creating results dir: $RESULTS_DIR"
  mkdir -p "$RESULTS_DIR"/{all,allu,radasm,radcor,radsigmi,radsigpl,radtot,logs,inputs}
fi

# Copy manifest if present
if [[ -f "$INPUT_DIR/manifest.csv" && $DRY_RUN -eq 0 ]]; then
  cp "$INPUT_DIR/manifest.csv" "$RESULTS_DIR/input_manifest.csv"
  log "Copied manifest.csv"
fi

# Save run info
if [[ $DRY_RUN -eq 0 ]]; then
  {
    echo "Run started:  $(date -Iseconds)"
    echo "Host:         $(hostname)"
    echo "Work dir:     $WORK_DIR"
    echo "Input dir:    $INPUT_DIR"
    echo "Results dir:  $RESULTS_DIR"
    echo "Executable:   $EXE_PATH"
    echo "Resume: $RESUME  Limit: $LIMIT  Live: $LIVE  Timeout: $TIMEOUT_SEC"
    echo "Env setup: $([[ $SKIP_ENV -eq 0 ]] && echo enabled || echo skipped)"
  } > "$RESULTS_DIR/run_info.txt"
fi

# --------------------------
# Collect input files
# --------------------------
declare -a INPUT_FILES=()
if supports_sort_z; then
  while IFS= read -r -d '' f; do INPUT_FILES+=("$f"); done \
    < <(find "$INPUT_DIR" -maxdepth 1 -type f -name '*.dat' -print0 | sort -z)
else
  while IFS= read -r -d '' f; do INPUT_FILES+=("$f"); done \
    < <(find "$INPUT_DIR" -maxdepth 1 -type f -name '*.dat' -print0)
  IFS=$'\n' INPUT_FILES=($(printf '%s\n' "${INPUT_FILES[@]}" | LC_ALL=C sort))
  IFS=$'\n\t'
fi

TOTAL=${#INPUT_FILES[@]}
if [[ $TOTAL -eq 0 ]]; then
  err "No .dat files found in: $INPUT_DIR"; exit 1
fi

step "Discovered $TOTAL input files"
[[ $LIMIT -gt 0 ]] && log "Processing at most $LIMIT file(s)"

# --------------------------
# Main loop
# --------------------------
OUT_KEYS=(all allu radasm radcor radsigmi radsigpl radtot)
processed=0; ok=0; skipped=0; failed=0

for input_path in "${INPUT_FILES[@]}"; do
  base="$(basename "$input_path" .dat)"
  step "[run] $base"

  # Resume check
  if [[ $RESUME -eq 1 ]]; then
    already_done=1
    for key in "${OUT_KEYS[@]}"; do
      [[ -f "$RESULTS_DIR/$key/${base}.dat" ]] || { already_done=0; break; }
    done
    if [[ $already_done -eq 1 ]]; then
      log "[skip] Outputs already exist for $base"
      ((skipped++)); continue
    fi
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[DRY-RUN] Would run: $EXE_PATH < $input_path"
    ((processed++))
    [[ $LIMIT -gt 0 && $processed -ge $LIMIT ]] && break
    continue
  fi

  # Stage input
  log "Staging input -> $WORK_DIR/input.dat"
  cp -f "$input_path" "$WORK_DIR/input.dat"
  if [[ ! -s "$WORK_DIR/input.dat" ]]; then
    err "Staged input.dat is missing or empty"; ((failed++)); continue
  fi

  # Run
  pushd "$WORK_DIR" >/dev/null
  out="$RESULTS_DIR/logs/${base}.out"
  errlog="$RESULTS_DIR/logs/${base}.err"
  log "stdout -> $out | stderr -> $errlog"

  start_ts=$(date +%s); rc=0

  if [[ $LIVE -eq 1 ]]; then
    if [[ $TIMEOUT_SEC -gt 0 ]] && have_timeout; then
      timeout -s SIGTERM "$TIMEOUT_SEC" "$EXE_PATH" \
        > >(tee "$out") 2> >(tee "$errlog" >&2) || rc=$?
    else
      "$EXE_PATH" > >(tee "$out") 2> >(tee "$errlog" >&2) || rc=$?
    fi
  else
    if [[ $TIMEOUT_SEC -gt 0 ]] && have_timeout; then
      timeout -s SIGTERM "$TIMEOUT_SEC" "$EXE_PATH" >"$out" 2>"$errlog" || rc=$?
    else
      "$EXE_PATH" >"$out" 2>"$errlog" || rc=$?
    fi
  fi

  dur=$(( $(date +%s) - start_ts ))
  log "Finished rc=$rc (${dur}s)"

  # Collect outputs
  moved_any=0
  for key in "${OUT_KEYS[@]}"; do
    [[ -f "${key}.dat" ]] && mv -f "${key}.dat" "$RESULTS_DIR/$key/${base}.dat" \
      && log "Saved $key" && moved_any=1
  done
  cp -f "input.dat" "$RESULTS_DIR/inputs/${base}.dat"
  rm -f "input.dat"
  popd >/dev/null

  if [[ $rc -eq 0 && $moved_any -eq 1 ]]; then ((ok++))
  else ((failed++)); warn "rc=$rc or no outputs for $base (see logs)"; fi

  ((processed++))
  if [[ $LIMIT -gt 0 && $processed -ge $LIMIT ]]; then
    step "Limit reached ($LIMIT). Stopping."; break
  fi
done

echo
step "Summary"
log "Processed : $processed"
log "OK        : $ok"
log "Skipped   : $skipped"
log "Failed    : $failed"
step "Results   : $RESULTS_DIR"
[[ $LIVE -eq 0 ]] && log "Tip: tail -f '$RESULTS_DIR/logs/<file>.out' to monitor."
