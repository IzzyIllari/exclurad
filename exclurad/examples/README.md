# examples/

Example input files for exclurad, configured for η-meson electroproduction
with CLAS12 kinematics.

## Input file format

```
<model>    !  1: AO  2: maid98  3: maid2000
<rc_mode>  !  0: Full  1: Factorizable and Leading log
<bmom>     !  bmom - lepton momentum [GeV]
<tmom>     !  tmom - momentum per nucleon
<lepton>   !  lepton - 1 electron, 2 muon
<ivec>     !  ivec  - detected hadron (1) p, (2) pi+
<vcut>     !  vcut  - cut on inelasticity [GeV^2]

<N> ! no. of points
<W_1> <W_2> ... <W_N>       ! W values [GeV]
<Q2_1> <Q2_2> ... <Q2_N>    ! Q^2 values [GeV^2]
<cos_1> <cos_2> ... <cos_N> ! Cos(Theta*) values
<phi_1> <phi_2> ... <phi_N> ! phi* values [deg]

0error detected by nag library routine   d01fce - ifail =     2
```

### Parameter notes

**model**: Controls the hadronic model used to compute the Born cross section.
For η electroproduction, use `3` (maid2000/EtaMAID). Options `1` (AO) and
`2` (maid98) are for pion electroproduction.

**rc_mode**: `0` computes the full O(α) radiative correction. `1` uses the
factorizable leading-log approximation, which is faster but less accurate.

**bmom**: Beam lepton momentum in GeV. For CLAS12 running at 6.535 GeV,
use `6.53`.

**ivec**: The detected recoil hadron. For η electroproduction (ep → e'pη),
the recoil proton is detected: use `1`. For pion electroproduction
(ep → e'nπ+), use `2`.

**vcut**: Inelasticity cut in GeV². Setting `vcut = 0.166` corresponds to
the cut used in the CLAS12 η analysis. Set to `0` to apply no cut. A
negative value sets a cut on v directly rather than on v² — see the EXCLURAD
paper (Afanasev et al., Phys. Rev. D 66, 2002) for definitions.

**N and data lines**: All four kinematic arrays must have exactly N entries.
N is limited to 10 per file by the Fortran reader. For larger grids, use
`scripts/rcgrid_inputgen.py`, which chunks automatically.

The trailing `0error...` line is a legacy artifact from the original NAG
library integration routine. It must be present for the parser to terminate
correctly.

### Multi-row layout (N > 10)

For N > 10, values can wrap across multiple rows — the Fortran reader is
whitespace-delimited and ignores line breaks within a data block. The `!`
comment marker on the last row of each block is the only required annotation.
See `input_multi_chunk.dat` for an example with N = 50.

---

## Files

### input_single_chunk.dat

A single 10-point file. W and Q² are held constant; cos(θ*) varies across
10 uniformly spaced values in [−0.28, +0.28]; φ* is fixed at 228°.

```
W   = 1.540 GeV
Q²  = 0.683 GeV²
φ*  = 228°
cos = −0.279 … +0.279  (10 points)
```

Run directly:
```bash
./build/exclurad.exe < examples/input_single_chunk.dat
```

### input_multi_chunk.dat

A 50-point file illustrating the multi-row layout. W and Q² are held
constant; cos(θ*) spans the full range [−0.999, +0.999] in 50 uniformly
spaced steps; φ* is fixed at 315°.

```
W   = 1.675 GeV
Q²  = 1.253 GeV²
φ*  = 315°
cos = −0.999 … +0.999  (50 points)
```

Run directly:
```bash
./build/exclurad.exe < examples/input_multi_chunk.dat
```

Note: despite N = 50, this is a single call to the executable — the Fortran
reader parses multi-row blocks correctly. The ≤10-per-file limit only applies
when using the batch runner scripts, which stage `input.dat` one file at a
time.

---

## Generating your own inputs

For production grids, use `scripts/rcgrid_inputgen.py` rather than writing
input files by hand. It generates a full 4D grid in W, Q², cos(θ*), and φ*,
handles chunking automatically, and produces a `manifest.csv` for tracking.

```bash
python3 scripts/rcgrid_inputgen.py --help
```

See `scripts/README.md` for a full walkthrough.
