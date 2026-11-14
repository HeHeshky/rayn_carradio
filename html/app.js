'use strict';

/* =====================================================================
 *  rayn_carradio – NUI
 *  1) Streams: hidden players (YouTube / <audio>) – one per vehicle
 *  2) Radio UI – visible only to the driver / front passenger
 * ===================================================================== */

const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'rayn_carradio';

// --- translations (sent from Lua on open, English fallback) ---
let STR = {};
const T = (k) => (STR[k] !== undefined ? STR[k] : k);
function applyLocale(strings) {
    if (strings && typeof strings === 'object') STR = strings;
    document.querySelectorAll('[data-i18n]').forEach((el) => { if (STR[el.dataset.i18n] !== undefined) el.innerHTML = STR[el.dataset.i18n]; });
    document.querySelectorAll('[data-i18n-ph]').forEach((el) => { if (STR[el.dataset.i18nPh] !== undefined) el.placeholder = STR[el.dataset.i18nPh]; });
    document.querySelectorAll('[data-i18n-title]').forEach((el) => { if (STR[el.dataset.i18nTitle] !== undefined) el.title = STR[el.dataset.i18nTitle]; });
}
const $ = (s) => document.querySelector(s);
const $$ = (s) => document.querySelectorAll(s);

async function nui(name, data) {
    try {
        const r = await fetch(`https://${RES}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data || {}),
        });
        return await r.json();
    } catch (e) {
        return null;
    }
}

async function req(name, args, okMsg) {
    const r = await nui('req', { name, args: args || {} });
    if (!r) { toast(T('no_response'), 'err'); return null; }
    if (!r.ok) { toast(r.err || T('error'), 'err'); return null; }
    if (okMsg) toast(okMsg, 'ok');
    return r.data === undefined ? true : r.data;
}

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmt = (t) => {
    if (!isFinite(t) || t < 0) t = 0;
    t = Math.floor(t);
    const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
    return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(s).padStart(2, '0');
};
const thumb = (tr) => (tr && tr.t === 'yt' && tr.id) ? `https://i.ytimg.com/vi/${tr.id}/mqdefault.jpg` : '';

/* =====================================================================
 *  1) STREAMS
 * ===================================================================== */
let ytReady = false;
const ytWait = [];
window.onYouTubeIframeAPIReady = () => { ytReady = true; ytWait.splice(0).forEach((f) => f()); };
const whenYT = (f) => (ytReady || (window.YT && window.YT.Player)) ? f() : ytWait.push(f);

const players = {};

class Stream {
    constructor(id) {
        this.id = id;
        this.tid = null;
        this.kind = null;
        this.obj = null;
        this.el = null;
        this.ready = false;
        this.vol = 0;
        this.state = null;
        this.elapsed = 0;
        this.recv = 0;
        this.endedTid = null;
    }

    expected() {
        const s = this.state;
        if (!s) return 0;
        if (s.pausedAt != null) return s.pausedAt;
        return this.elapsed + (performance.now() - this.recv) / 1000;
    }

    destroy() {
        try {
            if (this.kind === 'yt' && this.obj && this.obj.destroy) this.obj.destroy();
            if (this.kind === 'audio' && this.obj) { this.obj.pause(); this.obj.removeAttribute('src'); this.obj.load(); }
        } catch (e) { /* ignore */ }
        if (this.el) this.el.remove();
        this.obj = null;
        this.el = null;
        this.ready = false;
        this.kind = null;
    }

    sync(state, elapsed) {
        this.state = state;
        this.elapsed = elapsed;
        this.recv = performance.now();
        const tr = state && state.track;
        if (!tr || state.stopped) { this.destroy(); this.tid = null; return; }
        if (this.tid !== state.tid || !this.el) {
            this.destroy();
            this.tid = state.tid;
            this.create(tr);
        } else {
            this.apply(false);
        }
    }

    create(tr) {
        const tid = this.tid;
        this.el = document.createElement('div');
        this.el.className = 'pl';
        $('#players').appendChild(this.el);

        if (tr.t === 'yt') {
            this.kind = 'yt';
            const inner = document.createElement('div');
            this.el.appendChild(inner);
            whenYT(() => {
                if (this.tid !== tid || !this.el) return;
                this.obj = new YT.Player(inner, {
                    width: 200, height: 200, videoId: tr.id,
                    playerVars: { autoplay: 1, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, rel: 0, playsinline: 1, start: Math.floor(this.expected()) },
                    events: {
                        onReady: () => {
                            if (this.tid !== tid || !this.obj) return;
                            this.ready = true;
                            this.obj.unMute();
                            this.obj.setVolume(Math.round(this.vol * 100));
                            this.apply(true);
                        },
                        onStateChange: (e) => {
                            if (this.tid === tid && e.data === YT.PlayerState.ENDED) this.ended(false);
                        },
                        onError: () => { if (this.tid === tid) this.ended(true); },
                    },
                });
            });
        } else {
            this.kind = 'audio';
            const a = new Audio();
            a.preload = 'auto';
            a.volume = Math.min(1, Math.max(0, this.vol));
            a.addEventListener('loadedmetadata', () => { if (this.tid === tid) { this.ready = true; this.apply(true); } });
            a.addEventListener('ended', () => { if (this.tid === tid) this.ended(false); });
            a.addEventListener('error', () => { if (this.tid === tid) this.ended(true); });
            a.src = tr.url;
            this.obj = a;
            a.play().catch(() => {});
        }
    }

    // pulls the player to the server clock (every 3 s + on every change)
    apply(force) {
        if (!this.obj || !this.ready || !this.state) return;
        const want = this.expected();
        const paused = this.state.pausedAt != null;

        if (this.kind === 'yt') {
            const p = this.obj;
            if (!p.getPlayerState) return;
            const cur = p.getCurrentTime() || 0;
            const dur = p.getDuration() || 0;
            if ((force || Math.abs(cur - want) > 2) && (!dur || want < dur - 1)) p.seekTo(want, true);
            const ps = p.getPlayerState();
            if (paused) { if (ps !== 2) p.pauseVideo(); }
            else if (ps !== 1 && ps !== 3) p.playVideo();
        } else {
            const a = this.obj;
            const live = !isFinite(a.duration);
            if (!live && (force || Math.abs(a.currentTime - want) > 2) && want < a.duration - 1) a.currentTime = want;
            if (paused) { if (!a.paused) a.pause(); }
            else if (a.paused) a.play().catch(() => {});
        }
    }

    setVolume(v) {
        this.vol = v;
        if (!this.obj) return;
        if (this.kind === 'yt') { if (this.ready) this.obj.setVolume(Math.round(v * 100)); }
        else this.obj.volume = Math.min(1, Math.max(0, v));
    }

    ended(isError) {
        if (this.endedTid === this.tid) return;
        this.endedTid = this.tid;
        nui('ended', { id: this.id, tid: this.tid, error: isError });
    }

    time() {
        if (!this.obj || !this.ready) return [this.expected(), 0];
        if (this.kind === 'yt') return [this.obj.getCurrentTime() || 0, this.obj.getDuration() || 0];
        return [this.obj.currentTime || 0, isFinite(this.obj.duration) ? this.obj.duration : -1];
    }
}

setInterval(() => { for (const id in players) players[id].apply(false); }, 3000);

/* =====================================================================
 *  2) UI
 * ===================================================================== */
const ui = {
    open: false,
    id: null,
    st: null,
    q: [],
    elapsed: 0,
    recv: 0,
    view: 'now',
    pls: [],
    sel: null,
    volHold: 0,
    vol: 0.5,
};

// --- scale (1080p = 1) ---
function rescale() {
    const s = Math.min(window.innerWidth / 1920, window.innerHeight / 1080) * 1.05;
    $('#scale').style.setProperty('--s', Math.max(0.55, s).toFixed(3));
}
window.addEventListener('resize', rescale);
rescale();

// --- toast ---
let toastT = null;
function toast(msg, kind) {
    const t = $('#toast');
    t.textContent = msg;
    t.className = 'show ' + (kind || '');
    clearTimeout(toastT);
    toastT = setTimeout(() => { t.className = ''; }, 2600);
}

// --- views ---
function setView(v) {
    ui.view = v;
    $$('.view').forEach((el) => el.classList.toggle('active', el.dataset.v === v));
    $$('[data-view]').forEach((el) => el.classList.toggle('active', el.dataset.view === v));
    $$('.side .hw[data-view]').forEach((el) => el.classList.toggle('on', el.dataset.view === v));
    if (v === 'playlists' || v === 'link') loadPlaylists();
    if (v === 'link') setTimeout(() => $('#linkIn').focus(), 50);
}
$$('[data-view]').forEach((b) => b.addEventListener('click', () => setView(b.dataset.view)));

// --- control actions ---
function control(action, value) {
    return req('control', { action, value });
}
$$('[data-act]').forEach((b) => b.addEventListener('click', () => control(b.dataset.act)));

$('#eject').addEventListener('click', () => nui('close'));
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && ui.open) nui('close');
});

// --- equalizer (animated only while the UI is open and playing) ---
const eqEl = $('#eq');
for (let i = 0; i < 28; i++) eqEl.appendChild(document.createElement('i'));
const eqBars = [...eqEl.children];

// --- volume knob ---
const ticksEl = $('#ticks');
const TICKS = 21;
for (let i = 0; i < TICKS; i++) {
    const t = document.createElement('i');
    const a = -135 + (270 / (TICKS - 1)) * i;
    t.style.transform = `rotate(${a + 180}deg) translateY(66px)`;
    ticksEl.appendChild(t);
}
const tickEls = [...ticksEl.children];

function drawVol(v) {
    ui.vol = v;
    $('#knob').style.transform = `rotate(${-135 + v * 270}deg)`;
    $('#volv').textContent = Math.round(v * 100);
    const lit = Math.round(v * (TICKS - 1));
    tickEls.forEach((t, i) => t.classList.toggle('lit', i <= lit && v > 0));
}

let volSendT = null, volLast = 0;
function sendVol(final) {
    const now = Date.now();
    clearTimeout(volSendT);
    if (final || now - volLast > 220) {
        volLast = now;
        control('volume', Math.round(ui.vol * 100) / 100);
    } else {
        volSendT = setTimeout(() => sendVol(true), 230);
    }
}
function changeVol(v, final) {
    v = Math.min(1, Math.max(0, v));
    ui.volHold = Date.now() + 900;
    drawVol(v);
    sendVol(final);
}

const knob = $('#knob');
knob.addEventListener('wheel', (e) => {
    e.preventDefault();
    changeVol(ui.vol + (e.deltaY < 0 ? 0.05 : -0.05), false);
}, { passive: false });

let drag = null;
knob.addEventListener('mousedown', (e) => {
    const r = knob.getBoundingClientRect();
    drag = { cx: r.left + r.width / 2, cy: r.top + r.height / 2 };
    e.preventDefault();
});
window.addEventListener('mousemove', (e) => {
    if (!drag) return;
    let a = Math.atan2(e.clientX - drag.cx, drag.cy - e.clientY) * 180 / Math.PI; // 0 = top
    a = Math.min(135, Math.max(-135, a));
    changeVol((a + 135) / 270, false);
});
window.addEventListener('mouseup', () => {
    if (drag) { drag = null; sendVol(true); }
});

// --- progress / seeking ---
function currentTime() {
    const st = ui.st;
    if (!st || st.stopped) return [0, 0];
    const p = players[ui.id];
    if (p && p.tid === st.tid && p.ready) return p.time();
    const t = st.pausedAt != null ? st.pausedAt : ui.elapsed + (performance.now() - ui.recv) / 1000;
    return [t, 0];
}

$('#bar').addEventListener('click', (e) => {
    const [, dur] = currentTime();
    if (!dur || dur <= 0) return;
    const r = e.currentTarget.getBoundingClientRect();
    control('seek', Math.floor(((e.clientX - r.left) / r.width) * dur));
});

// --- "Now playing" rendering ---
function fitMarquee() {
    const box = $('.title');
    const span = $('#title');
    box.classList.remove('run');
    requestAnimationFrame(() => {
        const over = span.scrollWidth - box.clientWidth;
        if (over > 4) {
            box.style.setProperty('--off', `-${over + 60}px`);
            box.style.setProperty('--dur', `${Math.max(6, (over + 60) / 35)}s`);
            box.classList.add('run');
        }
    });
}

let lastTitleKey = null;
function renderNow() {
    const st = ui.st;
    const playing = st && !st.stopped && st.track;
    const tr = playing ? st.track : null;
    const paused = playing && st.pausedAt != null;

    const key = tr ? st.tid + tr.url : 'off';
    if (key !== lastTitleKey) {
        lastTitleKey = key;
        $('#title').textContent = tr ? (tr.title || T('track')) : T('radio_off');
        $('#artist').textContent = tr ? (tr.artist || '') : (ui.q.length ? T('press_play') : T('radio_hint'));
        const img = $('#artImg');
        const src = thumb(tr);
        $('#art').classList.remove('has-img');
        img.onload = () => $('#art').classList.add('has-img');
        img.onerror = () => $('#art').classList.remove('has-img');
        if (src) img.src = src; else img.removeAttribute('src');
        fitMarquee();
    }

    $('#art').classList.toggle('spin', !!playing && !paused);
    $('#bPlay').classList.toggle('playing', !!playing && !paused);
    $('#bShuffle').classList.toggle('on', !!(st && st.shuffle));
    const loop = st ? st.loop : 'all';
    $('#bLoop').classList.toggle('on', loop !== 'none');
    $('#bLoop').classList.toggle('one', loop === 'one');
    $('.hw.power').classList.toggle('on', !!playing);
    $('#tpos').textContent = st && st.count ? `${st.index} / ${st.count}` : '– / –';
    $('#srcBadge').textContent = tr ? (tr.t === 'yt' ? T('src_yt') : T('src_stream')) : T('src_radio');

    if (Date.now() > ui.volHold) drawVol(st ? (st.volume ?? 0.5) : ui.vol);
}

// --- queue ---
const icoNote = '<svg viewBox="0 0 24 24"><path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/></svg>';
const icoX = '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6 6 18"/></svg>';

function trackRow(tr, i, cur, extra) {
    const th = thumb(tr);
    return `<div class="item ${cur ? 'cur' : ''}" data-i="${i}">
        <span class="no">${cur ? '▶' : i + 1}</span>
        <span class="th" ${th ? `style="background-image:url('${th}')"` : ''}>${th ? '' : icoNote}</span>
        <span class="tx"><div class="t1">${esc(tr.title || T('track'))}</div><div class="t2">${esc(tr.artist || '')}</div></span>
        ${extra || ''}
    </div>`;
}

let lastQueueKey = null;
function renderQueue() {
    const st = ui.st;
    const curIdx = st && !st.stopped ? st.index - 1 : -1;
    const key = JSON.stringify([ui.q.map((t) => t.url), curIdx]);
    if (key === lastQueueKey) return;
    lastQueueKey = key;

    $('#qCount').textContent = ui.q.length;
    const list = $('#qList');
    if (!ui.q.length) {
        list.innerHTML = `<div class="empty">${T('queue_empty')}</div>`;
        return;
    }
    list.innerHTML = ui.q.map((tr, i) => trackRow(tr, i, i === curIdx, `<button class="x" data-rm="${i + 1}" title="${esc(T('t_remove'))}">${icoX}</button>`)).join('');
}

$('#qList').addEventListener('click', (e) => {
    const rm = e.target.closest('[data-rm]');
    if (rm) { e.stopPropagation(); control('remove', +rm.dataset.rm); return; }
    const it = e.target.closest('.item');
    if (it) control('jump', +it.dataset.i + 1);
});
$('#qClear').addEventListener('click', () => control('clear'));

// --- playlists ---
let plLoading = false;
async function loadPlaylists() {
    if (plLoading) return;
    plLoading = true;
    const d = await req('playlists');
    plLoading = false;
    if (!d) return;
    ui.pls = Array.isArray(d) ? d : [];
    if (ui.sel && !ui.pls.find((p) => p.id === ui.sel)) ui.sel = null;
    renderPlaylists();
}

function renderPlaylists() {
    const list = $('#plList');
    if (!ui.pls.length) {
        list.innerHTML = `<div class="empty">${T('no_playlists')}</div>`;
    } else {
        list.innerHTML = ui.pls.map((p) => `<div class="item pl-item ${p.id === ui.sel ? 'sel' : ''}" data-id="${p.id}">
            <span class="ico">${icoNote}</span>
            <span class="tx"><div class="t1">${esc(p.name)}</div><div class="t2">${(p.tracks || []).length} ${esc(T('tracks_short'))}</div></span>
        </div>`).join('');
    }

    // playlist select in the LINK tab
    const sel = $('#lPl');
    const prev = sel.value;
    sel.innerHTML = ui.pls.length
        ? ui.pls.map((p) => `<option value="${p.id}">${esc(p.name)}</option>`).join('')
        : `<option value="">${esc(T('create_first'))}</option>`;
    if (prev && ui.pls.find((p) => String(p.id) === prev)) sel.value = prev;

    renderPlDetail();
}

function renderPlDetail() {
    const box = $('#plDetail');
    const p = ui.pls.find((x) => x.id === ui.sel);
    if (!p) { box.innerHTML = `<div class="empty">${T('pick_playlist')}</div>`; return; }
    const tracks = p.tracks || [];
    box.innerHTML = `
        <div class="pl-title"><h2>${esc(p.name)} <small>${tracks.length} ${esc(T('tracks_short'))}</small></h2>
            <button class="pill sm danger" id="pdDel">${esc(T('delete'))}</button></div>
        <div class="pl-actions">
            <button class="pill sm" id="pdPlay" ${tracks.length ? '' : 'disabled'}>${esc(T('play'))}</button>
            <button class="pill sm ghost" id="pdShuffle" ${tracks.length ? '' : 'disabled'}>${esc(T('shuffle'))}</button>
            <button class="pill sm ghost" id="pdQueue" ${tracks.length ? '' : 'disabled'}>${esc(T('add_to_queue'))}</button>
            <button class="pill sm ghost" id="pdCur">${esc(T('add_current'))}</button>
        </div>
        <div class="list" id="pdList">${tracks.length
            ? tracks.map((t, i) => trackRow(t, i, false, `<button class="x" data-row="${t.rowId}" title="${esc(T('t_remove_pl'))}">${icoX}</button>`)).join('')
            : `<div class="empty">${T('empty_playlist')}</div>`}</div>
        <div class="row"><input id="pdLink" placeholder="${esc(T('paste_playlist'))}" spellcheck="false"><button class="pill" id="pdAdd">${esc(T('add'))}</button></div>`;

    $('#pdDel').onclick = async () => {
        if ($('#pdDel').dataset.confirm !== '1') {
            $('#pdDel').dataset.confirm = '1';
            $('#pdDel').textContent = T('confirm');
            return;
        }
        if (await req('deletePlaylist', { id: p.id }, T('playlist_deleted'))) { ui.sel = null; loadPlaylists(); }
    };
    $('#pdPlay').onclick = () => req('playPlaylist', { id: p.id, start: 1 }, T('now_playing') + p.name);
    $('#pdShuffle').onclick = () => req('playPlaylist', { id: p.id, start: 1 + Math.floor(Math.random() * tracks.length), shuffle: true }, T('shuffling') + p.name);
    $('#pdQueue').onclick = () => req('playPlaylist', { id: p.id, mode: 'queue' }, T('added_to_queue'));
    $('#pdCur').onclick = async () => { const r = await req('addCurrentToPlaylist', { id: p.id }); if (r) { toast(T('added') + r.title, 'ok'); loadPlaylists(); } };
    const add = async () => {
        const url = $('#pdLink').value.trim();
        if (!url) return;
        $('#pdAdd').disabled = true;
        const r = await req('addToPlaylist', { id: p.id, url });
        const btn = $('#pdAdd');
        if (btn) btn.disabled = false;
        if (r) { toast(T('added') + r.title, 'ok'); loadPlaylists(); }
    };
    $('#pdAdd').onclick = add;
    $('#pdLink').onkeydown = (e) => { if (e.key === 'Enter') add(); };
    $('#pdList').onclick = async (e) => {
        const rm = e.target.closest('[data-row]');
        if (rm) { e.stopPropagation(); if (await req('removeFromPlaylist', { rowId: +rm.dataset.row })) loadPlaylists(); return; }
        const it = e.target.closest('.item');
        if (it) req('playPlaylist', { id: p.id, start: +it.dataset.i + 1 });
    };
}

$('#plList').addEventListener('click', (e) => {
    const it = e.target.closest('.pl-item');
    if (!it) return;
    ui.sel = +it.dataset.id;
    renderPlaylists();
});
async function createPl() {
    const name = $('#plNew').value.trim();
    if (!name) return;
    const r = await req('createPlaylist', { name }, T('playlist_created'));
    if (r) { $('#plNew').value = ''; ui.sel = r.id; loadPlaylists(); }
}
$('#plCreate').addEventListener('click', createPl);
$('#plNew').addEventListener('keydown', (e) => { if (e.key === 'Enter') createPl(); });

// --- LINK tab ---
async function linkAction(kind) {
    const url = $('#linkIn').value.trim();
    if (!url) { toast(T('paste_link'), 'err'); return; }
    const btns = ['#lPlay', '#lQueue', '#lSave'].map((s) => $(s));
    btns.forEach((b) => (b.disabled = true));
    let r = null;
    if (kind === 'save') {
        const id = +$('#lPl').value;
        if (!id) { toast(T('create_playlist_first'), 'err'); btns.forEach((b) => (b.disabled = false)); return; }
        r = await req('addToPlaylist', { id, url });
        if (r) { toast(T('saved') + r.title, 'ok'); loadPlaylists(); }
    } else {
        r = await req('play', { url, mode: kind });
        if (r) {
            toast((kind === 'queue' ? T('queued') : T('now_playing')) + r.title, 'ok');
            if (kind === 'now') setView('now');
        }
    }
    btns.forEach((b) => (b.disabled = false));
    if (r) $('#linkIn').value = '';
}
$('#lPlay').addEventListener('click', () => linkAction('now'));
$('#lQueue').addEventListener('click', () => linkAction('queue'));
$('#lSave').addEventListener('click', () => linkAction('save'));
$('#linkIn').addEventListener('keydown', (e) => { if (e.key === 'Enter') linkAction('now'); });

// --- UI loop (only while open) ---
function tick() {
    if (!ui.open) return;
    const d = new Date();
    $('#clock').textContent = String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');

    const st = ui.st;
    const playing = st && !st.stopped && st.track;
    const [cur, dur] = currentTime();
    const live = dur < 0;
    $('#bar').classList.toggle('live', !!playing && live);
    $('#tcur').textContent = playing ? fmt(cur) : '0:00';
    $('#tdur').textContent = playing ? (live ? T('live') : (dur > 0 ? fmt(dur) : '--:--')) : '0:00';
    $('#fill').style.width = playing && dur > 0 ? Math.min(100, (cur / dur) * 100) + '%' : '0%';

    const moving = playing && st.pausedAt == null;
    for (let i = 0; i < eqBars.length; i++) {
        const h = moving ? 4 + Math.random() * 24 * (0.35 + 0.65 * Math.sin((i / eqBars.length) * Math.PI)) : 3;
        eqBars[i].style.height = h + 'px';
    }
}
setInterval(tick, 150);

/* =====================================================================
 *  Messages from Lua
 * ===================================================================== */
window.addEventListener('message', (e) => {
    const m = e.data;
    if (!m || !m.type) return;

    switch (m.type) {
        case 'sync': {
            let p = players[m.id];
            if (!p) p = players[m.id] = new Stream(m.id);
            p.setVolume(m.vol || 0);
            p.sync(m.state, m.elapsed);
            break;
        }
        case 'volume':
            for (const id in m.vols) if (players[id]) players[id].setVolume(m.vols[id]);
            break;
        case 'remove':
            if (players[m.id]) { players[m.id].destroy(); delete players[m.id]; }
            break;
        case 'open':
            applyLocale(m.locale);
            lastTitleKey = null;
            lastQueueKey = null;
            ui.open = true;
            $('#wrap').classList.remove('hidden');
            rescale();
            setView(ui.view || 'now');
            break;
        case 'close':
            ui.open = false;
            $('#wrap').classList.add('hidden');
            document.activeElement && document.activeElement.blur();
            break;
        case 'ui':
            ui.id = m.id;
            ui.st = m.state || null;
            ui.q = Array.isArray(m.queue) ? m.queue : Object.values(m.queue || {});
            ui.elapsed = m.elapsed || 0;
            ui.recv = performance.now();
            renderNow();
            renderQueue();
            tick();
            break;
    }
});
