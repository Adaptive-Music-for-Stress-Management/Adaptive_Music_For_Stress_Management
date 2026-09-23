"use strict";

const PORTAL_GRAPHS = [
  ["bpm", "BPM"], ["hrv_diff", "HRV differential"],
  ["right_brain", "EEG right brain"], ["left_brain", "EEG left brain"],
  ["right_ear", "EEG right ear"], ["left_ear", "EEG left ear"],
];

let supabaseClient = null;
let portalUser = null;
let selectedSession = null;
let authMode = "signin";
let landingSignalIndex = 0;
let landingAnalysisIndex = 0;
let landingPlayIndex = 0;

const PRIMARY_VIEWS = new Set(["landing", "accountDash", "flow", "dash"]);
const portalShow = (id, visible) => {
  const element = document.getElementById(id);
  if (!PRIMARY_VIEWS.has(id)) {
    element.hidden = !visible;
    return;
  }
  if (visible) {
    element.hidden = false;
    element.classList.remove("portal-fade-out");
    element.classList.add("portal-fade-in");
    setTimeout(() => element.classList.remove("portal-fade-in"), 520);
  } else if (!element.hidden) {
    element.classList.remove("portal-fade-in");
    element.classList.add("portal-fade-out");
    setTimeout(() => {
      if (element.classList.contains("portal-fade-out")) element.hidden = true;
    }, 320);
  }
};
const portalMessage = (id, text, error = false) => {
  const element = document.getElementById(id);
  element.textContent = text || "";
  element.classList.toggle("err", !!error);
};

async function configureSupabase() {
  let config = {};
  try { config = await (await fetch("/api/config")).json(); } catch (_) {}
  if (!config.supabase_configured || !window.supabase) {
    portalShow("supabaseNotice", true);
    document.getElementById("authSubmit").disabled = true;
    return;
  }
  supabaseClient = window.supabase.createClient(config.supabase_url, config.supabase_anon_key);
  supabaseClient.auth.onAuthStateChange((_event, session) => setPortalUser(session?.user || null));
  const {data} = await supabaseClient.auth.getSession();
  await setPortalUser(data.session?.user || null);
}

async function setPortalUser(user) {
  portalUser = user;
  if (!user) {
    portalShow("landing", true);
    portalShow("accountDash", false);
    portalShow("flow", false);
    portalShow("dash", false);
    return;
  }
  document.getElementById("accountEmail").textContent = user.email || "";
  portalShow("landing", false);
  // Supabase emits TOKEN_REFRESHED when a background tab becomes visible.
  // Keep the live dashboard in front during that event instead of resetting
  // the user to the account dashboard and making it look like the session ended.
  const liveViewOpen = window.AdaptuneSession?.isActive?.() ||
    !document.getElementById("flow").hidden || !document.getElementById("dash").hidden;
  portalShow("accountDash", !liveViewOpen);
  try {
    await supabaseClient.from("users").upsert({id: user.id, email: user.email || ""});
  } catch (_) {}
  await loadSessions();
}

document.querySelectorAll("[data-auth-mode]").forEach(button => {
  button.addEventListener("click", () => {
    authMode = button.dataset.authMode;
    document.querySelectorAll("[data-auth-mode]").forEach(item => item.classList.toggle("on", item === button));
    document.getElementById("authTitle").textContent = authMode === "signin" ? "Welcome back" : "Create your account";
    document.getElementById("authIntro").textContent = authMode === "signin"
      ? "Open your private Adaptune session dashboard."
      : "Save sessions securely and revisit your progress.";
    document.getElementById("authSubmit").textContent = authMode === "signin" ? "Log in" : "Create account";
    document.getElementById("authPassword").autocomplete = authMode === "signin" ? "current-password" : "new-password";
    portalMessage("authMessage", "");
  });
});

document.getElementById("authForm").addEventListener("submit", async event => {
  event.preventDefault();
  if (!supabaseClient) return;
  const email = document.getElementById("authEmail").value.trim();
  const password = document.getElementById("authPassword").value;
  const submit = document.getElementById("authSubmit");
  submit.disabled = true;
  portalMessage("authMessage", authMode === "signin" ? "Logging in…" : "Creating account…");
  const result = authMode === "signin"
    ? await supabaseClient.auth.signInWithPassword({email, password})
    : await supabaseClient.auth.signUp({email, password});
  submit.disabled = false;
  if (result.error) {
    portalMessage("authMessage", result.error.message, true);
  } else if (authMode === "signup" && !result.data.session) {
    portalMessage("authMessage", "Check your email to confirm your account, then log in.");
  }
});

document.getElementById("signOutBtn").addEventListener("click", async () => {
  await clearSpotifyData();
  await fetch("/api/session/clear", {method:"POST"});
  document.getElementById("analysisConsent").checked = false;
  if (supabaseClient) await supabaseClient.auth.signOut();
});

document.getElementById("startSessionBtn").addEventListener("click", () => {
  document.getElementById("flow").classList.remove("fade-out");
  portalShow("accountDash", false);
  portalShow("flow", true);
  portalShow("dash", false);
  if (typeof showScreen === "function") showScreen("scr-device");
});

document.getElementById("endSessionBtn").addEventListener("click", saveCurrentSession);

async function saveCurrentSession() {
  if (window.AdaptuneSession?.stopAudio) await window.AdaptuneSession.stopAudio();
  if (!supabaseClient || !portalUser || !window.AdaptuneSession) return;
  const button = document.getElementById("endSessionBtn");
  const original = button.textContent;
  button.disabled = true;
  button.textContent = "SAVING…";
  try {
    const snapshot = window.AdaptuneSession.snapshot();
    const sessionID = crypto.randomUUID();
    const graphPaths = {};
    for (const [key] of PORTAL_GRAPHS) {
      const dataURL = snapshot.graph_images[key];
      if (!dataURL) continue;
      const blob = await (await fetch(dataURL)).blob();
      const path = `${portalUser.id}/${sessionID}/${key}.png`;
      const {error} = await supabaseClient.storage.from("session-graphs").upload(path, blob, {
        contentType: "image/png", upsert: true,
      });
      if (error) throw error;
      graphPaths[key] = path;
    }
    const {error} = await supabaseClient.from("sessions").insert({
      id: sessionID,
      user_id: portalUser.id,
      started_at: snapshot.started_at,
      ended_at: snapshot.ended_at,
      graph_images: graphPaths,
      stress_points: snapshot.stress_points,
      avg_stress: snapshot.avg_stress,
    });
    if (error) throw error;
    portalShow("dash", false);
    document.getElementById("dash").classList.remove("shown");
    portalShow("flow", false);
    portalShow("accountDash", true);
    window.AdaptuneSession?.end?.();
    await loadSessions();
  } catch (error) {
    window.alert(`Session could not be saved: ${error.message || error}`);
  } finally {
    button.disabled = false;
    button.textContent = original;
  }
}

async function loadSessions() {
  if (!supabaseClient || !portalUser) return;
  const {data, error} = await supabaseClient.from("sessions")
    .select("id,started_at,ended_at,graph_images,stress_points,avg_stress")
    .order("started_at", {ascending: false});
  const grid = document.getElementById("sessionGrid");
  grid.replaceChildren();
  if (error) {
    document.getElementById("emptySessions").textContent = `Sessions could not be loaded: ${error.message}`;
    portalShow("emptySessions", true);
    return;
  }
  portalShow("emptySessions", !data?.length);
  (data || []).forEach(session => {
    const start = new Date(session.started_at);
    const button = document.createElement("button");
    button.className = "session-card";
    button.innerHTML = `<div class="date">${start.toLocaleDateString([], {dateStyle:"long"})}</div>` +
      `<div class="time">${start.toLocaleTimeString([], {timeStyle:"short"})}</div>` +
      `<div class="score">${session.avg_stress == null ? "—" : Number(session.avg_stress).toFixed(1)} <small>AVG STRESS</small></div>`;
    button.addEventListener("click", () => openSession(session));
    grid.appendChild(button);
  });
}

async function openSession(session) {
  selectedSession = session;
  const date = new Date(session.started_at);
  document.getElementById("sessionDate").textContent = date.toLocaleString([], {dateStyle:"full", timeStyle:"short"});
  document.getElementById("savedAverage").textContent = session.avg_stress == null ? "—" : Number(session.avg_stress).toFixed(1);
  document.getElementById("analysisResult").textContent = "";
  document.getElementById("analysisKey").value = "";
  const graphGrid = document.getElementById("savedGraphs");
  graphGrid.replaceChildren();
  for (const [key, label] of PORTAL_GRAPHS) {
    const card = document.createElement("div");
    card.className = "saved-graph";
    card.innerHTML = `<h3>${label.toUpperCase()}</h3>`;
    const path = session.graph_images?.[key];
    if (!path) {
      card.insertAdjacentHTML("beforeend", '<div class="no-reading">NO READING FOR THIS SESSION</div>');
    } else {
      const {data, error} = await supabaseClient.storage.from("session-graphs").download(path);
      if (error || !data) card.insertAdjacentHTML("beforeend", '<div class="no-reading">IMAGE UNAVAILABLE</div>');
      else {
        const image = document.createElement("img");
        image.alt = `${label} graph from saved session`;
        image.src = URL.createObjectURL(data);
        card.appendChild(image);
      }
    }
    graphGrid.appendChild(card);
  }
  portalShow("sessionOverlay", true);
  // A hidden canvas reports a zero-sized layout. Wait until the modal has
  // participated in layout before drawing the saved time series.
  requestAnimationFrame(() => requestAnimationFrame(() =>
    drawStressChart(document.getElementById("savedStressCanvas"), session.stress_points || [])));
}

document.getElementById("sessionClose").addEventListener("click", () => portalShow("sessionOverlay", false));
document.getElementById("sessionOverlay").addEventListener("click", event => {
  if (event.target.id === "sessionOverlay") portalShow("sessionOverlay", false);
});

document.getElementById("analyzeSessionBtn").addEventListener("click", async () => {
  const button = document.getElementById("analyzeSessionBtn");
  if (button.disabled) return;
  if (!document.getElementById("analysisConsent").checked) { portalMessage("analysisResult", "Please give permission to send stress readings first.", true); return; }
  const key = document.getElementById("analysisKey").value.trim();
  if (!selectedSession || !key) {
    portalMessage("analysisResult", "Enter your Anthropic API key first.", true);
    return;
  }
  const sessionBeingAnalyzed = selectedSession;
  button.disabled = true;
  portalMessage("analysisResult", "Analyzing your session…");
  try {
    const saved = await fetch("/api/anthropic_key", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify({key})});
    if (!saved.ok) throw new Error("Could not securely save the key. Check your connection.");
    document.getElementById("analysisKey").value = "";
    const response = await fetch("/api/session-analysis", {
      method:"POST", headers:{"Content-Type":"application/json"},
      body:JSON.stringify({consent: true, stress_points:sessionBeingAnalyzed.stress_points || [], avg_stress:sessionBeingAnalyzed.avg_stress}),
    });
    const result = await response.json();
    if (selectedSession !== sessionBeingAnalyzed) return;
    if (!response.ok || !result.ok) throw new Error(result.error || "Analysis failed");
    portalMessage("analysisResult", "AI-generated wellness information — may be inaccurate.\n\n" + result.analysis);
  } catch (error) {
    portalMessage("analysisResult", error.message || String(error), true);
  } finally { button.disabled = false; }
});

function drawStressChart(canvas, points) {
  const normalized = (points || []).map(point => {
    if (Array.isArray(point)) return {x: Number(point[0]), y: Number(point[1])};
    return {x: Number(point?.x ?? point?.seconds), y: Number(point?.y ?? point?.stress)};
  }).filter(point => Number.isFinite(point.x) && Number.isFinite(point.y));
  const empty = document.getElementById("savedStressEmpty");
  if (empty) empty.hidden = normalized.length > 0;
  const rect = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.round(rect.width * ratio));
  canvas.height = Math.max(1, Math.round(rect.height * ratio));
  const context = canvas.getContext("2d");
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  const width = rect.width, height = rect.height;
  context.clearRect(0, 0, width, height);
  context.strokeStyle = "#1c2733";
  for (let i = 1; i < 4; i++) { const y = height * i / 4; context.beginPath(); context.moveTo(0,y); context.lineTo(width,y); context.stroke(); }
  if (!normalized.length) return;
  const maxX = Math.max(1, ...normalized.map(point => point.x));
  const xPad = 8, yPad = 12;
  const pointPosition = point => ({
    x: xPad + (width - xPad * 2) * Math.max(0, point.x) / maxX,
    y: yPad + (height - yPad * 2) * (1 - Math.max(0, Math.min(100, point.y)) / 100),
  });
  if (normalized.length === 1) {
    const point = pointPosition(normalized[0]);
    context.fillStyle = "#2dd48f";
    context.beginPath(); context.arc(point.x, point.y, 4, 0, Math.PI * 2); context.fill();
    return;
  }
  const fill = context.createLinearGradient(0, 0, 0, height);
  fill.addColorStop(0, "rgba(45,212,143,.22)");
  fill.addColorStop(1, "rgba(45,212,143,0)");
  context.beginPath();
  normalized.forEach((point, index) => {
    const position = pointPosition(point);
    index ? context.lineTo(position.x, position.y) : context.moveTo(position.x, position.y);
  });
  const last = pointPosition(normalized[normalized.length - 1]);
  const first = pointPosition(normalized[0]);
  context.lineTo(last.x, height - yPad); context.lineTo(first.x, height - yPad); context.closePath();
  context.fillStyle = fill; context.fill();
  context.strokeStyle = "#2dd48f"; context.lineWidth = 2.5; context.beginPath();
  normalized.forEach((point, index) => {
    const position = pointPosition(point);
    const x = position.x, y = position.y;
    index ? context.lineTo(x,y) : context.moveTo(x,y);
  });
  context.stroke();
}

function drawLandingSignal() {
  const canvas = document.getElementById("landingGraph");
  const rect = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.round(rect.width * ratio); canvas.height = Math.round(rect.height * ratio);
  const context = canvas.getContext("2d"); context.setTransform(ratio,0,0,ratio,0,0);
  document.getElementById("landingGraphName").textContent = PORTAL_GRAPHS[landingSignalIndex][1].toUpperCase();
  context.clearRect(0,0,rect.width,rect.height); context.strokeStyle="#1c2733";
  for (let i=1;i<4;i++){const y=rect.height*i/4;context.beginPath();context.moveTo(0,y);context.lineTo(rect.width,y);context.stroke();}
  const colors=["#2dd48f","#e8a04c","#4fa3e0","#e87a9b","#3ac0c9","#b18cf2"];
  const seriesCount = landingSignalIndex < 2 ? 1 : 5;
  for(let series=0;series<seriesCount;series++){
    context.strokeStyle = seriesCount === 1 ? colors[landingSignalIndex] : ["#7aa2ff","#42d8dc","#64e28b","#ffd166","#f58bff"][series];
    context.lineWidth=2;context.beginPath();
    for(let i=0;i<100;i++){const x=rect.width*i/99;const y=rect.height*(.50+.13*Math.sin(i*.13+series*1.2)+.04*Math.sin(i*.51+landingSignalIndex));i?context.lineTo(x,y):context.moveTo(x,y);}
    context.stroke();
  }
}

function renderPlayPreview() {
  const stage = document.getElementById("landingPlayStage");
  if (landingPlayIndex === 0) {
    stage.innerHTML = `<div class="preview-kicker mono">PIANO</div><div class="landing-keys">${["C","D","E","F","G","A","B"].map(note=>`<button class="landing-key" data-note="${note}">${note}</button>`).join("")}</div>`;
  } else if (landingPlayIndex === 1) {
    stage.innerHTML = '<div class="preview-kicker mono">DRUMS</div><div class="landing-drums">'+["Kick","Hat","Snare","Tom","Crash","Ride"].map(name=>`<button class="landing-drum">${name}</button>`).join("")+"</div>";
  } else {
    stage.innerHTML = '<div class="preview-kicker mono">KARAOKE</div><div class="landing-lyrics"><span>Follow the feeling</span><b>sing into the calm</b><span>full lyrics, no timing</span></div>';
  }
  stage.querySelectorAll("[data-note]").forEach(button => button.addEventListener("click", () => playPreviewNote(button.dataset.note)));
}

function playPreviewNote(note) {
  if (audioSource === "spotify") { alert("Switch to local music before using play-along."); return; }
  const frequencies={C:261.63,D:293.66,E:329.63,F:349.23,G:392,A:440,B:493.88};
  const audioContext = new (window.AudioContext || window.webkitAudioContext)();
  const oscillator=audioContext.createOscillator(), gain=audioContext.createGain();
  instrumentSources.add(oscillator);
  oscillator.onended = () => { instrumentSources.delete(oscillator); audioContext.close(); };
  oscillator.frequency.value=frequencies[note];gain.gain.setValueAtTime(.12,audioContext.currentTime);gain.gain.exponentialRampToValueAtTime(.001,audioContext.currentTime+.5);oscillator.connect(gain).connect(audioContext.destination);oscillator.start();oscillator.stop(audioContext.currentTime+.5);
}

document.querySelectorAll("[data-carousel]").forEach(button => button.addEventListener("click", () => {
  const delta = button.classList.contains("next") ? 1 : -1;
  if (button.dataset.carousel === "signals") { landingSignalIndex=(landingSignalIndex+delta+PORTAL_GRAPHS.length)%PORTAL_GRAPHS.length;drawLandingSignal(); }
  if (button.dataset.carousel === "analysis") { landingAnalysisIndex=(landingAnalysisIndex+delta+2)%2;portalShow("analysisMeterPreview",landingAnalysisIndex===0);portalShow("analysisBreathePreview",landingAnalysisIndex===1); }
  if (button.dataset.carousel === "play") { landingPlayIndex=(landingPlayIndex+delta+3)%3;renderPlayPreview(); }
}));

const demoSongs=["A calmer track is ready","Breathe between the notes","Slow light, steady pulse"];
let demoSong=0,demoPlaying=false;
function changeDemoSong(delta){demoSong=(demoSong+delta+demoSongs.length)%demoSongs.length;document.getElementById("demoSongName").textContent=demoSongs[demoSong];}
document.getElementById("demoPrev").addEventListener("click",()=>changeDemoSong(-1));
document.getElementById("demoNext").addEventListener("click",()=>changeDemoSong(1));
document.getElementById("demoPlay").addEventListener("click",event=>{demoPlaying=!demoPlaying;event.currentTarget.textContent=demoPlaying?"Ⅱ":"▶";});

window.addEventListener("resize", drawLandingSignal);
renderPlayPreview();
requestAnimationFrame(drawLandingSignal);
configureSupabase();

document.getElementById("analysisRemoveKey").addEventListener("click", async () => {
  await fetch("/api/anthropic_key", {method:"DELETE"});
  document.getElementById("analysisKey").value = "";
  document.getElementById("analysisConsent").checked = false;
  portalMessage("analysisResult", "API key removed.");
  await refreshSpotify();
});
