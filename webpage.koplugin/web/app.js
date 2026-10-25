// The web page's shell: the API, small DOM helpers, dialogs, notices and the page router.
const App = { pages: {}, plugins: {} };

// KOReader writes an empty list as {}: lists from the reader go through these.
App.arr = (x) => (Array.isArray(x) ? x : []);
App.obj = (x) => (x && !Array.isArray(x) && typeof x === 'object' ? x : {});

App.api = async function (path, opts = {}) {
  const init = { method: opts.method || (opts.json !== undefined ? 'POST' : 'GET'), headers: {} };
  if (opts.json !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(opts.json);
  } else if (opts.body !== undefined) {
    init.body = opts.body;
  }
  const r = await fetch(path, init);
  const type = r.headers.get('content-type') || '';
  const data = r.status === 204 ? null : (type.includes('json') ? await r.json() : await r.text());
  // A password was set (or KOReader restarted): sign in again.
  if (r.status === 401 && data && data.login) { location.href = '/login'; return new Promise(() => {}); }
  if (!r.ok) throw new Error((data && data.error) || r.statusText || 'Failed');
  return data;
};

// h('div', { class: 'x', onclick }, child, 'text', [more])
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else if (k === 'html') el.innerHTML = v;
    else if (k === 'value') el.value = v;
    else if (k === 'checked') el.checked = !!v;
    else if (k === 'style') el.style.cssText = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  const add = (kid) => {
    if (kid === undefined || kid === null || kid === false) return;
    if (Array.isArray(kid)) kid.forEach(add);
    else el.appendChild(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  };
  kids.forEach(add);
  return el;
}

App.toast = function (text, bad) {
  const t = h('div', { class: 'toast' + (bad ? ' bad' : '') }, text);
  document.getElementById('toasts').appendChild(t);
  setTimeout(() => t.remove(), bad ? 6000 : 2600);
};

App.fail = (e) => App.toast(e && e.message ? e.message : String(e), true);

// After something was removed: what happened, with Undo for a few seconds (as on the Kindle).
// `onGone` runs when the Undo goes without being used.
App.undo = function (text, onUndo, seconds = 6, onGone) {
  const t = h('div', { class: 'toast undo' }, h('span', {}, text));
  let used = false;
  const btn = h('button', { class: 'btn small', onclick: () => { used = true; t.remove(); onUndo(); } }, 'Undo');
  t.append(btn);
  document.getElementById('toasts').appendChild(t);
  setTimeout(() => { t.remove(); if (!used && onGone) onGone(); }, seconds * 1000);
};

App.modal = function (title, body, buttons, wide) {
  return new Promise((resolve) => {
    const back = h('div', { class: 'modal-back' });
    const close = (v) => { back.remove(); resolve(v); };
    const box = h('div', { class: 'modal' + (wide ? ' wide' : '') }, h('h2', {}, title), body,
      h('div', { class: 'actions' }, buttons.map((b) =>
        h('button', { class: 'btn' + (b.primary ? ' primary' : '') + (b.danger ? ' danger' : ''), onclick: () => close(b.value ? b.value() : b.result) }, b.text))));
    back.addEventListener('click', (e) => { if (e.target === back) close(undefined); });
    back.appendChild(box);
    document.body.appendChild(back);
    const first = box.querySelector('input, textarea, select');
    if (first) first.focus();
  });
};

App.confirm = (title, text, ok = 'OK', danger) =>
  App.modal(title, h('p', {}, text), [{ text: 'Cancel', result: false }, { text: ok, result: true, primary: !danger, danger }]);

App.prompt = function (title, value = '', placeholder = '') {
  const input = h('input', { type: 'text', value, placeholder, style: 'width:100%' });
  input.addEventListener('keydown', (e) => { if (e.key === 'Enter') input.closest('.modal').querySelector('.btn.primary').click(); });
  return App.modal(title, input, [{ text: 'Cancel', result: null }, { text: 'Save', primary: true, value: () => input.value.trim() }]);
};

// A link to another site, in a new tab (an integration's own page, where to get a key...).
App.link = (text, url) => h('a', { href: url, target: '_blank', rel: 'noopener' }, text);

// The Microsoft account To Do and OneNote share (the launcher's appsmicrosoft.lua): the App ID,
// signing in with a code, who is signed in, which apps use it, signing out, Test connection.
App.microsoftCard = function () {
  const box = h('div', { class: 'card stack' }, h('h2', {}, 'Microsoft account'));
  const draw = (m) => {
    const client = h('input', { type: 'text', value: m.clientId || '', placeholder: '00000000-0000-0000-0000-000000000000', style: 'flex:1;min-width:260px' });
    const codeBox = h('div', {});
    const saveClient = () => App.api('/api/microsoft/clientid', { json: { id: client.value } });
    const signIn = async () => {
      await saveClient().catch(App.fail);
      const st = await App.api('/api/microsoft/signin', { json: {} }).catch(App.fail);
      if (st) App.pages.notes.showCode(codeBox, st, '/api/microsoft/signin', 'Signed in to Microsoft.');
    };
    const signOut = async () => {
      if (!await App.confirm('Sign out', 'Sign out of Microsoft on the Kindle? To Do and OneNote stop syncing; To Do keeps its lists on this Kindle.', 'Sign out', true)) return;
      await App.api('/api/microsoft/signout', { json: {} }).then(App.route, App.fail);
    };
    box.replaceChildren(h('h2', {}, 'Microsoft account'),
      h('p', { class: 'muted small' }, 'One App ID and one sign-in for To Do and Notes’ OneNote, the same as Settings > Microsoft on the Kindle.'),
      h('label', { class: 'field' }, h('span', {}, 'App (client) ID from your Microsoft ',
        App.link('Entra app registration', 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade'), ' (',
        App.link('how to make one', 'https://github.com/Mcp20091/kindle-koreader-apps/blob/main/guide/setup.md#microsoft-to-do-and-onenote'), ')'),
        h('div', { class: 'row' }, client, h('button', { class: 'btn', onclick: () => saveClient().then(() => App.toast('Saved'), App.fail) }, 'Save'))),
      h('div', { class: 'row' },
        m.signedIn ? h('span', { class: 'pill ok' }, m.account ? 'Signed in as ' + m.account : 'Signed in') : h('span', { class: 'pill' }, 'Not signed in'),
        h('button', { class: 'btn primary', onclick: signIn }, m.signedIn ? 'Sign in again' : 'Sign in'),
        m.signedIn ? h('button', { class: 'btn danger', onclick: signOut }, 'Sign out') : null),
      codeBox,
      App.arr(m.uses).length ? h('div', { class: 'list-rows' }, App.arr(m.uses).map((u) => h('div', {},
        h('span', { class: 'grow' }, u.name),
        h('span', { class: 'muted small' }, !m.signedIn ? 'Not signed in' : u.allowed ? 'Allowed' : 'Sign in again to allow')))) : null,
      m.clientId || m.signedIn ? App.connectionTest('microsoft') : null);
  };
  App.api('/api/microsoft').then((m) => { if (m.available) draw(m); }, () => {});
  return box;
};

// Connection test results (the launcher's appstest.lua, the same as on the Kindle): one
// row per thing tried, with its address under it; grouped by app when there are several.
App.testResults = function (list, at) {
  const rows = [];
  let last = null;
  const many = new Set(App.arr(list).map((r) => r.app)).size > 1;
  App.arr(list).forEach((r) => {
    if (many && r.appName !== last && r.appName !== r.name) { rows.push(h('div', { class: 'small', style: 'font-weight:600;margin-top:6px' }, r.appName || '')); }
    last = r.appName;
    const time = r.ms != null ? (r.ms < 1000 ? r.ms + ' ms' : (r.ms / 1000).toFixed(1) + ' s') : '';
    rows.push(h('div', {},
      h('span', { class: 'grow' }, (r.ok ? '✓ ' : '✗ ') + r.name, r.detail ? h('div', { class: 'muted small' }, r.detail) : null,
        !r.ok && r.raw && r.raw !== r.why ? h('div', { class: 'muted small' }, 'Error: ' + r.raw) : null),
      h('span', { class: 'muted small', style: 'text-align:right' }, r.ok ? [r.why, time].filter(Boolean).join(' · ') || 'Works' : (r.why || 'Doesn’t work'))));
  });
  if (!rows.length) rows.push(h('div', { class: 'muted small' }, 'Nothing set up to test yet.'));
  if (at) rows.push(h('div', { class: 'muted small' }, 'Checked ' + App.when(at)));
  return h('div', { class: 'list-rows' }, rows);
};

// A Test connection button and its results: `app` is one app's test (as named in
// PS.registerTest), or null for every app that's set up.
App.connectionTest = function (app, label) {
  const out = h('div', {});
  // Every app: pick which (the apps set up, all ticked to start with).
  const picks = h('div', { class: 'row', style: 'flex-wrap:wrap;gap:4px 14px' });
  if (!app) App.api('/api/diag/network/apps').then((r) => picks.replaceChildren(...App.arr(r.apps).map((a) => {
    const box = h('input', { type: 'checkbox', checked: true, value: a.key });
    box.addEventListener('change', () => { btn.textContent = count(); });
    return h('label', { class: 'small', style: 'display:inline-flex;gap:6px;align-items:center' }, box, a.name);
  }), ...(r.apps && r.apps.length ? [] : [h('span', { class: 'muted small' }, 'Nothing set up to test yet.')])),
  () => {}).then(() => { btn.textContent = count(); });
  const picked = () => [...picks.querySelectorAll('input:checked')].map((x) => x.value);
  const count = () => app ? (label || 'Test connection') : 'Test selected (' + picked().length + ')';
  const btn = h('button', { class: 'btn', onclick: async () => {
    if (!app && !picked().length) return App.toast('Tick at least one', true);
    btn.disabled = true;
    out.replaceChildren(h('div', { class: 'muted small' }, 'Testing… (each address on its own, up to 8 s each)'));
    const r = await App.api('/api/diag/network/test', { json: app ? { app } : { apps: picked() } }).catch(App.fail);
    if (!r) { btn.disabled = false; out.replaceChildren(); return; }
    const ask = async () => {
      const s = await App.api('/api/diag/network/test?key=' + encodeURIComponent(r.key)).catch(() => null);
      if (s && s.status === 'done') { out.replaceChildren(App.testResults(s.results)); btn.disabled = false; return; }
      setTimeout(ask, 1500);
    };
    setTimeout(ask, 1500);
  } }, label || 'Test connection');
  const box = h('div', { class: 'stack' }, app ? null : picks, h('div', {}, btn), out);
  box.show = (list, at) => out.replaceChildren(App.testResults(list, at));
  return box;
};

App.toggle = function (checked, onchange) {
  const input = h('input', { type: 'checkbox', checked });
  input.addEventListener('change', () => onchange(input.checked));
  return h('label', { class: 'switch' }, input, h('span'));
};

App.setting = (label, control, hint) =>
  h('div', { class: 'setting' }, h('div', {}, h('div', {}, label), hint ? h('div', { class: 'small muted' }, hint) : null), control);

App.select = function (options, value, onchange) {
  const s = h('select', {}, options.map(([v, text]) => h('option', { value: v }, text)));
  s.value = String(value);
  s.addEventListener('change', () => onchange(s.value));
  return s;
};

App.size = function (n) {
  if (n == null) return '';
  const u = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (i ? n.toFixed(n < 10 ? 1 : 0) : n) + ' ' + u[i];
};

App.when = function (seconds) {
  if (!seconds) return '';
  const d = new Date(seconds * 1000);
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: d.getFullYear() === new Date().getFullYear() ? undefined : 'numeric' }) +
    ' ' + d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
};

App.ago = function (seconds) {
  if (!seconds) return 'never';
  const m = Math.floor((Date.now() / 1000 - seconds) / 60);
  if (m < 1) return 'just now';
  if (m < 60) return m + ' min ago';
  if (m < 48 * 60) return Math.floor(m / 60) + ' h ago';
  return Math.floor(m / 1440) + ' days ago';
};

App.download = function (blob, name) {
  const a = h('a', { href: URL.createObjectURL(blob), download: name });
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
};

// A list the user can reorder: drag the handle, or the arrows. rows: [{ key, label, extra }]; onchange(keys).
// A visual editor: things drawn as they look on the Kindle, in zones (a grid, a
// group, Hidden...). Drag within or between zones with a mouse; tap one (on a
// phone too) for Move up, Move down, Move to a zone, and any extra actions.
// zones: [{ id, title, hint, empty, className, items: [{ key, ... }], render(item), accept(item) }]
// opts: { onChange(state: { zoneId: [keys] }), actions(item, zoneId) -> [{ text, fn, danger }] }
App.visualZones = function (zones, opts) {
  let drag = null;
  const state = {};
  const byKey = {};
  zones.forEach((z) => { state[z.id] = z.items.map((i) => i.key); z.items.forEach((i) => { byKey[i.key] = i; }); });
  const wrap = h('div', { class: 'stack' });
  const zoneOf = (key) => Object.keys(state).find((id) => state[id].includes(key));
  const move = (key, zoneId, beforeKey, delta) => {
    if (!key) return;
    const z = zones.find((x) => x.id === zoneId);
    if (z && z.accept && !z.accept(byKey[key])) return App.toast('That can’t go there', true);
    const from = zoneOf(key);
    let at = state[from].indexOf(key);
    state[from].splice(at, 1);
    const arr = state[zoneId];
    if (delta) at = Math.max(0, Math.min(arr.length, at + delta));
    else at = beforeKey ? arr.indexOf(beforeKey) : -1;
    if (at >= 0) arr.splice(at, 0, key); else arr.push(key);
    drag = null;
    draw();
    opts.onChange(state);
  };
  const menu = async (it, zoneId) => {
    const others = zones.filter((z) => z.id !== zoneId && (!z.accept || z.accept(it)));
    const extra = opts.actions ? opts.actions(it, zoneId) : [];
    const buttons = [{ text: 'Close', result: null }, { text: 'Move up', result: 'up' }, { text: 'Move down', result: 'down' },
      ...others.map((z) => ({ text: 'To ' + (z.short || z.title || z.id), result: 'to:' + z.id })),
      ...extra.map((x, i) => ({ text: x.text, result: 'x:' + i, danger: x.danger }))];
    const r = await App.modal(it.name || it.key, h('p', { class: 'muted small' }, 'Drag with a mouse, or use these.'), buttons);
    if (r === 'up') move(it.key, zoneId, null, -1);
    else if (r === 'down') move(it.key, zoneId, null, 1);
    else if (r && r.startsWith('to:')) move(it.key, r.slice(3), null);
    else if (r && r.startsWith('x:')) extra[Number(r.slice(2))].fn();
  };
  const draw = () => {
    wrap.replaceChildren(...zones.map((z) => {
      const box = h('div', { class: 've-zone ' + (z.className || '') });
      state[z.id].forEach((k) => {
        const it = byKey[k];
        const el = h('div', { class: 've-item', draggable: 'true', title: it.name || '' }, z.render ? z.render(it) : (it.name || k));
        el.addEventListener('dragstart', (e) => { drag = k; e.dataTransfer.effectAllowed = 'move'; el.classList.add('dragging'); });
        el.addEventListener('dragend', () => el.classList.remove('dragging'));
        el.addEventListener('dragover', (e) => { if (drag && drag !== k) { e.preventDefault(); el.classList.add('drop-before'); } });
        el.addEventListener('dragleave', () => el.classList.remove('drop-before'));
        el.addEventListener('drop', (e) => { e.preventDefault(); e.stopPropagation(); el.classList.remove('drop-before'); move(drag, z.id, k); });
        el.addEventListener('click', () => menu(it, z.id));
        box.append(el);
      });
      if (!state[z.id].length) box.append(h('span', { class: 'muted small' }, z.empty || 'Drop here'));
      box.addEventListener('dragover', (e) => { if (drag) { e.preventDefault(); box.classList.add('drop-on'); } });
      box.addEventListener('dragleave', () => box.classList.remove('drop-on'));
      box.addEventListener('drop', (e) => { e.preventDefault(); box.classList.remove('drop-on'); move(drag, z.id, null); });
      return h('div', {}, z.title ? h('div', { class: 've-title' }, z.title) : null, z.hint ? h('p', { class: 'muted small', style: 'margin:2px 0 6px' }, z.hint) : null, box);
    }));
  };
  draw();
  return wrap;
};

App.reorder = function (rows, onchange, renderExtra) {
  const box = h('div', { class: 'list-rows' });
  let dragged = null;
  let dragFrom = null;
  const history = [];
  const keys = () => [...box.children].map((r) => r.dataset.key);
  // Undo: the order before the last move.
  const undo = h('button', { class: 'btn small', style: 'display:none;margin-bottom:6px', onclick: () => {
    const prev = history.pop();
    if (!prev) return;
    for (const k of prev) {
      const row = [...box.children].find((r) => r.dataset.key === k);
      if (row) box.appendChild(row);
    }
    if (!history.length) undo.style.display = 'none';
    onchange(keys());
  } }, '↶ Undo');
  const remember = (before) => { history.push(before || keys()); undo.style.display = ''; };
  const move = (row, dir) => {
    const sib = dir < 0 ? row.previousElementSibling : row.nextElementSibling;
    if (!sib) return;
    remember();
    if (dir < 0) box.insertBefore(row, sib); else box.insertBefore(sib, row);
    onchange(keys());
  };
  const toEnd = (row, top) => {
    if (top ? row === box.firstElementChild : row === box.lastElementChild) return;
    remember();
    if (top) box.insertBefore(row, box.firstElementChild); else box.appendChild(row);
    onchange(keys());
  };
  for (const r of rows) {
    const row = h('div', { 'data-key': r.key, draggable: 'true', class: r.hidden ? 'hidden-row' : '' },
      h('span', { class: 'drag', title: 'Drag to move' }, '⠿'),
      h('span', { class: 'label grow' }, r.label),
      renderExtra ? renderExtra(r) : null,
      h('button', { class: 'icon-btn', title: 'Move to top', onclick: (e) => toEnd(e.target.closest('[data-key]'), true) }, '⤒'),
      h('button', { class: 'icon-btn', title: 'Up', onclick: (e) => move(e.target.closest('[data-key]'), -1) }, '↑'),
      h('button', { class: 'icon-btn', title: 'Down', onclick: (e) => move(e.target.closest('[data-key]'), 1) }, '↓'),
      h('button', { class: 'icon-btn', title: 'Move to bottom', onclick: (e) => toEnd(e.target.closest('[data-key]'), false) }, '⤓'));
    row.addEventListener('dragstart', () => { dragged = row; dragFrom = keys(); row.classList.add('dragging'); });
    row.addEventListener('dragend', () => {
      row.classList.remove('dragging');
      dragged = null;
      if (dragFrom && dragFrom.join('\n') !== keys().join('\n')) remember(dragFrom);
      dragFrom = null;
      onchange(keys());
    });
    row.addEventListener('dragover', (e) => {
      e.preventDefault();
      if (!dragged || dragged === row) return;
      const rect = row.getBoundingClientRect();
      box.insertBefore(dragged, e.clientY < rect.top + rect.height / 2 ? row : row.nextSibling);
    });
    box.appendChild(row);
  }
  return h('div', {}, undo, box);
};

// Tabs inside a page: [[key, label]], current, onpick.
App.tabs = (items, current, onpick) =>
  h('div', { class: 'tabs' }, items.map(([k, label]) => h('button', { class: k === current ? 'on' : '', onclick: () => onpick(k) }, label)));

App.route = function () {
  const hash = location.hash.slice(1) || 'home';
  const [page, query] = hash.split('?');
  const params = Object.fromEntries(new URLSearchParams(query || ''));
  for (const a of document.querySelectorAll('#nav a')) a.classList.toggle('on', a.dataset.page === page);
  // Drawn apart and shown when done; only the latest of overlapping loads is shown.
  const seq = App.seq = (App.seq || 0) + 1;
  const view = h('div');
  const p = App.pages[page] || App.pages.home;
  p.render(view, params).then(() => {
    if (seq === App.seq) document.getElementById('main').replaceChildren(view);
  }, App.fail);
};

// The Kindle's screen as a picture, and a remote: click the picture to tap the Kindle there (or hold),
// the buttons swipe; Live takes a new picture every few seconds. opts: { show, title, hint }.
App.remote = function (opts = {}) {
  const img = h('img', { alt: 'The Kindle’s screen', class: 'remote', style: 'display:none' });
  let live = null;
  const show = () => {
    if (!img.isConnected && img.src) { stop(); return; }
    img.src = '/api/screen?t=' + Date.now();
    img.style.display = '';
    button.textContent = 'Refresh';
    controls.style.display = '';
  };
  const stop = () => { if (live && live !== true) clearTimeout(live); live = null; };
  const button = h('button', { class: 'btn', onclick: show }, 'Show the screen');
  const mode = App.select([['tap', 'Click taps'], ['hold', 'Click holds']], 'tap', () => {});
  const gesture = async (json) => {
    await App.api('/api/kindle/gesture', { json }).catch(App.fail);
    setTimeout(show, 900);
  };
  img.addEventListener('click', (e) => {
    const r = img.getBoundingClientRect();
    gesture({ kind: mode.value, x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height });
  });
  // Live: the next picture asked for 3 s after the last one arrived (never
  // a queue of them on a slow Kindle), and none while this page is hidden.
  const next = () => {
    if (!live) return;
    if (!img.isConnected) { stop(); return; }
    live = setTimeout(() => { if (document.hidden) next(); else show(); }, 3000);
  };
  img.addEventListener('load', next);
  img.addEventListener('error', next);
  const liveToggle = App.toggle(false, (on) => {
    stop();
    if (on) {
      live = true;
      show();
    }
  });
  const swipe = (direction, label) => h('button', { class: 'btn small', onclick: () => gesture({ kind: 'swipe', direction }) }, label);
  const controls = h('div', { class: 'stack', style: 'display:none' },
    h('div', { class: 'row' }, mode, h('label', { class: 'row small' }, liveToggle, 'Live'),
      swipe('west', 'Swipe left'), swipe('east', 'Swipe right'), swipe('north', 'Swipe up'), swipe('south', 'Swipe down')),
    h('p', { class: 'muted small' }, 'Click the picture to tap the Kindle at that spot. Swipe left turns to the next page in a book.'));
  const card = h('div', { class: 'card stack', style: 'margin-top:16px' },
    h('div', { class: 'spread' }, h('h2', {}, opts.title || 'Kindle screen'), button),
    h('p', { class: 'muted small' }, opts.hint || 'What the Kindle shows right now. Use it as a remote: click the picture to tap the Kindle there.'),
    controls, img);
  card.show = show;
  if (opts.show) setTimeout(show, 0);
  return card;
};

// Keyboard shortcuts: / searches, 1-9 the tabs, ? lists them.
App.shortcuts = function () {
  document.addEventListener('keydown', (e) => {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    const t = e.target;
    const typing = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
    if (e.key === 'Escape') {
      const back = document.querySelector('.modal-back');
      if (back) back.click();
      else if (typing) t.blur();
      return;
    }
    if (typing || document.querySelector('.modal-back')) return;
    if (e.key === '/') {
      e.preventDefault();
      const s = document.getElementById('search');
      if (s) { s.focus(); s.select(); }
    } else if (/^[1-9]$/.test(e.key)) {
      const tabs = [...document.querySelectorAll('#nav a')].filter((a) => !a.classList.contains('off') && !a.classList.contains('hidden-tab'));
      const a = tabs[Number(e.key) - 1];
      if (a) location.hash = a.getAttribute('href');
    } else if (e.key === '?') {
      const tabs = [...document.querySelectorAll('#nav a')].filter((a) => !a.classList.contains('off') && !a.classList.contains('hidden-tab'));
      App.modal('Keyboard shortcuts', h('div', { class: 'stack' },
        h('div', {}, h('kbd', {}, '/'), '  Search'),
        tabs.map((a, i) => i < 9 ? h('div', {}, h('kbd', {}, String(i + 1)), '  ' + a.textContent) : null),
        h('div', {}, h('kbd', {}, 'Esc'), '  Close a box, or leave a text field'),
        h('div', {}, h('kbd', {}, '?'), '  This list')), [{ text: 'Close', primary: true }]);
    }
  });
};

// The tabs in the user's order, the hidden ones left out (System > Tabs): tabs = { order, hidden }.
// A tab not in the order (a new app) keeps its place after the ones that are. Home and System always show.
App.applyTabs = function (tabs) {
  App.tabOrder = { order: (tabs && tabs.order) || [], hidden: (tabs && tabs.hidden) || [] };
  const nav = document.getElementById('nav');
  const links = [...nav.querySelectorAll('a[data-page]')];
  // Each tab's place in index.html, kept from the first time (Reset puts them back there).
  links.forEach((a, i) => { if (a.dataset.at === undefined) a.dataset.at = String(i); });
  const rank = (a) => {
    const i = App.tabOrder.order.indexOf(a.dataset.page);
    return i >= 0 ? i : App.tabOrder.order.length + Number(a.dataset.at);
  };
  [...links].sort((x, y) => rank(x) - rank(y)).forEach((a) => {
    const always = a.dataset.page === 'home' || a.dataset.page === 'system';
    a.classList.toggle('hidden-tab', !always && App.tabOrder.hidden.includes(a.dataset.page));
    nav.append(a);
  });
};

App.start = async function () {
  App.shortcuts();
  try {
    const home = await App.api('/api/home');
    App.plugins = home.plugins;
    for (const a of document.querySelectorAll('#nav a[data-plugin]')) {
      a.classList.toggle('off', !home.plugins[a.dataset.plugin]);
    }
    App.applyTabs(home.tabs);
    document.title = home.model ? 'Kindle · ' + home.model : 'Kindle';
  } catch (e) { /* the pages say what is wrong */ }
  window.addEventListener('hashchange', App.route);
  App.route();
};
