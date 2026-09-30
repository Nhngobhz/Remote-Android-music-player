'use strict';

const ICON_PLAY = '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>';
const ICON_PAUSE = '<svg viewBox="0 0 24 24"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>';
const AUDIO_EXTENSIONS = ['mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'wav', 'flac', 'webm', 'mp4'];
const JOB_LABELS = { queued: 'Waiting', fetching: 'Looking up…', downloading: 'Downloading', done: 'Added', failed: 'Failed' };

const state = {
  pin: null,
  pollTimer: null,
  library: { version: -1, folders: [], tracks: [] },
  player: null,
  playerReceivedAt: 0,
  selectedFolder: 'all',
  seeking: false,
  volumeDragging: false,
  currentTrackId: null,
  jobRows: new Map(),
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

function storage(action, value) {
  try {
    if (action === 'get') return localStorage.getItem('mc-pin');
    if (action === 'set') localStorage.setItem('mc-pin', value);
    if (action === 'clear') localStorage.removeItem('mc-pin');
  } catch { /* storage unavailable (private mode); PIN just won't be remembered */ }
  return null;
}

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
  storage('set', pin);
  $('login').hidden = true;
  $('app').hidden = false;
  state.library.version = -1;
  poll();
}

function showLogin(message = '', prefill = '') {
  state.pin = null;
  clearTimeout(state.pollTimer);
  $('app').hidden = true;
  $('login').hidden = false;
  $('login-error').textContent = message;
  $('pin-input').value = prefill;
  $('pin-input').focus();
}

function logout(message = '') {
  storage('clear');
  showLogin(message);
}

async function poll() {
  clearTimeout(state.pollTimer);
  if (!state.pin) return;
  try {
    const status = await api('status');
    setConnected(true);
    applyPlayer(status.player);
    renderJobs(status.jobs);
    renderYtDlp(status.ytDlp);
    if (status.libraryVersion !== state.library.version) await refreshLibrary();
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

function applyPlayer(player) {
  state.player = player;
  state.playerReceivedAt = performance.now();
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

function renderTracks() {
  const list = $('track-list');
  list.replaceChildren();
  const tracks = state.selectedFolder === 'all'
    ? state.library.tracks
    : state.library.tracks.filter((t) => t.folderId === state.selectedFolder);
  $('empty-tracks').hidden = tracks.length > 0;
  $('play-folder').disabled = tracks.length === 0;
  $('shuffle-folder').disabled = tracks.length === 0;

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
        el('div', { class: 't-sub', text: subParts.join(' · ') }),
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
    row.label.textContent = job.title || job.url;
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
  const label = el('span', { class: 'label' });
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
  return { li, label, state: stateText, bar, fill, error, errorText };
}

// yt-dlp downloads the videos the app's built-in downloader can't get.
function renderYtDlp(info) {
  $('ytdlp').hidden = !info;
  if (!info) return;
  let text = info.updating ? 'Updating yt-dlp…'
    : info.version ? `Backup downloader: yt-dlp ${info.version}` : 'Backup downloader: yt-dlp is starting…';
  if (info.updateError && !info.updating) text += ` (last update failed: ${info.updateError})`;
  $('ytdlp-text').textContent = text;
  $('ytdlp-update').disabled = info.updating;
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
    const label = el('span', { class: 'label', text: file.name });
    const status = el('span', { class: 'state', text: 'Waiting' });
    const fill = el('div');
    const li = el('li', {}, [el('div', { class: 'progress-row' }, [label, status]), el('div', { class: 'bar' }, [fill])]);
    list.append(li);

    if (!AUDIO_EXTENSIONS.includes(ext)) {
      status.textContent = 'Not an audio file';
      status.classList.add('failed');
      setTimeout(() => li.remove(), 6000);
      continue;
    }
    try {
      await uploadFile(file, folderId, (fraction) => {
        const pct = Math.round(fraction * 100);
        fill.style.width = pct + '%';
        status.textContent = pct < 100 ? `${pct}%` : 'Saving…';
      });
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
    const button = $('yt-submit');
    button.disabled = true;
    button.textContent = 'Working…';
    const result = await run(() => api('youtube', {
      method: 'POST',
      body: { url: input.value, folderId: targetFolderId() },
    }));
    button.disabled = false;
    button.textContent = 'Download';
    if (!result) return;
    input.value = '';
    const n = result.jobs.length;
    toast(n === 1 ? 'Added to downloads' : `Added ${n} songs from the playlist to downloads`);
    poll();
  });

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
}

async function start() {
  wire();
  const saved = storage('get');
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
