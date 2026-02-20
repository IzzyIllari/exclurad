#!/usr/bin/env bash
#SBATCH --job-name=exclu-WQ2scan
#SBATCH --account=clas12
#SBATCH --partition=production
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=120M
#SBATCH --time=24:00:00
#SBATCH --gres=disk:2G
#SBATCH --output=/farm_out/%u/%x-%A_%a-%N.out
#SBATCH --error=/farm_out/%u/%x-%A_%a-%N.err

# exclu_30x30_WQ2scan_array.sbatch
#
# Slurm array job: each task covers one (W, Q²) point and runs a full
# 30×30 (cos θ*, φ*) angular grid internally (90 exclurad calls per task
# at 10 points per file). Results are compressed and tarred to RESULTS_ROOT.
#
# This script generates its own input files at runtime — no pre-generated
# input directory is needed. Use exclurad_run_chunk.sbatch instead if you
# have already generated inputs with rcgrid_inputgen.py.
#
# Typical submit (18×20 = 360 W×Q² points, 50 concurrent tasks):
#   sbatch --array=0-359%50 exclu_30x30_WQ2scan_array.sbatch \
#     --src-dir      /path/to/exclurad \
#     --results-root /path/for/results
#
# Single-point test (no array):
#   sbatch exclu_30x30_WQ2scan_array.sbatch \
#     --src-dir /path/to/exclurad --results-root /path/for/results \
#     --W 1.6639 --Q2 0.4276
#
# See slurm/README.md for a full walkthrough.

set -Eeuo pipefail
trap 'rc=$?; echo "[FATAL] rc=$rc at line $LINENO while running: $BASH_COMMAND"; exit $rc' ERR
IFS=$'\n\t'
LC_ALL=C

# ---------- Required ----------
SRC_DIR=""       # path to exclurad working dir (must contain build/exclurad.exe)
RESULTS_ROOT=""  # where to write per-task tarballs

# ---------- W×Q² scan grid (for array mode) ----------
W_MIN="1.4861"
W_MAX="2.0000"
N_W=18

Q2_MIN="0.3000"
Q2_MAX="5.0000"
N_Q2=20

# ---------- Single-point fallback (used when NOT running as an array job) ----------
W_IN="1.6639"
Q2_IN="0.4276"

# ---------- Physics model ----------
MODEL=3
RC_MODE=0
BMOM="6.53"
TMOM="0.0"
LEPTON=1
IVEC=1
VCUT="0.166"

# ---------- Angular grid ----------
# cos(θ*): endpoints at ±0.999 to avoid ±1 numerical issues
COS_MIN="-0.999"
COS_MAX="+0.999"
N_COS=30

# φ*: bin-centers to avoid exactly 0°, 180°, 360° (where sin φ* = 0)
N_PHI=30
N_PER_FILE=10  # ≤10 required by Fortran reader; 30 phi ÷ 10 = 3 files per cos value

PROGRESS_STEP=5

usage() {
  cat <<EOF
Usage:
  sbatch --array=0-$((N_W*N_Q2-1))%MAXRUN $0 --src-dir DIR --results-root DIR [options]

Required:
  --src-dir DIR         Exclurad working directory (contains build/exclurad.exe)
  --results-root DIR    Where per-task result tarballs are written

W×Q² grid (array mode):
  --w-min F  --w-max F  --n-w N
  --q2-min F --q2-max F --n-q2 N

Single-point (non-array) override:
  --W F   --Q2 F

Physics model:
  --model N --rc-mode N --bmom F --tmom F --lepton N --ivec N --vcut F

Angular grid:
  --cos-min F --cos-max F --n-cos N --n-phi N --progress-step N
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-dir)      SRC_DIR="$2";        shift 2 ;;
    --results-root) RESULTS_ROOT="$2";   shift 2 ;;
    --w-min)        W_MIN="$2";          shift 2 ;;
    --w-max)        W_MAX="$2";          shift 2 ;;
    --n-w)          N_W="$2";            shift 2 ;;
    --q2-min)       Q2_MIN="$2";         shift 2 ;;
    --q2-max)       Q2_MAX="$2";         shift 2 ;;
    --n-q2)         N_Q2="$2";           shift 2 ;;
    --W)            W_IN="$2";           shift 2 ;;
    --Q2)           Q2_IN="$2";          shift 2 ;;
    --model)        MODEL="$2";          shift 2 ;;
    --rc-mode)      RC_MODE="$2";        shift 2 ;;
    --bmom)         BMOM="$2";           shift 2 ;;
    --tmom)         TMOM="$2";           shift 2 ;;
    --lepton)       LEPTON="$2";         shift 2 ;;
    --ivec)         IVEC="$2";           shift 2 ;;
    --vcut)         VCUT="$2";           shift 2 ;;
    --cos-min)      COS_MIN="$2";        shift 2 ;;
    --cos-max)      COS_MAX="$2";        shift 2 ;;
    --n-cos)        N_COS="$2";          shift 2 ;;
    --n-phi)        N_PHI="$2";          shift 2 ;;
    --progress-step) PROGRESS_STEP="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$SRC_DIR" ]]     || { echo "ERROR: --src-dir is required";     exit 3; }
[[ -n "$RESULTS_ROOT" ]] || { echo "ERROR: --results-root is required"; exit 3; }
[[ -d "$SRC_DIR" ]]     || { echo "ERROR: SRC_DIR not found: $SRC_DIR"; exit 3; }
[[ -x "$SRC_DIR/build/exclurad.exe" ]] || { echo "ERROR: missing $SRC_DIR/build/exclurad.exe"; exit 4; }
mkdir -p "$RESULTS_ROOT"

fmt_w='%.4f'
fmt_q2='%.4f'
fmt_cos='%.6f'

# ---------- Array task → (W_IN, Q2_IN) ----------
lin_val() {
  awk -v a="$1" -v b="$2" -v n="$3" -v inc="$4" -v i="$5" 'BEGIN{
    if(n<=1){ printf("%.10f", a); exit }
    step = (inc==1 ? (b-a)/(n-1) : (b-a)/n);
    printf("%.10f", a + i*step);
  }'
}

if [[ -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  tot_tasks=$(( N_W * N_Q2 ))
  task=${SLURM_ARRAY_TASK_ID}
  if (( task < 0 || task >= tot_tasks )); then
    echo "ERROR: SLURM_ARRAY_TASK_ID=$task outside [0,$((tot_tasks-1))]"; exit 2
  fi
  iw=$(( task / N_Q2 ))
  iq=$(( task % N_Q2 ))
  W_IN=$(lin_val "$W_MIN" "$W_MAX" "$N_W" 1 "$iw")
  Q2_IN=$(lin_val "$Q2_MIN" "$Q2_MAX" "$N_Q2" 1 "$iq")
  echo "[array] task=$task -> iw=$iw iq=$iq => W=$W_IN Q2=$Q2_IN"
fi

# ---------- Scratch (unique per array task) ----------
ARRAY_JOB="${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-$$}}"
ARRAY_TASK="${SLURM_ARRAY_TASK_ID:-}"
TASK_TAG=""; [[ -n "$ARRAY_TASK" ]] && TASK_TAG="_T${ARRAY_TASK}"

SCRATCH_DIR="${SLURM_TMPDIR:-/scratch/slurm/${ARRAY_JOB}}${TASK_TAG}"
WORK="$SCRATCH_DIR/work"
mkdir -p "$WORK"

echo "========== STAGE 1/4: stage build & tables =========="
echo "[info] Scratch: $SCRATCH_DIR"
echo "[info] SRC_DIR: $SRC_DIR"
rsync -a "$SRC_DIR/build/" "$WORK/build/"
find "$SRC_DIR" -maxdepth 1 -type f \( -name "*.tbl" -o -name "*.inc" -o -name "maid*.dat" \) -print0 \
  | xargs -0 -I{} cp -a "{}" "$WORK/" || true
echo "[stage] done."

RES_LOCAL="$WORK/results"
mkdir -p "$RES_LOCAL"/{all,allu,radasm,radcor,radsigmi,radsigpl,radtot,inputs,logs}
MANIFEST="$RES_LOCAL/manifest.csv"
echo "seq,base,W,Q2,cos,phi_first,phi_last,N,rc,elapsed,peak_rss_kb" > "$MANIFEST"

# ---------- Helpers ----------
write_input_file() {
  local out="$1" W="$2" Q2="$3" COS="$4"; shift 4
  local -a phi_arr=( "$@" ); local N=${#phi_arr[@]}
  {
    echo "$MODEL       !  1: AO 2: maid98  3: maid2000"
    echo "$RC_MODE     !  0: Full, 1: Factorizable and Leading log"
    echo "$BMOM        !  bmom - lepton momentum"
    echo "$TMOM        !  tmom - momentum per nucleon"
    echo "$LEPTON      !  lepton - 1 electron, 2 muon"
    echo "$IVEC        !  ivec - detected hadron (1) p, (2) pi+"
    echo "$VCUT        !  vcut - cut on inelasticity (0.) if no cut, negative -- v"
    echo ""
    echo "$N ! no. of points"
    for ((i=0;i<N;i++)); do printf "$fmt_w "  "$W";   done; echo "! W values"
    for ((i=0;i<N;i++)); do printf "$fmt_q2 " "$Q2";  done; echo "! Q^2 values"
    for ((i=0;i<N;i++)); do printf "$fmt_cos " "$COS"; done; echo "! Cos(Theta) values"
    for p in "${phi_arr[@]}"; do printf "%d. " "$p"; done; echo "! phi values"
    echo ""
    echo "0error detected by nag library routine   d01fce - ifail =     2"
  } > "$out"
}

# ---------- Progress ----------
TOTAL_FILES=0; NEXT_PCT=0; NEXT_COUNT=0
compute_next_count() {
  awk -v tot="$TOTAL_FILES" -v pct="$NEXT_PCT" \
    'BEGIN{ printf("%d", int((tot*pct + 99)/100)) }'
}
progress_maybe() {
  local seq="$1" base="$2"
  if (( PROGRESS_STEP > 0 )) && (( seq >= NEXT_COUNT )); then
    printf "\n[progress] %3d%% (%d/%d)  %s\n" "$NEXT_PCT" "$seq" "$TOTAL_FILES" "$(date +%H:%M:%S)"
    local rt_path="$RES_LOCAL/radtot/${base}.dat.gz"
    echo "----- RADTOT: $rt_path (first 20 lines) -----"
    [[ -s "$rt_path" ]] && gzip -cd "$rt_path" | sed -n '1,20p' || echo "(missing)"
    echo "--------------------------------"
    NEXT_PCT=$(( NEXT_PCT + PROGRESS_STEP ))
    if (( NEXT_PCT <= 100 )); then NEXT_COUNT=$(compute_next_count)
    else NEXT_COUNT=$(( TOTAL_FILES + 1 )); fi
  fi
}

run_one_file() {
  local seq="$1" W="$2" Q2="$3" COS="$4"; shift 4
  local -a phi_arr=( "$@" )
  local phi_first="${phi_arr[0]}" phi_last="${phi_arr[$((${#phi_arr[@]}-1))]}"
  local base
  base=$(printf "grid_W%.4f_Q2%.4f_cos%+.3f_phi%03d-%03d_p%02d" \
    "$W" "$Q2" "$COS" "$phi_first" "$phi_last" "$seq")
  local inp="$WORK/input.dat"
  local log_out_gz="$RES_LOCAL/logs/${base}.out.gz"
  local log_err_gz="$RES_LOCAL/logs/${base}.err.gz"

  echo "[run] ($seq/$TOTAL_FILES) $base"
  write_input_file "$inp" "$W" "$Q2" "$COS" "${phi_arr[@]}"

  local rc=0 elapsed="" rss=""
  pushd "$WORK" >/dev/null
  if [[ -x /usr/bin/time ]]; then
    /usr/bin/time -v ./build/exclurad.exe \
      > >(gzip -c >> "$log_out_gz") \
      2> >(gzip -c >> "$log_err_gz") || rc=$?
    elapsed="$( { gzip -cd "$log_err_gz" 2>/dev/null | grep -m1 'Elapsed (wall clock) time' | sed 's/.*: *//'; } || true )"
    rss="$(     { gzip -cd "$log_err_gz" 2>/dev/null | grep -m1 'Maximum resident set size (kbytes)' | awk '{print $6}'; } || true )"
  else
    { time -p ./build/exclurad.exe; } \
      > >(gzip -c >> "$log_out_gz") \
      2> >(gzip -c >> "$log_err_gz") || rc=$?
    elapsed="$( { gzip -cd "$log_err_gz" 2>/dev/null | grep -m1 '^real ' | awk '{print $2}'; } || true )"
    rss=""
  fi

  local moved=0
  for key in all allu radasm radcor radsigmi radsigpl radtot; do
    if [[ -s "${key}.dat" ]]; then
      mv -f "${key}.dat" "$RES_LOCAL/${key}/${base}.dat"
      gzip -f "$RES_LOCAL/${key}/${base}.dat"
      moved=1
    fi
  done
  cp -f "$inp" "$RES_LOCAL/inputs/${base}.dat" || true
  rm -f "$inp" || true
  popd >/dev/null

  echo "$seq,$base,$W,$Q2,$COS,$phi_first,$phi_last,${#phi_arr[@]},$rc,${elapsed:-},${rss:-}" >> "$MANIFEST"
  (( rc != 0 || moved == 0 )) && echo "[warn] seq=$seq rc=$rc moved=$moved" || echo "[ok] seq=$seq"

  (( seq % 10 == 0 )) && \
    df -h "$WORK" | awk 'NR==2{printf("[df] %s avail on %s\n",$4,$6)}' || true

  progress_maybe "$seq" "$base"
}

# ---------- Configure ----------
echo "========== STAGE 2/4: configure run =========="
printf "[info] W=%.4f  Q2=%.4f  VCUT=%s\n" "$W_IN" "$Q2_IN" "$VCUT"
echo  "[info] cos grid: [$COS_MIN, $COS_MAX], N=$N_COS (endpoints included)"
echo  "[info] phi grid: $N_PHI bin-centers (avoids 0°, 180°, 360°); $N_PER_FILE per file"

# Build phi bin-centers: phi = (i + 0.5) * (360/N_PHI)
phi_step=$(awk -v n="$N_PHI" 'BEGIN{ printf("%.10f", 360.0/n) }')
phi_off=$(awk  -v s="$phi_step" 'BEGIN{ printf("%.10f", s/2.0) }')
PHI_LIST=()
for ((ip=0; ip<N_PHI; ip++)); do
  p=$(awk -v i="$ip" -v step="$phi_step" -v off="$phi_off" \
    'BEGIN{ printf("%.10f", i*step + off) }')
  p_int=$(printf "%.0f" "$p")
  PHI_LIST+=( $(( p_int % 360 )) )
done

chunks_phi=$(( (N_PHI + N_PER_FILE - 1) / N_PER_FILE ))
TOTAL_FILES=$(( N_COS * chunks_phi ))
echo "[plan] $TOTAL_FILES files (progress every ${PROGRESS_STEP}%)"
if (( PROGRESS_STEP > 0 )); then
  NEXT_PCT=$PROGRESS_STEP; NEXT_COUNT=$(compute_next_count)
else
  NEXT_PCT=0; NEXT_COUNT=$(( TOTAL_FILES + 1 ))
fi

# ---------- Run ----------
echo "========== STAGE 3/4: run EXCLURAD =========="
seq=1
for ((ic=0; ic<N_COS; ic++)); do
  cos_val=$(lin_val "$COS_MIN" "$COS_MAX" "$N_COS" 1 "$ic")
  cos_fmt=$(printf "$fmt_cos" "$cos_val")
  for ((start=0; start<${#PHI_LIST[@]}; start+=N_PER_FILE)); do
    phi_slice=()
    for ((j=0; j<N_PER_FILE && start+j < ${#PHI_LIST[@]}; j++)); do
      phi_slice+=( "${PHI_LIST[$((start+j))]}" )
    done
    run_one_file "$seq" "$(printf "$fmt_w" "$W_IN")" "$(printf "$fmt_q2" "$Q2_IN")" \
      "$cos_fmt" "${phi_slice[@]}"
    ((seq++))
  done
done
(( PROGRESS_STEP > 0 && NEXT_PCT <= 100 )) && progress_maybe "$TOTAL_FILES" "FINAL" || true

# ---------- Stage-out ----------
echo "========== STAGE 4/4: tar stage-out =========="
STAMP="$(date +%Y%m%d_%H%M%S)"
JOBTAG="J${ARRAY_JOB}"; [[ -n "$ARRAY_TASK" ]] && JOBTAG="${JOBTAG}_T${ARRAY_TASK}"
BASE_TAR=$(printf "results_W%.4f_Q2%.4f_30x30_%s_%s.tar.gz" "$W_IN" "$Q2_IN" "$STAMP" "$JOBTAG")
TAR_PATH="$RESULTS_ROOT/$BASE_TAR"
mkdir -p "$RESULTS_ROOT"
pushd "$WORK" >/dev/null; tar -czf "$TAR_PATH" results; popd >/dev/null
echo "[info] Tarball: $TAR_PATH"
echo "[done] All stages complete."
rm -rf "$SCRATCH_DIR" || true
