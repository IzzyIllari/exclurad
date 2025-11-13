/* assets/app.js
 * EXCLURAD web viewer – interactive Plotly controls
 * - Reads uncompressed Feather with Apache Arrow
 * - Lets user pick x, y, overlay
 * - Shows only the two fixed-kinematics sliders (disables x & overlay sliders)
 * - Color-blind friendly palette + dash cycle
 * - Proper MathJax labels for y-axis
 */

/* -----------------------
   Config / constants
------------------------ */
const DATA_URL_FULL   = 'data/exclurad_eta_web.feather';
const DATA_URL_SAMPLE = 'data/exclurad_eta_web_sample.feather';
const META_URL        = 'data/meta.json';

const OKABE_ITO = [
  '#0072B2','#D55E00','#009E73','#CC79A7',
  '#E69F00','#56B4E9','#000000','#F0E442'
];
const DASHES = ['solid','dash','dot','dashdot','longdash','longdashdot','solid','dash'];

// Mapping between UI variable names and dataframe columns
const VARCOL = { W: 'w_r', Q2: 'q2_r', cos: 'ct_r', phi: 'phi_deg' };
const VARLABEL = { W: 'W [GeV]', Q2: 'Q² [GeV²]', cos: 'cosθ*', phi: 'φ* [deg]' };

// y-variable choices
const Y_OPTIONS = [
  { key: 'delta_xsec_ratio', label: 'δ = σ_obs/σ₀', math: '\\delta = \\sigma_{\\mathrm{obs}}/\\sigma_{0}' },
  { key: 'A_ratio',          label: 'A_RC/A_Born',  math: 'A_{\\mathrm{RC}}/A_{\\mathrm{Born}}' }
];

// elements (filled in later)
const els = {};

// utility: convert Arrow Vector to JS array (with type checks)
function toArray(vec, name) {
  if (!vec) throw new Error(`Missing column: ${name}`);
  const out = [];
  for (let i = 0; i < vec.length; i++) out.push(vec.get(i));
  return out;
}

// Discrete slider support: we map slider to integer index into a sorted unique array
function makeDiscreteSlider(values, inputEl, valueEl, format = (v)=>v.toString()) {
  const arr = Array.from(new Set(values.filter(Number.isFinite))).sort((a,b)=>a-b);
  if (!arr.length) {
    inputEl.disabled = true;
    inputEl.classList.add('disabled');
    valueEl.textContent = '—';
    return { get: ()=>NaN, set: ()=>{}, values: [] };
  }
  inputEl.min = 0;
  inputEl.max = arr.length - 1;
  inputEl.step = 1;
  inputEl.value = 0;
  inputEl.disabled = false;
  inputEl.classList.remove('disabled');
  valueEl.textContent = format(arr[0]);

  function setFromValue(v) {
    // snap to nearest
    let idx = 0;
    let best = Math.abs(arr[0] - v);
    for (let i = 1; i < arr.length; i++) {
      const d = Math.abs(arr[i] - v);
      if (d < best) { best = d; idx = i; }
    }
    inputEl.value = idx;
    valueEl.textContent = format(arr[idx]);
  }
  function get() {
    const idx = parseInt(inputEl.value, 10);
    const v = arr[Math.max(0, Math.min(arr.length - 1, idx))];
    valueEl.textContent = format(v);
    return v;
  }
  return { get, set: setFromValue, values: arr };
}

/* -----------------------
   Load data (Arrow Feather)
------------------------ */
import { tableFromIPC } from "https://cdn.jsdelivr.net/npm/apache-arrow@15.0.2/+esm";

let TABLE = null;
let AX_UNIQUE = {}; // { W:[...], Q2:[...], cos:[...], phi:[...] }
let META = null;

async function loadTable(which='full') {
  const url = which === 'full' ? DATA_URL_FULL : DATA_URL_SAMPLE;
  const buff = await fetch(url).then(r => {
    if (!r.ok) throw new Error(`Failed to load ${url}: ${r.status}`);
    return r.arrayBuffer();
  });
  // Must be UNCOMPRESSED feather; otherwise Arrow-in-browser will throw
  const table = tableFromIPC(buff);
  // sanity columns
  ['ok_kin','ok_asym','ok_delta','w_r','q2_r','ct_r','phi_deg','delta_xsec_ratio','A_ratio'].forEach(c => {
    if (!table.getChild(c)) throw new Error(`Missing column: ${c}`);
  });
  return table;
}

async function materialize(which='full') {
  TABLE = await loadTable(which);
  META  = await fetch(META_URL).then(r => r.json()).catch(() => ({}));

  // Precompute unique sorted axis values
  AX_UNIQUE = {
    W:   uniqSorted(toArray(TABLE.getChild('w_r'), 'w_r')),
    Q2:  uniqSorted(toArray(TABLE.getChild('q2_r'),'q2_r')),
    cos: uniqSorted(toArray(TABLE.getChild('ct_r'),'ct_r')),
    phi: uniqSorted(toArray(TABLE.getChild('phi_deg'),'phi_deg'))
  };

  // Build discrete sliders (indices, not continuous floats)
  buildSliders();

  // Render first time
  render();
}

function uniqSorted(arr) {
  return Array.from(new Set(arr.filter(Number.isFinite))).sort((a,b)=>a-b);
}

/* -----------------------
   UI wiring
------------------------ */
function el(id) { return document.getElementById(id); }

function initElements() {
  els.ySel       = el('ySel');
  els.xSel       = el('xSel');
  els.overlaySel = el('overlaySel');
  els.datasetSel = el('datasetSel');
  els.updateBtn  = el('updateBtn');

  // slider inputs + readouts
  els.Win   = el('W_in');   els.Wval   = el('W_val');
  els.Q2in  = el('Q2_in');  els.Q2val  = el('Q2_val');
  els.cosin = el('cos_in'); els.cosval = el('cos_val');
  els.phiin = el('phi_in'); els.phival = el('phi_val');

  els.figDiv = el('figure');
  els.rowsFooter = el('rowsFooter');

  // y options
  els.ySel.innerHTML = '';
  for (const yo of Y_OPTIONS) {
    const opt = document.createElement('option');
    opt.value = yo.key; opt.textContent = yo.label;
    els.ySel.appendChild(opt);
  }
}

let SLIDERS = {}; // { W:{get,set,values}, Q2:{...}, cos:{...}, phi:{...} }

function buildSliders() {
  // formats
  const fW  = (v)=>v.toFixed(3);
  const fQ2 = (v)=>v.toFixed(3);
  const fC  = (v)=> (Math.abs(v)<1e-6 ? '0.000' : v.toFixed(3));
  const fP  = (v)=>v.toFixed(0);

  SLIDERS.W   = makeDiscreteSlider(AX_UNIQUE.W,   els.Win,   els.Wval,   fW);
  SLIDERS.Q2  = makeDiscreteSlider(AX_UNIQUE.Q2,  els.Q2in,  els.Q2val,  fQ2);
  SLIDERS.cos = makeDiscreteSlider(AX_UNIQUE.cos, els.cosin, els.cosval, fC);
  SLIDERS.phi = makeDiscreteSlider(AX_UNIQUE.phi, els.phiin, els.phival, fP);

  // default positions roughly mid-range
  // (leave defaults as whatever sliders were initialized to)

  // Hook change events for render
  [els.Win, els.Q2in, els.cosin, els.phiin].forEach(inp => {
    inp.addEventListener('input', () => render(false));
  });
}

/* Disable/hide sliders for the selected x and overlay variables */
function updateSliderEnableState() {
  const x = els.xSel.value;
  const ov = els.overlaySel.value;
  const fixed = new Set(['W','Q2','cos','phi']);
  fixed.delete(x); fixed.delete(ov);
  const enable = { W:false, Q2:false, cos:false, phi:false };
  for (const k of fixed) enable[k] = true;

  function setState(varName, inputEl, labelEl) {
    inputEl.disabled = !enable[varName];
    if (enable[varName]) {
      inputEl.classList.remove('disabled');
      labelEl.classList.remove('disabled');
    } else {
      inputEl.classList.add('disabled');
      labelEl.classList.add('disabled');
    }
  }

  setState('W',   els.Win,   el('W_lbl'));
  setState('Q2',  els.Q2in,  el('Q2_lbl'));
  setState('cos', els.cosin, el('cos_lbl'));
  setState('phi', els.phiin, el('phi_lbl'));
}

// Keep overlay dropdown from matching x
function refreshOverlayOptions() {
  const x = els.xSel.value;
  const keep = ['W','Q2','cos','phi'].filter(v => v !== x);
  const current = els.overlaySel.value;
  els.overlaySel.innerHTML = '';
  for (const v of keep) {
    const opt = document.createElement('option');
    opt.value = v; opt.textContent = v;
    els.overlaySel.appendChild(opt);
  }
  if (keep.includes(current)) els.overlaySel.value = current;
}

/* -----------------------
   Plot + data selection
------------------------ */
function currentSelection() {
  // pick y
  const ykey = els.ySel.value; // delta_xsec_ratio | A_ratio

  // base filter: ok_kin + ok_delta/asym
  const okKin   = TABLE.getChild('ok_kin');
  const okDelta = TABLE.getChild('ok_delta');
  const okAsym  = TABLE.getChild('ok_asym');

  const yOk = (ykey === 'delta_xsec_ratio') ? okDelta : okAsym;

  // fixed variables are those NOT equal to x or overlay
  const x = els.xSel.value;           // 'W'|'Q2'|'cos'|'phi'
  const overlay = els.overlaySel.value;
  const fixed = ['W','Q2','cos','phi'].filter(v => v !== x && v !== overlay);

  // fixed values from sliders (discrete)
  const fixVals = {};
  for (const v of fixed) fixVals[v] = SLIDERS[v].get();

  // Build arrays
  const cols = {
    x:  VARCOL[x],
    ov: VARCOL[overlay],
    W:  'w_r',  Q2: 'q2_r',  cos: 'ct_r',  phi: 'phi_deg',
    y:  ykey
  };

  const N = TABLE.length;
  const xa = toArray(TABLE.getChild(cols.x), 'xcol');
  const ova= toArray(TABLE.getChild(cols.ov), 'ovcol');
  const ya = toArray(TABLE.getChild(cols.y), 'ycol');
  const Wa = toArray(TABLE.getChild('w_r'), 'w_r');
  const Q2a= toArray(TABLE.getChild('q2_r'),'q2_r');
  const Ca = toArray(TABLE.getChild('ct_r'), 'ct_r');
  const Pa = toArray(TABLE.getChild('phi_deg'),'phi_deg');

  // mask by ok + fixed matches
  const mask = new Array(N);
  for (let i = 0; i < N; i++) {
    const ok = okKin.get(i) && yOk.get(i);
    if (!ok) { mask[i] = false; continue; }
    // test fixed equality; phi is rounded to 0.5 deg bins in UI, but data are exact -> use numeric equality on stored (rounded) columns
    let keep = true;
    for (const v of fixed) {
      const col = v==='W' ? Wa : v==='Q2' ? Q2a : v==='cos' ? Ca : Pa;
      if (col[i] !== fixVals[v]) { keep = false; break; }
    }
    mask[i] = keep;
  }

  // collect unique overlay values present in the masked set, sorted by coverage (count of unique x points)
  const byOv = new Map(); // ovVal -> Map(xVal -> yVal)
  for (let i = 0; i < N; i++) {
    if (!mask[i]) continue;
    const ovVal = ova[i];
    const xVal  = xa[i];
    const yVal  = ya[i];
    if (!Number.isFinite(ovVal) || !Number.isFinite(xVal) || !Number.isFinite(yVal)) continue;
    if (!byOv.has(ovVal)) byOv.set(ovVal, new Map());
    byOv.get(ovVal).set(xVal, yVal);
  }
  // turn to sorted traces by coverage then numeric ov
  const traces = [];
  for (const [ovVal, mp] of byOv.entries()) {
    const xs = Array.from(mp.keys()).sort((a,b)=>a-b);
    const ys = xs.map(xv => mp.get(xv));
    traces.push({ ovVal, xs, ys, n: xs.length });
  }
  traces.sort((a,b) => (b.n - a.n) || (a.ovVal - b.ovVal));

  return { traces, x, overlay, fixed, fixVals, ykey };
}

function yLabelMath(ykey) {
  const found = Y_OPTIONS.find(o => o.key === ykey);
  return found ? found.math : '';
}

function render(reflowTitle=true) {
  try {
    updateSliderEnableState();

    const { traces, x, overlay, fixed, fixVals, ykey } = currentSelection();

    // plotly traces
    const pltTraces = [];
    const maxTraces = 8;
    for (let i = 0; i < Math.min(maxTraces, traces.length); i++) {
      const t = traces[i];
      pltTraces.push({
        x: t.xs,
        y: t.ys,
        mode: 'lines+markers',
        name: overlay + '=' + (overlay==='W' ? t.ovVal.toFixed(3)
                                   : overlay==='Q2' ? t.ovVal.toFixed(3)
                                   : overlay==='cos'? t.ovVal.toFixed(3)
                                   : t.ovVal.toFixed(0)),
        line: { width: 2, color: OKABE_ITO[i % OKABE_ITO.length], dash: DASHES[i % DASHES.length] },
        marker: { size: 6, color: OKABE_ITO[i % OKABE_ITO.length] }
      });
    }

    // title text (plain, but with MathJax y-axis)
    const fixedTxt = fixed.map(v => {
      const val = fixVals[v];
      if (v === 'phi') return `φ*=${val.toFixed(0)}°`;
      if (v === 'cos') return `cosθ*=${val.toFixed(3)}`;
      if (v === 'W')   return `W=${val.toFixed(3)} GeV`;
      if (v === 'Q2')  return `Q²=${val.toFixed(3)} GeV²`;
      return `${v}=${val}`;
    }).join(', ');

    const title = `${Y_OPTIONS.find(o=>o.key===ykey).label} vs ${VARLABEL[x]}  |  fixed: ${fixedTxt}`;

    const layout = {
      template: 'plotly_white',
      title: { text: title, x: 0, xanchor: 'left', pad: { b: 24 } },  // <-- more space under the title
      margin: { t: 80, r: 30, b: 50, l: 60 },
      xaxis: { title: VARLABEL[x], zeroline: false },
      yaxis: { title: { text: '$' + yLabelMath(ykey) + '$' } },       // MathJax
      legend: {
        orientation: 'h',
        yanchor: 'top',
        y: 0.96,                 // sit below the (now padded) title
        xanchor: 'left',
        x: 0
      }
    };

    Plotly.react(els.figDiv, pltTraces, layout, {responsive: true, displaylogo: false});

    // footer counts
    const dedupRows = META?.counts?.dedup_rows ?? 0;
    const sampleRows = META?.counts?.sample_rows ?? 0;
    els.rowsFooter.textContent = `rows (dedup): ${dedupRows.toLocaleString()} • sample: ${sampleRows.toLocaleString()}`;

  } catch (e) {
    console.error(e);
    els.figDiv.innerHTML = `<div style="color:#b00020">Error: ${e.message}</div>`;
  }
}

/* -----------------------
   Boot
------------------------ */
function main() {
  initElements();

  // dataset switch
  els.datasetSel.addEventListener('change', () => {
    materialize(els.datasetSel.value.includes('full') ? 'full' : 'sample')
      .catch(e => {
        console.error(e);
        els.figDiv.innerHTML = `<div style="color:#b00020">Error: ${e.message}</div>`;
      });
  });

  // x changes → keep overlay ≠ x, and refresh slider state
  els.xSel.addEventListener('change', () => {
    refreshOverlayOptions();
    updateSliderEnableState();
    render();
  });

  // overlay changes → just update slider state and plot
  els.overlaySel.addEventListener('change', () => {
    updateSliderEnableState();
    render();
  });

  els.ySel.addEventListener('change', () => render());
  els.updateBtn.addEventListener('click', () => render());

  // initial
  refreshOverlayOptions();
  updateSliderEnableState();
  materialize(els.datasetSel.value.includes('full') ? 'full' : 'sample')
    .catch(e => {
      console.error(e);
      els.figDiv.innerHTML = `<div style="color:#b00020">Error: ${e.message}</div>`;
    });
}

document.addEventListener('DOMContentLoaded', main);
