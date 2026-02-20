#!/usr/bin/env bash
#SBATCH --job-name=exclu-chunk
#SBATCH --account=clas12
#SBATCH --partition=production
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=500M
#SBATCH --time=02:00:00
#SBATCH --output=/farm_out/%u/%x-%A_%a-%N.out
#SBATCH --error=/farm_out/%u/%x-%A_%a-%N.err

# exclurad_run_chunk.sbatch
#
# Run a chunk of pre-generated input files from an index, with collision-safe
# per-task scratch. Designed for Slurm array jobs where each task processes
# COUNT files from a shared index.
#
# Typical submit:
#   # Build index first (one absolute path per line, sorted):
#   find /path/to/inputs -maxdepth 1 -name '*.dat' | LC_ALL=C sort > inputs.index
#
#   # Submit array (e.g. 6250 chunks of 100 files, 50 concurrent):
#   sbatch --array=0-6249%50 exclurad_run_chunk.sbatch \
#     --inputs-dir /path/to/inputs \
#     --exe-path   /path/to/exclurad/build/exclurad.exe \
#     --results-root /path/for/results \
#     --count 100
#
# See slurm/README.md for a full walkthrough.

set -euo pipefail
IFS=$'\n\t'

# ---------- Defaults ----------
COUNT=100       # files per job; set 1 or 10 to benchmark
GROUP=""        # if empty, uses $SLURM_ARRAY_TASK_ID or 0
START_OFFSET=0  # extra global skip before grouping
INPUTS_DIR=""   # required unless using --index-file
INDEX_FILE=""   # optional: pre-built sorted list of .dat files (recommended for large campaigns)
EXE_PATH=""     # required: absolute path to build/exclurad.exe
RESULTS_ROOT="" # required: where to write results_* directories

usage() {
  cat <<EOF
Usage: sbatch $0 --inputs-dir DIR --exe-path PATH --results-root DIR [options]

Required:
  --inputs-dir DIR    Directory containing input .dat files
  --exe-path PATH     Absolute path to build/exclurad.exe
  --results-root DIR  Where to create results_* directories

Optional:
  --index-file FILE   Pre-built sorted list of .dat files (one per line).
                      Recommended for campaigns >10k files to avoid repeated find calls.
  --count N           Files per array task (default: 100)
  --group G           Chunk index (0-based); default: \$SLURM_ARRAY_TASK_ID or 0
  --start-offset K    Skip first K files globally (default: 0)
  -h|--help           Show help

Notes:
  OFFSET = START_OFFSET + GROUP * COUNT
  Build the index before submitting large arrays:
    find /path/to/inputs -maxdepth 1 -name '*.dat' | LC_ALL=C sort > inputs.index
EOF
}

# ---------- Parse CLI ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inputs-dir)   INPUTS_DIR="$2";   shift 2 ;;
    --index-file)   INDEX_FILE="$2";   shift 2 ;;
    --count)        COUNT="$2";        shift 2 ;;
    --group)        GROUP="$2";        shift 2 ;;
    --start-offset) START_OFFSET="$2"; shift 2 ;;
    --exe-path)     EXE_PATH="$2";     shift 2 ;;
    --results-root) RESULTS_ROOT="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# ---------- Validate ----------
[[ -n "$EXE_PATH" ]]     || { echo "ERROR: --exe-path is required";     exit 2; }
[[ -n "$RESULTS_ROOT" ]] || { echo "ERROR: --results-root is required"; exit 2; }
[[ -x "$EXE_PATH" ]]     || { echo "ERROR: exe not found/executable: $EXE_PATH"; exit 3; }
if [[ -n "$INDEX_FILE" ]]; then
  [[ -f "$INDEX_FILE" ]] || { echo "ERROR: --index-file not found: $INDEX_FILE"; exit 3; }
else
  [[ -n "$INPUTS_DIR" && -d "$INPUTS_DIR" ]] || { echo "ERROR: --inputs-dir missing or not a dir"; exit 3; }
fi
[[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]] || { echo "ERROR: --count must be a positive int"; exit 2; }
[[ "$START_OFFSET" =~ ^[0-9]+$ ]]             || { echo "ERROR: --start-offset must be >= 0";   exit 2; }
if [[ -z "$GROUP" ]]; then GROUP="${SLURM_ARRAY_TASK_ID:-0}"; fi
[[ "$GROUP" =~ ^[0-9]+$ ]] || { echo "ERROR: --group must be a non-negative int"; exit 2; }

OFFSET=$(( START_OFFSET + GROUP * COUNT ))

# ---------- Build file list for this chunk ----------
declare -a FILES=()
if [[ -n "$INDEX_FILE" ]]; then
  mapfile -t FILES < <(awk -v off="$OFFSET" -v cnt="$COUNT" \
    'NR>off && NR<=off+cnt {print}' "$INDEX_FILE")
else
  mapfile -t FILES < <(find "$INPUTS_DIR" -maxdepth 1 -type f -name '*.dat' \
    -print | LC_ALL=C sort | \
    awk -v off="$OFFSET" -v cnt="$COUNT" 'NR>off && NR<=off+cnt')
fi

TOTAL=${#FILES[@]}
(( TOTAL > 0 )) || { echo "ERROR: No files selected (OFFSET=$OFFSET, COUNT=$COUNT)."; exit 4; }

# ---------- Results directory ----------
INPUTS_BASE="$(basename "${INDEX_FILE:-$INPUTS_DIR}")"
STAMP="$(date +%Y%m%d_%H%M%S)"
JOBID="${SLURM_JOB_ID:-$$}"
RESULTS_DIR="${RESULTS_ROOT}/results_sbatch_N${TOTAL}_grp$(printf "%05d" "$GROUP")_off$(printf "%08d" "$OFFSET")_${INPUTS_BASE}_${JOBID}_${STAMP}"
mkdir -p "$RESULTS_DIR"/{all,allu,radasm,radcor,radsigmi,radsigpl,radtot,logs,inputs}

# Save file list and run info
> "$RESULTS_DIR/filelist_used.txt"
for i in "${!FILES[@]}"; do
  gi=$(( OFFSET + i + 1 ))
  printf "%08d %s\n" "$gi" "${FILES[$i]}" >> "$RESULTS_DIR/filelist_used.txt"
done

MANIFEST="$RESULTS_DIR/manifest.csv"
echo "input_base,group,global_idx,rc,elapsed,peak_rss_kb,notes" > "$MANIFEST"
{
  echo "Run started:  $(date -Iseconds)"
  echo "User:         $USER   Host: $(hostname)"
  echo "JobID:        $JOBID  ArrayTask: ${SLURM_ARRAY_TASK_ID:-NA}"
  echo "Group:        $GROUP  Offset: $OFFSET  Count: $COUNT"
  echo "Exe:          $EXE_PATH"
  echo "Inputs:       ${INDEX_FILE:-$INPUTS_DIR}"
} > "$RESULTS_DIR/run_info.txt"

# ---------- Main loop ----------
OK=0; FAIL=0
for idx in "${!FILES[@]}"; do
  INP="${FILES[$idx]}"
  BASE="$(basename "$INP" .dat)"
  GIDX=$(( OFFSET + idx + 1 ))

  echo "[$(date +%H:%M:%S)] [run] #$GIDX : $BASE"

  SCR="${SLURM_TMPDIR:-${TMPDIR:-$PWD}}/exclurad_${JOBID}/run_${BASE}"
  mkdir -p "$SCR"
  cp -f "$INP" "$SCR/input.dat"

  OUT="$RESULTS_DIR/logs/${BASE}.out"
  ERR="$RESULTS_DIR/logs/${BASE}.err"

  rc=0; elapsed=""; rss_kb=""
  pushd "$SCR" >/dev/null
  if [[ -x /usr/bin/time ]]; then
    /usr/bin/time -v "$EXE_PATH" >"$OUT" 2>"$ERR" || rc=$?
    elapsed="$(grep -m1 'Elapsed (wall clock) time' "$ERR" | sed 's/.*: *//'  || true)"
    rss_kb="$(grep -m1 'Maximum resident set size (kbytes)' "$ERR" | awk '{print $6}' || true)"
  else
    { time -p "$EXE_PATH"; } >"$OUT" 2>"$ERR" || rc=$?
    elapsed="$(grep -m1 '^real ' "$ERR" | awk '{print $2}' || true)"
    rss_kb=""
  fi

  moved_any=0
  for key in all allu radasm radcor radsigmi radsigpl radtot; do
    [[ -f "${key}.dat" ]] && { mv -f "${key}.dat" "$RESULTS_DIR/${key}/${BASE}.dat"; moved_any=1; }
  done
  cp -f "input.dat" "$RESULTS_DIR/inputs/${BASE}.dat" || true
  popd >/dev/null
  rm -rf "$SCR" || true

  if (( rc==0 && moved_any==1 )); then
    echo "${BASE},${GROUP},${GIDX},${rc},${elapsed},${rss_kb}," >> "$MANIFEST"
    ((OK++))
  else
    echo "${BASE},${GROUP},${GIDX},${rc},${elapsed},${rss_kb},rc=${rc}; outputs_moved=${moved_any}" >> "$MANIFEST"
    ((FAIL++))
  fi
done

echo ""
echo "Summary: group=$GROUP  offset=$OFFSET  count=$COUNT  ok=$OK  fail=$FAIL  total=$TOTAL"
echo "Results: $RESULTS_DIR"
