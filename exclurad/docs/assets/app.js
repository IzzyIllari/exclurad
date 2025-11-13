// --------- Data + UI wiring for EXCLURAD explorer (Arrow + Plotly) ---------
import { tableFromIPC } from "https://cdn.jsdelivr.net/npm/apache-arrow@15.0.2/+esm";

// Colorblind-friendly palette (Okabe-Ito) + dashes + markers
const COLORS = ["#0072B2","#D55E00","#009E73","#CC79A7","#E69F00","#56B4E9","#000000","#F0E442"];
const DASHES = ["solid","dash","dot","dashdot","longdash","longdashdot","solid","dash"];
const SYMBOLS = ["circle","triangle-up","square","diamond","x","star","cross","hexagram"];

const VARCOL = { W: "w_r", Q2: "q2_r", cos: "ct_r", phi: "phi_deg" };

const DATA_FILES = {
  sample: "./data/exclurad_eta_web_sample.feather",
  full:   "./data/exclurad_eta_web.feather",  // make sure you committed this if you choose 'full'
};

const PLOT_CONFIG = { responsive: true, displaylogo: false };

// Helpers
const fmt = (v, p=3) => (typeof v === "number" ? Number(v).toFixed(p) : v);
const approxEq = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps;

// Read Feather -> Arrow Table
async function loadFeather(url) {
  const resp = await fetch(url + "?v=" + Date.now()); // cache-bust on deploy updates
  if (!resp.ok) throw new Error(`Failed to fetch ${url}: ${resp.status}`);
  const buf = new Uint8Array(await resp.arrayBuffer());
  return tableFromIPC(buf);
}

function toArray(table, name) {
  const col = table.getChild(name);
  if (!col) throw new Error(`Missing column: ${name}`);
  return col.toArray(); // TypedArray / JS array depending on type
}

function uniqueSorted(arr) {
  const set = new Set(arr);
  const out = Array.from(set).filter(Number.isFinite);
  out.sort((a,b) => a - b);
  return out;
}

function buildDiscreteSlider(values, inputEl, ticksEl, labelEl, decimals) {
  // values: sorted numeric array
  inputEl.min = 0;
  inputEl.max = Math.max(0, values.length - 1);
  inputEl.step = 1;
  // datalist ticks (sparingly)
  ticksEl.innerHTML = "";
  const N = values.length;
  const every = Math.ceil(N / 10); // up to ~10 ticks
  for (let i = 0; i < N; i += every) {
    const opt = document.createElement("option");
    opt.value = String(i);
    opt.label = decimals != null ? Number(values[i]).toFixed(decimals) : String(values[i]);
    ticksEl.appendChild(opt);
  }
  const setFromIndex = (idx) => {
    idx = Math.max(0, Math.min(values.length - 1, Number(idx)));
    inputEl.value = String(idx);
    labelEl.textContent = decimals != null ? Number(values[idx]).toFixed(decimals) : String(values[idx]);
  };
  const getValue = () => values[Number(inputEl.value)];

  // initialize at median-ish
  setFromIndex(Math.floor(values.length / 2));

  inputEl.addEventListener("input", () => setFromIndex(inputEl.value));
  return { getValue, setFromIndex, values };
}

function groupCoverage(data, ycol, xvar, fixed, overlayKey, minPoints=4) {
  // Count distinct x points per overlay value for the filtered 'base'
  const xKey = VARCOL[xvar];
  const N = data.ok_kin.length;
  const mask = new Array(N).fill(true);

  // base validity (kin + appropriate y)
  for (let i = 0; i < N; i++) {
    mask[i] = data.ok_kin[i] && (
      (ycol === "delta_xsec_ratio" ? (data.ok_delta[i] && Number.isFinite(data.delta_xsec_ratio[i]))
                                   : (data.ok_asym[i]  && Number.isFinite(data.A_ratio[i])))
    );
  }

  // fixed (two of the remaining variables)
  for (const [k, v] of Object.entries(fixed)) {
    const arr = data[k];
    const want = Number(v);
    if (k === "phi_deg") {
      for (let i = 0; i < N; i++) mask[i] = mask[i] && approxEq(arr[i], want, 1e-3);
    } else {
      for (let i = 0; i < N; i++) mask[i] = mask[i] && approxEq(arr[i], want, 1e-6);
    }
  }

  // distinct x by overlay value
  const map = new Map(); // overlayVal -> Set of x
  for (let i = 0; i < N; i++) {
    if (!mask[i]) continue;
    const ov = data[overlayKey][i];
    const xv = data[xKey][i];
    if (!Number.isFinite(ov) || !Number.isFinite(xv)) continue;
    if (!map.has(ov)) map.set(ov, new Set());
    map.get(ov).add(xv);
  }
  const rows = [];
  for (const [ov, set] of map.entries()) rows.push({ ov, n: set.size });
  rows.sort((a,b) => (b.n - a.n) || (a.ov - b.ov));
  return rows.filter(r => r.n >= minPoints);
}

function buildCurves(data, ycol, xvar, overlayKey, fixed, overlayList, minPoints=4) {
  const xKey = VARCOL[xvar];
  const N = data.ok_kin.length;
  const traces = [];
  const allY = [];

  for (let idx = 0; idx < overlayList.length; idx++) {
    const ov = overlayList[idx];
    // filter rows for this curve
    const pts = [];
    for (let i = 0; i < N; i++) {
      if (!data.ok_kin[i]) continue;
      if (overlayKey === "phi_deg") { if (!approxEq(data[overlayKey][i], ov, 1e-3)) continue; }
      else                           { if (!approxEq(data[overlayKey][i], ov, 1e-6)) continue; }

      // fixed
      let ok = true;
      for (const [k, v0] of Object.entries(fixed)) {
        const v = Number(v0);
        if (k === "phi_deg") { if (!approxEq(data[k][i], v, 1e-3)) { ok = false; break; } }
        else                 { if (!approxEq(data[k][i], v, 1e-6)) { ok = false; break; } }
      }
      if (!ok) continue;

      const xv = data[xKey][i];
      const yv = (ycol === "delta_xsec_ratio") ? data.delta_xsec_ratio[i] : data.A_ratio[i];
      const yOK = (ycol === "delta_xsec_ratio") ? (data.ok_delta[i] && Number.isFinite(yv))
                                                : (data.ok_asym[i]  && Number.isFinite(yv));
      if (!Number.isFinite(xv) || !yOK) continue;
      pts.push([xv, yv]);
    }
    if (pts.length < minPoints) continue;
    pts.sort((a,b) => a[0] - b[0]);

    const color = COLORS[idx % COLORS.length];
    const dash  = DASHES[idx % DASHES.length];
    const sym   = SYMBOLS[idx % SYMBOLS.length];

    traces.push({
      x: pts.map(p => p[0]),
      y: pts.map(p => p[1]),
      mode: "lines+markers",
      name: `${overlayKey === "w_r" ? "W" : overlayKey === "q2_r" ? "Q²" : overlayKey === "ct_r" ? "cosθ*" : "φ*"}=${overlayKey==="w_r" ? fmt(ov,3) :
             overlayKey==="phi_deg" ? fmt(ov,0) : fmt(ov,3)}`,
      line: { width: 2, color, dash },
      marker: { size: 6, color, symbol: sym }
    });
    allY.push(...pts.map(p => p[1]));
  }
  return { traces, allY };
}

async function main() {
  // Elements
  const selY   = document.getElementById("y");
  const selX   = document.getElementById("x");
  const selOv  = document.getElementById("overlay");
  const selSet = document.getElementById("dataset");
  const btnUpd = document.getElementById("update");
  const metaDiv = document.getElementById("meta");

  // Sliders
  const W = document.getElementById("W"),     Wticks = document.getElementById("W_ticks"),     Wval = document.getElementById("W_val");
  const Q2= document.getElementById("Q2"),    Q2ticks= document.getElementById("Q2_ticks"),    Q2val= document.getElementById("Q2_val");
  const CS= document.getElementById("cos"),   CSticks= document.getElementById("cos_ticks"),   CSval= document.getElementById("cos_val");
  const PH= document.getElementById("phi"),   PHticks= document.getElementById("phi_ticks"),   PHval= document.getElementById("phi_val");

  // Load meta (optional)
  try {
    const m = await (await fetch("./data/meta.json")).json();
    metaDiv.textContent = `rows (dedup): ${m.counts.web_rows.toLocaleString()} • sample: ${m.counts.sample_rows.toLocaleString()}`;
  } catch { /* non-fatal */ }

  // Load table (default = sample)
  let table = await loadFeather(DATA_FILES[selSet.value]);

  // Arrow -> column arrays
  function materialize(table) {
    return {
      // rounded keys & raw angles
      w_r: toArray(table, "w_r"),
      q2_r: toArray(table, "q2_r"),
      ct_r: toArray(table, "ct_r"),
      phi_deg: toArray(table, "phi_deg"),
      // y columns
      delta_xsec_ratio: toArray(table, "delta_xsec_ratio"),
      A_ratio: toArray(table, "A_ratio"),
      // valids
      ok_kin:  toArray(table, "ok_kin"),
      ok_delta:toArray(table, "ok_delta"),
      ok_asym: toArray(table, "ok_asym"),
    };
  }
  let data = materialize(table);

  // Slider domains from data (discrete)
  const valsW   = uniqueSorted(Array.from(data.w_r));
  const valsQ2  = uniqueSorted(Array.from(data.q2_r));
  const valsCos = uniqueSorted(Array.from(data.ct_r));
  const valsPhi = uniqueSorted(Array.from(data.phi_deg));

  const sW   = buildDiscreteSlider(valsW,   W,  Wticks,  Wval, 3);
  const sQ2  = buildDiscreteSlider(valsQ2,  Q2, Q2ticks, Q2val,3);
  const sCos = buildDiscreteSlider(valsCos, CS, CSticks, CSval,3);
  const sPhi = buildDiscreteSlider(valsPhi, PH, PHticks, PHval,0);

  async function maybeReloadDataset() {
    const url = DATA_FILES[selSet.value];
    const currentURL = table?.schema?.metadata?.get("source") || "";
    if (!url || url === currentURL) return; // minimal check
    table = await loadFeather(url);
    data = materialize(table);
  }

  async function draw() {
    await maybeReloadDataset();

    const xvar = selX.value;           // 'W'|'Q2'|'cos'|'phi'
    const ycol = selY.value;           // 'delta_xsec_ratio'|'A_ratio'
    const overlay = selOv.value;

    if (overlay === xvar) {
      alert("Overlay variable must differ from x-axis.");
      return;
    }

    // fixed variables (the other two)
    const allVars = ["W","Q2","cos","phi"];
    const fixedVars = allVars.filter(v => v !== xvar && v !== overlay);
    const fixed = {};
    for (const v of fixedVars) {
      if (v === "W")   fixed["w_r"]   = sW.getValue();
      if (v === "Q2")  fixed["q2_r"]  = sQ2.getValue();
      if (v === "cos") fixed["ct_r"]  = sCos.getValue();
      if (v === "phi") fixed["phi_deg"]= sPhi.getValue();
    }

    // pick overlay values with best coverage
    const overlayKey = VARCOL[overlay];
    const cover = groupCoverage(data, ycol, xvar, fixed, overlayKey, 4);
    const maxTraces = 8;
    const picked = cover.slice(0, maxTraces).map(r => r.ov).sort((a,b) => a - b);

    // build traces
    const { traces, allY } = buildCurves(data, ycol, xvar, overlayKey, fixed, picked, 4);

    // labels
    const xlab = {W:"W [GeV]", Q2:"Q² [GeV²]", cos:"cosθ*", phi:"φ* [deg]"}[xvar];
    const ylab = (ycol === "delta_xsec_ratio") ? "δ = σ_obs/σ₀" : "A_RC / A_Born";

    const fixedLabel = Object.entries(fixed).map(([k,v]) => {
      if (k === "w_r") return `W=${fmt(v,3)} GeV`;
      if (k === "q2_r") return `Q²=${fmt(v,3)} GeV²`;
      if (k === "ct_r") return `cosθ*=${fmt(v,3)}`;
      if (k === "phi_deg") return `φ*=${fmt(v,0)}°`;
    }).join(", ");

    const layout = {
      title: `${ylab} vs ${xlab}  |  fixed: ${fixedLabel}`,
      xaxis: { title: xlab, zeroline: false },
      yaxis: { title: ylab, zeroline: false },
      legend: { orientation: "h", y: 1.1, x: 0 },
      margin: { t: 80, r: 20, b: 60, l: 60 },
      height: 640,
      template: "plotly_white"
    };

    // harmonize y-range a bit
    if (allY.length) {
      const finite = allY.filter(Number.isFinite);
      if (finite.length) {
        const lo = Math.min(...finite), hi = Math.max(...finite);
        const pad = 0.08 * Math.max(hi - lo, 1e-3);
        layout.yaxis.range = [lo - pad, hi + pad];
      }
    }

    Plotly.newPlot("plot", traces, layout, PLOT_CONFIG);
  }

  // initial draw + events
  btnUpd.addEventListener("click", draw);
  // update overlay choices when x changes so they can't be equal
  selX.addEventListener("change", () => {
    if (selOv.value === selX.value) {
      selOv.value = ["W","Q2","cos","phi"].find(v => v !== selX.value);
    }
  });

  await draw();
}

main().catch(err => {
  console.error(err);
  const div = document.getElementById("plot");
  if (div) div.textContent = String(err);
});

