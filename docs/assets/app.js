// EXCLURAD Interactive RC Explorer (browser-side)
// - Reads uncompressed Feather via Apache Arrow (ESM)
// - Builds multi-curve Plotly trace with color-blind palette + dashes
// - Sliders snap to values present in the dataset
// - Fixed sliders cascade: changing one updates the other to only show valid values
import * as arrow from "https://cdn.jsdelivr.net/npm/apache-arrow@14.0.2/+esm";

// ---------- Configuration ----------
const PATHS = {
  meta:   './data/meta.json',
  full:   './data/exclurad_eta_web.feather',
  sample: './data/exclurad_eta_web_sample.feather'
};
const VARCOL = { W: 'w_r', Q2: 'q2_r', cos: 'ct_r', phi: 'phi_deg' };
const LABELS = { W: 'W [GeV]', Q2: 'Q² [GeV²]', cos: 'cosθ*', phi: 'φ* [deg]' };
const COLORS = ["#0072B2","#D55E00","#009E73","#CC79A7","#E69F00","#56B4E9","#000000","#F0E442"];
const DASHES = ["solid","dash","dot","dashdot","longdash","longdashdot","solid","dash"];

// ---------- Helpers ----------
const $ = (id) => document.getElementById(id);
const fmt = (v, d=3) => Number.isFinite(v) ? v.toFixed(d) : "–";
const uniqueSorted = (arr) => Array.from(new Set(arr)).sort((a,b)=>a-b);
const decimalsFor = (id) => (id==='W') ? 3 : (id==='phi' ? 0 : 3);

function setSliderFromValues(id, values) {
  const slider = $(id);
  slider.min = 0;
  slider.max = Math.max(0, values.length - 1);
  slider.step = 1;
  const dl = $(`${id}_ticks`);
  dl.innerHTML = "";
  const K = Math.min(10, values.length);
  for (let t = 0; t < K; t++) {
    const j = Math.round(t * (values.length - 1) / (K - 1));
    const opt = document.createElement('option');
    opt.value = j;
    opt.label = fmt(values[j], decimalsFor(id));
    dl.appendChild(opt);
  }
}

function setSliderValue(id, values, atIndex) {
  const slider = $(id);
  const lbl = $(`${id}_val`);
  const j = Math.min(Math.max(0, atIndex | 0), Math.max(0, values.length - 1));
  slider.value = String(j);
  lbl.textContent = values.length ? fmt(values[j], decimalsFor(id)) : "–";
  return j;
}

function readSliderIndex(id) {
  return parseInt($(id).value || "0", 10);
}

function readSliderValue(id, values) {
  const j = Math.min(Math.max(0, readSliderIndex(id)), Math.max(0, values.length - 1));
  return values.length ? values[j] : NaN;
}

function toggleDisabled(which, disabled) {
  const blk = $(`blk-${which}`);
  const slider = $(which);
  slider.disabled = !!disabled;
  blk.classList.toggle('disabled', !!disabled);
}

function yAxisLabel(key) {
  if (key === 'delta_xsec_ratio') return 'δ = σ<sub>obs</sub>/σ<sub>0</sub>';
  return 'A<sub>RC</sub> / A<sub>Born</sub>';
}

// Find the index in `values` closest to `target`
function nearestIndex(values, target) {
  if (!values.length) return 0;
  let best = 0, bestDist = Math.abs(values[0] - target);
  for (let i = 1; i < values.length; i++) {
    const d = Math.abs(values[i] - target);
    if (d < bestDist) { best = i; bestDist = d; }
  }
  return best;
}

// ---------- Data holder ----------
const state = {
  table: null,
  cols: {},
  // allVals: all unique values per dimension (from dataset)
  allVals: { W: [], Q2: [], cos: [], phi: [] },
  // vals: currently valid values for fixed sliders (after cascading filter)
  vals: { W: [], Q2: [], cos: [], phi: [] },
  chosen: { x: 'W', overlay: 'Q2', y: 'delta_xsec_ratio', dataset: 'full' },
  // Build a fast lookup: Set of "w_r|q2_r|ct_r|phi_deg" strings
  combos: new Set()
};

function colToArray(tbl, name) {
  const v = (tbl.getChild && tbl.getChild(name)) || (tbl.getColumn && tbl.getColumn(name));
  if (!v) throw new Error(`Missing column: ${name}`);
  return v.toArray();
}

// Build a set of all valid kinematic combos for fast lookup
function buildComboSet() {
  const N = state.cols.w_r.length;
  state.combos.clear();
  for (let i = 0; i < N; i++) {
    if (!state.cols.ok_kin[i]) continue;
    const key = `${state.cols.w_r[i]}|${state.cols.q2_r[i]}|${state.cols.ct_r[i]}|${state.cols.phi[i]}`;
    state.combos.add(key);
  }
}

// Given the x and overlay dims (which are free), and one fixed dim's value,
// compute which values are available for the other fixed dim.
function availableValuesFor(targetDim, otherFixedDim, otherFixedVal) {
  const { x, overlay } = state.chosen;
  const dims = ['W', 'Q2', 'cos', 'phi'];
  const fixedDims = dims.filter(d => d !== x && d !== overlay);

  // We need: for each row, if otherFixedDim matches otherFixedVal,
  // collect all unique values of targetDim
  const targetCol = VARCOL[targetDim];
  const otherCol = VARCOL[otherFixedDim];

  const colMap = { w_r: state.cols.w_r, q2_r: state.cols.q2_r, ct_r: state.cols.ct_r, phi_deg: state.cols.phi };
  const N = state.cols.w_r.length;
  const result = new Set();

  for (let i = 0; i < N; i++) {
    if (!state.cols.ok_kin[i]) continue;
    if (colMap[otherCol][i] !== otherFixedVal) continue;
    result.add(colMap[targetCol][i]);
  }
  return Array.from(result).sort((a, b) => a - b);
}

async function loadFeather(kind) {
  const url = PATHS[kind];
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`Fetch failed: ${url} (${resp.status})`);
  const buf = await resp.arrayBuffer();
  const table = arrow.tableFromIPC(new Uint8Array(buf));

  const req = ['w_r', 'q2_r', 'ct_r', 'phi_deg', 'ok_kin', 'ok_delta', 'ok_asym', 'delta_xsec_ratio', 'A_ratio'];
  for (const c of req) {
    const has = (table.schema.fields || []).some(f => f.name === c);
    if (!has) throw new Error(`Missing column: ${c}`);
  }

  state.table = table;
  state.cols = {
    w_r:      colToArray(table, 'w_r'),
    q2_r:     colToArray(table, 'q2_r'),
    ct_r:     colToArray(table, 'ct_r'),
    phi:      colToArray(table, 'phi_deg'),
    ok_kin:   Array.from(colToArray(table, 'ok_kin'),  x => !!x),
    ok_delta: Array.from(colToArray(table, 'ok_delta'), x => !!x),
    ok_asym:  Array.from(colToArray(table, 'ok_asym'),  x => !!x),
    delta:    colToArray(table, 'delta_xsec_ratio'),
    A_ratio:  colToArray(table, 'A_ratio')
  };

  // All unique values per dimension
  state.allVals.W   = uniqueSorted(Array.from(state.cols.w_r));
  state.allVals.Q2  = uniqueSorted(Array.from(state.cols.q2_r));
  state.allVals.cos = uniqueSorted(Array.from(state.cols.ct_r));
  state.allVals.phi = uniqueSorted(Array.from(state.cols.phi));

  // Copy to vals (will be narrowed by cascading)
  for (const d of ['W', 'Q2', 'cos', 'phi']) {
    state.vals[d] = [...state.allVals[d]];
  }

  buildComboSet();
}

// ---------- Cascading slider logic ----------

function getFixedDims() {
  const { x, overlay } = state.chosen;
  return ['W', 'Q2', 'cos', 'phi'].filter(d => d !== x && d !== overlay);
}

// When one fixed slider changes, update the other fixed slider
// to only show values that have data at the current selection.
function cascadeSliders(changedDim) {
  const fixed = getFixedDims();
  if (fixed.length !== 2) return;

  const [dim1, dim2] = fixed;
  const otherDim = (changedDim === dim1) ? dim2 : dim1;

  // Get current value of the changed slider
  const changedVal = readSliderValue(changedDim, state.vals[changedDim]);

  // Compute available values for the other dim
  const available = availableValuesFor(otherDim, changedDim, changedVal);

  if (available.length === 0) {
    // No data — keep current values but show warning
    state.vals[otherDim] = [...state.allVals[otherDim]];
  } else {
    state.vals[otherDim] = available;
  }

  // Preserve the other slider's current value (snap to nearest available)
  const currentOtherVal = readSliderValue(otherDim, state.allVals[otherDim]);
  setSliderFromValues(otherDim, state.vals[otherDim]);
  const snapIdx = nearestIndex(state.vals[otherDim], currentOtherVal);
  setSliderValue(otherDim, state.vals[otherDim], snapIdx);
}

function initSliders() {
  for (const d of ['W', 'Q2', 'cos', 'phi']) {
    state.vals[d] = [...state.allVals[d]];
    setSliderFromValues(d, state.vals[d]);
    setSliderValue(d, state.vals[d], Math.floor(state.vals[d].length / 2));
  }
}

function updateDisabledSliders() {
  const { x, overlay } = state.chosen;
  for (const w of ['W', 'Q2', 'cos', 'phi']) {
    toggleDisabled(w, (w === x) || (w === overlay));
  }
}

// ---------- Plotting ----------

function buildMask(ykey, fixed) {
  const N = state.cols.w_r.length;
  const okY = (ykey === 'delta_xsec_ratio') ? state.cols.ok_delta : state.cols.ok_asym;
  const m = new Array(N);
  for (let i = 0; i < N; i++) {
    if (!state.cols.ok_kin[i] || !okY[i]) { m[i] = false; continue; }
    if ('w_r'  in fixed && state.cols.w_r[i]  !== fixed.w_r)  { m[i] = false; continue; }
    if ('q2_r' in fixed && state.cols.q2_r[i] !== fixed.q2_r) { m[i] = false; continue; }
    if ('ct_r' in fixed && state.cols.ct_r[i] !== fixed.ct_r) { m[i] = false; continue; }
    if ('phi'  in fixed && state.cols.phi[i]   !== fixed.phi)  { m[i] = false; continue; }
    m[i] = true;
  }
  return m;
}

function coverage(ykey, xvar, overlay, fixed) {
  const xcol = VARCOL[xvar];
  const overCol = VARCOL[overlay];
  const mask = buildMask(ykey, fixed);
  const sets = new Map();
  const N = state.cols.w_r.length;
  const colMap = { w_r: state.cols.w_r, q2_r: state.cols.q2_r, ct_r: state.cols.ct_r, phi_deg: state.cols.phi };
  for (let i = 0; i < N; i++) {
    if (!mask[i]) continue;
    const ov = colMap[overCol][i];
    const xv = colMap[xcol][i];
    if (!Number.isFinite(ov) || !Number.isFinite(xv)) continue;
    if (!sets.has(ov)) sets.set(ov, new Set());
    sets.get(ov).add(xv);
  }
  return Array.from(sets.entries())
    .map(([ov, set]) => ({ ov, n: set.size }))
    .filter(o => o.n >= 4)
    .sort((a, b) => (b.n - a.n) || (a.ov - b.ov));
}

function buildCurve(ykey, xvar, fixed) {
  const xcol = VARCOL[xvar];
  const mask = buildMask(ykey, fixed);
  const N = state.cols.w_r.length;
  const colMap = { w_r: state.cols.w_r, q2_r: state.cols.q2_r, ct_r: state.cols.ct_r, phi_deg: state.cols.phi };
  const xs = [], ys = [];
  for (let i = 0; i < N; i++) {
    if (!mask[i]) continue;
    const xv = colMap[xcol][i];
    const yv = (ykey === 'delta_xsec_ratio') ? state.cols.delta[i] : state.cols.A_ratio[i];
    if (Number.isFinite(xv) && Number.isFinite(yv)) { xs.push(xv); ys.push(yv); }
  }
  const idx = xs.map((v, i) => i).sort((a, b) => xs[a] - xs[b]);
  return { x: idx.map(i => xs[i]), y: idx.map(i => ys[i]) };
}

function readFixedFromSliders(xvar, overlay) {
  const fixed = {};
  for (const d of ['W', 'Q2', 'cos', 'phi']) {
    if (d === xvar || d === overlay) continue;
    const val = readSliderValue(d, state.vals[d]);
    if (Number.isFinite(val)) {
      if (d === 'phi') fixed['phi'] = val;
      else fixed[VARCOL[d]] = val;
    }
  }
  return fixed;
}

function draw() {
  const { x: xvar, overlay, y: ykey } = state.chosen;
  if (xvar === overlay) {
    Plotly.purge('plot');
    $('meta').textContent = 'Overlay must differ from x-axis variable.';
    return;
  }

  const fixed = readFixedFromSliders(xvar, overlay);
  const cov = coverage(ykey, xvar, overlay, fixed);
  const pick = cov.slice(0, 8).map(o => o.ov);

  if (pick.length === 0) {
    Plotly.purge('plot');
    $('meta').textContent = 'No data at this kinematic point. Try adjusting the sliders.';
    return;
  }

  const data = [];
  pick.forEach((ov, i) => {
    const f = { ...fixed };
    if (overlay === 'phi') f['phi'] = ov;
    else f[VARCOL[overlay]] = ov;
    const { x, y } = buildCurve(ykey, xvar, f);
    if (!x.length) return;
    data.push({
      x, y,
      mode: 'lines+markers',
      name: `${overlay}=${overlay === 'W' ? fmt(ov, 3) : (overlay === 'phi' ? fmt(ov, 0) : fmt(ov, 3))}`,
      line: { color: COLORS[i % COLORS.length], width: 2, dash: DASHES[i % DASHES.length] },
      marker: { size: 6 }
    });
  });

  if (data.length === 0) {
    Plotly.purge('plot');
    $('meta').textContent = 'No data at this kinematic point. Try adjusting the sliders.';
    return;
  }

  const xlab = LABELS[xvar];
  const ylab = yAxisLabel(ykey);
  const fixedStr = Object.entries(fixed).map(([k, v]) => {
    if (k === 'phi')  return `φ*=${fmt(v, 0)}°`;
    if (k === 'ct_r') return `cosθ*=${fmt(v, 3)}`;
    if (k === 'w_r')  return `W=${fmt(v, 3)} GeV`;
    if (k === 'q2_r') return `Q²=${fmt(v, 3)} GeV²`;
    return `${k}=${fmt(v, 3)}`;
  }).join(', ');
  const title = `${ylab} vs ${xlab}  |  fixed: ${fixedStr}`;

  const layout = {
    template: 'plotly_white',
    title: { text: title, y: 0.98, x: 0, xanchor: 'left' },
    margin: { t: 90, r: 20, b: 60, l: 60 },
    xaxis: { title: xlab },
    yaxis: { title: { text: ylab } },
    legend: { orientation: 'h', x: 0, y: 1.02, xanchor: 'left', yanchor: 'bottom' }
  };

  Plotly.newPlot('plot', data, layout, { responsive: true, displaylogo: false });
  $('meta').textContent = `rows: ${(state.cols.w_r || []).length.toLocaleString()} • curves: ${data.length} • sample: ${state.chosen.dataset === 'sample' ? 'yes' : 'no'}`;
}

// ---------- Main ----------
async function main() {
  try {
    // Wire dropdowns
    $('y').addEventListener('change', e => { state.chosen.y = e.target.value; });
    $('x').addEventListener('change', e => {
      state.chosen.x = e.target.value;
      updateDisabledSliders();
      // Reset fixed sliders to full range
      for (const d of getFixedDims()) {
        state.vals[d] = [...state.allVals[d]];
        setSliderFromValues(d, state.vals[d]);
        setSliderValue(d, state.vals[d], Math.floor(state.vals[d].length / 2));
      }
    });
    $('overlay').addEventListener('change', e => {
      state.chosen.overlay = e.target.value;
      updateDisabledSliders();
      for (const d of getFixedDims()) {
        state.vals[d] = [...state.allVals[d]];
        setSliderFromValues(d, state.vals[d]);
        setSliderValue(d, state.vals[d], Math.floor(state.vals[d].length / 2));
      }
    });
    $('dataset').addEventListener('change', async (e) => {
      state.chosen.dataset = e.target.value;
      await loadFeather(state.chosen.dataset);
      initSliders();
      updateDisabledSliders();
      draw();
    });

    // Slider live update + cascading
    for (const dim of ['W', 'Q2', 'cos', 'phi']) {
      $(dim).addEventListener('input', () => {
        setSliderValue(dim, state.vals[dim], readSliderIndex(dim));
        // Cascade: if this is a fixed slider, update the other fixed slider
        const fixed = getFixedDims();
        if (fixed.includes(dim)) {
          cascadeSliders(dim);
        }
      });
    }

    $('update').addEventListener('click', draw);

    // Initial load
    state.chosen.dataset = $('dataset').value;
    state.chosen.y = $('y').value;
    state.chosen.x = $('x').value;
    state.chosen.overlay = $('overlay').value;
    await loadFeather(state.chosen.dataset);
    initSliders();
    updateDisabledSliders();
    draw();
  } catch (err) {
    console.error(err);
    Plotly.purge('plot');
    $('meta').textContent = `Error: ${err.message}`;
  }
}

main();
