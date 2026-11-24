/* AI Control Center – gränssnitt. Ingen affärslogik här: allt går via /api. */
"use strict";

// ───────────────────────────────────────────────────────────── hjälpare
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const nf = new Intl.NumberFormat("sv-SE");
const num = (v) => (v == null ? "–" : nf.format(v));
const dec = (v, d = 3) => (v == null ? "–" : Number(v).toLocaleString("sv-SE", { minimumFractionDigits: d, maximumFractionDigits: d }));
const compact = (v) => {
  if (v == null) return "–";
  if (v >= 1e9) return dec(v / 1e9, 2) + " md";
  if (v >= 1e6) return dec(v / 1e6, 2) + " M";
  if (v >= 1e3) return dec(v / 1e3, v >= 1e5 ? 0 : 1) + " k";
  return String(v);
};
const bytes = (v) => {
  if (v == null) return "–";
  const u = ["B", "kB", "MB", "GB", "TB"]; let i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return dec(v, i > 1 ? 1 : 0) + " " + u[i];
};
const dur = (s) => {
  if (s == null || !isFinite(s)) return "–";
  s = Math.round(s);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  return h ? `${h} h ${m} min` : m ? `${m} min ${sec} s` : `${sec} s`;
};
const when = (iso) => (iso ? iso.replace("T", " ").slice(0, 16) : "–");

async function api(method, url, body) {
  const opt = { method, headers: {} };
  if (body instanceof Blob) opt.body = body;
  else if (body !== undefined) { opt.body = JSON.stringify(body); opt.headers["Content-Type"] = "application/json"; }
  let res;
  try { res = await fetch(url, opt); } catch { throw new Error("Ingen kontakt med AI Control Center-servern"); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.fel || `Fel ${res.status}`);
  return data;
}
const qs = (obj) => Object.entries(obj).filter(([, v]) => v !== "" && v != null).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");

function toast(msg, error = false) {
  const el = document.createElement("div");
  el.className = "toast" + (error ? " error" : "");
  el.textContent = msg;
  $("#toasts").append(el);
  setTimeout(() => el.remove(), error ? 7000 : 3500);
}
const fail = (e) => toast(e.message || String(e), true);

function modal({ title, body, footer = "", size = "" }) {
  const root = $("#modal-root");
  const el = document.createElement("div");
  el.className = "overlay";
  el.innerHTML = `<div class="modal ${size}" role="dialog" aria-modal="true"><header><h2>${esc(title)}</h2><button class="btn ghost small" data-close>✕</button></header><div class="body">${body}</div>${footer ? `<footer>${footer}</footer>` : ""}</div>`;
  const close = () => el.remove();
  el.addEventListener("mousedown", (e) => { if (e.target === el) close(); });
  el.addEventListener("click", (e) => { if (e.target.closest("[data-close]")) close(); });
  el.addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });
  root.append(el);
  const first = $("input:not([type=file]), textarea, select", el);
  if (first) first.focus();
  return { el, close };
}
function confirmDialog(title, text, okLabel = "OK", danger = false) {
  return new Promise((resolve) => {
    const m = modal({ title, size: "narrow", body: `<div>${text}</div>`,
      footer: `<button class="btn" data-no>Avbryt</button><button class="btn ${danger ? "danger" : "primary"}" data-yes>${esc(okLabel)}</button>` });
    $("[data-yes]", m.el).onclick = () => { m.close(); resolve(true); };
    $("[data-no]", m.el).onclick = () => { m.close(); resolve(false); };
    $("[data-close]", m.el).addEventListener("click", () => resolve(false));
    $("[data-yes]", m.el).focus();
  });
}
function formData(root) {
  const out = {};
  $$("[name]", root).forEach((el) => { out[el.name] = el.type === "checkbox" ? el.checked : el.value; });
  return out;
}

const ICON = {
  home: '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/></svg>',
  models: '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2l9 5v10l-9 5-9-5V7z"/><path d="M12 22V12M3 7l9 5 9-5"/></svg>',
  train: '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v18h18"/><path d="M7 15l4-5 3 3 5-7"/></svg>',
  chat: '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/></svg>',
  data: '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v6c0 1.7 3.6 3 8 3s8-1.3 8-3V5M4 11v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/></svg>',
};

const STATE = {
  starting: ["Startar", "run"], preparing: ["Förbereder", "run"], running: ["Tränar", "run"],
  paused: ["Pausad", "warn"], stopping: ["Avslutar", "warn"], completed: ["Klar", "good"],
  stopped: ["Avbruten", "warn"], failed: ["Misslyckades", "bad"],
};
const statePill = (s) => { const [t, c] = STATE[s] || [s, ""]; return `<span class="pill ${c}">${esc(t)}</span>`; };
const modelPill = (m) => m.tranar ? '<span class="pill run">Tränar</span>' : m.tranad ? '<span class="pill good">Tränad</span>' : '<span class="pill">Otränad</span>';

// ───────────────────────────────────────────────────────────── tillstånd
const S = {
  view: "oversikt", models: [], active: null, datasets: [], runs: [], system: null, presets: null,
  timer: null,
  train: { runId: null, metrics: [], logOffset: 0, log: "", model: null, timer: null },
  chat: { panels: [], busy: false, aborts: [], sessionId: null, sessionName: "", settings: { temperature: 0.7, max_tokens: 150, top_k: 40, mode: "chatt" } },
  data: { id: null, split: "alla", offset: 0 },
};
const VIEWS = {
  oversikt: { title: "Översikt", icon: ICON.home },
  modeller: { title: "Modeller", icon: ICON.models },
  traning: { title: "Träning", icon: ICON.train },
  testa: { title: "Testa modeller", icon: ICON.chat },
  dataset: { title: "Dataset", icon: ICON.data },
};
const modelById = (id) => S.models.find((m) => m.id === id);
const isExtern = (m) => m?.arkitektur?.architecture === "gpt-l3";
const archLabel = (arch) => S.presets?.arkitekturer?.[arch]?.label || S.presets?.externa_arkitekturer?.[arch]?.label || (arch === "gpt-l3" ? "Transformer (GPT, Lennart 3-format)" : arch);

// Laddningsindikator: en glänsande sfär med en roterande ring och en text som tickar.
const LOADER_ORB = '<span class="loader"><span class="orb"></span><span class="loader-text">tänker<i>.</i><i>.</i><i>.</i></span></span>';

// Varje modell får en egen färg och rörelse utifrån namnet; "busy" när den tränas.
function modelAvatar(m) {
  let h = 0;
  for (const ch of m.namn || m.id) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  const hues = [150, 185, 265, 35, 330];
  const c = `hsl(${hues[h % hues.length]} 85% 62%)`;
  const state = m.tranar ? "busy" : "idle";
  return `<div class="avatar ${state}" aria-hidden="true"><svg viewBox="0 0 44 44">
    <circle class="r1" cx="22" cy="22" r="20" fill="none" stroke="${c}" stroke-width="1.2" stroke-dasharray="4 5" opacity=".7"/>
    <polygon class="r2" points="22,6 35.6,14 35.6,30 22,38 8.4,30 8.4,14" fill="none" stroke="${c}" stroke-width="1.4" opacity=".9"/>
    <circle cx="22" cy="22" r="5" fill="${c}"/>
    <circle class="dot" cx="22" cy="22" r="5" fill="none" stroke="${c}" stroke-width="1.5"/>
  </svg></div>`;
}
const modelOptions = (sel, onlyTrained = false) => S.models.filter((m) => !onlyTrained || m.tranad)
  .map((m) => `<option value="${esc(m.id)}" ${m.id === sel ? "selected" : ""}>${esc(m.namn)}${m.tranad ? "" : " (otränad)"}</option>`).join("");

async function refresh() {
  const o = await api("GET", "/api/overview");
  S.models = o.modeller; S.active = o.aktiv_modell; S.datasets = o.dataset; S.runs = o.korningar; S.system = o.system;
  renderChrome();
}

function renderChrome() {
  const active = S.runs.filter((r) => r.aktiv).length;
  $("#nav").innerHTML = Object.entries(VIEWS).map(([id, v]) =>
    `<button class="${S.view === id ? "on" : ""}" data-view="${id}">${v.icon}<span>${v.title}</span>${id === "traning" && active ? `<span class="pill run">${active}</span>` : ""}</button>`).join("");
  $("#page-title").textContent = VIEWS[S.view].title;
  const sel = $("#active-model");
  if (document.activeElement !== sel) {
    sel.innerHTML = S.models.length ? modelOptions(S.active) : "<option>Inga modeller ännu</option>";
    sel.disabled = !S.models.length;
  }
  const sys = S.system || {};
  const dev = sys.enheter;
  const gpu = !dev ? "Kontrollerar …" : dev.fel ? "PyTorch saknas" : dev.gpus.length ? dev.gpus[0].namn : "Endast CPU";
  $("#side-status").innerHTML = `
    <div class="row"><span>CPU</span><b class="num">${sys.cpu_procent == null ? "–" : Math.round(sys.cpu_procent) + " %"}</b></div>
    <div class="row"><span>Minne</span><b class="num">${sys.minne_totalt ? bytes(sys.minne_anvant) + " / " + bytes(sys.minne_totalt) : "–"}</b></div>
    <div class="row"><span>Beräkning</span><b>${esc(gpu)}</b></div>
    <div class="row"><span>Version</span><b>${esc(sys.version || "")}</b></div>`;
}

function go(view, arg) {
  S.view = view;
  clearInterval(S.timer); clearInterval(S.train.timer);
  $("#view").style.overflow = "";
  $("#view").scrollTop = 0;
  renderChrome();
  ({ oversikt: viewOverview, modeller: viewModels, traning: viewTraining, testa: viewChat, dataset: viewDatasets })[view](arg);
}

// ───────────────────────────────────────────────────────────── översikt
function viewOverview() {
  const draw = () => {
    const trained = S.models.filter((m) => m.tranad).length;
    const active = S.runs.filter((r) => r.aktiv);
    const sys = S.system || {}, dev = sys.enheter;
    const mem = sys.minne_totalt ? (100 * sys.minne_anvant) / sys.minne_totalt : 0;
    const disk = sys.disk_totalt ? (100 * (sys.disk_totalt - sys.disk_ledigt)) / sys.disk_totalt : 0;
    $("#view").innerHTML = `
      <div class="grid cols-4">
        <div class="panel stat"><div class="label">Modeller</div><div class="value num">${S.models.length}</div><div class="sub">${trained} tränade</div></div>
        <div class="panel stat"><div class="label">Parametrar totalt</div><div class="value num">${compact(S.models.reduce((a, m) => a + m.arkitektur.n_params, 0))}</div><div class="sub">i alla modeller</div></div>
        <div class="panel stat"><div class="label">Dataset</div><div class="value num">${S.datasets.length}</div><div class="sub">${num(S.datasets.reduce((a, d) => a + d.antal, 0))} poster</div></div>
        <div class="panel stat"><div class="label">Aktiva träningar</div><div class="value num">${active.length}</div><div class="sub">${S.runs.length} körningar totalt</div></div>
      </div>
      <div class="grid cols-2" style="margin-top:16px">
        <div class="panel"><header><h2>Träning</h2><button class="btn small" data-view="traning">Öppna träning</button></header>
          ${active.length ? `<div class="body grid">${active.map((r) => `
            <div data-open-run="${esc(r.run_id)}" style="cursor:pointer">
              <div class="run-head"><span class="run-who">${r.aktiv ? '<span class="orb sm"></span>' : ""}<b>${esc(r.model_namn)}</b></span>${statePill(r.state)}</div>
              <div class="muted" style="font-size:12.5px;margin:2px 0 8px">${esc(r.dataset_namn)} · steg ${num(r.step)} / ${num(r.max_steps)} · loss ${dec(r.loss)} · kvar ${dur(r.eta)}</div>
              <div class="bar"><i style="width:${(100 * (r.step || 0)) / (r.max_steps || 1)}%"></i></div>
            </div>`).join("")}</div>`
          : `<div class="empty"><strong>Ingen träning pågår</strong>Starta en träning under Träning.</div>`}
          ${S.runs.filter((r) => !r.aktiv).length ? `<table><thead><tr><th>Senaste körningar</th><th>Status</th><th class="right">Steg</th><th class="right">Loss</th></tr></thead><tbody>
            ${S.runs.filter((r) => !r.aktiv).slice(0, 5).map((r) => `<tr class="click" data-open-run="${esc(r.run_id)}"><td>${esc(r.model_namn)}<div class="muted" style="font-size:12px">${when(r.started)}</div></td><td>${statePill(r.state)}</td><td class="right num">${num(r.step)}</td><td class="right num">${dec(r.loss)}</td></tr>`).join("")}
          </tbody></table>` : ""}
        </div>
        <div class="panel"><header><h2>Systemstatus</h2><span class="muted" style="font-size:12.5px">${esc(sys.os || "")}</span></header>
          <div class="body grid">
            <div><div class="run-head"><span>CPU <span class="muted">· ${sys.cpu_karnor || "–"} trådar</span></span><b class="num">${sys.cpu_procent == null ? "–" : Math.round(sys.cpu_procent) + " %"}</b></div><div class="bar" style="margin-top:6px"><i style="width:${sys.cpu_procent || 0}%"></i></div></div>
            <div><div class="run-head"><span>Minne</span><b class="num">${bytes(sys.minne_anvant)} / ${bytes(sys.minne_totalt)}</b></div><div class="bar ${mem > 85 ? "warn" : ""}" style="margin-top:6px"><i style="width:${mem}%"></i></div></div>
            <div><div class="run-head"><span>Disk</span><b class="num">${bytes(sys.disk_ledigt)} ledigt</b></div><div class="bar ${disk > 90 ? "warn" : ""}" style="margin-top:6px"><i style="width:${disk}%"></i></div></div>
            <dl class="kv">
              <dt>Beräkningsenhet</dt><dd>${!dev ? "Kontrollerar …" : dev.fel ? `<span class="pill bad">PyTorch kunde inte laddas</span>` : dev.gpus.length ? dev.gpus.map((g) => `${esc(g.namn)} (${bytes(g.minne)})`).join(", ") : "CPU (ingen kompatibel GPU hittad)"}</dd>
              <dt>PyTorch</dt><dd>${esc(dev?.torch || (dev?.fel ? dev.fel : "–"))}</dd>
              <dt>Python</dt><dd>${esc(sys.python || "–")}</dd>
              <dt>Datamapp</dt><dd class="mono">${esc(sys.datamapp || "")}</dd>
            </dl>
          </div>
        </div>
      </div>
      <div class="panel" style="margin-top:16px"><header><h2>Modeller</h2><div class="btn-row"><button class="btn small" data-view="modeller">Visa alla</button><button class="btn small primary" data-action="new-model">+ Ny modell</button></div></header>
        ${S.models.length ? `<table><thead><tr><th>Namn</th><th>Användningsområde</th><th>Arkitektur</th><th class="right">Parametrar</th><th class="right">Steg</th><th class="right">Loss</th><th>Status</th></tr></thead><tbody>
          ${S.models.map((m) => `<tr class="click" data-model-detail="${esc(m.id)}"><td><b>${esc(m.namn)}</b>${m.id === S.active ? ' <span class="pill plain run">aktiv</span>' : ""}</td><td class="muted">${esc(m.anvandningsomrade || "–")}</td><td>${esc(m.arkitektur.architecture.toUpperCase())}</td><td class="right num">${num(m.arkitektur.n_params)}</td><td class="right num">${num(m.steg)}</td><td class="right num">${dec(m.senaste_loss)}</td><td>${modelPill(m)}</td></tr>`).join("")}
        </tbody></table>` : `<div class="empty"><strong>Inga modeller ännu</strong>Skapa din första modell – till exempel Lennart från mallen.<div style="margin-top:12px"><button class="btn primary" data-action="new-model">+ Ny modell</button></div></div>`}
      </div>`;
  };
  draw();
  S.timer = setInterval(async () => { try { await refresh(); if (S.view === "oversikt" && !$(".overlay")) draw(); } catch { /* servern svarar inte just nu */ } }, 2500);
}

// ───────────────────────────────────────────────────────────── modeller
function viewModels() {
  const draw = () => {
    $("#view").innerHTML = `
      <div class="toolbar"><p>Skapa, importera och hantera dina modeller. Varje modell har en egen mapp med kod, konfiguration och checkpoints.</p>
        <div class="btn-row"><button class="btn" data-action="import-model">Importera modell</button><button class="btn primary" data-action="new-model">+ Ny modell</button></div></div>
      ${S.models.length ? `<div class="model-grid">${S.models.map((m) => {
        const a = m.arkitektur;
        return `<div class="panel model-card ${m.id === S.active ? "active" : ""}">
          <div class="head"><div class="who">${modelAvatar(m)}<div><h2>${esc(m.namn)}</h2><div class="tags" style="margin-top:6px">${m.anvandningsomrade ? `<span class="tag">${esc(m.anvandningsomrade)}</span>` : ""}${m.sprak ? `<span class="tag">${esc(m.sprak)}</span>` : ""}${m.ursprung === "importerad" ? '<span class="tag">Importerad</span>' : ""}</div></div></div>${modelPill(m)}</div>
          <div class="desc">${esc(m.beskrivning || "Ingen beskrivning.")}</div>
          <div class="facts">
            <div><span>Parametrar</span><b class="num">${compact(a.n_params)}</b></div>
            <div><span>Arkitektur</span><b>${esc(a.architecture.toUpperCase())} · ${a.n_layers} lager</b></div>
            <div><span>Context</span><b class="num">${num(a.context_length)}</b></div>
            <div><span>Tränade steg</span><b class="num">${num(m.steg)}</b></div>
            <div><span>Loss</span><b class="num">${dec(m.senaste_loss)}</b></div>
            <div><span>Checkpoints</span><b class="num">${m.antal_checkpoints}</b></div>
          </div>
          <div class="btn-row">
            ${m.id === S.active ? '<button class="btn small" disabled>Aktiv</button>' : `<button class="btn small" data-action="activate" data-id="${esc(m.id)}">Välj</button>`}
            ${isExtern(m) ? '<button class="btn small" disabled title="Lennart 3 tränas vidare på Kaggle (moln/lennart3)">Träna</button>' : `<button class="btn small" data-action="train-model" data-id="${esc(m.id)}">${m.tranar ? "Visa träning" : "Träna"}</button>`}
            <button class="btn small" data-action="chat-model" data-id="${esc(m.id)}" ${m.tranad ? "" : "disabled title='Träna modellen först'"}>Chatta</button>
            <button class="btn small" data-model-detail="${esc(m.id)}">Detaljer</button>
          </div>
          <div class="btn-row card-more">
            <button class="btn small ghost" data-action="rename-model" data-id="${esc(m.id)}">Byt namn</button>
            <button class="btn small ghost" data-action="config-model" data-id="${esc(m.id)}">Konfigurera</button>
            <button class="btn small ghost" data-action="export-model" data-id="${esc(m.id)}">Exportera</button>
            <button class="btn small ghost danger" data-action="delete-model" data-id="${esc(m.id)}">Ta bort</button>
          </div></div>`;
      }).join("")}</div>`
      : `<div class="panel empty"><strong>Inga modeller ännu</strong>Skapa en ny modell från en mall eller med egna inställningar.<div style="margin-top:12px"><button class="btn primary" data-action="new-model">+ Ny modell</button></div></div>`}`;
  };
  draw();
  S.timer = setInterval(async () => { try { await refresh(); if (S.view === "modeller" && !$(".overlay")) draw(); } catch { /* ignorera */ } }, 4000);
}

async function ensurePresets() {
  if (!S.presets) S.presets = await api("GET", "/api/presets");
  return S.presets;
}

async function modelForm(existing) {
  const P = await ensurePresets();
  const edit = !!existing;
  const locked = edit && (existing.tranad || existing.har_tokenizer || existing.tranar);
  const a = existing?.arkitektur || P.mallar[0];
  const v = existing || P.mallar[0];
  const gen = existing?.generering;
  const m = modal({
    title: edit ? `Konfigurera ${existing.namn}` : "Ny modell", size: "wide",
    body: `
      ${edit ? "" : `<label class="field"><span>Mall</span><select name="_preset">${P.mallar.map((p) => `<option value="${p.id}">${esc(p.label)}</option>`).join("")}<option value="">Egen modell (tomt formulär)</option></select></label>`}
      <div class="section-title">Om modellen</div>
      <div class="form-grid">
        <label class="field"><span>Modellnamn</span><input type="text" name="namn" value="${esc(v.namn || "")}" maxlength="60" placeholder="t.ex. Lennart"></label>
        <label class="field"><span>Språk</span><input type="text" name="sprak" value="${esc(v.sprak || "")}" placeholder="t.ex. Svenska"></label>
        <label class="field wide"><span>Användningsområde</span><input type="text" name="anvandningsomrade" value="${esc(v.anvandningsomrade || "")}" placeholder="t.ex. Cybersäkerhet och IT-säkerhet"></label>
        <label class="field wide"><span>Beskrivning</span><textarea name="beskrivning" rows="2">${esc(v.beskrivning || "")}</textarea></label>
      </div>
      <div class="section-title">Arkitektur ${locked ? '<span class="muted" style="text-transform:none;letter-spacing:0">– låst eftersom modellen har tränats</span>' : ""}</div>
      <fieldset ${locked ? "disabled" : ""} style="border:0;padding:0;margin:0;display:grid;gap:12px;min-width:0">
        <div class="form-grid three">
          <label class="field wide"><span>Modellarkitektur</span><select name="architecture">${isExtern(existing) ? `<option value="gpt-l3" selected>${esc(archLabel("gpt-l3"))}</option>` : ""}${Object.entries(P.arkitekturer).map(([id, x]) => `<option value="${id}" ${a.architecture === id ? "selected" : ""}>${esc(x.label)}</option>`).join("")}</select><span class="hint" id="arch-hint"></span></label>
          <label class="field"><span>Antal parametrar <em>(mål)</em></span><input type="number" name="target_params" value="${a.target_params || a.n_params || 1000000}" min="10000" step="10000"></label>
          <label class="field"><span>Antal lager</span><input type="number" name="n_layers" value="${a.n_layers}" min="1" max="48"></label>
          <label class="field"><span>Attention heads</span><input type="number" name="n_heads" value="${a.n_heads}" min="1" max="64"></label>
          <label class="field"><span>Context length <em>(tokens)</em></span><input type="number" name="context_length" value="${a.context_length}" min="16" max="8192"></label>
          <label class="field"><span>Ordförråd <em>(tokens)</em></span><select name="vocab_size">${[[260, "260 – tecken-/bytenivå"], [512, "512"], [1024, "1 024"], [2048, "2 048"], [4096, "4 096"], [8192, "8 192"], [16384, "16 384"]].map(([n, l]) => `<option value="${n}" ${a.vocab_size == n ? "selected" : ""}>${l}</option>`).join("")}</select></label>
          <label class="field"><span>Dropout</span><input type="number" name="dropout" value="${a.dropout}" min="0" max="0.8" step="0.05"></label>
          <label class="check wide"><input type="checkbox" name="_manual" ${edit && !a.target_params ? "checked" : ""}> Ange modellbredd (d_model) manuellt i stället för målparametrar</label>
          <label class="field" id="dmodel-field" hidden><span>Modellbredd <em>(d_model)</em></span><input type="number" name="d_model" value="${a.d_model || 128}" min="8" max="4096"></label>
        </div>
      </fieldset>
      <div class="estimate"><div><div class="hint">Faktiskt antal tränbara parametrar</div><b id="est-params">–</b></div><div class="hint" id="est-detail" style="text-align:right"></div></div>
      ${edit ? `<div class="section-title">Standardinställningar i chatten</div>
        <div class="form-grid three">
          <label class="field"><span>Temperatur</span><input type="number" name="g_temperature" value="${gen.temperature}" min="0" max="2" step="0.05"></label>
          <label class="field"><span>Max tokens</span><input type="number" name="g_max_tokens" value="${gen.max_tokens}" min="1" max="4096"></label>
          <label class="field"><span>Top-k</span><input type="number" name="g_top_k" value="${gen.top_k}" min="0" max="1000"></label>
        </div>` : `<div class="section-title">Träningsdata</div>
        <div class="form-grid">
          <label class="field"><span>Dataset <em>(valfritt – kan väljas senare)</em></span><select name="_dataset"><option value="">Välj senare</option>${S.datasets.map((d) => `<option value="${esc(d.id)}">${esc(d.namn)} (${num(d.antal)} poster)</option>`).join("")}</select></label>
          <label class="check" style="align-self:end;padding-bottom:8px"><input type="checkbox" name="_start"> Starta träningen direkt när modellen har skapats</label>
        </div>`}`,
    footer: `<button class="btn" data-close>Avbryt</button><button class="btn primary" id="model-save">${edit ? "Spara" : "Skapa modell"}</button>`,
  });
  const el = m.el;
  let preset = edit ? null : P.mallar[0];
  const spec = () => {
    const f = formData(el);
    const out = { architecture: f.architecture, n_layers: f.n_layers, n_heads: f.n_heads, context_length: f.context_length, vocab_size: f.vocab_size, dropout: f.dropout };
    if (f._manual) out.d_model = f.d_model; else out.target_params = f.target_params;
    return { f, out };
  };
  let estTimer;
  const estimate = () => {
    if (isExtern(existing)) {
      $("#est-params", el).textContent = num(a.n_params);
      $("#est-detail", el).innerHTML = `d_model ${a.d_model} · ${a.n_layers} lager · ${a.n_heads} heads<br>importerad från Kaggle – arkitekturen är fast`;
      $("#arch-hint", el).textContent = S.presets?.externa_arkitekturer?.["gpt-l3"]?.description || "";
      return;
    }
    const { f, out } = spec();
    $("#dmodel-field", el).hidden = !f._manual;
    $("[name=target_params]", el).disabled = f._manual;
    const info = P.arkitekturer[f.architecture];
    $("[name=n_heads]", el).disabled = !info.uses_heads;
    $("#arch-hint", el).textContent = info.description;
    clearTimeout(estTimer);
    estTimer = setTimeout(async () => {
      try {
        const r = await api("POST", "/api/models/estimate", out);
        $("#est-params", el).textContent = num(r.n_params);
        $("#est-detail", el).innerHTML = `d_model ${r.d_model} · ${r.n_layers} lager${r.architecture === "gpt" ? ` · ${r.n_heads} heads (${r.d_model / r.n_heads} dim/head)` : ""}<br>ca ${bytes(r.n_params * 4)} per checkpoint`;
        $("#model-save", el).disabled = false;
      } catch (e) {
        $("#est-params", el).textContent = "–";
        $("#est-detail", el).innerHTML = `<span style="color:var(--bad)">${esc(e.message)}</span>`;
        $("#model-save", el).disabled = true;
      }
    }, 150);
  };
  el.addEventListener("input", (e) => { if (e.target.name !== "_preset") estimate(); });
  if (!edit) {
    const applyPreset = (p) => {
      preset = p;
      const src = p || { namn: "", beskrivning: "", anvandningsomrade: "", sprak: "Svenska" };
      for (const k of ["namn", "beskrivning", "anvandningsomrade", "sprak", "architecture", "target_params", "n_layers", "n_heads", "context_length", "vocab_size", "dropout"]) {
        if (src[k] !== undefined && $(`[name=${k}]`, el)) $(`[name=${k}]`, el).value = src[k];
      }
      $("[name=_dataset]", el).value = p?.dataset && S.datasets.some((d) => d.id === p.dataset) ? p.dataset : "";
      $("[name=_manual]", el).checked = false;
      estimate();
    };
    $("[name=_preset]", el).onchange = (e) => applyPreset(P.mallar.find((p) => p.id === e.target.value) || null);
    applyPreset(P.mallar[0]);
  } else estimate();

  $("#model-save", el).onclick = async () => {
    const { f, out } = spec();
    const body = { namn: f.namn, beskrivning: f.beskrivning, anvandningsomrade: f.anvandningsomrade, sprak: f.sprak };
    if (!locked) Object.assign(body, out);
    try {
      if (edit) {
        body.generering = { temperature: f.g_temperature, max_tokens: f.g_max_tokens, top_k: f.g_top_k };
        await api("PATCH", `/api/models/${existing.id}`, body);
        toast("Modellen har sparats");
      } else {
        if (preset?.training) body.training = preset.training;
        if (f._dataset) body.dataset = f._dataset;
        const created = await api("POST", "/api/models", body);
        toast(`${created.namn} har skapats med ${num(created.arkitektur.n_params)} parametrar`);
        if (f._dataset && f._start) {
          const params = { ...(P.standard_traning), ...(preset?.training || {}) };
          const run = await api("POST", "/api/training/start", { model_id: created.id, dataset_id: f._dataset, params });
          m.close(); await refresh(); return go("traning", { runId: run.run_id });
        }
        if (f._dataset) { m.close(); await refresh(); return go("traning", { modelId: created.id }); }
      }
      m.close(); await refresh(); go(S.view === "oversikt" ? "modeller" : S.view);
    } catch (e) { fail(e); }
  };
}

async function modelDetail(id) {
  let m;
  try { m = await api("GET", `/api/models/${id}`); } catch (e) { return fail(e); }
  const a = m.arkitektur;
  const tabs = { info: "Information", filer: "Filer och kod", ckpt: `Checkpoints (${m.checkpoints.length})`, hist: `Träningshistorik (${m.historik.length})` };
  const dlg = modal({ title: m.namn, size: "wide", body: `<div class="tabs">${Object.entries(tabs).map(([k, t], i) => `<button data-tab="${k}" class="${i ? "" : "on"}">${t}</button>`).join("")}</div><div id="tab"></div>`,
    footer: `<button class="btn" data-action="export-model" data-id="${esc(m.id)}">Exportera</button><button class="btn" data-close data-action="config-model" data-id="${esc(m.id)}">Konfigurera</button>${isExtern(m) ? `<button class="btn primary" data-close data-action="chat-model" data-id="${esc(m.id)}">Chatta</button>` : `<button class="btn primary" data-close data-action="train-model" data-id="${esc(m.id)}">Träna</button>`}` });
  const show = async (tab) => {
    $$("[data-tab]", dlg.el).forEach((b) => b.classList.toggle("on", b.dataset.tab === tab));
    const box = $("#tab", dlg.el);
    if (tab === "info") {
      box.innerHTML = `<div class="grid cols-2"><dl class="kv">
          <dt>Status</dt><dd>${modelPill(m)}</dd><dt>Användningsområde</dt><dd>${esc(m.anvandningsomrade || "–")}</dd><dt>Språk</dt><dd>${esc(m.sprak || "–")}</dd>
          <dt>Ursprung</dt><dd>${m.ursprung === "importerad" ? "Importerad " + when(m.importerad) : "Skapad i kontrollpanelen"}</dd><dt>Skapad</dt><dd>${when(m.skapad)}</dd><dt>Senast ändrad</dt><dd>${when(m.andrad)}</dd>
          <dt>Tränade steg</dt><dd class="num">${num(m.steg)}</dd><dt>Senaste loss</dt><dd class="num">${dec(m.senaste_loss)}</dd><dt>Senaste val-loss</dt><dd class="num">${dec(m.senaste_val_loss)}</dd>
        </dl><dl class="kv">
          <dt>Arkitektur</dt><dd>${esc(archLabel(a.architecture))}</dd><dt>Parametrar</dt><dd class="num">${num(a.n_params)}</dd><dt>Lager</dt><dd>${a.n_layers}</dd>
          <dt>Attention heads</dt><dd>${a.architecture.startsWith("gpt") ? a.n_heads : "–"}</dd><dt>Modellbredd (d_model)</dt><dd>${a.d_model}</dd><dt>Context length</dt><dd>${num(a.context_length)} tokens</dd>
          <dt>Ordförråd</dt><dd>${num(a.vocab_size)} tokens${m.har_tokenizer ? "" : " (tokenizer tränas vid första träningen)"}</dd><dt>Dropout</dt><dd>${a.dropout}</dd><dt>Storlek på disk</dt><dd>${bytes(m.storlek)}</dd>
        </dl></div><div><div class="hint">Beskrivning</div>${esc(m.beskrivning || "–")}</div><div><div class="hint">Mapp</div><span class="mono">${esc(m.mapp)}</span></div>`;
    } else if (tab === "filer") {
      box.innerHTML = `<div class="grid" style="grid-template-columns:260px minmax(0,1fr)"><table><tbody>${m.filer.map((f) => `<tr class="${/\.(py|json|md)$/.test(f.namn) ? "click" : ""}" data-file="${esc(f.namn)}"><td class="mono">${esc(f.namn)}</td><td class="right muted num">${bytes(f.storlek)}</td></tr>`).join("")}</tbody></table><pre class="code" id="file-view">Välj en fil för att visa den.</pre></div>`;
      const open = async (name) => { try { $("#file-view", box).textContent = (await api("GET", `/api/models/${m.id}/file?${qs({ namn: name })}`)).innehall; } catch (e) { fail(e); } };
      $$("tr.click", box).forEach((tr) => (tr.onclick = () => open(tr.dataset.file)));
      open("model.py");
    } else if (tab === "ckpt") {
      box.innerHTML = m.checkpoints.length ? `<table><thead><tr><th>Fil</th><th class="right">Steg</th><th class="right">Loss</th><th class="right">Val-loss</th><th>Dataset</th><th>Sparad</th><th></th></tr></thead><tbody>${[...m.checkpoints].reverse().map((c) => `<tr><td class="mono">${esc(c.fil)} ${c.senaste ? '<span class="pill plain run">senaste</span>' : ""} ${c.bast ? '<span class="pill plain good">bästa</span>' : ""}</td><td class="right num">${num(c.step)}</td><td class="right num">${dec(c.train_loss)}</td><td class="right num">${dec(c.val_loss)}</td><td class="muted">${esc(c.dataset || "–")}</td><td class="muted">${when(c.tid)}</td><td class="right"><button class="btn small ghost danger" data-del-ckpt="${esc(c.fil)}">Ta bort</button></td></tr>`).join("")}</tbody></table>`
        : `<div class="empty"><strong>Inga checkpoints</strong>Checkpoints sparas automatiskt under träning.</div>`;
      $$("[data-del-ckpt]", box).forEach((b) => (b.onclick = async () => {
        if (!(await confirmDialog("Ta bort checkpoint", `Vill du ta bort <b>${esc(b.dataset.delCkpt)}</b>?`, "Ta bort", true))) return;
        try { m.checkpoints = (await api("DELETE", `/api/models/${m.id}/checkpoints/${b.dataset.delCkpt}`)).checkpoints; show("ckpt"); refresh(); } catch (e) { fail(e); }
      }));
    } else {
      box.innerHTML = m.historik.length ? `<table><thead><tr><th>Start</th><th>Dataset</th><th class="right">Steg</th><th class="right">Loss</th><th class="right">Val-loss</th><th>Tid</th><th>Enhet</th><th>Status</th></tr></thead><tbody>${[...m.historik].reverse().map((h) => `<tr><td>${when(h.start)}</td><td>${esc(h.dataset)}</td><td class="right num">${num(h.steg_fran)} → ${num(h.steg_till)}</td><td class="right num">${dec(h.loss)}</td><td class="right num">${dec(h.val_loss)}</td><td>${dur(h.sekunder)}</td><td class="muted">${esc(h.enhet)}</td><td>${statePill(h.status)}</td></tr>`).join("")}</tbody></table>`
        : `<div class="empty"><strong>Ingen träning ännu</strong>Här visas alla träningskörningar för modellen.</div>`;
    }
  };
  $$("[data-tab]", dlg.el).forEach((b) => (b.onclick = () => show(b.dataset.tab)));
  await ensurePresets();
  show("info");
}

const ACTIONS = {
  "new-model": () => modelForm(),
  "config-model": async (id) => { try { modelForm(await api("GET", `/api/models/${id}`)); } catch (e) { fail(e); } },
  "activate": async (id) => { try { await api("POST", "/api/active-model", { id }); await refresh(); go(S.view); } catch (e) { fail(e); } },
  "train-model": (id) => { const m = modelById(id); go("traning", m?.aktiv_korning ? { runId: m.aktiv_korning } : { modelId: id }); },
  "chat-model": (id) => go("testa", { modelId: id }),
  "export-model": (id) => { window.location.href = `/api/models/${id}/export`; toast("Exporten laddas ner som en zip-fil"); },
  "rename-model": (id) => {
    const m = modelById(id);
    const dlg = modal({ title: "Byt namn på modell", size: "narrow", body: `<label class="field"><span>Nytt namn</span><input type="text" name="namn" value="${esc(m.namn)}" maxlength="60"></label>`,
      footer: `<button class="btn" data-close>Avbryt</button><button class="btn primary" id="ok">Byt namn</button>` });
    const save = async () => { try { await api("PATCH", `/api/models/${id}`, { namn: $("[name=namn]", dlg.el).value }); dlg.close(); toast("Namnet har ändrats"); await refresh(); go(S.view); } catch (e) { fail(e); } };
    $("#ok", dlg.el).onclick = save;
    $("[name=namn]", dlg.el).onkeydown = (e) => { if (e.key === "Enter") save(); };
    $("[name=namn]", dlg.el).select();
  },
  "delete-model": async (id) => {
    const m = modelById(id);
    if (!(await confirmDialog("Ta bort modell", `Vill du ta bort <b>${esc(m.namn)}</b>? Modellens mapp med kod, konfiguration och alla checkpoints raderas permanent.`, "Ta bort", true))) return;
    try { await api("DELETE", `/api/models/${id}`); toast(`${m.namn} har tagits bort`); await refresh(); go(S.view); } catch (e) { fail(e); }
  },
  "import-model": () => {
    const dlg = modal({ title: "Importera modell", size: "narrow", body: `<p class="hint" style="margin:0">Välj en modell som exporterats från AI Control Center (.zip), <b>eller</b> Lennart 3 från Kaggle: markera <code>lennart3.pt</code> och <code>tokenizer.json</code> (gärna även <code>status.json</code>) samtidigt. Packa inte upp lennart3.pt – den är ett zip-arkiv inuti, och det får den vara. Kod i filerna körs aldrig – modellkoden genereras av panelen.</p><label class="field"><span>Namn <em>(valfritt)</em></span><input type="text" name="namn" placeholder="Behåll namnet i filen"></label>
      <div class="section-title">Stora modeller – rekommenderas för Lennart 3</div>
      <div class="hint" id="imp-folder">Läser mappen …</div>
      <div class="btn-row"><button class="btn" id="imp-scan">Sök igen</button><button class="btn primary" id="imp-folder-ok" disabled>Importera från mappen</button></div>
      <div class="section-title">Eller välj filer</div>
      <label class="field"><span>Filer</span><input type="file" name="fil" accept=".zip,.pt,.json,.txt" multiple></label><div class="hint" id="imp-status"></div>`,
      footer: `<button class="btn" data-close>Avbryt</button><button class="btn" id="ok">Importera valda filer</button>` });
    const scan = async () => {
      try {
        const r = await api("GET", "/api/models/import-folder");
        $("#imp-folder", dlg.el).innerHTML = `Lägg filerna i <code>${esc(r.mapp)}</code> – de läses direkt från disken, vilket fungerar även för filer på flera GB. ` +
          (r.filer.length ? `<br>I mappen: ${r.filer.map((f) => `<b>${esc(f.namn)}</b> (${bytes(f.storlek)})`).join(", ")}` : "<br>Mappen är tom just nu.");
        $("#imp-folder-ok", dlg.el).disabled = !r.redo;
      } catch (e) { $("#imp-folder", dlg.el).textContent = e.message; }
    };
    scan();
    $("#imp-scan", dlg.el).onclick = scan;
    $("#imp-folder-ok", dlg.el).onclick = async () => {
      const btn = $("#imp-folder-ok", dlg.el);
      btn.disabled = true;
      $("#imp-status", dlg.el).innerHTML = '<span class="loader"><span class="orb sm"></span>Importerar från mappen …</span>';
      try {
        const m = await api("POST", `/api/models/import-folder?${qs({ namn: $("[name=namn]", dlg.el).value })}`, new Blob([]));
        dlg.close(); toast(`${m.namn} har importerats`); await refresh(); go("modeller");
      } catch (e) { btn.disabled = false; $("#imp-status", dlg.el).textContent = ""; fail(e); }
    };
    $("#ok", dlg.el).onclick = async () => {
      const files = [...$("[name=fil]", dlg.el).files];
      if (!files.length) return toast("Välj en fil först", true);
      const total = files.reduce((n, f) => n + f.size, 0);
      if (total > 1.5 * 1024 ** 3) return toast(`Filerna är ${bytes(total)} – för stort att skicka genom fönstret. Använd mappen ovan i stället.`, true);
      const namn = $("[name=namn]", dlg.el).value;
      const btn = $("#ok", dlg.el);
      btn.disabled = true;
      $("#imp-status", dlg.el).innerHTML = '<span class="loader"><span class="orb sm"></span>Importerar … stora modeller kan ta en minut</span>';
      try {
        let m;
        if (files.length === 1 && files[0].name.toLowerCase().endsWith(".zip")) {
          m = await api("POST", `/api/models/import?${qs({ namn })}`, files[0]);
        } else {
          // Roll efter filnamn – tål "tokenizer (1).json" och att webbläsaren döpt om lennart3.pt till .zip.
          const role = (f) => {
            const n = f.name.toLowerCase();
            if (n.endsWith(".json") || n.endsWith(".txt")) return n.includes("tokenizer") ? "tokenizer.json" : n.includes("status") ? "status.json" : n.includes("config") ? "config.json" : null;
            return n.endsWith(".pt") || n.endsWith(".zip") || n.endsWith(".bin") ? "lennart3.pt" : null;
          };
          const roles = files.map(role);
          if (roles.includes(null)) throw new Error(`Okänd fil: ${files[roles.indexOf(null)].name}. Välj lennart3.pt, tokenizer.json och status.json.`);
          if (roles.filter((r) => r === "lennart3.pt").length !== 1) throw new Error("Välj exakt en modellfil (lennart3.pt – den kan heta .zip om webbläsaren döpt om den).");
          if (!roles.includes("tokenizer.json")) throw new Error("Markera även tokenizer.json (håll Ctrl nedtryckt när du väljer).");
          if (new Set(roles).size !== roles.length) throw new Error("Samma sorts fil är vald två gånger.");
          const delar = files.map((f, i) => `${roles[i]}:${f.size}`).join(",");
          m = await api("POST", `/api/models/import-lennart3?${qs({ namn, delar })}`, new Blob(files));
        }
        dlg.close(); toast(`${m.namn} har importerats`); await refresh(); go("modeller");
      } catch (e) { btn.disabled = false; $("#imp-status", dlg.el).textContent = ""; fail(e); }
    };
  },
  "import-dataset": () => importDataset(),
};

// ───────────────────────────────────────────────────────────── träning
async function viewTraining(arg = {}) {
  const T = S.train;
  const P = await ensurePresets();
  if (arg.runId) T.runId = arg.runId;
  else if (arg.modelId) { T.model = arg.modelId; T.runId = modelById(arg.modelId)?.aktiv_korning || null; }
  else if (!T.runId) T.runId = (S.runs.find((r) => r.aktiv) || S.runs[0])?.run_id || null;
  if (!T.model || !modelById(T.model)) T.model = (T.runId && S.runs.find((r) => r.run_id === T.runId)?.model_id) || S.active || S.models[0]?.id || null;
  if (S.view !== "traning") return;
  const dev = S.system?.enheter;
  const d = P.standard_traning;
  const field = (name, label, value, extra = "") => `<label class="field"><span>${label}</span><input type="number" name="${name}" value="${value}" ${extra}></label>`;

  $("#view").innerHTML = `
    <div class="grid split">
      <div class="panel"><header><h2>Ny träning</h2></header><div class="body grid" id="train-form">
        ${S.models.length ? "" : `<div class="hint">Skapa en modell först under Modeller.</div>`}
        <label class="field"><span>Modell</span><select name="model_id">${modelOptions(T.model)}</select></label>
        <label class="field"><span>Dataset</span><select name="dataset_id">${S.datasets.map((x) => `<option value="${esc(x.id)}">${esc(x.namn)} (${num(x.antal)} poster)</option>`).join("")}</select><span class="hint" id="ds-hint"></span></label>
        <label class="field"><span>Starta från</span><select name="resume_from"></select></label>
        <div class="form-grid">
          ${field("max_steps", "Antal steg", d.max_steps, 'min="1"')}
          ${field("batch_size", "Batchstorlek", d.batch_size, 'min="1"')}
          ${field("learning_rate", "Inlärningshastighet", d.learning_rate, 'step="any" min="0"')}
          <label class="field"><span>Enhet</span><select name="device">${(dev?.val || [{ id: "auto", namn: "Automatiskt" }, { id: "cpu", namn: "CPU" }]).map((o) => `<option value="${o.id}">${esc(o.namn)}</option>`).join("")}</select></label>
        </div>
        <details class="adv"><summary>Avancerade parametrar</summary><div class="form-grid">
          ${field("weight_decay", "Weight decay", d.weight_decay, 'step="any" min="0"')}
          ${field("warmup_steps", "Uppvärmningssteg", d.warmup_steps, 'min="0"')}
          ${field("grad_clip", "Gradientklippning", d.grad_clip, 'step="any" min="0"')}
          ${field("eval_interval", "Validera var N:e steg", d.eval_interval, 'min="1"')}
          ${field("checkpoint_interval", "Checkpoint var N:e steg", d.checkpoint_interval, 'min="1"')}
          ${field("keep_checkpoints", "Behåll antal checkpoints", d.keep_checkpoints, 'min="1"')}
          ${field("seed", "Slumpfrö", d.seed, 'min="0"')}
          ${field("threads", "CPU-trådar (0 = auto)", d.threads, 'min="0"')}
        </div></details>
        <button class="btn primary" id="train-start" ${S.models.length && S.datasets.length ? "" : "disabled"}>Starta träning</button>
        <div class="hint">Träningen körs i en egen process och fortsätter även om fönstret stängs.</div>
      </div></div>
      <div class="grid" style="min-width:0">
        <div class="panel" id="monitor"></div>
        <div class="panel"><header><h2>Körningar</h2></header><div id="run-list"></div></div>
      </div>
    </div>`;

  const form = $("#train-form");
  const syncModel = async () => {
    const id = $("[name=model_id]", form).value;
    if (!id) return;
    T.model = id;
    const sel = $("[name=resume_from]", form);
    let cks = [];
    try { cks = (await api("GET", `/api/models/${id}/checkpoints`)).checkpoints; } catch { /* tom lista */ }
    sel.innerHTML = cks.length
      ? `<option value="senaste">Fortsätt från senaste checkpoint (steg ${num(cks[cks.length - 1].step)})</option>${[...cks].reverse().slice(1).map((c) => `<option value="${esc(c.fil)}">Fortsätt från steg ${num(c.step)}${c.bast ? " (bästa)" : ""}</option>`).join("")}<option value="">Börja om från början (raderar tidigare vikter)</option>`
      : `<option value="">Från början (ny träning)</option>`;
    const m = modelById(id);
    if (m && !m.tranad && m.forslag) {
      if (m.forslag.dataset && S.datasets.some((x) => x.id === m.forslag.dataset)) $("[name=dataset_id]", form).value = m.forslag.dataset;
      for (const [k, val] of Object.entries(m.forslag.traning || {})) if ($(`[name=${k}]`, form)) $(`[name=${k}]`, form).value = val;
    }
    syncDataset();
  };
  const syncDataset = () => {
    const ds = S.datasets.find((x) => x.id === $("[name=dataset_id]", form).value);
    $("#ds-hint", form).textContent = !ds ? "Importera ett dataset under Dataset." : ds.uppdelning
      ? `Uppdelat: ${num(ds.uppdelning.train)} träning · ${num(ds.uppdelning.val)} validering · ${num(ds.uppdelning.test)} test`
      : "Inte uppdelat – 5 % hålls automatiskt undan för validering.";
  };
  $("[name=model_id]", form).onchange = syncModel;
  $("[name=dataset_id]", form).onchange = syncDataset;
  await syncModel();

  $("#train-start").onclick = async () => {
    const f = formData(form);
    const body = { model_id: f.model_id, dataset_id: f.dataset_id, resume_from: f.resume_from || null, params: f };
    const m = modelById(f.model_id);
    if (!f.resume_from && m?.tranad) {
      if (!(await confirmDialog("Börja om från början", `<b>${esc(m.namn)}</b> är redan tränad. Om du börjar om raderas modellens checkpoints och tokenizer, och allt tränas på nytt.`, "Börja om", true))) return;
      body.restart = true;
    }
    try {
      const run = await api("POST", "/api/training/start", body);
      toast("Träningen har startat");
      selectRun(run.run_id);
      await refresh(); drawRuns(); syncModel();
    } catch (e) { fail(e); }
  };

  const drawRuns = () => {
    $("#run-list").innerHTML = S.runs.length ? `<table><thead><tr><th>Start</th><th>Modell</th><th>Dataset</th><th class="right">Steg</th><th class="right">Loss</th><th>Status</th><th></th></tr></thead><tbody>
      ${S.runs.map((r) => `<tr class="click ${r.run_id === T.runId ? "sel" : ""}" data-run="${esc(r.run_id)}"><td>${when(r.started)}</td><td><b>${esc(r.model_namn)}</b></td><td class="muted">${esc(r.dataset_namn)}</td><td class="right num">${num(r.step)} / ${num(r.max_steps)}</td><td class="right num">${dec(r.loss)}</td><td>${statePill(r.state)}</td><td class="right">${r.aktiv ? "" : `<button class="btn small ghost danger" data-del-run="${esc(r.run_id)}">Ta bort</button>`}</td></tr>`).join("")}
      </tbody></table>` : `<div class="empty"><strong>Inga körningar ännu</strong>Välj modell och dataset till vänster och starta en träning.</div>`;
  };
  const selectRun = (id) => {
    T.runId = id; T.metrics = []; T.logOffset = 0; T.log = ""; T.drawn = null;
    drawRuns(); poll();
  };
  $("#run-list").onclick = async (e) => {
    const del = e.target.closest("[data-del-run]");
    if (del) {
      e.stopPropagation();
      if (!(await confirmDialog("Ta bort körning", "Körningens logg och mätvärden raderas. Modellens checkpoints påverkas inte.", "Ta bort", true))) return;
      try { await api("DELETE", `/api/training/runs/${del.dataset.delRun}`); if (T.runId === del.dataset.delRun) T.runId = null; await refresh(); drawRuns(); if (!T.runId) drawMonitor(null); } catch (err) { fail(err); }
      return;
    }
    const tr = e.target.closest("[data-run]");
    if (tr) selectRun(tr.dataset.run);
  };

  const drawMonitor = (st) => {
    const box = $("#monitor");
    if (!box) return;
    if (!st) { box.innerHTML = `<header><h2>Träningsförlopp</h2></header><div class="empty"><strong>Ingen körning vald</strong>Starta en träning eller välj en körning i listan.</div>`; T.drawn = null; return; }
    if (T.drawn !== st.run_id) {
      T.drawn = st.run_id;
      box.innerHTML = `<header><div><h2 id="m-title"></h2><div class="muted" style="font-size:12.5px" id="m-sub"></div></div><div class="btn-row" id="m-actions"></div></header>
        <div class="body grid">
          <div><div class="run-head"><span id="m-msg" class="muted"></span><b class="num" id="m-pct"></b></div><div class="bar" style="margin-top:6px"><i id="m-bar"></i></div></div>
          <div class="metrics" id="m-metrics"></div>
          <div><div class="run-head" style="margin-bottom:6px"><h3>Loss</h3><div class="legend"><span><i style="background:var(--accent)"></i>Träning</span><span><i style="background:var(--warn)"></i>Validering</span></div></div>
            <div class="chart-wrap"><canvas id="chart"></canvas></div></div>
          <div><h3 style="margin-bottom:6px">Logg</h3><pre class="code log" id="m-log"></pre></div>
          <div id="m-ckpt"></div>
        </div>`;
      $("#m-actions").onclick = async (e) => {
        const b = e.target.closest("[data-cmd]");
        if (!b) return;
        const cmd = b.dataset.cmd;
        if (cmd === "stop" && !(await confirmDialog("Avbryt träning", "Träningen avbryts och en checkpoint sparas så att du kan fortsätta senare.", "Avbryt träningen", true))) return;
        if (cmd === "kill" && !(await confirmDialog("Tvinga avslut", "Processen stängs omedelbart utan att spara. Använd bara om träningen inte svarar.", "Tvinga avslut", true))) return;
        try { await api("POST", `/api/training/runs/${st.run_id}/${cmd}`); poll(); } catch (err) { fail(err); }
      };
      T.ckptKey = null;
    }
    $("#m-title").innerHTML = `${esc(st.model_namn)} ${statePill(st.state)}`;
    $("#m-sub").textContent = `${st.dataset_namn} · startad ${when(st.started)}${st.resume_from ? ` · fortsätter från ${st.resume_from}` : ""}`;
    const pct = st.max_steps ? (100 * (st.step || 0)) / st.max_steps : 0;
    $("#m-msg").textContent = st.state === "failed" ? `${st.message}: ${st.error || ""}` : st.message || "";
    $("#m-msg").style.color = st.state === "failed" ? "var(--bad)" : "";
    $("#m-pct").textContent = `${dec(pct, 1)} %`;
    $("#m-bar").style.width = pct + "%";
    $("#m-bar").parentElement.className = "bar" + (st.state === "completed" ? " good" : st.state === "paused" || st.state === "stopped" ? " warn" : "");
    $("#m-metrics").innerHTML = [
      ["Steg", `${num(st.step)} / ${num(st.max_steps)}`], ["Loss", dec(st.loss)], ["Val-loss", dec(st.val_loss)],
      ["Hastighet", st.tokens_per_sec ? compact(Math.round(st.tokens_per_sec)) + " tok/s" : "–"],
      ["Tid", dur(st.elapsed)], [st.aktiv ? "Återstår" : "Enhet", st.aktiv ? dur(st.eta) : (st.device || "–")],
    ].map(([l, v]) => `<div><span>${l}</span><b>${esc(v)}</b></div>`).join("");
    const acts = [];
    if (st.state === "running") acts.push('<button class="btn small" data-cmd="pause">Pausa</button>');
    if (st.state === "paused") acts.push('<button class="btn small primary" data-cmd="resume">Fortsätt</button>');
    if (st.aktiv && st.state !== "stopping") acts.push('<button class="btn small danger" data-cmd="stop">Avbryt</button>');
    if (st.aktiv) acts.push('<button class="btn small ghost" data-cmd="kill" title="Stäng processen utan att spara">Tvinga avslut</button>');
    if (!st.aktiv && modelById(st.model_id)?.tranad) acts.push(`<button class="btn small primary" data-action="chat-model" data-id="${esc(st.model_id)}">Testa i chatten</button>`);
    const html = acts.join("");
    if ($("#m-actions").dataset.html !== html) { $("#m-actions").innerHTML = html; $("#m-actions").dataset.html = html; }
    const logEl = $("#m-log");
    if (logEl.textContent.length !== T.log.length) {
      const stick = logEl.scrollTop + logEl.clientHeight >= logEl.scrollHeight - 30;
      logEl.textContent = T.log;
      if (stick) logEl.scrollTop = logEl.scrollHeight;
    }
    drawChart($("#chart"), T.metrics);
  };
  const drawCkpts = async (st) => {
    const key = `${st.run_id}:${st.global_step}:${st.state}`;
    if (T.ckptKey === key || !$("#m-ckpt")) return;
    T.ckptKey = key;
    let cks = [];
    try { cks = (await api("GET", `/api/models/${st.model_id}/checkpoints`)).checkpoints; } catch { return; }
    if (!$("#m-ckpt")) return;
    $("#m-ckpt").innerHTML = `<h3 style="margin-bottom:6px">Checkpoints för ${esc(st.model_namn)}</h3>` + (cks.length
      ? `<table><thead><tr><th>Fil</th><th class="right">Steg</th><th class="right">Loss</th><th class="right">Val-loss</th><th>Sparad</th></tr></thead><tbody>${[...cks].reverse().map((c) => `<tr><td class="mono">${esc(c.fil)} ${c.senaste ? '<span class="pill plain run">senaste</span>' : ""} ${c.bast ? '<span class="pill plain good">bästa</span>' : ""}</td><td class="right num">${num(c.step)}</td><td class="right num">${dec(c.train_loss)}</td><td class="right num">${dec(c.val_loss)}</td><td class="muted">${when(c.tid)}</td></tr>`).join("")}</tbody></table>`
      : `<div class="hint">Inga checkpoints sparade ännu.</div>`);
  };

  let polling = false, lastState = null;
  const poll = async () => {
    if (polling || S.view !== "traning") return;
    if (!T.runId) return drawMonitor(null);
    polling = true;
    const id = T.runId;
    try {
      const r = await api("GET", `/api/training/runs/${id}?${qs({ metrics_from: T.metrics.length, log_offset: T.logOffset })}`);
      if (id !== T.runId || S.view !== "traning") return;
      T.metrics.push(...r.metrics); T.log = (T.log + r.log).slice(-200000); T.logOffset = r.log_offset;
      drawMonitor(r.status); drawCkpts(r.status);
      if (lastState !== `${id}:${r.status.state}`) { lastState = `${id}:${r.status.state}`; await refresh(); drawRuns(); if (!r.status.aktiv) syncModel(); }
    } catch (e) {
      if (/finns inte/.test(e.message)) { T.runId = null; drawMonitor(null); }
    } finally { polling = false; }
  };
  drawRuns();
  T.metrics = []; T.logOffset = 0; T.log = ""; T.drawn = null;
  poll();
  let n = 0;
  T.timer = setInterval(async () => { poll(); if (++n % 5 === 0) { try { await refresh(); drawRuns(); } catch { /* ignorera */ } } }, 1000);
  window.onresize = () => { if (S.view === "traning" && $("#chart")) drawChart($("#chart"), T.metrics); };
}

function drawChart(canvas, metrics) {
  if (!canvas) return;
  const dpr = window.devicePixelRatio || 1;
  const W = canvas.clientWidth, H = canvas.clientHeight;
  if (!W || !H) return;
  if (canvas.width !== W * dpr || canvas.height !== H * dpr) { canvas.width = W * dpr; canvas.height = H * dpr; }
  const g = canvas.getContext("2d");
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, W, H);
  const train = metrics.filter((m) => m.loss != null), val = metrics.filter((m) => m.val_loss != null);
  g.font = "11px 'Segoe UI', system-ui, sans-serif";
  if (!train.length) { g.fillStyle = "#5d6a7c"; g.textAlign = "center"; g.fillText("Väntar på första mätvärdet …", W / 2, H / 2); return; }
  const pad = { l: 44, r: 26, t: 12, b: 26 };
  const xs = [...train.map((m) => m.step), ...val.map((m) => m.step)];
  const ys = [...train.map((m) => m.loss), ...val.map((m) => m.val_loss)];
  let x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.min(...ys), y1 = Math.max(...ys);
  if (x1 === x0) x1 = x0 + 1;
  const span = y1 - y0 || 1; y0 = Math.max(0, y0 - span * 0.06); y1 += span * 0.06;
  const X = (v) => pad.l + ((v - x0) / (x1 - x0)) * (W - pad.l - pad.r);
  const Y = (v) => pad.t + (1 - (v - y0) / (y1 - y0)) * (H - pad.t - pad.b);
  g.strokeStyle = "#1e2835"; g.fillStyle = "#8d99ab"; g.lineWidth = 1;
  g.textAlign = "right"; g.textBaseline = "middle";
  for (let i = 0; i <= 4; i++) {
    const v = y0 + ((y1 - y0) * i) / 4, y = Math.round(Y(v)) + 0.5;
    g.beginPath(); g.moveTo(pad.l, y); g.lineTo(W - pad.r, y); g.stroke();
    g.fillText(v.toLocaleString("sv-SE", { maximumFractionDigits: 2, minimumFractionDigits: 2 }), pad.l - 8, y);
  }
  g.textAlign = "center"; g.textBaseline = "top";
  for (let i = 0; i <= 4; i++) { const v = Math.round(x0 + ((x1 - x0) * i) / 4); g.fillText(nf.format(v), X(v), H - pad.b + 8); }
  const line = (pts, color, key, dots) => {
    if (!pts.length) return;
    g.strokeStyle = color; g.fillStyle = color; g.lineWidth = 2; g.lineJoin = "round";
    g.beginPath();
    pts.forEach((m, i) => (i ? g.lineTo(X(m.step), Y(m[key])) : g.moveTo(X(m.step), Y(m[key]))));
    g.stroke();
    if (dots || pts.length === 1) pts.forEach((m) => { g.beginPath(); g.arc(X(m.step), Y(m[key]), 3, 0, 7); g.fill(); });
  };
  line(train, "#4c8dff", "loss", false);
  line(val, "#e0a93b", "val_loss", true);
}

// ───────────────────────────────────────────────────────────── chatt
function viewChat(arg = {}) {
  const C = S.chat;
  const trained = S.models.filter((m) => m.tranad);
  const pick = () => (modelById(S.active)?.tranad ? S.active : trained[0]?.id) || null;
  C.panels = C.panels.filter((p) => modelById(p.model_id)?.tranad);
  if (arg.modelId) { C.panels = [{ model_id: arg.modelId, checkpoint: "senaste", messages: [] }]; C.sessionId = null; C.sessionName = ""; applyDefaults(arg.modelId); }
  if (!C.panels.length && pick()) { C.panels = [{ model_id: pick(), checkpoint: "senaste", messages: [] }]; applyDefaults(pick()); }
  function applyDefaults(id) { const g = modelById(id)?.generering; if (g) Object.assign(C.settings, { temperature: g.temperature, max_tokens: g.max_tokens, top_k: g.top_k }); }

  if (!trained.length) {
    $("#view").innerHTML = `<div class="panel empty"><strong>Ingen tränad modell att testa</strong>Träna en modell först – sedan kan du chatta med den här.<div style="margin-top:12px"><button class="btn primary" data-view="traning">Gå till träning</button></div></div>`;
    return;
  }
  const s = C.settings;
  $("#view").innerHTML = `<div class="chat-layout">
    <div class="chat-side">
      <div class="panel"><header><h2>Inställningar</h2></header><div class="body grid">
        <label class="field"><span class="range-row"><span>Temperatur</span><b id="t-val" class="num">${dec(s.temperature, 2)}</b></span><input type="range" id="temperature" min="0" max="1.5" step="0.05" value="${s.temperature}"><span class="hint">0 = alltid mest sannolika ordet, högre = mer variation</span></label>
        <label class="field"><span>Max tokens</span><input type="number" id="max_tokens" min="1" max="4096" value="${s.max_tokens}"></label>
        <label class="field"><span>Top-k <em>(0 = av)</em></span><input type="number" id="top_k" min="0" max="1000" value="${s.top_k}"></label>
        <label class="field"><span>Läge</span><select id="mode"><option value="chatt" ${s.mode === "chatt" ? "selected" : ""}>Chatt (fråga/svar)</option><option value="text" ${s.mode === "text" ? "selected" : ""}>Fortsätt texten</option></select></label>
      </div></div>
      <div class="panel"><header><h2>Testsessioner</h2></header><div class="body grid">
        <div class="btn-row"><button class="btn small primary" id="save-session">Spara session</button><button class="btn small" id="new-chat">Ny chatt</button></div>
        <div class="hint" id="session-now"></div>
        <div class="session-list" id="sessions"></div>
      </div></div>
    </div>
    <div class="chat-main">
      <div class="toolbar" style="margin-bottom:10px"><p>Samma fråga skickas till alla valda modeller så att svaren kan jämföras sida vid sida.</p><button class="btn small" id="add-panel">+ Lägg till modell för jämförelse</button></div>
      <div class="chat-cols" id="cols"></div>
      <div class="composer"><textarea id="prompt" rows="1" placeholder="Skriv ett meddelande … (Enter skickar, Skift+Enter ger ny rad)"></textarea><button class="btn primary" id="send">Skicka</button></div>
    </div></div>`;
  $("#view").style.overflow = "hidden";

  const ckptOptions = async (p) => {
    try {
      const cks = (await api("GET", `/api/models/${p.model_id}/checkpoints`)).checkpoints;
      return `<option value="senaste">Senaste</option><option value="basta">Bästa</option>${[...cks].reverse().map((c) => `<option value="${esc(c.fil)}">Steg ${num(c.step)}</option>`).join("")}`;
    } catch { return `<option value="senaste">Senaste</option>`; }
  };
  const msgHtml = (m) => `<div class="msg ${m.role} ${m.error ? "error" : ""}">${esc(m.content)}${m.pending ? (m.content ? '<span class="cursor"></span>' : LOADER_ORB) : ""}${m.info ? `<span class="info">${esc(m.info)}</span>` : ""}</div>`;
  const drawCols = async () => {
    $("#cols").innerHTML = C.panels.map((p, i) => `<div class="panel chat-col" data-i="${i}"><header><select class="mdl" title="Modell">${modelOptions(p.model_id, true)}</select><select class="ckpt" title="Checkpoint"></select>${C.panels.length > 1 ? '<button class="btn small ghost" data-remove title="Ta bort panelen">✕</button>' : ""}</header>
      <div class="msgs">${p.messages.length ? p.messages.map(msgHtml).join("") : `<div class="empty"><strong>${esc(modelById(p.model_id)?.namn || "")}</strong>Skriv en fråga nedan för att börja.</div>`}</div></div>`).join("");
    $("#add-panel").disabled = C.panels.length >= 4 || C.busy;
    $$("#cols .msgs").forEach((el) => (el.scrollTop = el.scrollHeight));
    await Promise.all(C.panels.map(async (p, i) => {
      const sel = $(`#cols [data-i="${i}"] .ckpt`);
      const html = await ckptOptions(p);
      if (sel) { sel.innerHTML = html; sel.value = p.checkpoint; if (sel.selectedIndex < 0) { sel.value = "senaste"; p.checkpoint = "senaste"; } }
    }));
  };
  $("#cols").onchange = (e) => {
    const i = +e.target.closest("[data-i]").dataset.i;
    if (e.target.classList.contains("mdl")) { C.panels[i].model_id = e.target.value; C.panels[i].checkpoint = "senaste"; drawCols(); }
    else C.panels[i].checkpoint = e.target.value;
  };
  $("#cols").onclick = (e) => {
    if (!e.target.closest("[data-remove]") || C.busy) return;
    C.panels.splice(+e.target.closest("[data-i]").dataset.i, 1); drawCols();
  };
  $("#add-panel").onclick = () => {
    const used = new Set(C.panels.map((p) => p.model_id));
    const next = trained.find((m) => !used.has(m.id)) || trained[0];
    C.panels.push({ model_id: next.id, checkpoint: "senaste", messages: C.panels[0].messages.filter((m) => m.role === "user").length ? [] : [] });
    drawCols();
  };
  $("#temperature").oninput = (e) => { s.temperature = +e.target.value; $("#t-val").textContent = dec(s.temperature, 2); };
  $("#max_tokens").onchange = (e) => (s.max_tokens = Math.max(1, +e.target.value || 150));
  $("#top_k").onchange = (e) => (s.top_k = Math.max(0, +e.target.value || 0));
  $("#mode").onchange = (e) => (s.mode = e.target.value);

  const setBusy = (b) => { C.busy = b; $("#send").textContent = b ? "Stoppa" : "Skicka"; $("#send").classList.toggle("danger", b); $("#send").classList.toggle("primary", !b); $("#add-panel").disabled = b || C.panels.length >= 4; };
  const stream = async (p, i) => {
    const history = p.messages.filter((m) => !m.error).map(({ role, content }) => ({ role, content }));
    const msg = { role: "assistant", content: "", pending: true };
    p.messages.push(msg);
    const col = $(`#cols [data-i="${i}"] .msgs`);
    $(".empty", col)?.remove();
    const node = document.createElement("div");
    col.append(node);
    const paint = () => { node.className = `msg assistant ${msg.error ? "error" : ""}`; node.innerHTML = esc(msg.content) + (msg.pending ? (msg.content ? '<span class="cursor"></span>' : LOADER_ORB) : "") + (msg.info ? `<span class="info">${esc(msg.info)}</span>` : ""); col.scrollTop = col.scrollHeight; };
    paint();
    const ctrl = new AbortController();
    C.aborts.push(ctrl);
    try {
      const res = await fetch("/api/chat", { method: "POST", signal: ctrl.signal, headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ model_id: p.model_id, checkpoint: p.checkpoint, messages: history, ...s }) });
      if (!res.ok) throw new Error((await res.json().catch(() => ({}))).fel || `Fel ${res.status}`);
      const reader = res.body.getReader(), td = new TextDecoder();
      let buf = "", meta = {};
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += td.decode(value, { stream: true });
        let k;
        while ((k = buf.indexOf("\n\n")) >= 0) {
          const line = buf.slice(0, k); buf = buf.slice(k + 2);
          if (!line.startsWith("data: ")) continue;
          const ev = JSON.parse(line.slice(6));
          if (ev.typ === "start") meta = ev;
          else if (ev.typ === "token") { msg.content += ev.text; paint(); }
          else if (ev.typ === "klar") msg.info = `${meta.modell} · steg ${num(meta.steg)} · ${ev.tokens} tokens · ${dec(ev.sekunder, 1)} s${ev.tokens_per_sek ? ` · ${dec(ev.tokens_per_sek, 0)} tok/s` : ""}`;
          else if (ev.typ === "fel") throw new Error(ev.fel);
        }
      }
      if (!msg.content.trim() && !msg.info) msg.info = "Inget svar";
    } catch (e) {
      if (e.name === "AbortError") msg.info = "Stoppad";
      else { msg.error = true; msg.content = msg.content || e.message; }
    } finally { msg.pending = false; msg.content = msg.content.trim() || (msg.error ? msg.content : "(tomt svar)"); paint(); }
  };
  const send = async () => {
    if (C.busy) { C.aborts.forEach((a) => a.abort()); return; }
    const text = $("#prompt").value.trim();
    if (!text) return;
    $("#prompt").value = ""; $("#prompt").style.height = "";
    C.aborts = [];
    setBusy(true);
    C.panels.forEach((p, i) => { p.messages.push({ role: "user", content: text }); const col = $(`#cols [data-i="${i}"] .msgs`); $(".empty", col)?.remove(); col.insertAdjacentHTML("beforeend", msgHtml({ role: "user", content: text })); });
    await Promise.all(C.panels.map(stream));
    if (S.view === "testa") { setBusy(false); $("#prompt").focus(); } else C.busy = false;
  };
  $("#send").onclick = send;
  $("#prompt").onkeydown = (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } };
  $("#prompt").oninput = (e) => { e.target.style.height = ""; e.target.style.height = Math.min(160, e.target.scrollHeight + 2) + "px"; };

  const drawSessions = async () => {
    let list = [];
    try { list = (await api("GET", "/api/sessions")).sessioner; } catch { /* tom */ }
    if (!$("#sessions")) return;
    $("#session-now").textContent = C.sessionId ? `Öppen session: ${C.sessionName}` : "Den här chatten är inte sparad.";
    $("#sessions").innerHTML = list.length ? list.map((x) => `<div class="item" data-sid="${esc(x.id)}"><div style="min-width:0"><div style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(x.namn)}</div><small>${esc((x.modeller || []).join(", "))} · ${x.antal_meddelanden} meddelanden</small></div><button class="btn small ghost danger" data-del title="Ta bort">✕</button></div>`).join("") : `<div class="hint">Inga sparade sessioner.</div>`;
  };
  $("#sessions").onclick = async (e) => {
    const item = e.target.closest("[data-sid]");
    if (!item || C.busy) return;
    const sid = item.dataset.sid;
    try {
      if (e.target.closest("[data-del]")) {
        if (!(await confirmDialog("Ta bort session", "Vill du ta bort den sparade sessionen?", "Ta bort", true))) return;
        await api("DELETE", `/api/sessions/${sid}`);
        if (C.sessionId === sid) { C.sessionId = null; C.sessionName = ""; }
      } else {
        const ses = await api("GET", `/api/sessions/${sid}`);
        const fallback = pick();
        C.panels = ses.paneler.map((p) => ({ model_id: modelById(p.model_id)?.tranad ? p.model_id : fallback, checkpoint: "senaste", messages: p.meddelanden || [] }));
        Object.assign(C.settings, ses.installningar || {});
        C.sessionId = ses.id; C.sessionName = ses.namn;
        return viewChat();
      }
    } catch (err) { fail(err); }
    drawSessions();
  };
  $("#save-session").onclick = () => {
    if (!C.panels.some((p) => p.messages.length)) return toast("Det finns inget samtal att spara ännu", true);
    const dlg = modal({ title: "Spara testsession", size: "narrow", body: `<label class="field"><span>Namn</span><input type="text" name="namn" value="${esc(C.sessionName || "")}" placeholder="t.ex. Lennart efter 4 000 steg"></label>${C.sessionId ? '<label class="check"><input type="checkbox" name="ny"> Spara som ny session</label>' : ""}`,
      footer: `<button class="btn" data-close>Avbryt</button><button class="btn primary" id="ok">Spara</button>` });
    $("#ok", dlg.el).onclick = async () => {
      const f = formData(dlg.el);
      try {
        const ses = await api("POST", "/api/sessions", { id: f.ny ? null : C.sessionId, namn: f.namn, installningar: s,
          paneler: C.panels.map((p) => ({ model_id: p.model_id, modell: modelById(p.model_id)?.namn, checkpoint: p.checkpoint, meddelanden: p.messages.map(({ role, content, info }) => ({ role, content, info })) })) });
        C.sessionId = ses.id; C.sessionName = ses.namn; dlg.close(); toast("Sessionen har sparats"); drawSessions();
      } catch (e) { fail(e); }
    };
  };
  $("#new-chat").onclick = () => { if (C.busy) return; C.panels.forEach((p) => (p.messages = [])); C.sessionId = null; C.sessionName = ""; drawCols(); drawSessions(); };
  drawCols(); drawSessions(); setBusy(false);
  $("#prompt").focus();
}

// ───────────────────────────────────────────────────────────── dataset
function importDataset() {
  const dlg = modal({ title: "Importera dataset", body: `
    <label class="field"><span>Fil <em>(TXT, JSON eller JSONL)</em></span><input type="file" name="fil" accept=".txt,.json,.jsonl"></label>
    <p class="hint" style="margin:0">JSON/JSONL: poster med fälten <span class="mono">fråga/svar</span>, <span class="mono">question/answer</span>, <span class="mono">instruction/output</span>, <span class="mono">messages</span> eller <span class="mono">text</span> känns igen automatiskt. TXT delas upp i stycken.</p>
    <div class="form-grid">
      <label class="field"><span>Namn</span><input type="text" name="namn" placeholder="Filnamnet används om fältet lämnas tomt"></label>
      <label class="field"><span>Licens</span><input type="text" name="licens" placeholder="t.ex. CC BY 4.0, egen data"></label>
      <label class="field"><span>Datakälla</span><input type="text" name="kalla" placeholder="Varifrån kommer datat?"></label>
      <label class="field"><span>Länk till källa</span><input type="text" name="kall_url" placeholder="https://…"></label>
      <label class="field wide"><span>Beskrivning</span><textarea name="beskrivning" rows="2"></textarea></label>
    </div>`, footer: `<button class="btn" data-close>Avbryt</button><button class="btn primary" id="ok">Importera</button>` });
  $("#ok", dlg.el).onclick = async () => {
    const f = formData(dlg.el), file = $("[name=fil]", dlg.el).files[0];
    if (!file) return toast("Välj en fil först", true);
    try {
      const d = await api("POST", `/api/datasets/import?${qs({ filnamn: file.name, namn: f.namn, licens: f.licens, kalla: f.kalla, kall_url: f.kall_url, beskrivning: f.beskrivning })}`, file);
      dlg.close(); toast(`${d.namn}: ${num(d.antal)} poster importerade${d.overhoppade ? `, ${d.overhoppade} hoppades över` : ""}`);
      S.data.id = d.id; S.data.split = "alla"; S.data.offset = 0;
      await refresh(); go("dataset");
    } catch (e) { fail(e); }
  };
}

function viewDatasets() {
  const D = S.data;
  if (!S.datasets.some((d) => d.id === D.id)) { D.id = S.datasets[0]?.id || null; D.split = "alla"; D.offset = 0; }
  const TYPE = { chatt: "Fråga/svar", text: "Löpande text", blandat: "Blandat" };
  $("#view").innerHTML = `
    <div class="toolbar"><p>Importera och förbered träningsdata. Källa och licens sparas tillsammans med varje dataset.</p><button class="btn primary" data-action="import-dataset">Importera dataset</button></div>
    ${S.datasets.length ? `<div class="panel"><table><thead><tr><th>Namn</th><th>Format</th><th>Typ</th><th class="right">Poster</th><th class="right">Tecken</th><th>Uppdelning</th><th>Licens</th></tr></thead><tbody>
      ${S.datasets.map((d) => `<tr class="click ${d.id === D.id ? "sel" : ""}" data-ds="${esc(d.id)}"><td><b>${esc(d.namn)}</b>${d.inbyggt ? ' <span class="tag">Medföljer</span>' : ""}</td><td>${esc(d.format.toUpperCase())}</td><td>${TYPE[d.typ] || d.typ}</td><td class="right num">${num(d.antal)}</td><td class="right num">${compact(d.tecken)}</td><td>${d.uppdelning ? `<span class="num">${num(d.uppdelning.train)} / ${num(d.uppdelning.val)} / ${num(d.uppdelning.test)}</span>` : '<span class="muted">Inte uppdelat</span>'}</td><td class="${d.licens ? "" : "muted"}">${esc(d.licens || "Inte angiven")}</td></tr>`).join("")}
    </tbody></table></div><div id="ds-detail" style="margin-top:16px"></div>`
    : `<div class="panel empty"><strong>Inga dataset</strong>Importera en TXT-, JSON- eller JSONL-fil för att komma igång.</div>`}`;
  $$("[data-ds]").forEach((tr) => (tr.onclick = () => { D.id = tr.dataset.ds; D.split = "alla"; D.offset = 0; viewDatasets(); }));
  const d = S.datasets.find((x) => x.id === D.id);
  if (!d) return;
  const u = d.uppdelning || { andel_train: 80, andel_val: 10, andel_test: 10, seed: 42 };
  $("#ds-detail").innerHTML = `<div class="grid split">
    <div class="grid">
      <div class="panel"><header><h2>Källa och licens</h2></header><div class="body grid" id="ds-meta">
        <label class="field"><span>Namn</span><input type="text" name="namn" value="${esc(d.namn)}"></label>
        <label class="field"><span>Beskrivning</span><textarea name="beskrivning" rows="2">${esc(d.beskrivning)}</textarea></label>
        <label class="field"><span>Datakälla</span><input type="text" name="kalla" value="${esc(d.kalla)}"></label>
        <label class="field"><span>Länk till källa</span><input type="text" name="kall_url" value="${esc(d.kall_url)}"></label>
        <label class="field"><span>Licens</span><input type="text" name="licens" value="${esc(d.licens)}"></label>
        <label class="field"><span>Anteckningar</span><textarea name="anteckningar" rows="2">${esc(d.anteckningar || "")}</textarea></label>
        <div class="hint">Originalfil: ${esc(d.originalfil)} · importerad ${when(d.skapad)}${d.overhoppade ? ` · ${d.overhoppade} rader kunde inte tolkas` : ""}</div>
        <div class="btn-row"><button class="btn primary" id="ds-save">Spara</button><span style="flex:1"></span><button class="btn danger" id="ds-delete">Ta bort dataset</button></div>
      </div></div>
      <div class="panel"><header><h2>Rensa och dela upp</h2></header><div class="body grid">
        <div class="run-head"><div><b>Dubbletter</b><div class="hint">${d.dubbletter_borttagna ? `${num(d.dubbletter_borttagna)} dubbletter har tagits bort.` : "Identiska poster tas bort (skiftläge och blanksteg ignoreras)."}</div></div><button class="btn" id="ds-dedupe">Rensa dubbletter</button></div>
        <div style="border-top:1px solid var(--border)"></div>
        <div><b>Uppdelning</b><div class="hint">Andelar i procent. Samma slumpfrö ger samma uppdelning.</div></div>
        <div class="form-grid" style="grid-template-columns:repeat(4,minmax(0,1fr))" id="ds-split">
          <label class="field"><span>Träning</span><input type="number" name="train" value="${u.andel_train}" min="1" max="100"></label>
          <label class="field"><span>Validering</span><input type="number" name="val" value="${u.andel_val}" min="0" max="99"></label>
          <label class="field"><span>Test</span><input type="number" name="test" value="${u.andel_test}" min="0" max="99"></label>
          <label class="field"><span>Slumpfrö</span><input type="number" name="seed" value="${u.seed}" min="0"></label>
        </div>
        <div class="btn-row"><button class="btn" id="ds-do-split">${d.uppdelning ? "Dela upp på nytt" : "Dela upp"}</button>${d.uppdelning ? `<button class="btn ghost" id="ds-unsplit">Ta bort uppdelning</button><span class="hint num">${num(d.uppdelning.train)} träning · ${num(d.uppdelning.val)} validering · ${num(d.uppdelning.test)} test</span>` : ""}</div>
      </div></div>
    </div>
    <div class="panel"><header><h2>Förhandsgranskning</h2><div class="tabs" style="border:0">${[["alla", "Alla"], ...(d.uppdelning ? [["train", "Träning"], ["val", "Validering"], ["test", "Test"]] : [])].map(([k, t]) => `<button data-split="${k}" class="${D.split === k ? "on" : ""}">${t}</button>`).join("")}</div></header>
      <div class="body"><div class="grid" id="ds-rows" style="gap:8px"></div><div class="pager"><button class="btn small" id="pg-prev">← Föregående</button><span class="muted num" id="pg-info"></span><button class="btn small" id="pg-next">Nästa →</button></div></div>
    </div></div>`;
  const LIMIT = 12;
  const load = async () => {
    try {
      const r = await api("GET", `/api/datasets/${d.id}/preview?${qs({ del: D.split, offset: D.offset, limit: LIMIT })}`);
      if (!$("#ds-rows")) return;
      $("#ds-rows").innerHTML = r.poster.map((rec, i) => `<div class="record"><span class="idx">#${r.offset + i + 1}</span>${rec.messages ? rec.messages.map((m) => `<p><span class="role ${m.role}">${m.role === "user" ? "Fråga" : "Svar"}</span>${esc(m.content)}</p>`).join("") : `<p>${esc(rec.text.length > 900 ? rec.text.slice(0, 900) + " …" : rec.text)}</p>`}</div>`).join("") || `<div class="empty">Inga poster.</div>`;
      $("#pg-info").textContent = r.totalt ? `${num(r.offset + 1)}–${num(Math.min(r.offset + LIMIT, r.totalt))} av ${num(r.totalt)}` : "";
      $("#pg-prev").disabled = r.offset <= 0; $("#pg-next").disabled = r.offset + LIMIT >= r.totalt;
    } catch (e) { fail(e); }
  };
  $$("[data-split]").forEach((b) => (b.onclick = () => { D.split = b.dataset.split; D.offset = 0; $$("[data-split]").forEach((x) => x.classList.toggle("on", x === b)); load(); }));
  $("#pg-prev").onclick = () => { D.offset = Math.max(0, D.offset - LIMIT); load(); };
  $("#pg-next").onclick = () => { D.offset += LIMIT; load(); };
  const act = async (fn, msg) => { try { const r = await fn(); toast(typeof msg === "function" ? msg(r) : msg); D.offset = 0; await refresh(); viewDatasets(); } catch (e) { fail(e); } };
  $("#ds-save").onclick = () => act(() => api("PATCH", `/api/datasets/${d.id}`, formData($("#ds-meta"))), "Uppgifterna har sparats");
  $("#ds-dedupe").onclick = () => act(() => api("POST", `/api/datasets/${d.id}/dedupe`), (r) => (r.borttagna ? `${num(r.borttagna)} dubbletter togs bort` : "Inga dubbletter hittades"));
  $("#ds-do-split").onclick = () => act(() => api("POST", `/api/datasets/${d.id}/split`, formData($("#ds-split"))), (r) => `Uppdelat: ${num(r.uppdelning.train)} träning, ${num(r.uppdelning.val)} validering, ${num(r.uppdelning.test)} test`);
  if ($("#ds-unsplit")) $("#ds-unsplit").onclick = () => { D.split = "alla"; act(() => api("POST", `/api/datasets/${d.id}/split`, { ta_bort: true }), "Uppdelningen har tagits bort"); };
  $("#ds-delete").onclick = async () => {
    if (!(await confirmDialog("Ta bort dataset", `Vill du ta bort <b>${esc(d.namn)}</b>? Redan tränade modeller påverkas inte.`, "Ta bort", true))) return;
    D.id = null; act(() => api("DELETE", `/api/datasets/${d.id}`), "Datasetet har tagits bort");
  };
  load();
}

// ───────────────────────────────────────────────────────────── start
document.addEventListener("click", (e) => {
  const v = e.target.closest("[data-view]");
  if (v) { $("#view").style.overflow = ""; return go(v.dataset.view); }
  const a = e.target.closest("[data-action]");
  if (a && ACTIONS[a.dataset.action]) return ACTIONS[a.dataset.action](a.dataset.id);
  const d = e.target.closest("[data-model-detail]");
  if (d) return modelDetail(d.dataset.modelDetail);
  const r = e.target.closest("[data-open-run]");
  if (r) return go("traning", { runId: r.dataset.openRun });
});
$("#active-model").onchange = (e) => ACTIONS.activate(e.target.value);

(async () => {
  try { await refresh(); await ensurePresets(); } catch (e) { fail(e); }
  go("oversikt");
  setInterval(() => { if (S.view === "testa" || S.view === "dataset") refresh().catch(() => {}); }, 5000);
})();
