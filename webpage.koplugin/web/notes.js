// Notes: notebooks in their folders (drawn here from their ink, saved as PNG), new, rename, duplicate,
// delete, move, several at once; pages bookmarked, deleted or saved several at once; order;
// Notes' settings (grouped as on the Kindle) and OneNote (the AI is the AI tab's, ai.js).
App.pages.notes = {
  tab: 'notebooks',
  cache: {},
  async render(main, params) {
    const s = await App.api('/api/notes');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'The Notes plugin isn’t installed on this Kindle.')); return; }
    s.notebooks = App.arr(s.notebooks);
    s.folders = App.arr(s.folders);
    s.settings = App.obj(s.settings);
    s.settings.order = App.arr(s.settings.order);
    if (params.nb) return this.viewer(main, s, params.nb);
    const page = this;
    const body = h('div');
    const draw = () => {
      body.innerHTML = '';
      body.append(App.tabs([['notebooks', 'Notebooks'], ['order', 'Order'], ['settings', 'Settings'], ['accounts', 'Integrations']], page.tab, (k) => { page.tab = k; draw(); }),
        page[page.tab](s));
    };
    main.append(h('div', { class: 'spread' }, h('div', {}, h('h1', {}, 'Notes'), h('p', { class: 'sub' }, s.notebooks.length + ' notebook(s)')),
      h('div', { class: 'row' },
        s.hasFolders ? h('button', { class: 'btn', onclick: () => page.newFolder() }, 'New folder') : null,
        h('button', { class: 'btn primary', onclick: () => page.newNotebook(s) }, 'New notebook'))), body);
    draw();
  },

  // The folder shown ('' is the top level) and, while selecting, what's ticked ('f:path' / 'n:id').
  folder: '',
  sel: null,

  notebooks(s) {
    const page = this;
    const folder = page.folder;
    const parentOf = (p) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '');
    const nameOf = (p) => p.slice(p.lastIndexOf('/') + 1);
    const within = (p, f) => p === f || p.startsWith(f + '/');
    if (folder && !s.folders.includes(folder)) page.folder = '';
    const kids = s.folders.filter((p) => parentOf(p) === page.folder).sort((a, b) => nameOf(a).localeCompare(nameOf(b)));
    const here = s.notebooks.filter((nb) => (nb.folder || '') === page.folder);
    const count = (p) => s.notebooks.filter((nb) => nb.folder && within(nb.folder, p)).length;
    const sel = page.sel;
    const box = h('div', { class: 'stack' });
    const redraw = () => { const parent = box.parentNode; const fresh = page.notebooks(s); parent.replaceChild(fresh, box); };
    const go = (p) => { page.folder = p; page.sel = null; redraw(); };

    // Where we are: Notes › Work › Clients.
    const crumbs = h('div', { class: 'row small' });
    crumbs.append(h('a', { href: '#notes', onclick: (e) => { e.preventDefault(); go(''); } }, 'Notes'));
    let acc = '';
    for (const part of page.folder ? page.folder.split('/') : []) {
      acc = acc ? acc + '/' + part : part;
      const to = acc;
      crumbs.append(h('span', { class: 'muted' }, '›'), h('a', { href: '#notes', onclick: (e) => { e.preventDefault(); go(to); } }, part));
    }

    // Select, or what to do with what's ticked.
    const bar = h('div', { class: 'row' });
    if (!sel) {
      bar.append(h('button', { class: 'btn small', onclick: () => { page.sel = new Set(); redraw(); } }, 'Select'));
    } else {
      const ids = [...sel].filter((k) => k.startsWith('n:')).map((k) => k.slice(2));
      const paths = [...sel].filter((k) => k.startsWith('f:')).map((k) => k.slice(2));
      const none = sel.size === 0;
      bar.append(...[h('strong', {}, sel.size + ' selected'),
        h('button', { class: 'btn small', disabled: none, onclick: () => page.moveTo(s, ids, paths) }, 'Move to…'),
        h('button', { class: 'btn small', disabled: !ids.length, onclick: () => page.bulk({ op: 'duplicate', ids }) }, 'Duplicate'),
        paths.length === 1 && ids.length === 0 ? h('button', { class: 'btn small', onclick: () => page.renameFolder(paths[0]) }, 'Rename') : null,
        h('button', { class: 'btn small danger', disabled: none, onclick: () => page.deleteMany(s, ids, paths) }, 'Delete…'),
        h('button', { class: 'btn small', onclick: () => {
          for (const p of kids) sel.add('f:' + p);
          for (const nb of here) sel.add('n:' + nb.id);
          redraw();
        } }, 'Select all'),
        h('button', { class: 'btn small', onclick: () => { page.sel = null; redraw(); } }, 'Done')].filter(Boolean));
    }
    box.append(h('div', { class: 'spread' }, crumbs, bar));

    // The trash, at the top level.
    const trash = App.arr(s.trash);
    if (!page.folder && !sel && trash.length) {
      box.append(page.trashCard(trash));
    }
    if (!kids.length && !here.length) {
      box.append(h('div', { class: 'empty' }, page.folder ? 'This folder is empty.' : 'No notebooks yet.'));
      return box;
    }
    const grid = h('div', { class: 'grid' });
    const tick = (key) => (sel ? h('input', { type: 'checkbox', checked: sel.has(key), style: 'margin-right:6px', onclick: (e) => e.stopPropagation(),
      onchange: (e) => { if (e.target.checked) sel.add(key); else sel.delete(key); redraw(); } }) : null);
    for (const p of kids) {
      const key = 'f:' + p;
      const n = count(p);
      grid.append(h('div', { class: 'card nb-card', onclick: () => {
        if (sel) { if (sel.has(key)) sel.delete(key); else sel.add(key); redraw(); } else go(p);
      } },
        h('div', { class: 'folder-face' }, '📁'),
        h('div', { class: 'title' }, tick(key), nameOf(p)),
        h('div', { class: 'small muted' }, n === 0 ? 'Empty' : n + ' notebook' + (n === 1 ? '' : 's'))));
    }
    for (const nb of here) {
      const key = 'n:' + nb.id;
      // Locked with a PIN on the Kindle: a lock, not its pages.
      const canvas = nb.locked ? h('div', { class: 'folder-face' }, '🔒') : h('canvas', { width: 300, height: 400 });
      grid.append(h('div', { class: 'card nb-card', onclick: () => {
        if (sel) { if (sel.has(key)) sel.delete(key); else sel.add(key); redraw(); }
        else if (nb.locked) App.toast('This notebook is locked. Open it on the Kindle.');
        else location.hash = '#notes?nb=' + nb.id;
      } }, canvas,
        h('div', { class: 'title' }, tick(key), nb.name), h('div', { class: 'small muted' }, (nb.locked ? 'Locked · ' : '') + nb.pages + ' page(s) · ' + App.when(nb.modified))));
      if (!nb.locked) this.load(nb.id, nb.modified).then((data) => this.draw(canvas, data, 0, 300)).catch(() => {});
    }
    box.append(grid);
    return box;
  },

  // Deleted notebooks (kept 30 days): restore or delete each permanently, or empty it all.
  trashCard(trash) {
    const list = h('div', { class: 'stack', style: 'display:none' });
    for (const e of trash) {
      list.append(h('div', { class: 'spread' },
        h('div', {}, h('div', {}, e.name), h('div', { class: 'small muted' },
          e.pages + ' page(s) · deleted ' + App.when(e.at) + (e.folder ? ' · from ' + e.folder.split('/').join(' › ') : ''))),
        h('div', { class: 'row' },
          h('button', { class: 'btn small', onclick: () => App.api('/api/notes/trash', { json: { op: 'restore', id: e.id } }).then(App.route, App.fail) }, 'Restore'),
          h('button', { class: 'btn small danger', onclick: async () => {
            if (await App.confirm('Delete permanently', 'Permanently delete “' + e.name + '”? This can’t be undone.', 'Delete', true)) {
              App.api('/api/notes/trash', { json: { op: 'purge', id: e.id } }).then(App.route, App.fail);
            }
          } }, 'Delete permanently'))));
    }
    const toggle = h('button', { class: 'btn small', onclick: () => {
      const open = list.style.display === 'none';
      list.style.display = open ? '' : 'none';
      toggle.textContent = open ? 'Hide' : 'Show';
    } }, 'Show');
    return h('div', { class: 'card stack' },
      h('div', { class: 'spread' }, h('div', {}, h('strong', {}, 'Trash · ' + trash.length + ' notebook(s)'),
        h('div', { class: 'small muted' }, 'Deleted notebooks are kept for 30 days.')),
        h('div', { class: 'row' }, toggle, h('button', { class: 'btn small danger', onclick: async () => {
          if (await App.confirm('Empty trash', 'Permanently delete the ' + trash.length + ' notebook(s) in the trash? This can’t be undone.', 'Empty trash', true)) {
            App.api('/api/notes/trash', { json: { op: 'empty' } }).then(App.route, App.fail);
          }
        } }, 'Empty trash'))),
      list);
  },

  async bulk(body) {
    await App.api('/api/notes/folders', { json: body }).then(() => { this.sel = null; App.route(); }, App.fail);
  },

  async newFolder() {
    const name = await App.prompt('New folder', '', 'Folder name');
    if (!name || !name.trim()) return;
    await this.bulk({ op: 'new', path: (this.folder ? this.folder + '/' : '') + name.trim() });
  },

  async renameFolder(path) {
    const name = await App.prompt('Rename folder', path.slice(path.lastIndexOf('/') + 1));
    if (!name || !name.trim()) return;
    const parent = path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : '';
    await this.bulk({ op: 'rename', path, to: (parent ? parent + '/' : '') + name.trim() });
  },

  // Folders and notebooks into a folder picked (or a new one).
  async moveTo(s, ids, paths) {
    const within = (p, f) => p === f || p.startsWith(f + '/');
    const options = [['', 'Notes (top level)']].concat(s.folders.filter((p) => !paths.some((f) => within(p, f)))
      .map((p) => [p, p.split('/').join(' › ')]));
    const pick = App.select(options, this.folder, () => {});
    const fresh = h('input', { type: 'text', placeholder: 'or a new folder in it', style: 'width:100%' });
    const ok = await App.modal('Move ' + (ids.length + paths.length) + ' item(s) to', h('div', { class: 'stack' },
      h('label', { class: 'field' }, h('span', {}, 'Folder'), pick), h('label', { class: 'field' }, h('span', {}, 'New folder (optional)'), fresh)),
    [{ text: 'Cancel', result: false }, { text: 'Move', primary: true, result: true }]);
    if (!ok) return;
    const to = fresh.value.trim() ? (pick.value ? pick.value + '/' : '') + fresh.value.trim() : pick.value;
    await this.bulk({ op: 'move', ids, paths, to });
  },

  // Folders and notebooks deleted; a folder's notebooks too, or kept (moved up a folder).
  async deleteMany(s, ids, paths) {
    const within = (p, f) => p === f || p.startsWith(f + '/');
    const inside = s.notebooks.filter((nb) => nb.folder && paths.some((p) => within(nb.folder, p)) && !ids.includes(nb.id)).length;
    const what = [ids.length ? ids.length + ' notebook(s)' : '', paths.length ? paths.length + ' folder(s)' : ''].filter(Boolean).join(' and ');
    if (!inside) {
      if (await App.confirm('Delete', 'Delete ' + what + '? Notebooks go to the trash (restored there for 30 days).', 'Delete', true)) {
        await this.bulk({ op: 'delete', ids, paths, keep: true });
      }
      return;
    }
    const choice = await App.modal('Delete', h('p', {}, 'Delete ' + what + '? The folders have ' + inside + ' more notebook(s) in them. Notebooks go to the trash (restored there for 30 days).'),
      [{ text: 'Cancel', result: null }, { text: 'Delete folder only (keep notebooks)', result: 'keep' }, { text: 'Delete folder and notebooks', danger: true, result: 'all' }]);
    if (!choice) return;
    await this.bulk({ op: 'delete', ids, paths, keep: choice === 'keep' });
  },

  async load(id, modified) {
    const cached = this.cache[id];
    if (!cached || (modified !== undefined && cached.modified !== modified)) {
      const entry = { modified };
      this.cache[id] = entry;
      entry.promise = App.api('/api/notes/notebook?id=' + encodeURIComponent(id)).then((d) => {
        d.pages = App.arr(d.pages);
        for (const pg of d.pages) pg.strokes = App.arr(pg.strokes);
        d.tips = App.obj(d.tips);
        return d;
      });
    }
    this.cache[id].promise.catch(() => { if (this.cache[id] && this.cache[id].promise) delete this.cache[id]; });
    return this.cache[id].promise;
  },

  // A page of `data` onto `canvas`, `width` pixels across (the height follows the page).
  draw(canvas, data, index, width) {
    const scale = width / data.width;
    canvas.width = Math.round(width);
    canvas.height = Math.round(data.height * scale);
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    const mm = (data.dpi || 300) / 25.4 * scale;
    const gap = { narrow: 7.1, wide: 8.7, grid: 5, dots: 5 }[data.paper] * mm;
    if (gap) {
      ctx.fillStyle = data.paper === 'dots' ? '#808080' : '#c0c0c0';
      const line = Math.max(1, scale);
      if (data.paper === 'narrow' || data.paper === 'wide') {
        for (let y = 2 * gap; y < canvas.height; y += gap) ctx.fillRect(0, Math.round(y), canvas.width, line);
      } else if (data.paper === 'grid') {
        for (let y = gap; y < canvas.height; y += gap) ctx.fillRect(0, Math.round(y), canvas.width, line);
        for (let x = gap; x < canvas.width; x += gap) ctx.fillRect(Math.round(x), 0, line, canvas.height);
      } else {
        const dot = Math.max(1.5, 3 * scale * 1.5);
        for (let y = gap; y < canvas.height; y += gap) for (let x = gap; x < canvas.width; x += gap) ctx.fillRect(x, y, dot, dot);
      }
    }
    const pg = data.pages[index];
    if (!pg) return;
    const tips = data.tips || {};
    const ordered = [...pg.strokes.filter((st) => (tips[st.t] || {}).under), ...pg.strokes.filter((st) => !(tips[st.t] || {}).under)];
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    for (const st of ordered) {
      const g = st.c ?? (tips[st.t] || { grey: 0 }).grey;
      ctx.strokeStyle = ctx.fillStyle = `rgb(${g},${g},${g})`;
      const p = st.p;
      const q = st.q;
      if (p.length === 2) {
        const w = (q ? q[0] : st.w) * scale;
        ctx.fillRect(p[0] * scale - w / 2, p[1] * scale - w / 2, w, w);
        continue;
      }
      for (let i = 0; i + 3 < p.length; i += 2) {
        const k = i / 2;
        const w = q ? (q[k] + (q[k + 1] ?? q[k])) / 2 : st.w;
        ctx.lineWidth = Math.max(0.6, w * scale);
        ctx.beginPath();
        ctx.moveTo(p[i] * scale, p[i + 1] * scale);
        ctx.lineTo(p[i + 2] * scale, p[i + 3] * scale);
        ctx.stroke();
      }
    }
    // Typed text boxes (pictures and tape as grey boxes).
    for (const it of App.arr(pg.items)) {
      if (it.k === 'text') {
        const size = it.size * scale;
        ctx.fillStyle = '#000';
        ctx.font = (it.italic ? 'italic ' : '') + (it.bold ? 'bold ' : '') + size + 'px ' + (it.serif ? 'serif' : 'sans-serif');
        ctx.textBaseline = 'top';
        let y = it.y * scale;
        for (const line of String(it.text).split('\n')) {
          ctx.fillText(line, it.x * scale, y, it.w * scale);
          if (it.link) ctx.fillRect(it.x * scale, y + size * 1.15, Math.min(it.w * scale, ctx.measureText(line).width), Math.max(1, size / 14));
          y += size * 1.3;
        }
      } else {
        ctx.fillStyle = it.k === 'tape' && !it.open ? '#999' : '#ddd';
        ctx.fillRect(it.x * scale, it.y * scale, it.w * scale, it.h * scale);
      }
    }
  },

  async viewer(main, s, id) {
    delete this.cache[id];
    const data = await this.load(id);
    if (data.pdf) App.toast('PDF pages show only the writing here: Download PDF shows them whole.');
    const page = this;
    const pages = h('div', { class: 'pages' });
    const safe = data.name.replace(/[\\/:*?"<>|]+/g, '_');
    const png = (i) => new Promise((resolve) => {
      const c = document.createElement('canvas');
      page.draw(c, data, i, data.width);
      c.toBlob((b) => { App.download(b, `${safe} - page ${String(i + 1).padStart(2, '0')}.png`); resolve(); }, 'image/png');
    });
    const picked = new Set();
    const pageBar = h('div', { class: 'row' });
    const drawBar = () => {
      pageBar.innerHTML = '';
      if (!picked.size) return;
      const list = [...picked].sort((a, b) => a - b);
      const allStarred = list.every((i) => data.pages[i].star);
      pageBar.append(h('strong', {}, picked.size + ' page(s) selected'),
        h('button', { class: 'btn small', onclick: async () => { for (const i of list) await png(i); } }, 'Save PNGs'),
        h('button', { class: 'btn small', onclick: () => pagesOp(allStarred ? 'unstar' : 'star', list) }, allStarred ? 'Remove bookmarks' : 'Bookmark'),
        h('button', { class: 'btn small danger', disabled: list.length >= data.pages.length, onclick: async () => {
          if (await App.confirm('Delete pages', 'Delete ' + list.length + ' page(s)? This cannot be undone.', 'Delete pages', true)) pagesOp('delete', list);
        } }, 'Delete pages'),
        h('button', { class: 'btn small', onclick: () => { picked.clear(); for (const cb of pages.querySelectorAll('input[type=checkbox]')) cb.checked = false; drawBar(); } }, 'Clear'));
    };
    async function pagesOp(op, list) {
      await App.api('/api/notes/pages', { json: { id, op, pages: list.map((i) => i + 1) } }).then(App.route, App.fail);
    }
    data.pages.forEach((pg, i) => {
      const c = h('canvas');
      const cb = h('input', { type: 'checkbox', onchange: (e) => { if (e.target.checked) picked.add(i); else picked.delete(i); drawBar(); } });
      pages.append(h('div', { class: 'page-wrap' },
        h('div', { class: 'spread small muted', style: 'max-width:760px;margin:0 auto 6px' },
          h('label', { class: 'row' }, cb, (pg.star ? '★ ' : '') + 'Page ' + (i + 1)),
          h('button', { class: 'btn small', onclick: () => png(i) }, 'Save PNG')),
        c, pg.text ? h('div', { class: 'card small', style: 'max-width:760px;margin:8px auto 0;white-space:pre-wrap' }, pg.text) : null));
      requestAnimationFrame(() => page.draw(c, data, i, Math.min(760, pages.clientWidth || 760) * (window.devicePixelRatio || 1)));
    });
    main.append(
      h('div', { class: 'spread' },
        h('div', {}, h('a', { href: '#notes', class: 'small' }, '← Notebooks'), h('h1', {}, data.name),
          h('p', { class: 'sub' }, data.pages.length + ' page(s) · ' + data.paper + ' paper')),
        h('div', { class: 'row' },
          h('button', { class: 'btn primary', onclick: async () => { for (let i = 0; i < data.pages.length; i++) await png(i); } }, 'Save all pages'),
          h('button', { class: 'btn', onclick: (e) => page.downloadPdf(id, e.currentTarget) }, 'Download PDF'),
          h('button', { class: 'btn', onclick: () => page.addPicture(id) }, 'Add picture'),
          h('button', { class: 'btn', onclick: () => op('rename') }, 'Rename'),
          h('button', { class: 'btn', onclick: () => op('duplicate') }, 'Duplicate'),
          h('button', { class: 'btn danger', onclick: () => op('delete') }, 'Delete'))),
      h('div', { style: 'max-width:760px;margin:0 auto 10px' }, pageBar),
      pages);

    async function op(kind) {
      if (kind === 'rename' || kind === 'duplicate') {
        const name = await App.prompt(kind === 'rename' ? 'Rename notebook' : 'Copy name', kind === 'rename' ? data.name : data.name + ' (copy)');
        if (!name) return;
        const ok = await App.api('/api/notes/notebook', { json: { op: kind, id, name } }).then(() => true, (e) => { App.fail(e); return false; });
        if (!ok) return;
        if (kind === 'duplicate') { location.hash = '#notes'; return; }
        App.route();
      } else if (await App.confirm('Delete notebook', 'Move “' + data.name + '” to the trash? You can restore it for 30 days.', 'Delete', true)) {
        const ok = await App.api('/api/notes/notebook', { json: { op: 'delete', id } }).then(() => true, (e) => { App.fail(e); return false; });
        if (ok) location.hash = '#notes';
      }
    }
  },

  // A picture from this computer on a new page at the end of notebook `id`.
  addPicture(id) {
    const input = h('input', { type: 'file', accept: 'image/png,image/jpeg', style: 'display:none' });
    input.addEventListener('change', async () => {
      const file = input.files[0];
      if (!file) return;
      App.toast('Uploading ' + file.name + '…');
      const r = await fetch('/api/notes/image?id=' + encodeURIComponent(id) + '&name=' + encodeURIComponent(file.name),
        { method: 'PUT', body: file }).catch(() => null);
      if (!r || !r.ok) { App.toast(r ? (await r.text()) : 'The upload failed', true); return; }
      const d = await r.json();
      App.toast('Added to ' + d.where);
      delete this.cache[id];
      App.route();
    });
    document.body.append(input);
    input.click();
    setTimeout(() => input.remove(), 60000);
  },

  async newNotebook(s) {
    const name = h('input', { type: 'text', placeholder: 'Notebook name', style: 'width:100%' });
    const paper = App.select(Object.entries(s.papers), s.settings.paper || 'narrow', () => {});
    // Or a PDF from this computer: a notebook to write on, or a puzzle book.
    const pdf = h('input', { type: 'file', accept: 'application/pdf,.pdf' });
    const kind = App.select([['notebook', 'A notebook to write on'], ['puzzle', 'A puzzle book']], 'notebook', () => {});
    const ok = await App.modal('New notebook', h('div', { class: 'stack' },
      h('label', { class: 'field' }, h('span', {}, 'Name'), name), h('label', { class: 'field' }, h('span', {}, 'Paper'), paper),
      h('label', { class: 'field' }, h('span', {}, 'Or from a PDF (optional)'), pdf),
      h('label', { class: 'field' }, h('span', {}, 'The PDF becomes'), kind)),
    [{ text: 'Cancel', result: false }, { text: 'Create', primary: true, result: true }]);
    if (!ok) return;
    if (pdf.files.length) {
      const file = pdf.files[0];
      const title = name.value.trim() || file.name.replace(/\.pdf$/i, '');
      App.toast('Uploading ' + file.name + '…');
      const q = '?name=' + encodeURIComponent(title) + '&puzzle=' + (kind.value === 'puzzle' ? '1' : '0') + '&folder=' + encodeURIComponent(this.folder || '');
      const r = await fetch('/api/notes/pdf' + q, { method: 'PUT', body: file }).catch(() => null);
      if (r && r.status === 401) { location.reload(); return; }
      if (!r || !r.ok) {
        let why = 'The upload failed';
        if (r) { try { why = (await r.json()).error || why; } catch (e) { /* not JSON */ } }
        App.toast(why, true);
        return;
      }
      App.toast('Made ' + title);
      App.route();
      return;
    }
    if (!name.value.trim()) return;
    await App.api('/api/notes/notebook', { json: { op: 'new', name: name.value.trim(), paper: paper.value, folder: this.folder } }).catch(App.fail);
    App.route();
  },

  // The notebook's PDF: made on the Kindle in the background (a big book
  // takes a while), asked about every 1.5 s, then downloaded.
  async downloadPdf(id, btn) {
    const url = '/api/notes/pdf?id=' + encodeURIComponent(id);
    const label = btn.textContent;
    btn.disabled = true;
    btn.textContent = 'Making the PDF\u2026';
    try {
      for (let i = 0; i < 600; i++) {
        const r = await App.api(url + '&check=1');
        if (r.error) throw new Error(r.error);
        if (r.ready) { location.href = url; return; }
        await new Promise((ok) => setTimeout(ok, 1500));
      }
      throw new Error('The PDF is taking too long');
    } catch (e) {
      App.fail(e);
    } finally {
      btn.disabled = false;
      btn.textContent = label;
    }
  },

  order(s) {
    let ids = s.notebooks.map((n) => n.id);
    return h('div', { class: 'card' }, h('h2', {}, 'Notebook order'),
      h('p', { class: 'muted small' }, 'Reordering here switches the Kindle’s notebook list to “My order”.'),
      App.reorder(s.notebooks.map((n) => ({ key: n.id, label: n.name })), (keys) => {
        ids = keys;
        App.api('/api/notes/notebook', { json: { op: 'order', ids } }).then(() => { s.settings.sort = 'custom'; }, App.fail);
      }));
  },

  // The toolbar as it looks on the Kindle (a column of Notes' own icons, top
  // to bottom): drag a button to reorder it, onto a group to put it in, or
  // back onto the toolbar to take it out; click one for the same by tapping
  // (phones can't drag). The fixed buttons are shown greyed.
  toolbarCard(s, st, set) {
    const tools = s.tools || {};
    const shown = s.actionsShown || null;
    const actions = App.arr(s.actions).filter((a) => !shown || shown[a.key]);
    const icons = s.icons || {};
    const groupOrder = App.arr(s.groupOrder).length ? App.arr(s.groupOrder) : Object.keys(s.groups || {});
    const groupName = (g) => (s.groupNames || {})[g] || g;
    const actionLabel = (k) => (actions.find((a) => a.key === k) || {}).label;
    const label = (k) => k.startsWith('g:') ? groupName(k.slice(2)) + ' (group)' : (tools[k] || actionLabel(k) || k);
    const isAction = (k) => !!actionLabel(k);
    // The model: the toolbar's order, the groups' members, what's hidden.
    let order = App.arr(s.toolbar).slice();
    const groups = {};
    const saved = s.groupsSaved || s.groups || {};
    for (const g of groupOrder) groups[g] = App.arr(saved[g]).filter((k) => tools[k] || isAction(k));
    const hidden = new Set(App.arr(st.hidden));
    const groupOf = (k) => groupOrder.find((g) => groups[g].includes(k));
    const save = () => {
      // Tools and groups not on the toolbar (and not in a group) are hidden;
      // actions on it are its buttons.
      const onBar = new Set(order);
      const hide = [];
      for (const k of Object.keys(tools)) if (!onBar.has(k) && !groupOf(k)) hide.push(k);
      for (const g of groupOrder) if (!onBar.has('g:' + g)) hide.push('g:' + g);
      const buttons = actions.map((a) => a.key).filter((k) => onBar.has(k));
      return App.api('/api/notes/settings', { json: { order, buttons, hidden: hide, groups } })
        .then(() => { st.order = order; st.orderSet = true; st.buttons = buttons; st.hidden = hide; st.groups = groups; draw(); },
          (e) => { App.fail(e); });
    };
    const takeOut = (k) => {
      order = order.filter((x) => x !== k);
      for (const g of groupOrder) groups[g] = groups[g].filter((x) => x !== k);
    };
    // The icons, fetched once (Notes' own SVGs).
    const svgs = {};
    const icon = (name) => {
      const span = h('span', { class: 'tile-icon' });
      if (svgs[name]) span.innerHTML = svgs[name];
      return span;
    };
    const fixedTop = ['house', 'book-open'];
    const fixedTail = ['chevron-up', 'chevron-down', 'layout-grid', 'file-plus', 'ellipsis', 'panel-left-close'];
    const fixedBottom = ['refresh-cw', 'bell', 'settings'];
    let dragging = null;
    const strip = h('div', { class: 'ntb' });
    const groupsBox = h('div', { class: 'stack' });
    const adder = h('div', { class: 'row' });
    const fixed = (name, title) => h('div', { class: 'ntb-btn fixed', title }, icon(name));
    const button = (k, where) => {
      const b = h('div', { class: 'ntb-btn', draggable: 'true', title: label(k) }, icon(icons[k] || 'circle'),
        h('span', { class: 'ntb-label' }, label(k)));
      b.addEventListener('dragstart', (ev) => { dragging = k; ev.dataTransfer.effectAllowed = 'move'; b.classList.add('dragging'); });
      b.addEventListener('dragend', () => b.classList.remove('dragging'));
      if (where === 'bar') {
        b.addEventListener('dragover', (ev) => { if (dragging && dragging !== k) { ev.preventDefault(); b.classList.add('drop-before'); } });
        b.addEventListener('dragleave', () => b.classList.remove('drop-before'));
        b.addEventListener('drop', (ev) => {
          ev.preventDefault(); ev.stopPropagation(); b.classList.remove('drop-before');
          const m = dragging;
          if (!m || m === k) return;
          if (m.startsWith('g:') === false || !groupOf(m)) {
            takeOut(m);
            order.splice(order.indexOf(k), 0, m);
            save();
          }
        });
      }
      b.addEventListener('click', () => menu(k, where));
      return b;
    };
    const menu = async (k, where) => {
      const g = where === 'bar' ? null : where;
      const into = !k.startsWith('g:') ? App.select([['', g ? 'Move to another group…' : 'Put in a group…'],
        ...groupOrder.filter((x) => x !== g).map((x) => [x, groupName(x)])], '', () => {}) : null;
      const actionsList = [{ text: 'Cancel', result: null }];
      if (!g) actionsList.push({ text: 'Up', result: 'up' }, { text: 'Down', result: 'down' });
      if (g) actionsList.push({ text: 'Out of the group', result: 'out' });
      if (into) actionsList.push({ text: 'Move', result: 'into' });
      actionsList.push({ text: 'Remove', danger: true, result: 'remove' });
      const body = h('div', { class: 'stack' },
        h('p', { class: 'muted small' }, k.startsWith('g:') ? 'A group: one toolbar button that opens a short list of its own.'
          : g ? 'In the ' + groupName(g) + ' group.' : 'On the toolbar.'),
        into);
      const r = await App.modal(label(k), body, actionsList);
      if (r === 'up' || r === 'down') {
        const i = order.indexOf(k), j = i + (r === 'up' ? -1 : 1);
        if (j < 0 || j >= order.length) return;
        order.splice(i, 1); order.splice(j, 0, k); save();
      } else if (r === 'out') { takeOut(k); order.push(k); save(); }
      else if (r === 'into' && into.value) { takeOut(k); groups[into.value].push(k); save(); }
      else if (r === 'remove') { takeOut(k); save(); }
    };
    const draw = () => {
      strip.replaceChildren(
        ...fixedTop.map((n) => fixed(n, n === 'house' ? 'The launcher (always first)' : 'Back to the notebooks')),
        ...order.filter((k) => !k.startsWith('g:') || groups[k.slice(2)]).map((k) => button(k, 'bar')),
        h('div', { class: 'ntb-note muted small' }, 'Your favorite pens, the time, the pages'),
        ...fixedTail.map((n) => fixed(n, 'Always there')),
        h('div', { class: 'ntb-sep' }),
        ...fixedBottom.map((n) => fixed(n, 'Always at the bottom')));
      groupsBox.replaceChildren(...groupOrder.map((g) => {
        const box = h('div', { class: 'qgroup-items' }, groups[g].length ? groups[g].map((k) => button(k, g))
          : h('span', { class: 'muted small' }, 'Drop buttons here'));
        box.addEventListener('dragover', (ev) => { if (dragging && !dragging.startsWith('g:')) { ev.preventDefault(); box.classList.add('drop-on'); } });
        box.addEventListener('dragleave', () => box.classList.remove('drop-on'));
        box.addEventListener('drop', (ev) => {
          ev.preventDefault(); ev.stopPropagation(); box.classList.remove('drop-on');
          const m = dragging;
          if (!m || m.startsWith('g:') || groups[g].includes(m)) return;
          takeOut(m); groups[g].push(m); save();
        });
        return h('div', { class: 'qgroup' }, h('div', { class: 'small', style: 'font-weight:600' }, icon(icons['g:' + g] || 'folder'), ' ', groupName(g)), box);
      }));
      // Adding: tools and groups taken off, actions not on it (nor in a group).
      const addable = [];
      for (const k of Object.keys(tools)) if (!order.includes(k) && !groupOf(k)) addable.push(k);
      for (const g of groupOrder) if (!order.includes('g:' + g)) addable.push('g:' + g);
      for (const a of actions) if (!order.includes(a.key) && !groupOf(a.key)) addable.push(a.key);
      const pick = h('select', {}, h('option', { value: '' }, addable.length ? 'Add a button…' : 'Everything is on it'),
        addable.map((k) => h('option', { value: k }, label(k))));
      adder.replaceChildren(pick, h('button', { class: 'btn', onclick: () => {
        if (!pick.value) return;
        order.push(pick.value);
        save();
      } }, 'Add'));
    };
    strip.addEventListener('dragover', (ev) => { if (dragging) ev.preventDefault(); });
    strip.addEventListener('drop', (ev) => {
      ev.preventDefault();
      const m = dragging;
      if (!m) return;
      takeOut(m); order.push(m); save();
    });
    // Icons: every one the editor can show, in one request.
    const names = new Set([...fixedTop, ...fixedTail, ...fixedBottom, ...Object.values(icons)]);
    App.api('/api/notes/icons?names=' + encodeURIComponent([...names].join(','))).then((r) => {
      Object.assign(svgs, (r && r.icons) || {});
      draw();
    }, () => draw());
    draw();
    return h('div', { class: 'card stack' }, h('h2', {}, 'Toolbar buttons'),
      h('p', { class: 'muted small' }, 'As on the Kindle, top to bottom. Drag a button to move it, onto a group to put it in, or back onto the toolbar to take it out; click one to move or remove it. Greyed buttons are always there.'),
      h('div', { class: 'ntb-row' }, strip, h('div', { class: 'stack', style: 'flex:1;min-width:220px' }, h('div', { class: 'small', style: 'font-weight:600' }, 'Groups'), groupsBox)),
      adder);
  },

  settings(s) {
    const st = s.settings;
    const set = (key) => (value) => App.api('/api/notes/settings', { json: { [key]: value } })
      .then(() => { st[key] = value; return true; }, (e) => { App.fail(e); return false; });
    const on = (key, dflt) => (st[key] === undefined || st[key] === null ? dflt : st[key]);
    const favCount = h('span', {}, String(st.favorites || 0));
    return h('div', {},
      h('div', { class: 'card' }, h('h2', {}, 'Toolbar'),
        App.setting('Side', App.select([['left', 'Left'], ['right', 'Right']], st.side, set('side'))),
        App.setting('Start with toolbar hidden', App.toggle(st.folded, set('folded'))),
        App.setting('Quick note buttons by the handle', App.toggle(st.quick_buttons !== false, set('quick_buttons')), 'Peek, Swap, Discard and Save beside the quick note pad’s handle (the toolbar has them too).')),
      this.toolbarCard(s, st, set),
      h('div', { class: 'card' }, h('h2', {}, 'Writing'),
        App.setting('Pen side button', App.select([['eraser', 'Eraser'], ['lasso', 'Lasso'], ['hl', 'Highlighter'], ['ruler', 'Ruler (straight lines)'], ['none', 'Nothing']], st.side_button, set('side_button'))),
        App.setting('Eraser', App.select([['false', 'Partial'], ['true', 'Whole stroke']], String(!!st.whole_eraser), (v) => set('whole_eraser')(v === 'true'))),
        App.setting('Eraser: highlighter only', App.toggle(!!st.eraser_hl, set('eraser_hl')), 'The ink, text boxes and pictures stay.'),
        App.setting('Pen pressure', App.select([['soft', 'Soft'], ['normal', 'Normal'], ['firm', 'Firm']], st.pen_feel || 'normal', set('pen_feel')),
          'Soft: a light touch writes wider. Firm: press harder for a wide line.'),
        App.setting('Two pages when turned on its side', App.toggle(on('spread_turn', true), set('spread_turn')),
          'Portrait notebooks show two pages side by side with the Kindle on its side.'),
        App.setting('Stroke smoothing', App.select([['0', 'Off'], ['1', 'Light'], ['2', 'Strong']], st.smooth || 0, (v) => set('smooth')(Number(v)))),
        App.setting('When closing', App.select([['auto', 'Save automatically'], ['ask', 'Ask']], st.close_action || 'auto', set('close_action')),
          'Ask: Save, Rename or Don\u2019t save when you close a notebook you changed.'),
        App.setting('Favorite pens', h('div', { class: 'row' }, favCount, h('button', { class: 'btn small', onclick: () => {
          set('favorites')([]).then((ok) => { if (ok) { st.favorites = 0; favCount.textContent = '0'; } });
        } }, 'Clear')))),
      h('div', { class: 'card' }, h('h2', {}, 'Shapes'),
        App.setting('Shape recognition (hold the pen)', App.toggle(st.snap_hold, set('snap_hold'))),
        App.setting('Snap lines to 0°, 45°, 90°', App.toggle(st.level_lines, set('level_lines'))),
        App.setting('Snap line ends to ink', App.toggle(st.join_ends, set('join_ends')))),
      h('div', { class: 'card' }, h('h2', {}, 'New notebooks'),
        App.setting('Template', App.select(Object.entries(s.papers), st.paper, set('paper'))),
        App.setting('Pen pressure', App.toggle(st.pressure, set('pressure'))),
        App.setting('Add the date to names', App.select([['off', 'Off'], ['before', 'Before the name'], ['after', 'After the name']], st.name_date || 'off', set('name_date')),
          'A name you type gets the date too: “Oct 21 – Meeting” or “Meeting – Oct 21”. Left blank, the name is the date and time.'),
        App.setting('Suggest names (AI)', App.toggle(!!st.suggest_names, set('suggest_names')),
          'Notebooks still named by date get a name from the AI when you close them.')),
      h('div', { class: 'card' }, h('h2', {}, 'Notebook list'),
        App.setting('Default sort', App.select([['last', 'Last used'], ['name', 'Name'], ['created', 'Date created'], ['modified', 'Date modified'], ['custom', 'My order']], st.sort_default || 'last', set('sort_default')),
          'The sort Notes starts with. Last used: whatever you picked last with Sort at the top of the list.'),
        App.setting('Recent notebooks', App.select([['folder', 'As a folder'], ['top', 'At the top'], ['off', 'Off']], st.recent_mode || (st.show_recent === false ? 'off' : 'folder'), set('recent_mode')),
          'The notebooks opened last: a Recent folder first in the list, at the top of the list, or not shown.'),
        App.setting('Sort by', App.select([['name', 'Name'], ['created', 'Date created'], ['modified', 'Date modified'], ['custom', 'My order']], st.sort, set('sort')),
          'The Order tab puts them in your own order.')),
      h('div', { class: 'card' }, h('h2', {}, 'Screen'),
        App.setting('Template lines', App.select([['light', 'Light'], ['medium', 'Medium'], ['dark', 'Dark']], st.paper_lines || 'medium', set('paper_lines'))),
        App.setting('Full refresh', App.select([['6', 'Every 6 pauses'], ['3', 'Every 3 pauses'], ['1', 'Every pause'], ['0', 'Never']], on('deghost', 6), (v) => set('deghost')(Number(v)))),
        App.setting('KOReader gestures', App.toggle(on('ko_gestures', true), set('ko_gestures')), 'Two fingers, edge swipes and multiswipes work in Notes.')));
  },

  accounts(s) {
    const st = s.settings;
    const set = (key) => (value) => App.api('/api/notes/settings', { json: { [key]: value } })
      .then(() => { st[key] = value; return true; }, (e) => { App.fail(e); return false; });
    const box = h('div');
    if (s.onenote && s.onenote.shared) {
      // The one Microsoft account (Settings > Microsoft on the Kindle, as To Do's tab), then OneNote's own.
      box.append(App.microsoftCard(), h('div', { class: 'card stack' },
        h('h2', {}, 'OneNote'),
        s.onenote.needsAllow ? h('p', { class: 'small' }, 'The Microsoft account here was signed in for To Do only: sign in again above, and one sign-in covers To Do and OneNote.') : null,
        s.onenote.signedIn && App.connectionTest ? App.connectionTest('notes') : null,
        App.setting('Send automatically', App.toggle(st.onenote_auto, set('onenote_auto')), 'When Wi-Fi is on.'),
        App.setting('Notebooks sent', App.select([['false', 'All'], ['true', 'Ones I pick']], String(!!st.onenote_picked_only), (v) => set('onenote_picked_only')(v === 'true')),
          'Pick them on the Kindle: hold a notebook in the list.'),
        App.setting('Typed text of each page', App.toggle(st.onenote_text, set('onenote_text')), 'Read by the AI and added under the page.')));
    } else if (s.onenote) {
      const client = h('input', { type: 'text', value: s.onenote.ownClientId, placeholder: s.onenote.clientId ? 'Using To Do’s: ' + s.onenote.clientId : '00000000-0000-0000-0000-000000000000', style: 'flex:1;min-width:260px' });
      const codeBox = h('div');
      box.append(h('div', { class: 'card stack' },
        h('h2', {}, 'OneNote'),
        h('div', { class: 'row' },
          s.onenote.signedIn ? h('span', { class: 'pill ok' }, 'Signed in') : h('span', { class: 'pill' }, 'Not signed in'),
          h('button', { class: 'btn primary', onclick: signIn }, s.onenote.signedIn ? 'Sign in again' : 'Sign in'),
          s.onenote.signedIn ? h('button', { class: 'btn danger', onclick: signOut }, 'Sign out') : null),
        codeBox,
        // Microsoft's sign-in and OneNote tried, from the Kindle.
        s.onenote.signedIn && App.connectionTest ? App.connectionTest('notes') : null,
        App.setting('Send automatically', App.toggle(st.onenote_auto, set('onenote_auto')), 'When Wi-Fi is on.'),
        App.setting('Notebooks sent', App.select([['false', 'All'], ['true', 'Ones I pick']], String(!!st.onenote_picked_only), (v) => set('onenote_picked_only')(v === 'true')),
          'Pick them on the Kindle: hold a notebook in the list.'),
        App.setting('Typed text of each page', App.toggle(st.onenote_text, set('onenote_text')), 'Read by the AI and added under the page.'),
        h('label', { class: 'field' }, h('span', {}, 'App (client) ID (leave empty to use To Do’s)'),
          h('div', { class: 'row' }, client, h('button', { class: 'btn', onclick: saveClient }, 'Save')))));
      async function saveClient() {
        await App.api('/api/notes/onenote/clientid', { json: { id: client.value } }).then(() => App.toast('Saved'), App.fail);
      }
      async function signIn() {
        await saveClient();
        const r = await App.api('/api/notes/onenote/signin', { json: {} }).catch(App.fail);
        if (r) App.pages.notes.showCode(codeBox, r, '/api/notes/onenote/signin', 'Signed in to OneNote');
      }
      async function signOut() {
        if (!await App.confirm('Sign out', 'Sign out of OneNote? Pages already sent stay in OneNote.', 'Sign out', true)) return;
        await App.api('/api/notes/onenote/signout', { json: {} }).then(App.route, App.fail);
      }
    }
    // The AI services are the launcher's (the AI tab), shared with Crosswords and SSH.
    box.append(h('div', { class: 'card stack' }, h('h2', {}, 'AI'),
      h('p', { class: 'muted small' }, s.aiSetUp ? 'Reading handwriting, Ask, Make PDF and drawing use the AI services set up in the AI tab.'
        : 'No AI service is set up yet: set one up in the AI tab to read handwriting, Ask, Make PDF and draw.'),
      h('div', {}, h('a', { class: 'btn', href: '#ai' }, 'AI settings')),
      s.aiSetUp ? App.setting('Dates written beside tasks', App.toggle(st.todo_dates !== false, set('todo_dates')),
        'When adding to To Do: “Fri”, “10/30”, “9am”, “remind Mon 7pm”.') : null));
    if (!box.children.length) box.append(h('div', { class: 'empty' }, 'This version of Notes has no OneNote or AI settings.'));
    return box;
  },

  showCode(box, st, statusUrl, doneText) {
    box.innerHTML = '';
    box.append(h('div', { class: 'card', style: 'background:var(--soft)' },
      h('div', {}, 'Open ', h('a', { href: st.url, target: '_blank' }, st.url), ' and enter'),
      h('div', { class: 'code-box', style: 'margin:10px 0' }, st.code),
      h('div', { class: 'small muted' }, 'This page updates automatically when you’re done.')));
    const poll = async () => {
      const now = await App.api(statusUrl).catch(() => null);
      if (!now || now.status === 'waiting') return setTimeout(poll, 3000);
      if (now.status === 'ok') { App.toast(doneText); App.route(); return; }
      box.innerHTML = '';
      App.toast(now.status === 'expired' ? 'The code expired. Sign in again.' : 'Could not sign in: ' + (now.message || ''), true);
    };
    setTimeout(poll, 3000);
  },
};
