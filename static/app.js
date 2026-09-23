/* ============================================================
   Adaptune — live dashboard logic
   Sections: utils · flow · websocket · graphs · meter · SUNO
             player · Spotify/Claude personalize · karaoke ·
             breathe · play-along
   ============================================================ */
"use strict";

const $ = id => document.getElementById(id);
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
const css = v => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
const fmtTime = s => {
  if (!isFinite(s) || s < 0) s = 0;
  const m = Math.floor(s / 60), ss = Math.floor(s % 60);
  return String(m).padStart(2, "0") + ":" + String(ss).padStart(2, "0");
};
/* ============================ 1 · setup flow ============================ */
const screens = {};
document.querySelectorAll(".screen").forEach(s => screens[s.id] = s);
function showScreen(id) {
  Object.values(screens).forEach(s => s.classList.toggle("active", s.id === id));
}
document.querySelectorAll("[data-go]").forEach(btn => {
  btn.addEventListener("click", async () => {
    const go = btn.dataset.go;
    if (go === "mobile")       showScreen("scr-mobile-note");
    else if (go === "device-back") showScreen("scr-device");
    else if (go === "computer")    showScreen("scr-input");
    else if (go === "input-back")  showScreen("scr-input");
    else if (go === "muse")        showScreen("scr-muse");
    else if (go === "demo") {
      btn.classList.add("busy");
      try { await fetch("/api/input", {method:"POST", headers:{"Content-Type":"application/json"},
                                       body: JSON.stringify({input:"demo"})}); } catch(e){}
      btn.classList.remove("busy");
      showScreen("scr-stressed");
    }
  });
});
$("museConnectBtn").addEventListener("click", async () => {
  const btn = $("museConnectBtn");
  $("museErr").hidden = true;
  btn.classList.add("busy");
  btn.querySelector(".fo-desc").textContent = "connecting…";
  let ok = false, detail = "";
  try {
    const r = await fetch("/api/input", {method:"POST", headers:{"Content-Type":"application/json"},
                                         body: JSON.stringify({input:"muse"})});
    const payload = await r.json();
    ok = payload.ok;
    detail = payload.detail || "";
  } catch(e) {}
  btn.classList.remove("busy");
  if (ok) showScreen("scr-stressed");
  else {
    btn.querySelector(".fo-desc").textContent = "scan again for Muse 2";
    $("museErr").textContent = detail || "The Muse 2 could not be connected through MuseLSL.";
    $("museErr").hidden = false;
  }
});
async function answerStressed(stressed) {
  try { await fetch("/api/baseline", {method:"POST", headers:{"Content-Type":"application/json"},
                                      body: JSON.stringify({stressed})}); } catch(e){}
  stressLabelSeen = null;
  sunoTarget = null;
  sessionStressPoints = [];
  sessionGraphImages = {};
  sessionStartedAt = Date.now();
  lastRecordedStressSecond = -1;
  const flow = $("flow");
  flow.classList.add("fade-out");
  setTimeout(() => { flow.hidden = true; }, 450);
  $("dash").hidden = false;
  requestAnimationFrame(() => requestAnimationFrame(() => $("dash").classList.add("shown")));
}
$("stressedYes").addEventListener("click", () => answerStressed(true));
$("stressedNo").addEventListener("click", () => answerStressed(false));

/* ============================ 2 · websocket ============================ */
let S = null;                    // latest snapshot from the server
let lastBeatSeq = -1;
let sessionStartedAt = Date.now();
let sessionStressPoints = [];
let sessionGraphImages = {};
let lastRecordedStressSecond = -1;
function connectWS() {
  const ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws");
  ws.onmessage = ev => {
    S = JSON.parse(ev.data);
    const beat = S.beat_seq !== lastBeatSeq;
    if (beat) lastBeatSeq = S.beat_seq;
    onSnapshot(S, beat);
  };
  ws.onclose = () => setTimeout(connectWS, 1000);
}
connectWS();

function onSnapshot(s, beat) {
  updateGraphs(s, beat);
  updateMeter(s);
  updateChrome(s);
  sunoTick(s);
  breatheTick(s);
  adaptSpotifyToStress(s);
  if (!$('dash').hidden && s.stress != null) {
    const second = Math.max(0, Math.round((Date.now() - sessionStartedAt) / 1000));
    if (second !== lastRecordedStressSecond) {
      lastRecordedStressSecond = second;
      sessionStressPoints.push({x: second, y: Number(s.stress)});
    }
  }
}

async function adaptSpotifyToStress(s) {
  const label = s.stress_label;
  if (!label) return;
  if (stressLabelSeen == null) {
    stressLabelSeen = label;                 // establish the initial label without interrupting playback
    return;
  }
  if (label === stressLabelSeen) return;
  if (Date.now() - lastAutomaticRequest < 60000) return;
  if (stressAdaptInFlight || !spMode || !spTrack || audioSource !== "spotify") return;
  if (preferenceRequestBusy) return;
  stressLabelSeen = label;
  lastAutomaticRequest = Date.now();
  stressAdaptInFlight = true;
  try {
    await spRequestTrack("stress");
  } finally {
    stressAdaptInFlight = false;
  }
}

function updateChrome(s) {
  const pill = $("inputPill");
  pill.textContent = s.input === "muse" ? "MUSE 2" : s.input === "demo" ? "DEMO MODE" : "—";
  pill.classList.toggle("live", s.input === "demo" || (s.input === "muse" && s.muse_streaming));
  const t = s.session_sec || 0;
  $("clock").textContent = [Math.floor(t/3600), Math.floor(t%3600/60), t%60]
      .map(x => String(x).padStart(2, "0")).join(":");
  const cal = $("calPill");
  cal.hidden = !s.calibrating;
  if (s.calibrating) cal.textContent = "calibrating baseline · " +
      (s.calibration_left != null ? Math.ceil(s.calibration_left) + "s" : "waiting for signal");
}

/* ============================ 3 · graphs ============================ */
const GRAPHS = [
  {key:"bpm",        name:"BPM",                   color:css("--c-bpm"), dec:0, perBeat:true},
  {key:"hrv_diff",   name:"HRV DIFFERENTIAL · ms", color:css("--c-hrv"), dec:0, perBeat:true},
  {key:"right_brain",name:"EEG RIGHT BRAIN · BAND POWER", color:css("--c-rb"), eeg:true},
  {key:"left_brain", name:"EEG LEFT BRAIN · BAND POWER",  color:css("--c-lb"), eeg:true},
  {key:"right_ear",  name:"EEG RIGHT EAR · BAND POWER",   color:css("--c-re"), eeg:true},
  {key:"left_ear",   name:"EEG LEFT EAR · BAND POWER",    color:css("--c-le"), eeg:true},
];
const EEG_BANDS = Object.freeze([
  {key:"delta", name:"δ", color:"#7aa2ff"},
  {key:"theta", name:"θ", color:"#42d8dc"},
  {key:"alpha", name:"α", color:"#64e28b"},
  {key:"beta",  name:"β", color:"#ffd166"},
  {key:"gamma", name:"γ", color:"#f58bff"},
]);
const NPTS = 140;
const tiles = {};
{
  const stack = $("gstack");
  for (const g of GRAPHS) {
    const tile = document.createElement("div");
    tile.className = "gtile";
    const legend = g.eeg ? `<div class="glegend">${EEG_BANDS.map(b =>
      `<span style="color:${b.color}">${b.name}</span>`).join("")}</div>` : "";
    const value = g.eeg ? "" :
      `<span class="gval" id="gv-${g.key}" style="color:${g.color}">--</span>`;
    tile.innerHTML =
      `<div class="gtop"><span class="gname">${g.name}</span>` +
      `${value}</div>` +
      `<div class="gplot"><canvas></canvas>${legend}<div class="gnosig" id="gn-${g.key}" hidden>NO&nbsp;READING</div></div>`;
    stack.appendChild(tile);
    const cv = tile.querySelector("canvas");
    const bandBufs = Object.fromEntries(EEG_BANDS.map(band => [band.key, []]));
    tiles[g.key] = {g, cv, ctx: cv.getContext("2d"), buf: [], bandBufs, active: false};
  }
}
function pushPoint(t, v) { t.buf.push(v); if (t.buf.length > NPTS) t.buf.shift(); }
function pushBandPoints(t, values) {
  for (const band of EEG_BANDS) {
    const buf = t.bandBufs[band.key];
    buf.push(Number(values[band.key]));
    if (buf.length > NPTS) buf.shift();
  }
}
function glowValues() {
  for (const g of GRAPHS) {
    const el = $("gv-" + g.key);
    if (!el) continue;
    el.classList.remove("glow"); void el.offsetWidth; el.classList.add("glow");
  }
}
function updateGraphs(s, beat) {
  for (const g of GRAPHS) {
    const t = tiles[g.key];
    let v = null, active = false, bands = null;
    if (g.eeg) {
      bands = s.eeg_bands ? s.eeg_bands[g.key] : null;
      active = !!(s.eeg_active && s.eeg_active[g.key] && bands &&
                  EEG_BANDS.every(band => bands[band.key] != null));
    }
    else       { v = s[g.key]; active = v != null; }
    t.active = active;
    const valEl = $("gv-" + g.key);
    $("gn-" + g.key).hidden = active;
    if (!active) {
      if (valEl) valEl.textContent = "--";
      if (g.eeg) for (const band of EEG_BANDS) t.bandBufs[band.key] = [];
    } else {
      if (g.eeg) {
        pushBandPoints(t, bands);
      } else {
        valEl.textContent = Number(v).toFixed(g.dec);
        if (g.perBeat && beat) pushPoint(t, v);
      }
    }
    drawTile(t);
    if (active && t.cv.width && t.cv.height) sessionGraphImages[g.key] = t.cv.toDataURL("image/png");
  }
  if (beat) glowValues();
}

window.AdaptuneSession = {
  snapshot() {
    const values = sessionStressPoints.map(point => point.y).filter(Number.isFinite);
    return {
      started_at: new Date(sessionStartedAt).toISOString(),
      ended_at: new Date().toISOString(),
      graph_images: {...sessionGraphImages},
      stress_points: sessionStressPoints.slice(),
      avg_stress: values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null,
    };
  },
  stopAudio: stopSessionAudio,
};
function drawTile(t) {
  const cv = t.cv, r = cv.getBoundingClientRect();
  if (!r.width || !r.height) return;
  const dpr = window.devicePixelRatio || 1;
  const W = Math.round(r.width * dpr), H = Math.round(r.height * dpr);
  if (cv.width !== W || cv.height !== H) { cv.width = W; cv.height = H; }
  const ctx = t.ctx, w = r.width, h = r.height;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  // recessive grid: 3 horizontal lines
  ctx.strokeStyle = css("--grid"); ctx.lineWidth = 1;
  ctx.beginPath();
  for (let i = 1; i <= 3; i++) { const y = Math.round(h * i / 4) + .5; ctx.moveTo(0, y); ctx.lineTo(w, y); }
  ctx.stroke();
  const series = t.g.eeg ? EEG_BANDS.map(band => t.bandBufs[band.key]) : [t.buf];
  const allValues = series.flat();
  if (!t.active || allValues.length < 2) return;
  let lo = Math.min(...allValues), hi = Math.max(...allValues);
  if (hi - lo < 1e-6) { lo -= 1; hi += 1; }
  const pad = (hi - lo) * 0.12; lo -= pad; hi += pad;
  series.forEach((values, seriesIndex) => {
    ctx.strokeStyle = t.g.eeg ? EEG_BANDS[seriesIndex].color : t.g.color;
    ctx.lineWidth = t.g.eeg ? 1.45 : 2;
    ctx.lineJoin = "round";
    ctx.beginPath();
    values.forEach((value, i) => {
      const x = (i / (NPTS - 1)) * w, y = h - ((value - lo) / (hi - lo)) * h;
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
    });
    ctx.stroke();
  });
}

/* ============================ 4 · meter ============================ */
const LABEL_COLOR = {"Calm": css("--calm"), "Mild-stress": css("--mild"), "Stressed": css("--stressed")};
function updateMeter(s) {
  const label = $("stressLabel"), value = $("stressValue"), needle = $("meterNeedle");
  if (s.stress == null) {
    if (s.calibrating) {
      label.textContent = "Calibrating";
      label.style.color = css("--muted");
      value.textContent = s.calibration_left != null ? Math.ceil(s.calibration_left) + "s left" : "…";
      value.style.color = css("--muted");
      needle.style.left = "0%";
      return;
    }
    label.textContent = "—"; label.style.color = css("--muted");
    value.textContent = "--"; value.style.color = css("--muted");
    needle.style.left = "0%";
    return;
  }
  const col = LABEL_COLOR[s.stress_label] || css("--muted");
  label.textContent = s.stress_label;
  label.style.color = col;
  value.textContent = s.stress.toFixed(1);
  value.style.color = col;
  needle.style.left = "calc(" + clamp(s.stress, 0, 100) + "% - 2px)";
}

/* ============================ 5 · audio source arbiter ============================ */
let audioSource = "suno";              // "suno" | "spotify" — which system owns the speakers
let audioHandoffId = 0, sunoLoadRequestId = 0, spotifyPlayRequestId = 0;
function ownsAudioHandoff(id, source) {
  return id === audioHandoffId && audioSource === source;
}
async function claimAudio(src) {
  if (src !== "karaoke") {
    $("karaokeAudio").pause();
    karaokeGeneration += 1;
  }
  if (src === "spotify") {
    for (const node of instrumentSources) { try { node.stop(); } catch (_) {} }
    instrumentSources.clear();
  }
  if (audioSource === src) return true;
  const handoffId = ++audioHandoffId;
  audioSource = src;
  breatheSourceCheck();
  if (src === "spotify") {
    sunoLoadRequestId += 1;
    await sunoFadeStop(handoffId);
  } else {
    spotifyPlayRequestId += 1;
    if (spPlayer) {
      try { await spPlayer.pause(); } catch (_) { if (handoffId === audioHandoffId) audioSource = "spotify"; $("karaokeMsg").hidden = false; $("karaokeMsg").textContent = "Pause Spotify before starting local audio."; return false; }
    }
    spIsPlaying = false;
    if (src === "karaoke") { sunoLoadRequestId += 1; sunoEls.forEach(el => el.pause()); sunoPlaying = false; }
  }
  return ownsAudioHandoff(handoffId, src);
}

/* ============================ 6 · SUNO player ============================ */
const sunoEls = [$("audioA"), $("audioB")];
let sunoIdx = 0, sunoPlaying = false, sunoFetching = false;
let sunoBucket = null;                 // bucket of the audible song
let sunoTarget = null;
let sunoCurrentFile = null;
const SUNO_VOL = 0.9, FADE_MS = 1100;
sunoEls.forEach(el => { el.volume = 0; });

function fadeEl(el, to, ms) {
  // interval + wall-clock (not rAF): fades must finish even in a backgrounded tab,
  // otherwise bucket switches stall while the music tab is hidden
  return new Promise(res => {
    if (el._fade) {
      clearInterval(el._fade.timer);
      el._fade.resolve(false);
    }
    const from = el.volume, t0 = performance.now();
    if (ms <= 0) { el.volume = clamp(to, 0, 1); res(true); return; }
    const fade = {timer: null, resolve: res};
    el._fade = fade;
    fade.timer = setInterval(() => {
      const k = Math.min(1, (performance.now() - t0) / ms);
      el.volume = clamp(from + (to - from) * k, 0, 1);
      if (k >= 1) {
        clearInterval(fade.timer);
        if (el._fade === fade) el._fade = null;
        res(true);
      }
    }, 40);
  });
}
async function sunoFadeStop(handoffId) {
  const el = sunoEls[sunoIdx];
  if (!await fadeEl(el, 0, 600)) return false;
  if (handoffId != null && !ownsAudioHandoff(handoffId, "spotify")) return false;
  try { el.pause(); } catch(e){}
  sunoPlaying = false;
  $("sunoPlay").innerHTML = "&#9654;";
  return true;
}
async function sunoLoad(bucket, autoplay) {
  if (sunoFetching) return;
  const requestId = ++sunoLoadRequestId;
  sunoFetching = true;
  try {
    const cur = sunoEls[sunoIdx];
    const q = "bucket=" + (bucket != null ? bucket : sunoTargetBucket());
    const j = await (await fetch("/api/suno/next?" + q +
              "&current=" + encodeURIComponent(sunoCurrentFile || ""))).json();
    if (!j || !j.url) { sunoFetching = false; return; }
    if (requestId !== sunoLoadRequestId || audioSource !== "suno") return;
    // fade OUT the old song fully, then fade IN the new one (spec: fade out - fade in)
    if (!cur.paused) {
      if (!await fadeEl(cur, 0, FADE_MS)) return;
      if (requestId !== sunoLoadRequestId || audioSource !== "suno") return;
      try { cur.pause(); } catch(e){}
    }
    sunoIdx ^= 1;
    const nxt = sunoEls[sunoIdx];
    nxt.src = j.url; nxt.volume = 0;
    $("sunoName").textContent = j.name;
    sunoCurrentFile = j.file || j.name;
    $("sunoBucket").textContent = j.bucket + " BPM folder";
    sunoBucket = j.bucket;
    if (autoplay || sunoPlaying) {
      if (requestId !== sunoLoadRequestId || audioSource !== "suno") return;
      try { await nxt.play(); sunoPlaying = true; $("sunoPlay").innerHTML = "&#10074;&#10074;"; } catch(e){}
      await fadeEl(nxt, SUNO_VOL, FADE_MS);
    }
  } finally { sunoFetching = false; }
}

// Inverse tempo rule: 210 - floor-to-ten(user BPM), clamped to 60...150.
// A temporary missing reading keeps the last target instead of interrupting music.
function updateSunoTarget(bucket) {
  if (bucket == null) return false;
  const next = clamp(Math.floor(Number(bucket) / 10) * 10, 60, 150);
  if (next === sunoTarget) return false;
  sunoTarget = next;
  return true;
}
function sunoTargetBucket() {
  updateSunoTarget(S && S.song_bucket);
  return sunoTarget || 60;
}
function sunoTick(s) {
  if (!sunoPlaying || sunoFetching || audioSource !== "suno") return;
  if (!updateSunoTarget(s.song_bucket)) return;
  if (sunoBucket != null && sunoBucket !== sunoTarget) sunoLoad(sunoTarget);
}
$("sunoPlay").addEventListener("click", async () => {
  const el = sunoEls[sunoIdx];
  if (sunoPlaying && audioSource === "suno") {
    sunoPlaying = false;
    $("sunoPlay").innerHTML = "&#9654;";
    if (!await fadeEl(el, 0, 500)) return;
    try { el.pause(); } catch(e){}
  } else {
    if (!await claimAudio("suno")) return;
    const target = sunoTargetBucket();
    if (!el.src || sunoBucket !== target) { await sunoLoad(target, true); return; }
    sunoPlaying = true;
    $("sunoPlay").innerHTML = "&#10074;&#10074;";
    try { await el.play(); } catch(e){}
    fadeEl(el, SUNO_VOL, 700);
  }
});
$("sunoNext").addEventListener("click", async () => {
  if (!await claimAudio("suno")) return;
  sunoPlaying = true; await sunoLoad(sunoTargetBucket(), true);
});
$("sunoPrev").addEventListener("click", async () => {
  if (!await claimAudio("suno")) return;
  sunoPlaying = true; await sunoLoad(sunoTargetBucket(), true);
});
sunoEls.forEach(el => {
  el.addEventListener("ended", () => { if (el === sunoEls[sunoIdx] && sunoPlaying) sunoLoad(sunoTargetBucket(), true); });
  el.addEventListener("timeupdate", () => {
    if (el !== sunoEls[sunoIdx]) return;
    if (!sunoDragging && isFinite(el.duration) && el.duration > 0)
      $("sunoBar").value = Math.round(1000 * el.currentTime / el.duration);
    $("sunoCur").textContent = fmtTime(el.currentTime);
    $("sunoEnd").textContent = fmtTime(el.duration);
  });
});
let sunoDragging = false;
// safety net: a click that doesn't change the value never fires 'change', which
// would otherwise leave the drag flag stuck and freeze the timeline display
window.addEventListener("pointerup", () => setTimeout(() => { sunoDragging = false; spDragging = false; }, 60));
$("sunoBar").addEventListener("pointerdown", () => sunoDragging = true);
$("sunoBar").addEventListener("change", () => {
  const el = sunoEls[sunoIdx];
  if (isFinite(el.duration)) el.currentTime = el.duration * $("sunoBar").value / 1000;
  sunoDragging = false;
});
$("sunoBar").addEventListener("input", () => {
  const el = sunoEls[sunoIdx];
  if (isFinite(el.duration)) $("sunoCur").textContent = fmtTime(el.duration * $("sunoBar").value / 1000);
});

/* ============================ 7 · Spotify + Claude personalize ============================ */
let preferenceRequestBusy = false, preferenceGeneration = 0;
let lastAutomaticRequest = 0;
const instrumentSources = new Set();
let spotifyConnectionGeneration = 0;
let spPlayer = null, spDeviceId = null, spConnected = false, spPremium = false, spKeySet = false;
let spMode = null, spValue = "", spTrack = null, spIsPlaying = false;
let spLastPos = 0, spDuration = 0, spDragging = false;
let stressLabelSeen = null, stressAdaptInFlight = false;
let spPlaylistId = null, playlistCatalog = null, playlistLoading = null;

async function spToken() {
  try { return (await (await fetch("/api/spotify/token")).json()).access_token; } catch(e){ return null; }
}
async function refreshSpotify() {
  const revision = spotifyConnectionGeneration;
  let j = {};
  try { j = await (await fetch("/api/spotify/status")).json(); } catch(e){}
  if (revision !== spotifyConnectionGeneration) return;
  spConnected = !!j.connected; spPremium = !!j.premium; spKeySet = !!j.key_set;
  const msg = $("spMsg");
  $("keyRow").hidden = spKeySet;
  $("spConnect").hidden = !(spKeySet && !spConnected);
  if (!j.configured)      { msg.textContent = "Server is missing Spotify credentials (SPOTIFY_CLIENT_ID / SECRET)."; msg.className = "setup-msg mono err"; }
  else if (!spKeySet)     { msg.textContent = "Step 1 — enter your Anthropic API key."; msg.className = "setup-msg mono"; }
  else if (!spConnected)  { msg.textContent = "Step 2 — connect your Spotify account."; msg.className = "setup-msg mono"; }
  else if (!spPremium)    { msg.textContent = "I apologize, but you need Spotify premium to access this feature."; msg.className = "setup-msg mono err"; }
  else                    { msg.textContent = ""; }
  const full = spConnected && spPremium;
  $("spFull").hidden = !full;
  $("spSetup").hidden = full && spKeySet;
  if (!full) { playlistCatalog = null; spPlaylistId = null; }
  if (spConnected) maybeInitSpotify();
}
$("antConfirm").addEventListener("click", async () => {
  const key = $("antKey").value.trim();
  if (!key) return;
  try { await fetch("/api/anthropic_key", {method:"POST", headers:{"Content-Type":"application/json"},
                                           body: JSON.stringify({key})}); } catch(e){}
  $("antKey").value = "";
  refreshSpotify();
});
$("spConnect").addEventListener("click", () =>
  window.open("/login", "spotify_auth", "width=520,height=720,menubar=no,toolbar=no"));
window.addEventListener("message", e => { if (e.origin === location.origin && e.data === "spotify-connected") refreshSpotify(); });

async function maybeInitSpotify() {
  if (spPlayer || !window._sdkLoaded || !spConnected) return;
  const revision = spotifyConnectionGeneration;
  const tok = await spToken();
  if (!tok || spPlayer || !spConnected || revision !== spotifyConnectionGeneration) return;
  spPlayer = new Spotify.Player({
    name: "Adaptune", volume: 0.9,
    getOAuthToken: cb => spToken().then(t => t && cb(t)),
  });
  spPlayer.addListener("ready", ({device_id}) => { spDeviceId = device_id; });
  spPlayer.addListener("not_ready", () => { spDeviceId = null; });
  spPlayer.addListener("player_state_changed", st => { spIsPlaying = !!(st && !st.paused); });
  spPlayer.addListener("account_error", () => {
    $("spMsg").textContent = "I apologize, but you need Spotify premium to access this feature.";
    $("spMsg").className = "setup-msg mono err";
  });
  spPlayer.connect();
}

/* tabs */
const TAB_PLACEHOLDER = {
  vibe: "What's your vibe?",
  artist: "Enter your favorite artist",
  playlist: "Enter your playlist's name",
  song: "Enter your favorite song",
};
let tabMode = null;
document.querySelectorAll(".tab").forEach(tab => {
  tab.addEventListener("click", () => {
    tabMode = tab.dataset.mode;
    document.querySelectorAll(".tab").forEach(t => t.classList.toggle("on", t === tab));
    const isPlaylist = tabMode === "playlist";
    $("tabMenu").hidden = isPlaylist;
    $("playlistMenu").hidden = !isPlaylist;
    $("prefInput").placeholder = TAB_PLACEHOLDER[tabMode];
    $("prefInput").value = "";
    clearPrefMessage();
    if (!isPlaylist) clearPlaylistPickerSelection();
    if (isPlaylist) loadPlaylistPicker();
    else $("prefInput").focus();
  });
});
$("prefConfirm").addEventListener("click", confirmPref);
$("prefInput").addEventListener("keydown", e => { if (e.key === "Enter") confirmPref(); });
$("prefInput").addEventListener("input", () => {
  if (tabMode !== "playlist") {
    // A new non-playlist preference supersedes any failed playlist attempt
    // before the user presses Confirm, so neither its error nor green button
    // selection can leak into the new flow.
    clearPrefMessage();
    clearPlaylistPickerSelection();
  }
});

async function confirmPref() {
  if (preferenceRequestBusy) return;
  const value = $("prefInput").value.trim();
  if (!value || !tabMode || tabMode === "playlist") return;
  spMode = tabMode; spValue = value;
  setPrefLoading(tabMode === "playlist" ? "loading your playlist…" : "asking Claude…");

  const ok = await spRequestTrack("init");
  if (ok) clearPrefLoading();
}
function setPrefLoading(message) {
  $("prefMsg").innerHTML = '<span class="spin"></span>' + message;
  $("prefMsg").className = "setup-msg mono loading";
}
function clearPrefLoading() {
  const msg = $("prefMsg");
  if (!msg.classList.contains("loading")) return;
  msg.classList.add("fading");
  setTimeout(() => {
    // A newer request may already have reused this message element.
    if (!msg.classList.contains("fading")) return;
    msg.textContent = "";
    msg.className = "setup-msg mono";
  }, 260);
}
function clearPrefMessage() {
  // Unlike clearPrefLoading, this deliberately clears errors as well as the
  // transient Claude message when the user starts a different preference.
  const msg = $("prefMsg");
  msg.textContent = "";
  msg.className = "setup-msg mono";
}
function clearPlaylistPickerSelection() {
  spPlaylistId = null;
  if (playlistCatalog) renderPlaylistPicker();
  else {
    const list = $("playlistList");
    list.textContent = "";
    list.className = "playlist-list";
  }
}
async function loadPlaylistPicker() {
  if (playlistLoading) return playlistLoading;
  if (playlistCatalog) { renderPlaylistPicker(); return; }
  const revision = spotifyConnectionGeneration;
  const list = $("playlistList");
  list.innerHTML = '<div class="setup-msg mono loading"><span class="spin"></span>loading your playlists…</div>';
  playlistLoading = (async () => {
    try {
      const r = await fetch("/api/playlists");
      const j = await r.json();
      if (revision !== spotifyConnectionGeneration) return;
      if (!j.ok) throw new Error(j.error || "playlist lookup failed");
      playlistCatalog = j.playlists || [];
      renderPlaylistPicker();
    } catch(e) {
      if (revision !== spotifyConnectionGeneration) return;
      list.textContent = "Couldn't load your playlists. Reconnect Spotify and try again.";
      list.className = "playlist-list setup-msg mono err";
    } finally {
      playlistLoading = null;
    }
  })();
  return playlistLoading;
}
function renderPlaylistPicker() {
  const list = $("playlistList");
  list.className = "playlist-list";
  list.textContent = "";
  if (!playlistCatalog || !playlistCatalog.length) {
    list.textContent = "No playlists were found in this Spotify account.";
    list.classList.add("setup-msg", "mono");
    return;
  }
  for (const playlist of playlistCatalog) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "playlist-choice";
    btn.dataset.playlistId = playlist.id;
    btn.classList.toggle("on", playlist.id === spPlaylistId);
    const title = document.createElement("span");
    title.textContent = playlist.name;
    btn.append(title);
    btn.addEventListener("click", () => choosePlaylist(playlist));
    list.appendChild(btn);
  }
}
function markPlaylistSelected(playlistId) {
  document.querySelectorAll(".playlist-choice").forEach(btn =>
    btn.classList.toggle("on", btn.dataset.playlistId === playlistId));
}
async function choosePlaylist(playlist) {
  if (preferenceRequestBusy) return;
  spMode = "playlist";
  spValue = playlist.name;
  spPlaylistId = playlist.id;
  markPlaylistSelected(playlist.id);
  setPrefLoading("loading selected playlist…");

  await spRequestTrack("init");
}
async function spRequestTrack(direction) {
  if (preferenceRequestBusy) return false;
  preferenceRequestBusy = true;
  const revision = preferenceGeneration;
  document.querySelectorAll("#prefConfirm, #spPrevBtn, #spNextBtn").forEach(el => el.disabled = true);
  if (direction !== "init") {
    setPrefLoading(direction === "stress" ? "adapting to your current stress level…" : "asking Claude…");
  }
  try {
    const r = await fetch("/api/personalize", {method:"POST", headers:{"Content-Type":"application/json"},
        body: JSON.stringify({mode: spMode, value: spValue,
                              playlist_id: spMode === "playlist" ? spPlaylistId : null, direction})});
    const j = await r.json();
    if (revision !== preferenceGeneration) return false;
    if (!j.ok) {
      const errs = {
        no_key: "Enter your Anthropic API key first.",
        not_connected: "Connect Spotify first.",
        not_premium: "I apologize, but you need Spotify premium to access this feature.",
        playlist_not_found: "Couldn't find a playlist with that name in your library.",
        playlist_empty: "That playlist has no playable songs.",
        playlist_track_unavailable: "That playlist song is unavailable to play.",
        playlist_selection_failed: "Couldn't choose a suitable song from that playlist — try again.",
        not_found: "Couldn't find a matching song — try different wording.",
      };
      $("prefMsg").textContent = errs[j.error] || ("Something went wrong: " + (j.error || "unknown"));
      $("prefMsg").className = "setup-msg mono err";
      return false;
    }
    if (j.playlist) $("spModeSub").textContent =
        `playlist · ${j.playlist.name} · ${j.playlist.index + 1}/${j.playlist.count}`;
    else $("spModeSub").textContent = spMode + " · " + spValue;
    if (j.playlist && j.playlist.id) markPlaylistSelected(j.playlist.id);
    const started = await spPlayTrack(j.track);
    if (started) clearPrefLoading();
    return started;
  } catch(e) {
    $("prefMsg").textContent = "Request failed — is the server still running?";
    $("prefMsg").className = "setup-msg mono err";
    return false;
  } finally {
    preferenceRequestBusy = false;
    clearPrefLoading();
    document.querySelectorAll("#prefConfirm, #spPrevBtn, #spNextBtn").forEach(el => el.disabled = false);
  }
}
async function spPlayTrack(track, {positionMs = 0, autoplay = true} = {}) {
  const requestId = ++spotifyPlayRequestId;
  if (!await claimAudio("spotify") || requestId !== spotifyPlayRequestId || audioSource !== "spotify") {
    return false;
  }
  await maybeInitSpotify();
  if (requestId !== spotifyPlayRequestId || audioSource !== "spotify") return false;
  if (!spDeviceId) await new Promise(r => setTimeout(r, 800));
  if (requestId !== spotifyPlayRequestId || audioSource !== "spotify") return false;
  if (!spDeviceId) {
    $("prefMsg").textContent = "Spotify player not ready yet — try again in a moment.";
    $("prefMsg").className = "setup-msg mono err";
    return false;
  }
  const tok = await spToken();
  try {
    if (spTrack && spPlayer) await spFade(0, 500);                    // fade out old
    if (requestId !== spotifyPlayRequestId || audioSource !== "spotify") return false;
    const safePosition = Math.max(0, Math.min(Math.round(positionMs || 0), Math.max(0, (track.duration_ms || 0) - 250)));
    if (!track.image) throw new Error("Artwork unavailable.");
    $("spArtwork").src = track.image;
    $("spOpen").href = track.external_url || "https://open.spotify.com/track/" + encodeURIComponent(track.id);
    $("spTrackName").textContent = track.name + " — " + (track.artist || "");
    $("spPlayerUI").hidden = false;
    const response = await fetch("https://api.spotify.com/v1/me/player/play?device_id=" + spDeviceId, {
      method: "PUT", headers: {Authorization: "Bearer " + tok, "Content-Type": "application/json"},
      body: JSON.stringify({uris: [track.uri], position_ms: safePosition}),
    });
    if (!response.ok) throw new Error("Spotify playback request failed (" + response.status + ")");
    if (requestId !== spotifyPlayRequestId || audioSource !== "spotify") {
      if (spPlayer) await spPlayer.pause().catch(()=>{});
      return false;
    }
    spTrack = track;
    spDuration = track.duration_ms || 0;
    $("spTrackName").textContent = track.name + " — " + (track.artist || "");
    $("spPlayerUI").hidden = false;
    spLastPos = safePosition;
    if (spPlayer) {
      try { await spPlayer.setVolume(0); } catch(e){}
      if (autoplay) {
        $("spPlayBtn").innerHTML = "&#10074;&#10074;";
        spIsPlaying = true;
        spFade(0.9, 900);                                                // fade in new
      } else {
        // Spotify's API has no "load this track paused" endpoint. Start it at
        // zero volume, then pause immediately so a user pause during karaoke
        // lookup stays a pause after the instrumental is ready.
        await spPlayer.pause().catch(()=>{});
        $("spPlayBtn").innerHTML = "&#9654;";
        spIsPlaying = false;
      }
    }
    return true;
  } catch(e) {
    console.warn("[spotify] play failed", e);
    $("prefMsg").textContent = "Spotify couldn't start that song — try again.";
    $("prefMsg").className = "setup-msg mono err";
    return false;
  }
}
let spFadeId = 0;
async function spFade(to, ms) {
  if (!spPlayer) return false;
  const fadeId = ++spFadeId;
  let from = to > 0 ? 0 : 0.9;
  try { const st = await spPlayer.getVolume(); if (isFinite(st)) from = st; } catch(e){}
  const steps = 12, dt = Math.max(20, ms / steps);
  for (let i = 1; i <= steps; i++) {
    if (fadeId !== spFadeId) return false;
    try { await spPlayer.setVolume(clamp(from + (to - from) * i / steps, 0, 1)); } catch(e){}
    await new Promise(r => setTimeout(r, dt));
  }
  return fadeId === spFadeId;
}
async function spotifyFadeStop(handoffId) {
  if (!spPlayer) {
    if (handoffId != null && !ownsAudioHandoff(handoffId, "suno")) return false;
    spIsPlaying = false;
    return true;
  }
  const faded = await spFade(0, 500);
  if (!faded || (handoffId != null && !ownsAudioHandoff(handoffId, "suno"))) return false;
  await spPlayer.pause().catch(()=>{});
  if (handoffId != null && !ownsAudioHandoff(handoffId, "suno")) return false;
  spIsPlaying = false;
  $("spPlayBtn").innerHTML = "&#9654;";
  return true;
}

async function stopSessionAudio() {
  // Ending a session owns the final handoff: invalidate any song lookup or
  // crossfade that could otherwise restart playback after the dashboard closes.
  const stopToken = ++audioHandoffId;
  preferenceGeneration += 1;
  karaokeGeneration += 1;
  $("karaokeAudio").pause();
  for (const node of instrumentSources) { try { node.stop(); } catch (_) {} }
  instrumentSources.clear();
  sunoLoadRequestId += 1;
  spotifyPlayRequestId += 1;
  sunoFetching = false;
  sunoPlaying = false;
  spIsPlaying = false;
  spLastPos = 0;
  $("sunoPlay").innerHTML = "&#9654;";
  $("spPlayBtn").innerHTML = "&#9654;";

  const stopSuno = sunoEls.map(async element => {
    await fadeEl(element, 0, 350);
    if (stopToken !== audioHandoffId) return;
    try {
      element.pause();
      element.currentTime = 0;
    } catch (_) {}
  });
  const stopSpotify = (async () => {
    if (!spPlayer) return;
    await spFade(0, 350);
    if (stopToken !== audioHandoffId) return;
    await spPlayer.pause().catch(() => {});
  })();
  await Promise.all([...stopSuno, stopSpotify]);
  await fetch("/api/anthropic_key", {method: "DELETE"});
  spKeySet = false;
  refreshSpotify();
}
$("spPlayBtn").addEventListener("click", async () => {
  if (!spPlayer) return;
  if (spIsPlaying && audioSource === "spotify") {
    const handoffId = ++audioHandoffId;
    await spotifyFadeStop(handoffId);
    return;
  }
  const requestId = ++spotifyPlayRequestId;
  if (!await claimAudio("spotify") || requestId !== spotifyPlayRequestId || audioSource !== "spotify") return;
  await spPlayer.resume().catch(()=>{});
  if (requestId !== spotifyPlayRequestId || audioSource !== "spotify") {
    await spPlayer.pause().catch(()=>{});
    return;
  }
  spIsPlaying = true;
  $("spPlayBtn").innerHTML = "&#10074;&#10074;";
  spFade(0.9, 700);
});
$("spNextBtn").addEventListener("click", () => spSkip("next"));
$("spPrevBtn").addEventListener("click", () => spSkip("prev"));
function spSkip(direction) {
  if (!spMode) return;
  spRequestTrack(direction);                 // re-prompt Claude / walk the playlist
}

/* position poll: timeline, lyric sync, end-of-track detection */
setInterval(async () => {
  if (!spPlayer || audioSource !== "spotify") return;
  let st = null;
  try { st = await spPlayer.getCurrentState(); } catch(e){}
  if (!st) return;
  const pos = st.position, dur = st.duration || spDuration;
  spDuration = dur;
  if (!spDragging && dur > 0) $("spBar").value = Math.round(1000 * pos / dur);
  $("spCur").textContent = fmtTime(pos / 1000);
  $("spEnd").textContent = fmtTime(dur / 1000);
  $("spPlayBtn").innerHTML = st.paused ? "&#9654;" : "&#10074;&#10074;";

  // track finished -> advance the loop. spLastPos is the latch: it only holds a
  // near-the-end value if we actually heard the song play there, and it resets to 0
  // the moment we fire, so this can't double-trigger. (The SDK's own
  // player_state_changed clears spIsPlaying before this poll runs, so the latch
  // must not depend on spIsPlaying.)
  if (st.paused && pos === 0 && dur > 0 && spLastPos > dur - 3000) {
    spLastPos = 0;
    spIsPlaying = false;
    spSkip("next");
    return;
  }
  if (!st.paused) spLastPos = pos;
}, 300);
$("spBar").addEventListener("pointerdown", () => spDragging = true);
$("spBar").addEventListener("change", async () => {
  if (spPlayer && spDuration) await spPlayer.seek(spDuration * $("spBar").value / 1000).catch(()=>{});
  spDragging = false;
});

refreshSpotify();

/* ============================ 8 · relief switching ============================ */
const reliefViews = {karaoke: $("rsKaraoke"), breathe: $("rsBreathe"), play: $("rsPlay")};
const reliefBtns  = {karaoke: $("rKaraoke"),  breathe: $("rBreathe"),  play: $("rPlay")};
let reliefMode = null;
function setRelief(mode) {
  if (mode === "play" && audioSource === "spotify") { alert("Switch to local music before using play-along."); return; }
  reliefMode = (reliefMode === mode) ? null : mode;
  if (reliefMode !== "karaoke") { karaokeGeneration += 1; $("karaokeAudio").pause(); }
  $("rsEmpty").hidden = reliefMode !== null;
  for (const k of Object.keys(reliefViews)) {
    const on = k === reliefMode;
    reliefBtns[k].classList.toggle("on", on);
    if (on) { reliefViews[k].hidden = false; requestAnimationFrame(() => reliefViews[k].classList.add("shown")); }
    else    { reliefViews[k].classList.remove("shown"); setTimeout(() => { if (reliefMode !== k) reliefViews[k].hidden = true; }, 400); }
  }
  karaokeActive = reliefMode === "karaoke";
  if (reliefMode === "karaoke") enterKaraoke();
  if (reliefMode === "breathe") enterBreathe(); else exitBreathe();
  if (reliefMode === "play")  { enterPlayalong(); setInstrument("piano"); }   // piano is ALWAYS the default
}
$("rKaraoke").addEventListener("click", () => setRelief("karaoke"));
$("rBreathe").addEventListener("click", () => setRelief("breathe"));
$("rPlay").addEventListener("click", () => setRelief("play"));

/* ============================ 9 · karaoke ============================ */
let karaokeActive = false, karaokeFetching = false, karaokeGeneration = 0;
async function enterKaraoke() {
  if (karaokeFetching) return;
  preferenceGeneration += 1; // A delayed recommendation cannot interrupt karaoke.
  const msg = $("karaokeMsg"); msg.hidden = false;
  karaokeFetching = true;
  const revision = ++karaokeGeneration;
  $("karaokeChoose").disabled = true;
  msg.textContent = "Loading karaoke…";
  try {
    const response = await fetch("/api/karaoke");
    const result = await response.json();
    if (revision !== karaokeGeneration || !karaokeActive) return;
    if (!result.ok) throw new Error("Karaoke unavailable.");
    if (!await claimAudio("karaoke")) throw new Error("Pause Spotify before starting karaoke.");
    if (revision !== karaokeGeneration || !karaokeActive) return;
    const song = result.song;
    const heading = document.createElement("h3");
    heading.textContent = song.title + " — " + song.author;
    const lyrics = document.createElement("div");
    lyrics.className = "static-lyrics"; lyrics.textContent = song.lyrics;
    $("lyricsBox").replaceChildren(heading, lyrics); $("lyricsBox").hidden = false;
    $("karaokeAudio").src = "/karaoke/" + encodeURIComponent(song.audio);
    await $("karaokeAudio").play();
    if (revision !== karaokeGeneration || !karaokeActive) { $("karaokeAudio").pause(); return; }
    msg.textContent = "Full supplied transcript · not synchronized to playback";
  } catch (error) {
    if (revision === karaokeGeneration) msg.textContent = "Could not start karaoke. Pause Spotify if needed, then press Restart karaoke.";
  } finally { karaokeFetching = false; $("karaokeChoose").disabled = false; }
}
$("karaokeChoose").addEventListener("click", enterKaraoke);
$("karaokeAudio").addEventListener("play", () => {
  if (audioSource !== "karaoke" || !karaokeActive) $("karaokeAudio").pause();
});

/* ============================ 10 · breathe ============================ */
let breatheOn = false, breatheBuffering = true;
let audioCtx = null, analyser = null, waveData = null, breatheRAF = 0;
let breatheCircleBpm = null, breatheCycleStart = 0;
const BMSG = "I apologize, but you must enable the AI-generated songs to use the breathe feature";

function ensureAudioGraph() {
  if (audioCtx) { audioCtx.resume().catch(()=>{}); return; }
  const AC = window.AudioContext || window.webkitAudioContext;
  audioCtx = new AC();
  analyser = audioCtx.createAnalyser();
  analyser.fftSize = 1024;
  waveData = new Uint8Array(analyser.fftSize);
  for (const el of sunoEls) {
    const src = audioCtx.createMediaElementSource(el);
    src.connect(audioCtx.destination);
    src.connect(analyser);
  }
}
function breatheSourceCheck() {
  if (!breatheOn) return;
  const blocked = audioSource === "spotify";
  if (blocked) setBuffering(true);
  $("breatheMsg").textContent = BMSG;
  $("breatheMsg").hidden = !blocked;
  $("breatheWrap").style.display = blocked ? "none" : "";
}
function enterBreathe() {
  breatheOn = true;
  ensureAudioGraph();
  breatheSourceCheck();
  if (audioSource === "spotify") return;    // blocked; breatheTick starts the loop once unblocked
  breatheRetarget(true);
  startBreatheLoop();
}
function exitBreathe() {
  if (!breatheOn) return;
  breatheOn = false;
  cancelAnimationFrame(breatheRAF); breatheRAF = 0;
  breatheCircleBpm = null;
  breatheCycleStart = 0;
  $("breatheLoading").hidden = true;
  $("bCircle").classList.remove("buffering");
}
function breatheRetarget(force) {
  const userBpm = Number((S && S.bpm) || 60);
  if (!Number.isFinite(userBpm) || userBpm <= 0) return;

  // circle_BPM = 5 × log₂(user_BPM). Preserve the current cycle phase when
  // BPM changes so the new value takes effect immediately without a visual jump.
  const circleBpm = 5 * Math.log2(userBpm);
  if (force || breatheBuffering || circleBpm !== breatheCircleBpm) {
    const now = performance.now();
    if (breatheCircleBpm && breatheCycleStart) {
      const oldCycleMs = 60000 / breatheCircleBpm;
      const phase = ((now - breatheCycleStart) % oldCycleMs + oldCycleMs) % oldCycleMs / oldCycleMs;
      breatheCycleStart = now - phase * (60000 / circleBpm);
    } else {
      breatheCycleStart = now;
    }
    breatheCircleBpm = circleBpm;
    $("breatheTarget").textContent =
      "circle " + circleBpm.toFixed(1) + " BPM · user " + userBpm.toFixed(1) + " BPM";
    setBuffering(false);
  }
}
function breatheTick(s) {
  if (!breatheOn) return;
  breatheSourceCheck();
  if (audioSource !== "suno") return;
  breatheRetarget(!breatheRAF);                    // recalculate from every live BPM update
  if (!breatheRAF) startBreatheLoop();             // resumed after Spotify ownership
}
function setBuffering(on) {
  breatheBuffering = on;
  $("bCircle").classList.toggle("buffering", on);
  $("breatheLoading").hidden = !on;
  $("breatheStatus").textContent = on ? "buffering · reading your BPM…" : "breathe with the circle";
}
function startBreatheLoop() {
  cancelAnimationFrame(breatheRAF);
  const canvas = $("waveCanvas"), cctx = canvas.getContext("2d");
  const loop = now => {
    if (!breatheOn) return;
    breatheRAF = requestAnimationFrame(loop);
    if (analyser) analyser.getByteTimeDomainData(waveData);
    renderBreathCircle(now);
    drawWave(cctx, canvas);
  };
  breatheRAF = requestAnimationFrame(loop);
}
function renderBreathCircle(now) {
  if (!breatheOn || breatheBuffering || !breatheCircleBpm) return;
  const c = $("bCircle");
  const cycleMs = 60000 / breatheCircleBpm;
  const phase = ((now - breatheCycleStart) % cycleMs + cycleMs) % cycleMs / cycleMs;
  // A cosine gives equally long contraction and expansion phases: fully
  // expanded at cycle BPM ticks, fully contracted halfway between them.
  const amount = (1 + Math.cos(2 * Math.PI * phase)) / 2;
  c.style.transform = "scale(" + (0.55 + 0.45 * amount).toFixed(4) + ")";
}
function drawWave(cctx, canvas) {
  const r = canvas.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const W = Math.round(r.width * dpr), H = Math.round(r.height * dpr);
  if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; }
  cctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  cctx.clearRect(0, 0, r.width, r.height);
  cctx.strokeStyle = css("--c-bpm"); cctx.lineWidth = 1.6; cctx.lineJoin = "round";
  cctx.beginPath();
  const n = waveData ? waveData.length : 0;
  for (let i = 0; i < n; i++) {
    const x = (i / (n - 1)) * r.width;
    const y = r.height / 2 + ((waveData[i] - 128) / 128) * (r.height / 2) * 0.95;
    i === 0 ? cctx.moveTo(x, y) : cctx.lineTo(x, y);
  }
  cctx.stroke();
}

/* ============================ 11 · play-along ============================ */
let paInstrument = "piano", paBuilt = false;
const PIANO_KEYS = [                                     // one octave: C4..B4
  {note: 60, key: "a", label: "A", white: true,  name: "C"},
  {note: 61, key: "w", label: "W", white: false, name: "C#", after: 0},
  {note: 62, key: "s", label: "S", white: true,  name: "D"},
  {note: 63, key: "e", label: "E", white: false, name: "D#", after: 1},
  {note: 64, key: "d", label: "D", white: true,  name: "E"},
  {note: 65, key: "f", label: "F", white: true,  name: "F"},
  {note: 66, key: "t", label: "T", white: false, name: "F#", after: 3},
  {note: 67, key: "g", label: "G", white: true,  name: "G"},
  {note: 68, key: "y", label: "Y", white: false, name: "G#", after: 4},
  {note: 69, key: "h", label: "H", white: true,  name: "A"},
  {note: 70, key: "u", label: "U", white: false, name: "A#", after: 5},
  {note: 71, key: "j", label: "J", white: true,  name: "B"},
];
const DRUMS = [
  {id: "kick",    label: "Kick",     key: "a"},
  {id: "hihat",   label: "Hi-hat",   key: "s"},
  {id: "snare",   label: "Snare",    key: "d"},
  {id: "lowtom",  label: "Low-tom",  key: "f"},
  {id: "midtom",  label: "Mid-tom",  key: "g"},
  {id: "hightom", label: "High-tom", key: "h"},
  {id: "crash",   label: "Crash",    key: "j"},
  {id: "ride",    label: "Ride",     key: "k"},
];
function enterPlayalong() {
  ensureAudioGraph();                                   // shares the AudioContext
  if (paBuilt) return;
  paBuilt = true;
  const piano = $("pianoBox");
  const whites = PIANO_KEYS.filter(k => k.white);
  whites.forEach(k => {
    const el = document.createElement("div");
    el.className = "pkey";
    el.innerHTML = `<span>${k.label}</span>`;
    el.dataset.note = k.note;
    piano.appendChild(el);
    k.el = el;
  });
  PIANO_KEYS.filter(k => !k.white).forEach(k => {
    const el = document.createElement("div");
    el.className = "pkey-black";
    el.innerHTML = `<span>${k.label}</span>`;
    el.dataset.note = k.note;
    const frac = (k.after + 1) / whites.length;         // sits on the boundary after white #after
    el.style.left = "calc(" + (frac * 100) + "% - 4.5%)";
    piano.appendChild(el);
    k.el = el;
  });
  PIANO_KEYS.forEach(k => {
    k.el.addEventListener("pointerdown", e => { e.preventDefault(); pressPiano(k); });
  });
  const drums = $("drumBox");
  DRUMS.forEach(d => {
    const el = document.createElement("button");
    el.className = "dpad";
    el.innerHTML = `${d.label}<small>${d.key.toUpperCase()}</small>`;
    el.addEventListener("pointerdown", e => { e.preventDefault(); pressDrum(d); });
    drums.appendChild(el);
    d.el = el;
  });
}
$("paPiano").addEventListener("click", () => setInstrument("piano"));
$("paDrums").addEventListener("click", () => setInstrument("drums"));
function setInstrument(which) {
  paInstrument = which;
  $("paPiano").classList.toggle("on", which === "piano");
  $("paDrums").classList.toggle("on", which === "drums");
  $("pianoBox").hidden = which !== "piano";
  $("drumBox").hidden = which !== "drums";
}
function flash(el) { el.classList.add("down"); setTimeout(() => el.classList.remove("down"), 130); }
function pressPiano(k) { flash(k.el); playNote(k.note); }
function pressDrum(d)  { flash(d.el); playDrum(d.id); }

document.addEventListener("keydown", e => {
  if (reliefMode !== "play" || e.repeat) return;
  const tag = (document.activeElement && document.activeElement.tagName) || "";
  if (tag === "INPUT" || tag === "TEXTAREA") return;
  const key = e.key.toLowerCase();
  if (paInstrument === "piano") {
    const k = PIANO_KEYS.find(p => p.key === key);
    if (k) { pressPiano(k); e.preventDefault(); }
  } else {
    const d = DRUMS.find(p => p.key === key);
    if (d) { pressDrum(d); e.preventDefault(); }
  }
});

function playNote(midi) {
  if (audioSource === "spotify") { alert("Switch to local music before using instruments."); return; }
  ensureAudioGraph();
  const t = audioCtx.currentTime;
  const f = 440 * Math.pow(2, (midi - 69) / 12);
  const g = audioCtx.createGain();
  g.gain.setValueAtTime(0, t);
  g.gain.linearRampToValueAtTime(0.5, t + 0.012);
  g.gain.exponentialRampToValueAtTime(0.001, t + 1.4);
  const o1 = audioCtx.createOscillator(); o1.type = "triangle"; o1.frequency.value = f;
  const o2 = audioCtx.createOscillator(); o2.type = "sine";     o2.frequency.value = f * 2;
  const g2 = audioCtx.createGain(); g2.gain.value = 0.25;
  o1.connect(g); o2.connect(g2); g2.connect(g); g.connect(audioCtx.destination);
  instrumentSources.add(o1); instrumentSources.add(o2);
  o1.onended = () => instrumentSources.delete(o1);
  o2.onended = () => instrumentSources.delete(o2);
  o1.start(t); o2.start(t);
  o1.stop(t + 1.5); o2.stop(t + 1.5);
}
function noiseBuffer() {
  if (noiseBuffer._b) return noiseBuffer._b;
  const b = audioCtx.createBuffer(1, audioCtx.sampleRate, audioCtx.sampleRate);
  const d = b.getChannelData(0);
  for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
  return (noiseBuffer._b = b);
}
function playDrum(id) {
  if (audioSource === "spotify") { alert("Switch to local music before using instruments."); return; }
  ensureAudioGraph();
  const t = audioCtx.currentTime;
  const out = audioCtx.createGain(); out.connect(audioCtx.destination);
  const tone = (f0, f1, dur, vol) => {
    const o = audioCtx.createOscillator(), g = audioCtx.createGain();
    o.frequency.setValueAtTime(f0, t);
    o.frequency.exponentialRampToValueAtTime(Math.max(f1, 1), t + dur);
    g.gain.setValueAtTime(vol, t);
    g.gain.exponentialRampToValueAtTime(0.001, t + dur);
    instrumentSources.add(o); o.onended = () => instrumentSources.delete(o);
    o.connect(g); g.connect(out); o.start(t); o.stop(t + dur + 0.05);
  };
  const noise = (dur, vol, filterType, freq) => {
    const src = audioCtx.createBufferSource(); src.buffer = noiseBuffer();
    const g = audioCtx.createGain();
    g.gain.setValueAtTime(vol, t);
    g.gain.exponentialRampToValueAtTime(0.001, t + dur);
    let node = src;
    if (filterType) {
      const fl = audioCtx.createBiquadFilter(); fl.type = filterType; fl.frequency.value = freq;
      src.connect(fl); node = fl;
    }
    instrumentSources.add(src); src.onended = () => instrumentSources.delete(src);
    node.connect(g); g.connect(out); src.start(t); src.stop(t + dur + 0.05);
  };
  switch (id) {
    case "kick":    tone(150, 40, 0.45, 1.0); break;
    case "snare":   tone(210, 160, 0.15, 0.4); noise(0.18, 0.6, "highpass", 1200); break;
    case "hihat":   noise(0.06, 0.4, "highpass", 7500); break;
    case "lowtom":  tone(120, 70,  0.4, 0.8); break;
    case "midtom":  tone(170, 100, 0.35, 0.8); break;
    case "hightom": tone(230, 140, 0.3, 0.8); break;
    case "crash":   noise(1.1, 0.5, "bandpass", 4800); break;
    case "ride":    noise(0.7, 0.3, "bandpass", 6800); tone(720, 700, 0.4, 0.08); break;
  }
}

async function clearSpotifyData() {
  spotifyConnectionGeneration += 1;
  spConnected = false;
  preferenceGeneration += 1; karaokeGeneration += 1;
  await stopSessionAudio();
  if (spPlayer) spPlayer.disconnect();
  spPlayer = null; spDeviceId = null;
  spTrack = null; spMode = null; spValue = ""; spLastPos = 0; spDuration = 0;
  playlistCatalog = null; spPlaylistId = null;
  $("playlistList")?.replaceChildren();
  $("spArtwork").removeAttribute("src"); $("spOpen").removeAttribute("href");
  $("spPlayerUI").hidden = true; $("spTrackName").textContent = "";
  $("spModeSub").textContent = ""; $("prefInput").value = "";
  clearPrefMessage();
  await fetch("/api/spotify/disconnect", {method: "POST"});
  audioSource = "suno";
  await refreshSpotify();
}
$("spDisconnect").addEventListener("click", clearSpotifyData);
$("antRemove").addEventListener("click", async () => {
  preferenceGeneration += 1; karaokeGeneration += 1;
  await fetch("/api/anthropic_key", {method:"DELETE"});
  await refreshSpotify();
});
setInterval(refreshSpotify, 30000);
