'use strict';

const ICON_PLAY = '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>';
const ICON_PAUSE = '<svg viewBox="0 0 24 24"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>';
const AUDIO_EXTENSIONS = ['mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'wav', 'flac'];
// The phone plays a video's sound and the karaoke screen shows its picture.
const VIDEO_EXTENSIONS = ['mp4', 'm4v', 'mov', 'webm', 'mkv'];
const JOB_LABELS = { queued: 'Waiting', fetching: 'Looking up…', downloading: 'Downloading', done: 'Added', failed: 'Failed' };

// "/?screen" opens just the karaoke screen, e.g. in a window on a TV.
const SCREEN_MODE = new URLSearchParams(location.search).has('screen');
const SYNC_STEP_MS = 100;
const SYNC_LIMIT_MS = 3000;

const state = {
  pin: null,
  pollTimer: null,
  library: { version: -1, folders: [], tracks: [] },
  player: null,
  playerReceivedAt: 0,
  selectedFolder: 'all',
  searchQuery: '',
  ytSearch: 0, // counts YouTube searches, so a stale one can't show its results
  seeking: false,
  volumeDragging: false,
  currentTrackId: null,
  jobRows: new Map(),
};

// The karaoke screen: the current song's video and lyrics, following the phone.
const stage = {
  trackId: undefined, // song whose video and lyrics are loaded; null when nothing plays
  hasVideo: false,
  subtitles: [],
  lyricsOn: true, // off for every song once turned off, e.g. for videos with the words in the picture
  lyricsLang: null,
  cues: [],
  clock: null, // estimate of the phone's playback position, see updatePhoneClock
  offsetMs: 0, // how much later than the music the video and lyrics are shown
  barTimer: null,
};

const $ = (id) => document.getElementById(id);

function el(tag, props = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === 'class') node.className = value;
    else if (key === 'text') node.textContent = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value);
  }
  for (const child of children) node.append(child);
  return node;
}

// Per-browser settings. Storage may be unavailable (private mode); then nothing is remembered.
const prefs = {
  get(key) {
    try { return localStorage.getItem(key); } catch { return null; }
  },
  set(key, value) {
    try { localStorage.setItem(key, value); } catch { /* not remembered */ }
  },
  remove(key) {
    try { localStorage.removeItem(key); } catch { /* not remembered */ }
  },
};

function formatTime(ms) {
  if (ms == null || !isFinite(ms) || ms < 0) return '0:00';
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`;
}

let toastTimer = null;
function toast(message, isError = false) {
  const node = $('toast');
  node.textContent = message;
  node.classList.toggle('error', isError);
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { node.hidden = true; }, isError ? 5000 : 3000);
}

// ---------- API ----------

class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function api(path, { method = 'GET', body } = {}) {
  const headers = { 'X-Pin': state.pin || '' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  let res;
  try {
    res = await fetch('/api/' + path, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new ApiError(0, "Can't reach the phone");
  }
  let data = null;
  try { data = await res.json(); } catch { /* empty body */ }
  if (!res.ok) throw new ApiError(res.status, (data && data.error) || `Request failed (${res.status})`);
  return data;
}

// Runs a user action, reporting failures as a toast and a bad PIN as a logout.
async function run(action) {
  try {
    return await action();
  } catch (e) {
    if (e.status === 401) logout('The PIN changed on the phone. Enter the new one.');
    else toast(e.message, true);
  }
}

async function playerCommand(path, body) {
  const status = await run(() => api('player/' + path, { method: 'POST', body: body ?? {} }));
  if (status) applyPlayer(status);
}

// ---------- Login / polling ----------

async function login(pin) {
  state.pin = pin;
  try {
    await api('ping');
  } catch (e) {
    state.pin = null;
    throw e;
  }
  prefs.set('mc-pin', pin);
  $('login').hidden = true;
  $('app').hidden = SCREEN_MODE;
  state.library.version = -1;
  stage.trackId = undefined; // reload media, whose links carry the PIN
  poll();
}

function showLogin(message = '', prefill = '') {
  state.pin = null;
  clearTimeout(state.pollTimer);
  $('app').hidden = true;
  $('stage').hidden = true;
  $('stage-video').pause();
  $('login').hidden = false;
  $('login-error').textContent = message;
  $('pin-input').value = prefill;
  $('pin-input').focus();
}

function logout(message = '') {
  prefs.remove('mc-pin');
  showLogin(message);
}

async function poll() {
  clearTimeout(state.pollTimer);
  if (!state.pin) return;
  try {
    const sent = performance.now();
    const status = await api('status');
    setConnected(true);
    // The phone read its position somewhere between sending and receiving; take the middle.
    applyPlayer(status.player, (sent + performance.now()) / 2);
    if (!SCREEN_MODE) {
      renderJobs(status.jobs);
      renderYtDlp(status.ytDlp);
      if (status.libraryVersion !== state.library.version) await refreshLibrary();
    }
  } catch (e) {
    if (e.status === 401) {
      logout('The PIN changed on the phone. Enter the new one.');
      return;
    }
    setConnected(false);
  }
  if (state.pin) state.pollTimer = setTimeout(poll, 1000);
}

function setConnected(ok) {
  $('conn').classList.toggle('offline', !ok);
  $('conn-text').textContent = ok ? 'Connected' : "Can't reach the phone";
  $('stage-offline').hidden = ok;
}

async function refreshLibrary() {
  state.library = await api('library');
  const folderStillExists =
    state.selectedFolder === 'all' || state.library.folders.some((f) => f.id === state.selectedFolder);
  if (!folderStillExists) state.selectedFolder = 'all';
  renderFolders();
  renderTracks();
}

// ---------- Player ----------

function applyPlayer(player, sampledAt = performance.now()) {
  state.player = player;
  state.playerReceivedAt = performance.now();
  updatePhoneClock(player, sampledAt);
  renderPlayer();
}

function folderName(id) {
  if (id === 'all') return 'All music';
  return state.library.folders.find((f) => f.id === id)?.name ?? '';
}

function currentPosition() {
  const p = state.player;
  if (!p) return 0;
  let pos = p.positionMs;
  if (p.playing && p.processing === 'ready') pos += performance.now() - state.playerReceivedAt;
  return p.durationMs ? Math.min(pos, p.durationMs) : pos;
}

function renderPlayer() {
  const p = state.player;
  if (!p) return;
  const track = p.track;
  $('now-title').textContent = track ? track.title : 'Nothing playing';
  const sub = [];
  if (track?.artist) sub.push(track.artist);
  const source = p.queueSource && folderName(p.queueSource);
  if (source) sub.push('Playing from ' + source);
  $('now-sub').textContent = sub.join(' · ');

  const playBtn = $('btn-play');
  playBtn.innerHTML = p.playing ? ICON_PAUSE : ICON_PLAY;
  playBtn.title = p.playing ? 'Pause' : 'Play';
  playBtn.setAttribute('aria-label', playBtn.title);

  $('btn-shuffle').classList.toggle('active', p.shuffle);
  $('btn-repeat').classList.toggle('active', p.repeat !== 'off');
  $('repeat-one').hidden = p.repeat !== 'one';
  $('btn-repeat').title = { off: 'Repeat: off', all: 'Repeat: all', one: 'Repeat: this song' }[p.repeat];

  if (!state.volumeDragging) $('volume').value = Math.round(p.volume * 100);
  renderSeek();

  const trackId = track?.id ?? null;
  if (trackId !== state.currentTrackId) {
    state.currentTrackId = trackId;
    highlightCurrentTrack();
  }
  renderFolderPlayingDots();
  renderStage();
}

function renderSeek() {
  const p = state.player;
  if (!p || state.seeking) return;
  const duration = p.durationMs ?? 0;
  const seek = $('seek');
  seek.max = duration;
  seek.value = currentPosition();
  seek.disabled = !p.track || !duration;
  $('pos').textContent = formatTime(currentPosition());
  $('dur').textContent = formatTime(duration);
}

// ---------- Karaoke screen ----------

// Video and subtitle elements can't send the PIN header, so it goes in the link.
function mediaUrl(path) {
  return `/api/${path}?pin=${encodeURIComponent(state.pin || '')}`;
}

// Where the phone is in the song. Polls come once a second over Wi-Fi, so each one nudges
// a running estimate instead of replacing it; that keeps network jitter out of the video.
// A big jump (a seek, a new song, play/pause) starts the estimate over.
function updatePhoneClock(p, sampledAt) {
  const playing = !!(p.playing && p.processing === 'ready');
  const trackId = p.track?.id ?? null;
  const c = stage.clock;
  if (c && playing && c.playing && c.trackId === trackId) {
    const predicted = c.pos + (sampledAt - c.at);
    const error = p.positionMs - predicted;
    if (Math.abs(error) < 500) {
      stage.clock = { trackId, playing, at: sampledAt, pos: predicted + error * 0.3 };
      return;
    }
  }
  stage.clock = { trackId, playing, at: sampledAt, pos: p.positionMs };
}

function phonePosition() {
  const c = stage.clock;
  if (!c) return 0;
  return c.pos + (c.playing ? performance.now() - c.at : 0);
}

function renderStage() {
  const track = state.player?.track ?? null;
  if ((track?.id ?? null) !== stage.trackId) loadStageTrack(track);
  const show = SCREEN_MODE || stage.hasVideo || stage.subtitles.length > 0;
  $('stage').hidden = !show;
  $('player').classList.toggle('has-stage', show && !SCREEN_MODE);
}

function loadStageTrack(track) {
  stage.trackId = track?.id ?? null;
  stage.hasVideo = !!track?.hasVideo;
  stage.subtitles = track?.subtitles ?? [];
  const video = $('stage-video');
  video.hidden = !stage.hasVideo;
  if (stage.hasVideo) {
    video.src = mediaUrl(`tracks/${track.id}/video`);
  } else if (video.hasAttribute('src')) {
    video.removeAttribute('src');
    video.load(); // lets go of the previous song's video
  }
  $('stage-title-text').textContent = track ? track.title : 'Nothing playing';
  $('stage-title-sub').textContent = track?.artist ?? '';
  renderLyricsChoices();
  loadLyrics();
}

const languageNames = (() => {
  try { return new Intl.DisplayNames([navigator.language, 'en'], { type: 'language' }); } catch { return null; }
})();

// "km" -> "Khmer". YouTube also has codes like "en-nP7-2PuUl7o" for a second English track.
function languageName(code) {
  const base = code.split('-')[0];
  for (const candidate of [code, base]) {
    try {
      const name = languageNames?.of(candidate);
      if (name && name !== candidate) return candidate === code ? name : `${name} (${code})`;
    } catch { /* not a language tag */ }
  }
  return code;
}

function renderLyricsChoices() {
  const select = $('lyrics-lang');
  select.replaceChildren(...stage.subtitles.map((code) => el('option', { value: code, text: languageName(code) })));
  stage.lyricsLang = pickLyrics(stage.subtitles);
  if (stage.lyricsLang) select.value = stage.lyricsLang;
  renderLyricsToggle();
}

function renderLyricsToggle() {
  const toggle = $('lyrics-toggle');
  toggle.hidden = stage.subtitles.length === 0;
  toggle.textContent = stage.lyricsOn ? 'Subtitles: On' : 'Subtitles: Off';
  toggle.setAttribute('aria-pressed', String(stage.lyricsOn));
  $('lyrics-lang').hidden = !stage.lyricsOn || stage.subtitles.length < 2;
}

// The language chosen last time (or the same language from another region), else the first.
function pickLyrics(codes) {
  const wanted = prefs.get('mc-lyrics');
  const base = (code) => code.split('-')[0].toLowerCase();
  return codes.find((c) => c === wanted)
    ?? codes.find((c) => wanted && base(c) === base(wanted))
    ?? codes[0]
    ?? null;
}

async function loadLyrics() {
  stage.cues = [];
  const { trackId, lyricsLang } = stage;
  if (!trackId || !lyricsLang || !stage.lyricsOn) return;
  try {
    const res = await fetch(mediaUrl(`tracks/${trackId}/subtitles/${encodeURIComponent(lyricsLang)}`));
    if (!res.ok) return;
    const cues = parseVtt(await res.text());
    if (stage.trackId === trackId && stage.lyricsLang === lyricsLang && stage.lyricsOn) stage.cues = cues;
  } catch { /* no lyrics this time; the video carries on */ }
}

// WebVTT cues as { from, to, text } in milliseconds, without styling tags.
function parseVtt(text) {
  const cues = [];
  for (const block of text.replace(/\r\n?/g, '\n').split(/\n{2,}/)) {
    const lines = block.split('\n');
    const at = lines.findIndex((line) => line.includes('-->'));
    if (at < 0) continue; // the header, NOTE and STYLE blocks
    const [from, to] = lines[at].split('-->').map((part) => vttTime(part.trim().split(/\s+/)[0]));
    const body = decodeHtml(lines.slice(at + 1).join('\n').replace(/<[^>]*>/g, '')).trim();
    if (from != null && to != null && body) cues.push({ from, to, text: body });
  }
  return cues;
}

function vttTime(text) {
  const m = /^(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{3})$/.exec(text ?? '');
  if (!m) return null;
  return ((Number(m[1] ?? 0) * 60 + Number(m[2])) * 60 + Number(m[3])) * 1000 + Number(m[4]);
}

// Turns "&amp;" into "&". A textarea's content is never parsed as markup, so this is safe.
const entityDecoder = document.createElement('textarea');
function decodeHtml(text) {
  entityDecoder.innerHTML = text;
  return entityDecoder.value;
}

// Runs ten times a second while the karaoke screen shows.
function tickStage() {
  if ($('stage').hidden) return;
  const at = phonePosition() - stage.offsetMs;
  syncVideo(at / 1000);
  const lyrics = stage.cues.filter((c) => c.from <= at && at < c.to).map((c) => c.text).join('\n');
  const line = $('stage-lyrics');
  if (line.textContent !== lyrics) line.textContent = lyrics;
  line.hidden = !lyrics;
  $('stage-title').hidden = stage.hasVideo;
}

// The video follows the music on the phone. Small drifts are evened out by playing a little
// faster or slower, which looks smoother than jumping; big ones (a seek, a new song) jump.
function syncVideo(target) {
  const video = $('stage-video');
  if (!stage.hasVideo || video.readyState < HTMLMediaElement.HAVE_METADATA || video.seeking) return;
  const end = Number.isFinite(video.duration) ? video.duration : Infinity;
  const at = Math.min(Math.max(target, 0), end);
  const playing = stage.clock?.playing && !document.hidden && target < end;
  if (!playing) {
    if (!video.paused) video.pause();
    if (Math.abs(video.currentTime - at) > 0.25) video.currentTime = at;
    return;
  }
  const drift = video.currentTime - at;
  if (video.paused || Math.abs(drift) > 1.5) {
    video.currentTime = at;
    video.playbackRate = 1;
    if (video.paused) video.play().catch(() => { /* retried on the next tick */ });
    return;
  }
  video.playbackRate = Math.abs(drift) < 0.025 ? 1 : Math.min(1.25, Math.max(0.8, 1 - drift));
}

function setSyncOffset(ms) {
  stage.offsetMs = Math.max(-SYNC_LIMIT_MS, Math.min(SYNC_LIMIT_MS, Math.round(ms / SYNC_STEP_MS) * SYNC_STEP_MS));
  prefs.set('mc-sync', String(stage.offsetMs));
  const seconds = stage.offsetMs / 1000;
  const sign = seconds > 0 ? '+' : seconds < 0 ? '−' : '';
  $('sync-value').textContent = `${sign}${Math.abs(seconds).toFixed(1)} s`;
}

function toggleFullscreen() {
  if (document.fullscreenElement) {
    document.exitFullscreen().catch(() => {});
  } else {
    $('stage').requestFullscreen().catch(() => toast("The browser wouldn't go full screen", true));
  }
}

// The control bar and the mouse pointer show while the mouse moves over the video, then get
// out of the way. The bar stays while the pointer rests on it, e.g. with the language list open.
function showStageBar() {
  const node = $('stage');
  node.classList.add('active');
  node.classList.remove('idle');
  clearTimeout(stage.barTimer);
  stage.barTimer = setTimeout(hideStageBar, 2500);
}

function hideStageBar() {
  const node = $('stage');
  if (node.querySelector('.stage-bar').matches(':hover')) {
    stage.barTimer = setTimeout(hideStageBar, 2500);
    return;
  }
  node.classList.remove('active');
  node.classList.add('idle');
}

function wireStage() {
  const node = $('stage');
  node.addEventListener('pointermove', showStageBar);
  node.addEventListener('pointerdown', showStageBar);
  node.addEventListener('pointerleave', () => node.classList.remove('active'));
  node.addEventListener('dblclick', (e) => {
    if (!e.target.closest('.stage-bar')) toggleFullscreen();
  });
  document.addEventListener('fullscreenchange', () => {
    $('stage-full').textContent = document.fullscreenElement ? 'Exit full screen' : 'Full screen';
  });
  $('stage-full').addEventListener('click', toggleFullscreen);
  $('stage-window').addEventListener('click', () => {
    const screen = window.open('/?screen', 'mc-karaoke', 'popup,width=1280,height=720');
    if (!screen) toast('The browser blocked the new window. Allow pop-ups for this page.', true);
  });
  $('sync-earlier').addEventListener('click', () => setSyncOffset(stage.offsetMs - SYNC_STEP_MS));
  $('sync-later').addEventListener('click', () => setSyncOffset(stage.offsetMs + SYNC_STEP_MS));
  $('lyrics-toggle').addEventListener('click', () => {
    stage.lyricsOn = !stage.lyricsOn;
    prefs.set('mc-subtitles', stage.lyricsOn ? 'on' : 'off');
    renderLyricsToggle();
    loadLyrics();
  });
  $('lyrics-lang').addEventListener('change', (e) => {
    stage.lyricsLang = e.target.value;
    prefs.set('mc-lyrics', stage.lyricsLang);
    loadLyrics();
  });

  const video = $('stage-video');
  video.addEventListener('error', () => {
    if (!video.getAttribute('src')) return;
    stage.hasVideo = false; // the title and lyrics show instead
    video.hidden = true;
  });

  stage.lyricsOn = prefs.get('mc-subtitles') !== 'off';
  setSyncOffset(Number(prefs.get('mc-sync')) || 0);
  setInterval(tickStage, 100);
}

// ---------- Folders ----------

function renderFolders() {
  const list = $('folder-list');
  list.replaceChildren();
  const entries = [
    { id: 'all', name: 'All music', trackCount: state.library.tracks.length },
    ...state.library.folders,
  ];
  for (const folder of entries) {
    const button = el('button', {
      class: folder.id === state.selectedFolder ? 'selected' : '',
      'data-folder': folder.id,
      onclick: () => selectFolder(folder.id),
    }, [
      el('span', { class: 'name', text: folder.name }),
      el('span', {}, [
        el('span', { class: 'playing-dot', text: '♪ ', hidden: '' }),
        el('span', { class: 'count', text: String(folder.trackCount) }),
      ]),
    ]);
    list.append(el('li', {}, [button]));
  }
  renderFolderPlayingDots();

  const editable = state.selectedFolder !== 'all' && state.selectedFolder !== 'unsorted';
  $('folder-title').textContent = folderName(state.selectedFolder);
  $('rename-folder').hidden = !editable;
  $('delete-folder').hidden = !editable;
  $('add-target').textContent = state.selectedFolder === 'all'
    ? 'New songs go to Unsorted. Playlist links get their own folder.'
    : `New songs go to "${folderName(state.selectedFolder)}".`;
}

function renderFolderPlayingDots() {
  const source = state.player?.queueSource;
  for (const button of $('folder-list').querySelectorAll('button')) {
    button.querySelector('.playing-dot').hidden = button.dataset.folder !== source;
  }
}

function selectFolder(id) {
  state.selectedFolder = id;
  renderFolders();
  renderTracks();
}

// ---------- Tracks ----------

// Lower case without accents, so "cafe" finds "Café". Only Latin accents are dropped: in
// scripts such as Khmer, the combining marks are vowels.
function foldText(text) {
  return text.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}

// Songs whose title or artist has every word typed in the search box.
function matchesSearch(track, words) {
  const text = foldText(`${track.title} ${track.artist ?? ''}`);
  return words.every((word) => text.includes(word));
}

function renderTracks() {
  const list = $('track-list');
  list.replaceChildren();
  const inFolder = state.selectedFolder === 'all'
    ? state.library.tracks
    : state.library.tracks.filter((t) => t.folderId === state.selectedFolder);
  const query = state.searchQuery.trim();
  const words = foldText(query).split(/\s+/).filter(Boolean);
  const tracks = words.length ? inFolder.filter((t) => matchesSearch(t, words)) : inFolder;
  $('track-search').hidden = state.library.tracks.length === 0;
  $('empty-tracks').hidden = tracks.length > 0;
  const where = state.selectedFolder === 'all' ? '' : ` in "${folderName(state.selectedFolder)}"`;
  $('empty-tracks-text').textContent = inFolder.length === 0
    ? 'No songs here yet. Search YouTube or paste a link, or drop music or video files above.'
    : `No songs${where} match "${query}".`;
  $('search-all').hidden = inFolder.length === 0 || state.selectedFolder === 'all';
  $('play-folder').disabled = inFolder.length === 0;
  $('shuffle-folder').disabled = inFolder.length === 0;

  for (const track of tracks) {
    const moveSelect = el('select', {
      'aria-label': 'Move to folder',
      title: 'Move to folder',
      onchange: (e) => moveTrack(track, e.target.value),
    });
    for (const folder of state.library.folders) {
      const option = el('option', { value: folder.id, text: folder.name });
      option.selected = folder.id === track.folderId;
      moveSelect.append(option);
    }

    const subParts = [];
    if (track.artist) subParts.push(track.artist);
    if (state.selectedFolder === 'all') subParts.push(folderName(track.folderId));
    subParts.push(track.source === 'youtube' ? 'YouTube' : 'Uploaded');
    const tags = [];
    if (track.hasVideo) tags.push(el('span', { class: 'tag', text: 'Video' }));
    if (track.subtitles?.length) tags.push(el('span', { class: 'tag', text: 'Lyrics' }));

    const playBtn = el('button', {
      class: 'icon play-btn',
      title: 'Play',
      'aria-label': `Play ${track.title}`,
      onclick: () => playerCommand('play', { folderId: state.selectedFolder, trackId: track.id }),
    });
    playBtn.innerHTML = ICON_PLAY;

    list.append(el('li', { 'data-track': track.id }, [
      playBtn,
      el('div', { class: 't-main' }, [
        el('div', { class: 't-title', text: track.title, title: track.title }),
        el('div', { class: 't-sub' }, [...tags, subParts.join(' · ')]),
      ]),
      el('span', { class: 't-dur', text: track.durationMs ? formatTime(track.durationMs) : '' }),
      el('div', { class: 't-actions' }, [
        moveSelect,
        el('button', { text: 'Rename', onclick: () => renameTrack(track) }),
        el('button', { class: 'danger', text: 'Delete', onclick: () => deleteTrack(track) }),
      ]),
    ]));
  }
  highlightCurrentTrack();
}

function highlightCurrentTrack() {
  for (const li of $('track-list').children) {
    li.classList.toggle('current', li.dataset.track === state.currentTrackId);
  }
}

async function moveTrack(track, folderId) {
  const ok = await run(() => api('tracks/' + track.id, { method: 'PATCH', body: { folderId } }));
  if (ok) toast(`Moved to "${folderName(folderId)}"`);
  await run(refreshLibrary);
}

async function renameTrack(track) {
  const title = prompt('New song name:', track.title);
  if (title == null || !title.trim() || title === track.title) return;
  await run(() => api('tracks/' + track.id, { method: 'PATCH', body: { title } }));
  await run(refreshLibrary);
}

async function deleteTrack(track) {
  if (!confirm(`Delete "${track.title}" from the phone?`)) return;
  await run(() => api('tracks/' + track.id, { method: 'DELETE' }));
  await run(refreshLibrary);
}

// ---------- Downloads (YouTube jobs) ----------

// Rows are updated in place so buttons don't get replaced mid-click by the 1s poll.
function renderJobs(jobs) {
  $('jobs-card').hidden = jobs.length === 0;
  const list = $('job-list');
  const seen = new Set();
  jobs.forEach((job, index) => {
    seen.add(job.id);
    let row = state.jobRows.get(job.id);
    if (!row) {
      row = createJobRow(job.id);
      state.jobRows.set(job.id, row);
    }
    if (list.children[index] !== row.li) list.insertBefore(row.li, list.children[index] ?? null);
    row.videoTag.hidden = !job.video;
    row.labelText.textContent = job.title || job.url;
    row.label.title = job.url;
    const pct = Math.round(job.progress * 100);
    row.state.textContent = job.status === 'downloading' ? `${pct}%` : JOB_LABELS[job.status];
    row.state.className = 'state ' + job.status;
    row.bar.hidden = job.status !== 'downloading' && job.status !== 'fetching';
    row.fill.style.width = `${job.status === 'fetching' ? 0 : pct}%`;
    row.error.hidden = job.status !== 'failed';
    row.errorText.textContent = job.error || '';
  });
  for (const [id, row] of state.jobRows) {
    if (!seen.has(id)) {
      row.li.remove();
      state.jobRows.delete(id);
    }
  }
}

function createJobRow(jobId) {
  const videoTag = el('span', { class: 'tag', text: 'Video', hidden: '' });
  const labelText = document.createTextNode('');
  const label = el('span', { class: 'label' }, [videoTag, labelText]);
  const stateText = el('span', { class: 'state' });
  const fill = el('div');
  const bar = el('div', { class: 'bar' }, [fill]);
  const errorText = el('span');
  const retry = el('button', {
    class: 'link',
    text: 'Retry',
    onclick: () => run(() => api(`jobs/${jobId}/retry`, { method: 'POST' })),
  });
  const error = el('div', { class: 'job-error' }, [errorText, retry]);
  const li = el('li', {}, [el('div', { class: 'progress-row' }, [label, stateText]), bar, error]);
  return { li, label, labelText, videoTag, state: stateText, bar, fill, error, errorText };
}

// The phone downloads with yt-dlp, which keeps itself up to date.
function renderYtDlp(info) {
  $('ytdlp').hidden = !info;
  if (!info) return;
  let text = info.updating ? 'Updating yt-dlp…'
    : info.version ? `Downloads use yt-dlp ${info.version}` : 'yt-dlp is starting…';
  if (info.updateError && !info.updating) text += ` (last update failed: ${info.updateError})`;
  $('ytdlp-text').textContent = text;
  $('ytdlp-update').disabled = info.updating;
}

// Links (and bare playlist ids) are downloaded; anything else is looked up on YouTube.
function isYoutubeLink(text) {
  return /^https?:\/\/|youtube(-nocookie)?\.com\/|youtu\.be\//i.test(text)
    || /^(PL|RD|OLAK5uy_|UU|UL|PU|FL|LL)[\w-]{10,}$/.test(text);
}

function updateYtButton() {
  $('yt-submit').textContent = isYoutubeLink($('yt-url').value.trim()) ? 'Download' : 'Search';
}

// Queues a YouTube link on the phone, with the video too when the box is ticked.
async function addDownload(url) {
  const video = $('yt-video').checked;
  const result = await run(() => api('youtube', {
    method: 'POST',
    body: { url, folderId: targetFolderId(), video },
  }));
  if (!result) return false;
  const n = result.jobs.length;
  const what = n === 1 ? 'Added to downloads' : `Added ${n} songs from the playlist to downloads`;
  toast(video ? `${what}, with video` : what);
  poll();
  return true;
}

// The phone searches with yt-dlp, which takes a few seconds.
async function searchYoutube(query) {
  const token = ++state.ytSearch;
  const button = $('yt-submit');
  button.disabled = true;
  button.textContent = 'Searching…';
  $('yt-results').hidden = false;
  $('yt-results-title').textContent = `Searching YouTube for "${query}"…`;
  $('yt-result-list').replaceChildren();
  const data = await run(() => api('youtube/search?q=' + encodeURIComponent(query)));
  button.disabled = false;
  updateYtButton();
  if (token !== state.ytSearch) return;
  if (!data) {
    $('yt-results').hidden = true;
    return;
  }
  $('yt-results-title').textContent = data.results.length
    ? `YouTube results for "${query}"`
    : `YouTube found nothing for "${query}"`;
  const saved = new Set(state.library.tracks.map((t) => t.sourceUrl).filter(Boolean));
  $('yt-result-list').replaceChildren(...data.results.map((video) => youtubeResult(video, saved.has(video.url))));
}

function closeYoutubeResults() {
  state.ytSearch++;
  $('yt-results').hidden = true;
  $('yt-result-list').replaceChildren();
}

function youtubeResult(video, saved) {
  const title = video.title || video.url;
  const sub = [video.channel, video.durationMs ? formatTime(video.durationMs) : null].filter(Boolean).join(' · ');
  // Thumbnails come straight from YouTube, so they only show when the PC is online too.
  const thumb = video.id
    ? el('img', {
      class: 'thumb',
      alt: '',
      loading: 'lazy',
      src: `https://i.ytimg.com/vi/${encodeURIComponent(video.id)}/mqdefault.jpg`,
      onerror: (e) => e.target.classList.add('broken'),
    })
    : el('span', { class: 'thumb' });
  const download = el('button', {
    text: 'Download',
    onclick: async () => {
      download.disabled = true;
      if (await addDownload(video.url)) download.textContent = 'Added';
      else download.disabled = false;
    },
  });
  return el('li', {}, [
    thumb,
    el('div', { class: 'r-main' }, [
      el('a', { class: 'r-title', href: video.url, target: '_blank', rel: 'noopener', text: title, title }),
      el('div', { class: 'r-sub' }, [...(saved ? [el('span', { class: 'tag', text: 'In library' })] : []), sub]),
    ]),
    download,
  ]);
}

async function updateYtDlp() {
  $('ytdlp-update').disabled = true;
  $('ytdlp-text').textContent = 'Updating yt-dlp…';
  const result = await run(() => api('ytdlp/update', { method: 'POST' }));
  if (result) toast(result.updated ? `Updated yt-dlp to ${result.version}` : `yt-dlp is up to date (${result.version})`);
  poll();
}

// ---------- Uploads ----------

function targetFolderId() {
  return state.selectedFolder === 'all' ? null : state.selectedFolder;
}

function uploadFile(file, folderId, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/upload' + (folderId ? '?folderId=' + encodeURIComponent(folderId) : ''));
    xhr.setRequestHeader('X-Pin', state.pin || '');
    xhr.upload.onprogress = (e) => { if (e.lengthComputable) onProgress(e.loaded / e.total); };
    xhr.onload = () => {
      let data = null;
      try { data = JSON.parse(xhr.responseText); } catch { /* non-JSON */ }
      if (xhr.status >= 200 && xhr.status < 300) resolve(data);
      else reject(new ApiError(xhr.status, data?.error || `Upload failed (${xhr.status})`));
    };
    xhr.onerror = () => reject(new ApiError(0, "Can't reach the phone"));
    const form = new FormData();
    form.append('file', file, file.name);
    xhr.send(form);
  });
}

async function uploadFiles(fileList) {
  const folderId = targetFolderId();
  const files = [...fileList];
  const list = $('upload-list');
  let added = 0;
  // Sequential keeps the phone's disk and Wi-Fi from being swamped by a big drop.
  for (const file of files) {
    const ext = file.name.includes('.') ? file.name.split('.').pop().toLowerCase() : '';
    const videoTag = el('span', { class: 'tag', text: 'Video', hidden: '' });
    const label = el('span', { class: 'label' }, [videoTag, file.name]);
    const status = el('span', { class: 'state', text: 'Waiting' });
    const fill = el('div');
    const li = el('li', {}, [el('div', { class: 'progress-row' }, [label, status]), el('div', { class: 'bar' }, [fill])]);
    list.append(li);

    if (!AUDIO_EXTENSIONS.includes(ext) && !VIDEO_EXTENSIONS.includes(ext)) {
      status.textContent = 'Not a music or video file';
      status.classList.add('failed');
      setTimeout(() => li.remove(), 6000);
      continue;
    }
    try {
      const result = await uploadFile(file, folderId, (fraction) => {
        const pct = Math.round(fraction * 100);
        fill.style.width = pct + '%';
        status.textContent = pct < 100 ? `${pct}%` : 'Saving…';
      });
      videoTag.hidden = !result?.added?.some((t) => t.hasVideo);
      fill.style.width = '100%';
      status.textContent = 'Added';
      status.classList.add('done');
      added++;
      setTimeout(() => li.remove(), 3000);
    } catch (e) {
      if (e.status === 401) {
        logout('The PIN changed on the phone. Enter the new one.');
        return;
      }
      status.textContent = e.message;
      status.classList.add('failed');
      setTimeout(() => li.remove(), 8000);
    }
  }
  if (added > 0) {
    toast(`Added ${added} song${added === 1 ? '' : 's'}`);
    await run(refreshLibrary);
  }
}

// ---------- Wiring ----------

function wire() {
  $('login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const pin = $('pin-input').value.trim();
    $('login-error').textContent = '';
    try {
      await login(pin);
    } catch (err) {
      $('login-error').textContent = err.status === 401 ? 'Wrong PIN, check the phone screen.' : err.message;
    }
  });
  $('logout').addEventListener('click', () => logout());

  $('btn-play').addEventListener('click', () => playerCommand(state.player?.playing ? 'pause' : 'play'));
  $('btn-prev').addEventListener('click', () => playerCommand('previous'));
  $('btn-next').addEventListener('click', () => playerCommand('next'));
  $('btn-shuffle').addEventListener('click', () => playerCommand('shuffle', { enabled: !state.player?.shuffle }));
  $('btn-repeat').addEventListener('click', () => {
    const next = { off: 'all', all: 'one', one: 'off' }[state.player?.repeat ?? 'off'];
    playerCommand('repeat', { mode: next });
  });

  const seek = $('seek');
  seek.addEventListener('input', () => {
    state.seeking = true;
    $('pos').textContent = formatTime(Number(seek.value));
  });
  seek.addEventListener('change', async () => {
    await playerCommand('seek', { positionMs: Number(seek.value) });
    state.seeking = false;
  });

  const volume = $('volume');
  let volumeTimer = null;
  volume.addEventListener('pointerdown', () => { state.volumeDragging = true; });
  volume.addEventListener('input', () => {
    clearTimeout(volumeTimer);
    volumeTimer = setTimeout(() => playerCommand('volume', { volume: Number(volume.value) / 100 }), 120);
  });
  volume.addEventListener('change', () => { state.volumeDragging = false; });

  $('play-folder').addEventListener('click', () => playerCommand('play', { folderId: state.selectedFolder, shuffle: false }));
  $('shuffle-folder').addEventListener('click', () => playerCommand('play', { folderId: state.selectedFolder, shuffle: true }));

  $('rename-folder').addEventListener('click', async () => {
    const current = folderName(state.selectedFolder);
    const name = prompt('New folder name:', current);
    if (name == null || !name.trim() || name === current) return;
    await run(() => api('folders/' + state.selectedFolder, { method: 'PATCH', body: { name } }));
    await run(refreshLibrary);
  });

  $('delete-folder').addEventListener('click', async () => {
    const name = folderName(state.selectedFolder);
    if (!confirm(`Delete the folder "${name}"? Its songs will move to Unsorted.`)) return;
    const ok = await run(() => api('folders/' + state.selectedFolder, { method: 'DELETE' }));
    if (ok) state.selectedFolder = 'all';
    await run(refreshLibrary);
  });

  $('new-folder-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const input = $('new-folder-name');
    const folder = await run(() => api('folders', { method: 'POST', body: { name: input.value } }));
    if (!folder) return;
    input.value = '';
    state.selectedFolder = folder.id;
    await run(refreshLibrary);
  });

  $('yt-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const input = $('yt-url');
    const text = input.value.trim();
    if (!text) return;
    if (!isYoutubeLink(text)) {
      searchYoutube(text);
      return;
    }
    const button = $('yt-submit');
    button.disabled = true;
    button.textContent = 'Working…';
    const added = await addDownload(text);
    button.disabled = false;
    if (added) input.value = '';
    updateYtButton();
  });
  $('yt-url').addEventListener('input', updateYtButton);
  $('yt-results-close').addEventListener('click', closeYoutubeResults);
  const withVideo = prefs.get('mc-video');
  if (withVideo !== null) $('yt-video').checked = withVideo === '1';
  $('yt-video').addEventListener('change', (e) => prefs.set('mc-video', e.target.checked ? '1' : '0'));

  $('track-search').addEventListener('input', (e) => {
    state.searchQuery = e.target.value;
    renderTracks();
  });
  $('search-all').addEventListener('click', () => selectFolder('all'));

  $('clear-jobs').addEventListener('click', () => run(() => api('jobs/clear', { method: 'POST' })));
  $('ytdlp-update').addEventListener('click', updateYtDlp);

  const drop = $('drop-zone');
  $('file-input').addEventListener('change', (e) => {
    if (e.target.files.length) uploadFiles(e.target.files);
    e.target.value = '';
  });
  drop.addEventListener('dragover', (e) => {
    e.preventDefault();
    drop.classList.add('dragover');
  });
  drop.addEventListener('dragleave', () => drop.classList.remove('dragover'));
  drop.addEventListener('drop', (e) => {
    e.preventDefault();
    drop.classList.remove('dragover');
    if (e.dataTransfer.files.length) uploadFiles(e.dataTransfer.files);
  });
  // Stop a file dropped slightly outside the zone from navigating the page away.
  window.addEventListener('dragover', (e) => e.preventDefault());
  window.addEventListener('drop', (e) => e.preventDefault());

  // Smoothly advance the seek bar between 1s polls.
  setInterval(renderSeek, 250);
  wireStage();
}

async function start() {
  if (SCREEN_MODE) {
    document.title = 'Karaoke screen';
    document.body.classList.add('screen-mode');
    document.body.append($('stage'));
    $('stage-window').hidden = true;
  }
  wire();
  const saved = prefs.get('mc-pin');
  if (!saved) {
    showLogin();
    return;
  }
  try {
    await login(saved);
  } catch (e) {
    if (e.status === 401) logout();
    else showLogin(e.message, saved);
  }
}

start();
