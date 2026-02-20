# EXCLURAD

Fortran code for calculation of QED radiative corrections to exclusive
electroproduction on the nucleon. The current repository contains two
configurations:

- **Pion electroproduction** (original 2002 code): corrections to the
  unpolarized coincidence cross section and beam spin asymmetry (fifth
  structure function) for ep → e'nπ⁺.
- **η-meson electroproduction** (2025 extension): adapted for ep → e'pη
  using updated EtaMAID-2023 hadronic model tables and CLAS12 kinematics.

Distinctive features of the underlying formalism:
- Covariant infrared divergence cancellation (Bardin–Shumeiko method),
  giving results independent of the soft/hard photon splitting parameter.
- Exact integration over the bremsstrahlung photon phase space — no
  peaking approximation.

The code is extendable to any exclusive two-body electroproduction process,
e.g. p(e,e'K)Λ, d(e,e'p)n, ³He(e,e'p)d.

---

## References

Original pion code:

> A. Afanasev, I. Akushevich, V. Burkert, K. Joo,  
> *QED Radiative Corrections in Processes of Exclusive Pion Electroproduction*,  
> Phys. Rev. D **66**, 074004 (2002). [hep-ph/0208183](https://arxiv.org/abs/hep-ph/0208183)

η-meson extension (2025):

> I. Illari, A. Afanasev, W.J. Briscoe, V.L. Kashevarov, A. Schmidt, I. Strakovsky,  
> *Amplitude-Based Analysis of QED Radiative Corrections to Electroproduction of η-Mesons*,  
> in preparation.

---

## Interactive RC Explorer

A browser-based visualisation of the η-channel radiative correction output
(δ = σ_obs/σ₀ and A_RC/A_Born) is available at:

**<https://izzyillari.github.io/exclurad/>**

The dataset was computed with the η-channel configuration described below
(vcut = 0.166 GeV²,  beam energy 6.53 GeV, full O(α) corrections).
Use the sliders to fix two kinematic variables and plot curves overlaid
by a third.

---

## Repository layout

```
exclurad/
├── exclurad.F          # Main Fortran source (η-modified)
├── fint.F              # CERNLIB-free numerical integration
├── mpintp.inc          # Mass/channel constants (η configuration)
├── spp.inc             # Kinematics include
├── maid07-PPpi.tbl     # EtaMAID-2023 hadronic model table
├── Makefile            # GNU make build
├── sconscript          # SCons build
├── sconstruct          # SCons build
├── input.dat           # Template input file (η defaults, 10 points)
├── examples/           # Annotated example input files
│   ├── README.md
│   ├── input_single_chunk.dat   # 10-point example
│   └── input_multi_chunk.dat    # 50-point multi-row example
├── scripts/            # Input generation and local runners
│   ├── README.md
│   ├── rcgrid_inputgen.py       # 4D kinematic grid generator
│   ├── run_exclurad_grid.sh     # Verbose sequential runner
│   └── run_exclurad_skip_unphys.sh  # Runner with unphysical-skip detection
└── slurm/              # JLab farm batch scripts
    ├── README.md
    ├── exclurad_one_input.sbatch       # Single-file test job
    ├── exclurad_run_chunk.sbatch       # Chunk array (pre-generated grid)
    ├── exclu_30x30_WQ2scan_array.sbatch # Self-contained W×Q² array job
    └── exclu_vcut_scan.sbatch          # ν_cut scan at fixed kinematics
```

---

## Getting started

### Clone

```bash
git clone https://github.com/JeffersonLab/exclurad.git
cd exclurad
```

### Build

```bash
# GNU make
make

# or SCons (original build system)
scons
```

The executable is written to `build/exclurad.exe`.

On the JLab interactive farm (`ifarm`), GNU Fortran (GCC) 11.5.0 is
available at `/usr/bin/gfortran` with no environment modules required.

### Run a single input

```bash
./build/exclurad.exe < input.dat
```

Outputs are written to the current directory: `all.dat`, `allu.dat`,
`radasm.dat`, `radcor.dat`, `radsigmi.dat`, `radsigpl.dat`, `radtot.dat`.

---

## Input file format

```
3       !  1: AO  2: maid98  3: maid2000
0       !  0: Full, 1: Factorizable and Leading log
6.53    !  bmom - lepton momentum [GeV]
0.0     !  tmom - momentum per nucleon
1       !  lepton - 1 electron, 2 muon
1       !  ivec  - detected hadron (1) p, (2) pi+
0.166   !  vcut  - cut on inelasticity [GeV²] (0 = no cut)

10 ! no. of points
<W values>        ! W [GeV]
<Q² values>       ! Q² [GeV²]
<cos(θ*) values>  ! Cos(Theta*)
<φ* values>       ! phi* [deg]

0error detected by nag library routine   d01fce - ifail =     2
```

Key parameters for η electroproduction (ep → e'pη):

| Parameter | Value | Notes |
|---|---|---|
| `model` | `3` | EtaMAID (maid2000 slot, updated to EtaMAID-2023 tables) |
| `ivec` | `1` | Detected recoil proton |
| `bmom` | `6.53` | CLAS12 beam momentum [GeV] |
| `vcut` | `0.166` | Inelasticity cut [GeV²] used in CLAS12 η analysis |

The maximum number of points per file is **10** (Fortran reader limit).
For larger grids, use `scripts/rcgrid_inputgen.py` which chunks
automatically. See `examples/README.md` for annotated input files and
`examples/input_multi_chunk.dat` for the multi-row layout used when N > 10.

---

## Generating and running a grid

### 1. Generate inputs

```bash
python3 scripts/rcgrid_inputgen.py \
  --w-min 1.487 --w-max 1.999 --n-w 30 \
  --q2-min 0.3  --q2-max 4.0  --n-q2 30 \
  --cos-min -0.9 --cos-max 0.9 --n-cos 30 \
  --n-phi 19 \
  --tag my_run
# Output: rcgrid-phi_sweep_grid_my_run_<timestamp>/
```

See `scripts/README.md` for all flags.

### 2. Run locally (sequential)

```bash
./scripts/run_exclurad_grid.sh \
  --input-dir rcgrid-phi_sweep_grid_my_run_...  \
  --work-dir  .
```

For runs near the η threshold or large |cos θ*|, use the unphysical-skip
runner instead:

```bash
./scripts/run_exclurad_skip_unphys.sh \
  --input-dir rcgrid-phi_sweep_grid_my_run_...  \
  --work-dir  .                                  \
  --timeout-sec 600
```

### 3. Run on the JLab farm (Slurm)

```bash
# Build index
find rcgrid-phi_sweep_grid_my_run_... -name '*.dat' | LC_ALL=C sort > inputs.index

# Submit array (100 files per task, 50 concurrent)
N=$(wc -l < inputs.index)
TASKS=$(( (N + 99) / 100 - 1 ))
sbatch --array=0-${TASKS}%50 slurm/exclurad_run_chunk.sbatch \
  --index-file   $(pwd)/inputs.index                           \
  --exe-path     $(pwd)/build/exclurad.exe                     \
  --results-root /volatile/clas12/$USER/exclurad/results       \
  --count        100
```

See `slurm/README.md` for the full set of batch scripts and workflows.

---

## η-channel modifications (2025)

The following source-level changes were made relative to the original 2002
pion code to support η electroproduction:

| File | Change |
|---|---|
| `exclurad.F` | η mass, beam energy default, output formatting |
| `mpintp.inc` | Channel constants, grid dimensions for EtaMAID |
| `maid07-PPpi.tbl` | Replaced with EtaMAID-2023 tables (V. Kashevarov) |
| `fint.F` | CERNLIB-free replacement for numerical integration |

The pion tables (`maid07-NPpi.tbl`, `maid98-PNpi.tbl`, `maid98-PPpi.tbl`)
are no longer included; this repository targets η production only.
The original pion version remains available at the
[JLab RC page](https://www.jlab.org/RC/).
