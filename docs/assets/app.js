// EXCLURAD Interactive RC Explorer (browser-side)
// - Reads uncompressed Feather via Apache Arrow (ESM)
// - Builds multi-curve Plotly trace with color-blind palette + dashes
// - Sliders snap to values present in the dataset
// - Disables only the sliders that correspond to x and overlay

import * as arrow from "https://cdn.jsdelivr.net/npm/apache-arrow@14.0.2/+esm";

// ---------- Configuration ----------
const PATHS = {
  meta:  './data/meta.json',
  full:  './data/exclurad_eta_web.feather',        // uncompressed
  sample:'./data/exclurad_eta_web_sample.feather'  // uncompressed
};

const VARCOL = { W: 'w_r', Q2: 'q2_r', cos: 'ct_r', phi: 'phi_deg' };
const LABELS = { W: 'W [GeV]', Q2: 'Q² [GeV²]', cos: 'cosθ*', phi: 'φ* [deg]' };

// Okabe–Ito palette + distinct dashes (color-blind friendly)
const COLORS = ["#0072B2","#D55E00","#009E73","#CC79A7","#E69F00","#56B4E9","#000000","#F0E442"];
const DASHES = ["solid","dash","dot","dashdot","longdash","longdashdot","solid","dash"];

// ---------- Helpers ----------
const $ = (id) => document.getElementById(id);
const fmt = (v, d=3) => Number.isFinite(v) ? v.toFixed(d) : "–";
const uniqueSorted = (arr) => Array.from(new Set(arr)).sort((a,b)=>a-b);

function setSliderFromValues(id, values, decimals=3) {
  const slider = $(id);
  slider.min = 0;
  slider.max = Math.max(0, values.length - 1);
  slider.step = 1;
  // Build sparse ticks
  const dl = $(`${id}_ticks`);
  dl.innerHTML = "";
  const K = Math.min(10, values.length);
  for (let t=0; t<K; t++){
    const j = Math.round(t*(values.length-1)/(K-1));
    const opt = document.createElement('option');
    opt.value = j;
    opt.label = fmt(values[j], id==='W'?3: (id==='phi'?0:3));
    dl.appendChild(opt);
  }
}

function setSliderValue(id, values, atIndex) {
  const slider = $(id);
  const lbl = $(`${id}_val`);
  const j = Math.min(Math.max(0, atIndex|0), values.length-1);
  slider.value = String(j);
  const decimals = (id==='W') ? 3 : (id==='phi' ? 0 : 3);
  lbl.textContent = values.length ? fmt(values[j], decimals) : "–";
  return j;
}

function readSliderValue(id, values) {
  const slider = $(id);
  const j = Math.min(Math.max(0, parseInt(slider.value||"0",10)), Math.max(0, values.length-1));
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

// ---------- Data holder ----------
const state = {
  table: null,
  cols: {},
  vals: { W:[], Q2:[], cos:[], phi:[] },
  chosen: { x:'W', overlay:'Q2', y:'delta_xsec_ratio', dataset:'full' }
};

// Convert an Arrow table column to a JS typed array
function colToArray(tbl, name) {
  const v = (tbl.getChild && tbl.getChild(name)) || (tbl.getColumn && tbl.getColumn(name));
  if (!v) throw new Error(`Missing column: ${name}`);
  return v.toArray();
}

async function loadFeather(kind) {
  const url = PATHS[kind];
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`Fetch failed: ${url} (${resp.status})`);
  const buf = await resp.arrayBuffer();
  // Some servers serve as ArrayBuffer; Arrow accepts Uint8Array
  const table = arrow.tableFromIPC(new Uint8Array(buf));

  // Required columns
  const req = ['w_r','q2_r','ct_r','phi_deg','ok_kin','ok_delta','ok_asym','delta_xsec_ratio','A_ratio'];
  for (const c of req) {
    const has = (table.schema.fields || []).some(f => f.name === c);
    if (!has) throw new Error(`Missing column: ${c}`);
  }

  state.table = table;
  state.cols = {
    w_r:  colToArray(table, 'w_r'),
    q2_r: colToArray(table, 'q2_r'),
    ct_r: colToArray(table, 'ct_r'),
    phi:  colToArray(table, 'phi_deg'),
    ok_kin:   Array.from(colToArray(table, 'ok_kin'),  x => !!x),
    ok_delta: Array.from(colToArray(table, 'ok_delta'),x => !!x),
    ok_asym:  Array.from(colToArray(table, 'ok_asym'), x => !!x),
    delta: colToArray(table, 'delta_xsec_ratio'),
    A_ratio: colToArray(table, 'A_ratio')
  };

  // Unique, sorted slider values
  state.vals.W   = uniqueSorted(Array.from(state.cols.w_r));
  state.vals.Q2  = uniqueSorted(Array.from(state.cols.q2_r));
  state.vals.cos = uniqueSorted(Array.from(state.cols.ct_r));
  state.vals.phi = uniqueSorted(Array.from(state.cols.phi));
}

function buildMask(ykey, fixed) {
  const N = state.cols.w_r.length;
  const okY = (ykey === 'delta_xsec_ratio') ? state.cols.ok_delta : state.cols.ok_asym;
  const m = new Array(N);
  for (let i=0;i<N;i++){
    if (!state.cols.ok_kin[i] || !okY[i]) { m[i]=false; continue; }
    if ('w_r' in fixed && state.cols.w_r[i] !== fixed.w_r) { m[i]=false; continue; }
    if ('q2_r' in fixed && state.cols.q2_r[i] !== fixed.q2_r) { m[i]=false; continue; }
    if ('ct_r' in fixed && state.cols.ct_r[i] !== fixed.ct_r) { m[i]=false; continue; }
    if ('phi'  in fixed && state.cols.phi[i]  !== fixed.phi)  { m[i]=false; continue; }
    m[i] = true;
  }
  return m;
}

// Count distinct x values per overlay value (coverage)
function coverage(ykey, xvar, overlay, fixed) {
  const xcol = VARCOL[xvar];
  const overCol = VARCOL[overlay];
  const mask = buildMask(ykey, fixed);
  const sets = new Map();
  const N = state.cols.w_r.length;

  for (let i=0;i<N;i++){
    if (!mask[i]) continue;
    const ov = (overCol==='phi') ? state.cols.phi[i] : state.cols[overCol][i];
    const xv = state.cols[xcol][i];
    if (!Number.isFinite(ov) || !Number.isFinite(xv)) continue;
    if (!sets.has(ov)) sets.set(ov, new Set());
    sets.get(ov).add(xv);
  }

  // Build sorted list (most points first)
  const items = Array.from(sets.entries())
    .map(([ov, set]) => ({ov, n: set.size}))
    .filter(o => o.n >= 4)
    .sort((a,b) => (b.n - a.n) || (a.ov - b.ov));
  return items;
}

function buildCurve(ykey, xvar, fixed) {
  const xcol = VARCOL[xvar];
  const mask = buildMask(ykey, fixed);
  const N = state.cols.w_r.length;
  const xs = [], ys = [];
  for (let i=0;i<N;i++){
    if (!mask[i]) continue;
    const xv = state.cols[xcol][i];
    const yv = (ykey==='delta_xsec_ratio') ? state.cols.delta[i] : state.cols.A_ratio[i];
    if (Number.isFinite(xv) && Number.isFinite(yv)) { xs.push(xv); ys.push(yv); }
  }
  // sort by x
  const idx = xs.map((v, i) => i).sort((a,b)=>xs[a]-xs[b]);
  return { x: idx.map(i=>xs[i]), y: idx.map(i=>ys[i]) };
}

function snapSelectionToValues() {
  // Initialize sliders based on dataset values
  setSliderFromValues('W',   state.vals.W,   3);
  setSliderFromValues('Q2',  state.vals.Q2,  3);
  setSliderFromValues('cos', state.vals.cos, 3);
  setSliderFromValues('phi', state.vals.phi, 0);

  // Pick medians for a reasonable starting point
  setSliderValue('W',   state.vals.W,   Math.floor(state.vals.W.length/2));
  setSliderValue('Q2',  state.vals.Q2,  Math.floor(state.vals.Q2.length/2));
  setSliderValue('cos', state.vals.cos, Math.floor(state.vals.cos.length/2));
  setSliderValue('phi', state.vals.phi, Math.floor(state.vals.phi.length/2));
}

function updateDisabledSliders() {
  const { x, overlay } = state.chosen;
  // Disable x and overlay sliders, enable the other two
  const all = ['W','Q2','cos','phi'];
  for (const w of all) {
    const disable = (w === x) || (w === overlay);
    toggleDisabled(w, disable);
  }
}

function readFixedFromSliders(xvar, overlay) {
  const fixed = {};
  const dims = ['W','Q2','cos','phi'];
  for (const d of dims) {
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
  const xvar = state.chosen.x;
  const overlay = state.chosen.overlay;
  const ykey = state.chosen.y;

  if (xvar === overlay) {
    Plotly.purge('plot');
    $('meta').textContent = 'Overlay must differ from x.';
    return;
  }

  const fixed = readFixedFromSliders(xvar, overlay);
  const cov = coverage(ykey, xvar, overlay, fixed);
  const pick = cov.slice(0, 8).map(o => o.ov);

  const data = [];
  const yArrays = [];

  pick.forEach((ov, i) => {
    const f = { ...fixed };
    if (overlay === 'phi') f['phi'] = ov;
    else f[VARCOL[overlay]] = ov;

    const { x, y } = buildCurve(ykey, xvar, f);
    if (!x.length) return;
    yArrays.push(...y);

    data.push({
      x, y,
      mode: 'lines+markers',
      name: `${overlay}=${overlay==='W' ? fmt(ov,3) : (overlay==='phi' ? fmt(ov,0) : fmt(ov,3))}`,
      line: { color: COLORS[i % COLORS.length], width: 2, dash: DASHES[i % DASHES.length] },
      marker: { size: 6 }
    });
  });

  const xlab = LABELS[xvar];
  const ylab = yAxisLabel(ykey);
  const fixedStr = Object.entries(fixed).map(([k,v]) => {
    if (k === 'phi') return `φ*=${fmt(v,0)}°`;
    if (k === 'ct_r') return `cosθ*=${fmt(v,3)}`;
    if (k === 'w_r')  return `W=${fmt(v,3)} GeV`;
    if (k === 'q2_r') return `Q²=${fmt(v,3)} GeV²`;
    return `${k}=${fmt(v,3)}`;
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

  Plotly.newPlot('plot', data, layout, {responsive:true, displaylogo:false});
  $('meta').textContent = `rows (dedup): ${(state.cols.w_r||[]).length.toLocaleString()} • sample: ${state.chosen.dataset==='sample' ? 'yes' : 'no'}`;
}

async function main() {
  try {
    // Wire dropdowns + button
    $('y').addEventListener('change', e => { state.chosen.y = e.target.value; });
    $('x').addEventListener('change', e => { state.chosen.x = e.target.value; updateDisabledSliders(); });
    $('overlay').addEventListener('change', e => { state.chosen.overlay = e.target.value; updateDisabledSliders(); });
    $('dataset').addEventListener('change', async (e) => {
      state.chosen.dataset = e.target.value;
      await loadFeather(state.chosen.dataset);
      snapSelectionToValues();
      updateDisabledSliders();
      draw();
    });

    // Slider labels update live
    ['W','Q2','cos','phi'].forEach(dim => {
      $(dim).addEventListener('input', () => {
        const arr = state.vals[dim];
        setSliderValue(dim, arr, parseInt($(dim).value||"0",10));
      });
    });

    $('update').addEventListener('click', draw);

    // Initial load
    state.chosen.dataset = $('dataset').value;
    state.chosen.y = $('y').value;
    state.chosen.x = $('x').value;
    state.chosen.overlay = $('overlay').value;

    await loadFeather(state.chosen.dataset);
    snapSelectionToValues();
    updateDisabledSliders();
    draw();
  } catch (err) {
    console.error(err);
    Plotly.purge('plot');
    $('meta').textContent = `Error: ${err.message}`;
  }
}

main();
