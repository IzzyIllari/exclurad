#!/usr/bin/env bash
#SBATCH --job-name=exclu-vcut-scan
#SBATCH --account=clas12
#SBATCH --partition=production
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=150M
#SBATCH --time=10:00:00
#SBATCH --gres=disk:2G
#SBATCH --output=/farm_out/%u/%x-%A_%a-%N.out
#SBATCH --error=/farm_out/%u/%x-%A_%a-%N.err

# exclu_vcut_scan.sbatch
#
# Run an exclurad ν_cut scan at fixed kinematics (W, Q², cos θ*, φ*).
# Scans N_VCUT points from VCUT_MIN up to the kinematic maximum
#   v_m(W) = (W - m_p)² - m_η²
# which is computed automatically if --vcut-max is not provided.
#
# Each vcut value is a separate exclurad call (N=1 point per call).
# Results are compressed and tarred to RESULTS_ROOT.
#
# Typical submit:
#   sbatch exclu_vcut_scan.sbatch \
#     --src-dir      /path/to/exclurad \
#     --results-root /path/for/results \
#     --W 1.9000 --Q2 0.4105 --n-vcut 50
#
# See slurm/README.md for a full walkthrough.

set -Eeuo pipefail
trap 'rc=$?; echo "[FATAL] rc=$rc at line $LINENO while running: $BASH_COMMAND"; exit $rc' ERR
IFS=$'\n\t'
LC_ALL=C

# ---------- Required ----------
SRC_DIR=""       # path to exclurad working dir (must contain build/exclurad.exe)
RESULTS_ROOT=""  # where to write the result tarball

# ---------- Kinematics ----------
W_IN="1.9000"
Q2_IN="0.4105"
COS_FIXED="-0.75"
PHI_FIXED=90

# ---------- Physics model ----------
MODEL=3
RC_MODE=0
BMOM="6.53"
TMOM="0.0"
LEPTON=1
IVEC=1

# ---------- ν_cut scan ----------
VCUT_MIN="0.0"
VCUT_MAX=""   # if empty, computed from W and eta mass kinematics
N_VCUT=50

PROGRESS_STEP=5

usage() {
  cat <<EOF
Usage: sbatch $0 --src-dir DIR --results-root DIR [options]

Required:
  --src-dir DIR         Exclurad working directory (contains build/exclurad.exe)
  --results-root DIR    Where the result tarball is written

Kinematics:
  --W F         W [GeV] (default: $W_IN)
  --Q2 F        Q² [GeV²] (default: $Q2_IN)
  --cos F       cos(θ*) (default: $COS_FIXED)
  --phi N       φ* [deg] (default: $PHI_FIXED)

ν_cut scan:
  --vcut-min F  Lower bound (default: $VCUT_MIN)
  --vcut-max F  Upper bound (default: kinematic max v_m(W) for η)
  --n-vcut N    Number of scan points (default: $N_VCUT)

Physics model:
  --model N --rc-mode N --bmom F --tmom F --lepton N --ivec N

Other:
  --progress-step N   Report progress every N% (default: $PROGRESS_STEP)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-dir)      SRC_DIR="$2";        shift 2 ;;
    --results-root) RESULTS_ROOT="$2";   shift 2 ;;
    --W)            W_IN="$2";           shift 2 ;;
    --Q2)           Q2_IN="$2";          shift 2 ;;
    --cos)          COS_FIXED="$2";      shift 2 ;;
    --phi)          PHI_FIXED="$2";      shift 2 ;;
    --vcut-min)     VCUT_MIN="$2";       shift 2 ;;
    --vcut-max)     VCUT_MAX="$2";       shift 2 ;;
    --n-vcut)       N_VCUT="$2";         shift 2 ;;
    --model)        MODEL="$2";          shift 2 ;;
    --rc-mode)      RC_MODE="$2";        shift 2 ;;
    --bmom)         BMOM="$2";           shift 2 ;;
    --tmom)         TMOM="$2";           shift 2 ;;
    --lepton)       LEPTON="$2";         shift 2 ;;
    --ivec)         IVEC="$2";           shift 2 ;;
    --progress-step) PROGRESS_STEP="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$SRC_DIR" ]]      || { echo "ERROR: --src-dir is required";     exit 3; }
[[ -n "$RESULTS_ROOT" ]] || { echo "ERROR: --results-root is required"; exit 3; }
[[ -d "$SRC_DIR" ]]      || { echo "ERROR: SRC_DIR not found: $SRC_DIR"; exit 3; }
[[ -x "$SRC_DIR/build/exclurad.exe" ]] || { echo "ERROR: missing $SRC_DIR/build/exclurad.exe"; exit 4; }
mkdir -p "$RESULTS_ROOT"

fmt_w='%.4f'; fmt_q2='%.4f'; fmt_cos='%.6f'

# Compute kinematic ν_max for p(detected), η(undetected) if not supplied
if [[ -z "$VCUT_MAX" ]]; then
  VCUT_MAX=$(awk -v W="$W_IN" 'BEGIN{
    Mp=0.938272; Meta=0.547862;
    vm=(W-Mp)*(W-Mp) - Meta*Meta;
    if(vm<0) vm=0;
    printf("%.6f", vm);
  }')
  echo "[info] Computed VCUT_MAX = $VCUT_MAX GeV² from W=$W_IN (η kinematics)"
fi

# ---------- Scratch ----------
SCRATCH_DIR="${SLURM_TMPDIR:-/scratch/slurm/${SLURM_JOB_ID:-$$}}"
WORK="$SCRATCH_DIR/work"
mkdir -p "$WORK"

echo "========== STAGE 1/4: stage build & tables =========="
rsync -a "$SRC_DIR/build/" "$WORK/build/"
find "$SRC_DIR" -maxdepth 1 -type f \( -name "*.tbl" -o -name "*.inc" -o -name "maid*.dat" \) -print0 \
  | xargs -0 -I{} cp -a "{}" "$WORK/" || true
echo "[stage] done."

RES_LOCAL="$WORK/results"
mkdir -p "$RES_LOCAL"/{all,allu,radasm,radcor,radsigmi,radsigpl,radtot,inputs,logs}
MANIFEST="$RES_LOCAL/manifest.csv"
echo "seq,base,W,Q2,cos,phi,N,vcut,rc,elapsed,peak_rss_kb" > "$MANIFEST"

# ---------- Helpers ----------
lin_val() {
  awk -v a="$1" -v b="$2" -v n="$3" -v inc="$4" -v i="$5" 'BEGIN{
    if(n<=1){ printf("%.10f", a); exit }
    step=(inc==1 ? (b-a)/(n-1) : (b-a)/n);
    printf("%.10f", a+i*step);
  }'
}

write_input_file() {
  local out="$1" W="$2" Q2="$3" COS="$4" VCUT_VAL="$5" PHI="$6"
  {
    echo "$MODEL       !  1: AO 2: maid98  3: maid2000"
    echo "$RC_MODE     !  0: Full, 1: Factorizable and Leading log"
    echo "$BMOM        !  bmom - lepton momentum"
    echo "$TMOM        !  tmom - momentum per nucleon"
    echo "$LEPTON      !  lepton - 1 electron, 2 muon"
    echo "$IVEC        !  ivec - detected hadron (1) p, (2) pi+"
    echo "$VCUT_VAL    !  vcut - cut on inelasticity (0.) if no cut, negative -- v"
    echo ""
    echo "1 ! no. of points"
    printf "$fmt_w "   "$W";   echo "! W values"
    printf "$fmt_q2 "  "$Q2";  echo "! Q^2 values"
    printf "$fmt_cos "  "$COS"; echo "! Cos(Theta) values"
    printf "%d. "       "$PHI"; echo "! phi values"
    echo ""
    echo "0error detected by nag library routine   d01fce - ifail =     2"
  } > "$out"
}

# ---------- Progress ----------
TOTAL_FILES="$N_VCUT"; NEXT_PCT=0; NEXT_COUNT=0
compute_next_count() {
  awk -v tot="$TOTAL_FILES" -v pct="$NEXT_PCT" \
    'BEGIN{ printf("%d", int((tot*pct + 99)/100)) }'
}
progress_maybe() {
  local seq="$1" base="$2"
  if (( PROGRESS_STEP > 0 )) && (( seq >= NEXT_COUNT )); then
    printf "\n[progress] %3d%% (%d/%d)  %s\n" "$NEXT_PCT" "$seq" "$TOTAL_FILES" "$(date +%H:%M:%S)"
    local rt_path="$RES_LOCAL/radtot/${base}.dat.gz"
    echo "----- RADTOT (first 10 lines) -----"
    [[ -s "$rt_path" ]] && gzip -cd "$rt_path" | sed -n '1,10p' || echo "(missing)"
    echo "-----------------------------------"
    NEXT_PCT=$(( NEXT_PCT + PROGRESS_STEP ))
    if (( NEXT_PCT <= 100 )); then NEXT_COUNT=$(compute_next_count)
    else NEXT_COUNT=$(( TOTAL_FILES + 1 )); fi
  fi
}

run_one() {
  local seq="$1" W="$2" Q2="$3" COS="$4" VCUT_VAL="$5" PHI="$6"
  local base
  base=$(printf "vcut_W%.4f_Q2%.4f_cos%+.3f_phi%03d_v%.6f_p%03d" \
    "$W" "$Q2" "$COS" "$PHI" "$VCUT_VAL" "$seq")
  local inp="$WORK/input.dat"
  local log_out_gz="$RES_LOCAL/logs/${base}.out.gz"
  local log_err_gz="$RES_LOCAL/logs/${base}.err.gz"

  echo "[run] ($seq/$TOTAL_FILES) vcut=$VCUT_VAL  $base"
  write_input_file "$inp" "$W" "$Q2" "$COS" "$VCUT_VAL" "$PHI"

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
      # For radtot, append the vcut value as an extra column for easy post-processing
      if [[ "$key" == "radtot" ]]; then
        awk -v v="$VCUT_VAL" '{ printf("%s, %12.6f\n", $0, v) }' "${key}.dat" \
          > "${key}.tmp" && mv "${key}.tmp" "${key}.dat"
      fi
      mv -f "${key}.dat" "$RES_LOCAL/${key}/${base}.dat"
      gzip -f "$RES_LOCAL/${key}/${base}.dat"
      moved=1
    fi
  done
  cp -f "$inp" "$RES_LOCAL/inputs/${base}.dat" || true
  rm -f "$inp" || true
  popd >/dev/null

  echo "$seq,$base,$W,$Q2,$COS,$PHI,1,$VCUT_VAL,$rc,${elapsed:-},${rss:-}" >> "$MANIFEST"
  (( rc != 0 || moved == 0 )) && echo "[warn] seq=$seq rc=$rc moved=$moved" || echo "[ok] seq=$seq"

  (( seq % 10 == 0 )) && \
    df -h "$WORK" | awk 'NR==2{printf("[df] %s avail on %s\n",$4,$6)}' || true

  progress_maybe "$seq" "$base"
}

# ---------- Configure ----------
echo "========== STAGE 2/4: configure run =========="
printf "[info] W=%.4f  Q2=%.4f  cos=%.3f  phi=%d\n" "$W_IN" "$Q2_IN" "$COS_FIXED" "$PHI_FIXED"
echo  "[info] vcut range: [$VCUT_MIN, $VCUT_MAX]  N_VCUT=$N_VCUT (inclusive endpoints)"

if (( PROGRESS_STEP > 0 )); then
  NEXT_PCT=$PROGRESS_STEP; NEXT_COUNT=$(compute_next_count)
else
  NEXT_PCT=0; NEXT_COUNT=$(( TOTAL_FILES + 1 ))
fi

COS_FMT=$(printf "$fmt_cos" "$COS_FIXED")
W_FMT=$(printf   "$fmt_w"   "$W_IN")
Q2_FMT=$(printf  "$fmt_q2"  "$Q2_IN")

# ---------- Run ----------
echo "========== STAGE 3/4: run EXCLURAD =========="
seq=1
for ((iv=0; iv<N_VCUT; iv++)); do
  v_val=$(lin_val "$VCUT_MIN" "$VCUT_MAX" "$N_VCUT" 1 "$iv")
  VCUT_FMT=$(printf "%.6f" "$v_val")
  run_one "$seq" "$W_FMT" "$Q2_FMT" "$COS_FMT" "$VCUT_FMT" "$PHI_FIXED"
  ((seq++))
done
(( PROGRESS_STEP > 0 && NEXT_PCT <= 100 )) && progress_maybe "$TOTAL_FILES" "FINAL" || true

# ---------- Stage-out ----------
echo "========== STAGE 4/4: tar stage-out =========="
STAMP="$(date +%Y%m%d_%H%M%S)"
JOBID="${SLURM_JOB_ID:-$$}"
BASE_TAR=$(printf "results_vcut_scan_W%.4f_Q2%.4f_cos%.3f_phi%03d_%s_J%s.tar.gz" \
  "$W_IN" "$Q2_IN" "$COS_FIXED" "$PHI_FIXED" "$STAMP" "$JOBID")
TAR_PATH="$RESULTS_ROOT/$BASE_TAR"
mkdir -p "$RESULTS_ROOT"
pushd "$WORK" >/dev/null; tar -czf "$TAR_PATH" results; popd >/dev/null
echo "[info] Tarball: $TAR_PATH"
echo "[done] All stages complete."
rm -rf "$SCRATCH_DIR" || true
