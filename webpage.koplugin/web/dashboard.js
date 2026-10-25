// Dashboard: parts picked from the other tabs, for what is used most, in your order; saved on this
// Kindle. Each part reuses its tab's drawing where it can; a part whose plugin isn't installed is left out.
App.pages.dashboard = {
  editing: false,

  // The kinds of part: their name, the plugin they need, and (for some) what to pick when adding one.
  kinds: {
    todo: { name: 'A To Do list', plugin: 'todo' },
    haQuick: { name: 'Home Assistant: Quick tiles', plugin: 'homeassistant' },
    haRoom: { name: 'Home Assistant: a room', plugin: 'homeassistant' },
    notebooks: { name: 'Recent notebooks', plugin: 'notes' },
    crossword: { name: 'Today’s crossword', plugin: 'crosswords' },
    wikipedia: { name: 'Saved Wikipedia articles', plugin: 'wikipedia' },
    syncthing: { name: 'Syncthing status', plugin: 'syncthing' },
    ssh: { name: 'An SSH command', plugin: 'sshclient' },
    recent: { name: 'Recent files' },
    folder: { name: 'A favorite folder' },
    controls: { name: 'Kindle controls' },
    remote: { name: 'Kindle screen (remote)' },
  },

  installed(p) {
    const k = this.kinds[p.kind];
    return k && (!k.plugin || App.plugins[k.plugin]);
  },

  async render(main) {
    const d = await App.api('/api/dashboard');
    const page = this;
    const parts = App.arr(d.parts);
    const shown = parts.filter((p) => page.installed(p));
    main.append(
      h('div', { class: 'spread' },
        h('div', {}, h('h1', {}, 'Dashboard'), h('p', { class: 'sub' }, 'What you use most from the other tabs, on one page. Saved on this Kindle.')),
        h('div', { class: 'row' },
          parts.length ? h('button', { class: 'btn', onclick: () => { page.editing = !page.editing; App.route(); } }, page.editing ? 'Done' : 'Edit') : null,
          h('button', { class: 'btn primary', onclick: () => page.add(parts) }, 'Add a part…'))));
    if (!parts.length) {
      main.append(h('div', { class: 'card' }, h('p', { class: 'muted' }, 'Nothing here yet. Use Add a part… to put a To Do list, Home Assistant’s tiles, the Kindle’s controls and more on this page.')));
      return;
    }
    if (page.editing) {
      // The order (drag or the arrows), and ✕ to remove one.
      const rows = parts.map((p, i) => ({ key: String(i), label: page.label(p) + (page.installed(p) ? '' : ' (plugin not installed)') }));
      let order = rows.map((r) => r.key);
      const save = () => page.save(order.map((k) => parts[Number(k)]));
      main.append(h('div', { class: 'card' }, h('h2', {}, 'Parts'),
        App.reorder(rows, (keys) => { order = keys; save(); }, (r) => h('button', { class: 'icon-btn', title: 'Remove', onclick: async () => {
          order = order.filter((k) => k !== r.key);
          await save();
          App.route();
        } }, '✕'))));
      return;
    }
    // Each part drawn as its data comes (a slow one doesn't hold up the rest).
    for (const p of shown) {
      const slot = h('div', { class: 'card' }, h('h2', {}, page.label(p)), h('p', { class: 'muted small' }, 'Loading…'));
      main.append(slot);
      page.part(p).then((el) => { if (el) slot.replaceWith(el); else slot.remove(); }, (e) => {
        slot.replaceChildren(h('h2', {}, page.label(p)), h('p', { class: 'muted small' }, e && e.message ? e.message : 'Not available.'));
      });
    }
  },

  label(p) {
    if (p.kind === 'haRoom') return p.room || 'Room';
    if (p.kind === 'ssh') return 'SSH: ' + (p.name || 'command');
    if (p.kind === 'folder') return p.name || p.path || 'Folder';
    if (p.kind === 'todo') return 'To Do';
    return (this.kinds[p.kind] || { name: p.kind }).name;
  },

  async save(parts) {
    try { await App.api('/api/dashboard', { json: { parts } }); } catch (e) { App.fail(e); }
  },

  // Add a part…: the kind, then (for some) which list, room, command or folder.
  async add(parts) {
    const page = this;
    const kinds = Object.entries(page.kinds).filter(([kind]) => page.installed({ kind }));
    const pick = App.select(kinds.map(([k, v]) => [k, v.name]), kinds[0][0], () => {});
    const kind = await App.modal('Add a part', h('div', { class: 'stack' }, h('label', { class: 'field' }, h('span', {}, 'Part'), pick)),
      [{ text: 'Cancel', result: null }, { text: 'Next', primary: true, value: () => pick.value }]);
    if (!kind) return;
    let part = { kind };
    const choose = async (title, options) => {
      if (!options.length) { App.toast('Nothing to choose from yet', true); return null; }
      const sel = App.select(options, options[0][0], () => {});
      return App.modal(title, h('label', { class: 'field' }, h('span', {}, title), sel),
        [{ text: 'Cancel', result: null }, { text: 'Add', primary: true, value: () => sel.value }]);
    };
    try {
      if (kind === 'todo') {
        const t = await App.api('/api/todo');
        const list = await choose('Which list', App.arr(t.lists).map((l) => [l.id, l.name]));
        if (!list) return;
        part.list = list;
      } else if (kind === 'haRoom') {
        const ha = await App.api('/api/dashboard/ha');
        const room = await choose('Which room', App.arr(ha.rooms).map((r) => [r, r]));
        if (!room) return;
        part.room = room;
      } else if (kind === 'ssh') {
        const s = await App.api('/api/ssh');
        const options = [];
        for (const x of App.arr(s.hosts)) {
          for (const c of App.arr(x.commands)) options.push([x.id + '/' + c.id, (x.name || x.address) + ': ' + (c.name || c.cmd)]);
        }
        const ref = await choose('Which command', options);
        if (!ref) return;
        part = { kind, ref, name: (options.find((o) => o[0] === ref) || [])[1] };
      } else if (kind === 'folder') {
        const f = await App.api('/api/files?path=/');
        const places = App.obj(f.places);
        const options = [...(places.home && places.home !== '/' ? [[places.home, 'Home folder']] : []),
          ...App.arr(places.shortcuts).map((p) => [p.path, p.name])];
        if (!options.length) { App.toast('No favorite folders yet: add some on the Files tab (★) or in KOReader', true); return; }
        const path = await choose('Which folder', options);
        if (!path) return;
        part = { kind, path, name: (options.find((o) => o[0] === path) || [])[1] };
      }
    } catch (e) { return App.fail(e); }
    await page.save([...parts, part]);
    App.toast('Added');
    App.route();
  },

  // One part, drawn: a card (or nothing to leave it out).
  async part(p) {
    const card = (title, ...kids) => h('div', { class: 'card' }, h('h2', {}, title), ...kids);
    const more = (href, text) => h('p', { class: 'small', style: 'margin:10px 0 0' }, h('a', { href }, text));
    switch (p.kind) {
      case 'todo': {
        const s = await App.api('/api/todo');
        if (!s.installed) return null;
        s.lists = App.arr(s.lists);
        for (const l of s.lists) {
          l.tasks = App.arr(l.tasks);
          for (const t of l.tasks) t.steps = App.arr(t.steps);
        }
        const list = s.lists.find((l) => l.id === p.list);
        if (!list) return card('To Do', h('p', { class: 'muted' }, 'This list is gone. Edit the dashboard to remove it.'));
        const open = list.tasks.filter((t) => !t.completed);
        const input = h('input', { type: 'text', placeholder: 'Add a task', style: 'flex:1' });
        const add = async () => {
          const title = input.value.trim();
          if (!title) return;
          await App.api('/api/todo/task', { json: { op: 'add', list: list.id, title } }).catch(App.fail);
          App.route();
        };
        input.addEventListener('keydown', (e) => { if (e.key === 'Enter') add(); });
        const todo = App.pages.todo;
        return card(list.name,
          open.length ? h('div', {}, open.slice(0, 12).map((t) => todo.taskRow(s, list, t))) : h('p', { class: 'muted' }, 'Nothing to do.'),
          h('div', { class: 'row', style: 'margin-top:10px' }, input, h('button', { class: 'btn small', onclick: add }, 'Add')),
          more('#todo?list=' + encodeURIComponent(list.id), open.length > 12 ? 'All ' + open.length + ' tasks' : 'Open in To Do'));
      }
      case 'haQuick':
      case 'haRoom': {
        const q = p.kind === 'haQuick' ? 'quick=1' : 'room=' + encodeURIComponent(p.room || '');
        const ha = await App.api('/api/dashboard/ha?' + q);
        if (!ha.installed) return null;
        const title = p.kind === 'haQuick' ? 'Home Assistant · Quick' : (p.room || 'Room');
        if (!ha.signedIn) return card(title, h('p', { class: 'muted' }, 'Not signed in to Home Assistant.'), more('#ha', 'Sign in'));
        const tiles = App.arr(ha.tiles);
        if (!tiles.length) return card(title, h('p', { class: 'muted' }, p.kind === 'haRoom' ? 'No devices in this room (or it’s gone).' : 'No Quick tiles yet.'));
        return card(title, h('div', { class: 'tiles' }, tiles.map((t) => this.haTile(t))),
          h('p', { class: 'muted small', style: 'margin:10px 0 0' }, 'Updated ' + App.ago(ha.updated) + '. Tap a tile to switch it, as on the Kindle.'));
      }
      case 'notebooks': {
        const s = await App.api('/api/notes');
        if (!s.installed) return null;
        const list = App.arr(s.notebooks).slice().sort((a, b) => (b.modified || 0) - (a.modified || 0)).slice(0, 8);
        return card('Recent notebooks', list.length ? h('div', { class: 'list-rows' }, list.map((nb) =>
          h('div', {}, h('a', { class: 'grow', href: '#notes?nb=' + encodeURIComponent(nb.id) }, (nb.locked ? '🔒 ' : '') + nb.name),
            h('span', { class: 'muted small' }, App.when(nb.modified))))) : h('p', { class: 'muted' }, 'No notebooks yet.'),
          more('#notes', 'All notebooks'));
      }
      case 'crossword': {
        const s = await App.api('/api/crosswords');
        if (!s.installed) return null;
        // Each puzzle's day: days since 1970-01-01 in local time (as the Kindle's Crossword.localDay).
        const today = Math.floor((Date.now() - new Date().getTimezoneOffset() * 60000) / 86400000);
        const rows = [];
        for (const b of App.arr(s.books)) {
          for (const pz of App.arr(b.puzzles)) {
            if (pz.day === today) rows.push([b, pz]);
          }
        }
        const cw = App.pages.crosswords;
        return card('Today’s crossword', rows.length ? h('div', { class: 'list-rows' }, rows.map(([b, pz]) =>
          h('div', {}, h('div', { class: 'grow' }, h('strong', {}, pz.label), h('div', { class: 'small muted' }, b.name)),
            h('span', { class: 'pill' + (pz.state === 'done' ? ' ok' : '') }, { done: 'Done', started: 'Started', new: 'Not started' }[pz.state] || pz.state),
            h('button', { class: 'btn small', onclick: () => cw.open(b, pz) }, 'Open on Kindle')))) :
          h('p', { class: 'muted' }, 'None for today on the Kindle yet.'), more('#crosswords', 'Crosswords'));
      }
      case 'wikipedia': {
        const s = await App.api('/api/wikipedia');
        if (!s.installed) return null;
        s.saved = App.arr(s.saved);
        s.recent = App.arr(s.recent);
        const el = App.pages.wikipedia.saved(s);
        // (Its tab's heading, said for this page.)
        const title = el.querySelector('h2');
        if (title && title.firstChild) title.firstChild.textContent = 'Saved Wikipedia articles ';
        return el;
      }
      case 'syncthing': {
        const s = await App.api('/api/syncthing');
        if (!s.installed) return null;
        ['folders', 'devices', 'pendingDevices', 'pendingFolders'].forEach((k) => { s[k] = App.arr(s[k]); });
        const st = App.pages.syncthing;
        const box = h('div', {}, st.status(s));
        const req = st.requests(s);
        if (req) box.append(req);
        return box;
      }
      case 'ssh': {
        const run = async (button) => {
          button.disabled = true;
          try { await App.api('/api/dashboard/ssh', { json: { ref: p.ref } }); App.toast('Running on the Kindle; the output shows there'); } catch (e) { App.fail(e); }
          button.disabled = false;
        };
        const button = h('button', { class: 'btn primary', onclick: () => run(button) }, 'Run on the Kindle');
        return card(this.label(p), h('div', { class: 'spread' },
          h('p', { class: 'muted small', style: 'margin:0' }, 'Runs this saved command on the Kindle, as its gesture does.'), button));
      }
      case 'recent': {
        const r = await App.api('/api/library/recent?n=8');
        const files = App.arr(r.files);
        return card('Recent files', files.length ? h('div', { class: 'list-rows' }, files.map((f) => {
          const dir = f.path.replace(/\/[^/]+$/, '') || '/';
          return h('div', {}, h('a', { class: 'grow', href: '#files?path=' + encodeURIComponent(dir) + '&find=' + encodeURIComponent(f.name), title: f.path }, f.name),
            h('span', { class: 'muted small' }, App.when(f.mtime)));
        })) : h('p', { class: 'muted' }, 'No files yet.'), more('#files', 'Files'));
      }
      case 'folder': {
        const f = await App.api('/api/files?path=' + encodeURIComponent(p.path || '/'));
        const entries = App.arr(f.entries);
        const join = (name) => (f.path === '/' ? '' : f.path) + '/' + name;
        const list = entries.slice(0, 12).map((e) => h('div', {}, e.dir
          ? h('a', { class: 'grow', href: '#files?path=' + encodeURIComponent(join(e.name)) }, '📁 ' + e.name)
          : h('a', { class: 'grow', href: '#files?path=' + encodeURIComponent(f.path) + '&find=' + encodeURIComponent(e.name) }, e.name),
        e.dir ? null : h('button', { class: 'btn small', onclick: () => App.api('/api/books/open', { json: { path: join(e.name) } })
          .then(() => App.toast('Opening “' + e.name + '” on the Kindle'), App.fail) }, 'Open on Kindle')));
        return card(this.label(p), entries.length ? h('div', { class: 'list-rows' }, list) : h('p', { class: 'muted' }, 'This folder is empty.'),
          more('#files?path=' + encodeURIComponent(f.path), entries.length > 12 ? 'All ' + entries.length + ' items' : 'Open in Files'));
      }
      case 'controls': return App.kindleControls();
      case 'remote': return App.remote();
      default: return null;
    }
  },

  // A Home Assistant tile: dark when on; a tap does what it does on the Kindle (asked first where the Kindle asks).
  haTile(t) {
    const el = h('button', { class: 'ha-tile' + (t.on ? ' on' : '') + (t.gone ? ' gone' : ''), disabled: !t.tap, title: t.tap ? '' : 'Change it on the Kindle' },
      h('strong', {}, t.name), h('span', { class: 'small' }, t.state));
    el.addEventListener('click', async () => {
      if (t.confirm && !await App.confirm(t.name, t.confirm, 'OK')) return;
      el.disabled = true;
      try {
        const r = await App.api('/api/dashboard/ha/act', { json: { id: t.id } });
        // The state as switched (Home Assistant's own a moment later).
        if (r.tile) el.replaceWith(this.haTile(r.tile));
        setTimeout(() => { if (location.hash.startsWith('#dashboard') && !this.editing) App.route(); }, 2500);
      } catch (e) { App.fail(e); el.disabled = false; }
    });
    return el;
  },
};
