// Files: browse the reader's storage as a list or as covers (titles, authors, progress); sort, group by
// author, series or status, and filter, or search every folder; recent files; quick links to KOReader's
// Home folder, favorite folders and files; upload here or straight to the Home folder (drag and drop too),
// or get a file from a link; download (several as one zip), folders, rename, move (drag onto a folder or
// Move to…), copy, delete with Undo; collections; a book's details and highlights; open a book on the
// Kindle and mark it reading, on hold or finished; what uses the space. The same as the Kindle's Library.
App.pages.files = {
  async render(main, params) {
    const pref = (k, d) => { try { return localStorage.getItem('files.' + k) || d; } catch (e) { return d; } };
    const save = (k, v) => { try { localStorage.setItem('files.' + k, v); } catch (e) { /* not kept */ } };
    // Opens where it was left (the last folder looked at).
    const path = params.path || pref('last', '/documents');
    const find = params.find || '';
    let data;
    try {
      data = await App.api('/api/files?path=' + encodeURIComponent(path));
    } catch (e) {
      if (path !== '/') { location.hash = '#files?path=/'; return; }
      throw e;
    }
    data.entries = App.arr(data.entries);
    save('last', data.path);
    const bookData = await App.api('/api/books?path=' + encodeURIComponent(data.path)).catch(() => ({}));
    const books = App.obj(bookData.books);
    let view = pref('view', 'list');
    let sort = pref('sort', 'name');
    let group = pref('group', 'none');
    let filter = '';
    const selected = new Set();
    const join = (name) => (data.path === '/' ? '' : data.path) + '/' + name;
    const reload = () => App.route();
    const bookOf = (e) => (!e.dir && books[e.name]) || null;
    const titleOf = (e) => (bookOf(e) && bookOf(e).title) || e.name;

    const crumbs = h('div', { class: 'row small' });
    const parts = data.path.split('/').filter(Boolean);
    crumbs.append(dropOn(h('a', { href: '#files?path=/' }, data.root), '/'));
    parts.forEach((p, i) => {
      const to = '/' + parts.slice(0, i + 1).join('/');
      crumbs.append(' / ', dropOn(h('a', { href: '#files?path=' + encodeURIComponent(to) }, p), to));
    });

    // KOReader's Home folder, favorite folders (its folder shortcuts) and
    // favorite files (its Favorites collection), a tap away.
    const places = App.obj(data.places);
    const home = places.home && places.home !== '/' ? places.home : null;
    const links = [...(home ? [{ name: 'Home folder', path: home }] : []), ...App.arr(places.shortcuts)];
    const favFiles = App.arr(places.files);
    const fileLink = (f) => {
      const dir = f.path.replace(/\/[^/]+$/, '') || '/';
      return h('a', { class: 'btn small', href: '#files?path=' + encodeURIComponent(dir) + '&find=' + encodeURIComponent(f.path.split('/').pop()), title: f.path }, '★ ' + f.name);
    };
    const placeRow = links.length || favFiles.length ? h('div', { class: 'row', style: 'margin-top:10px' },
      links.map((p) => h('a', { class: 'btn small' + (p.path === data.path ? ' primary' : ''), href: '#files?path=' + encodeURIComponent(p.path), title: p.path }, p.name)),
      favFiles.map(fileLink)) : null;

    const fileInput = h('input', { type: 'file', multiple: true, style: 'display:none' });
    let uploadTo = data.path;
    fileInput.addEventListener('change', () => { upload([...fileInput.files], uploadTo); fileInput.value = ''; });
    const pick = (to) => { uploadTo = to; fileInput.click(); };
    const elsewhere = home && home !== data.path;
    // What to do with the ticked files.
    const withSel = h('select', { disabled: true }, [['', 'With selected…'], ['zip', 'Download (one zip)'], ['move', 'Move to…'],
      ['copy', 'Copy to…'], ['reading', 'Mark as reading'], ['abandoned', 'Mark as on hold'], ['complete', 'Mark as finished'],
      ['collect', 'Add to a collection…'], ['rename', 'Rename from book details'], ['delete', 'Delete']].map(([v, t]) => h('option', { value: v }, t)));
    withSel.addEventListener('change', () => { const v = withSel.value; withSel.value = ''; if (v) selectedAction(v); });
    const progress = h('div', { class: 'stack' });

    const drop = h('div', { class: 'drop' }, 'Drop files here to upload them to this folder');
    drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('over'); });
    drop.addEventListener('dragleave', () => drop.classList.remove('over'));
    drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('over'); upload([...e.dataTransfer.files], data.path); });

    const search = h('input', { type: 'search', placeholder: 'Filter this folder', style: 'min-width:200px', value: find });
    search.addEventListener('input', () => { filter = search.value.trim().toLowerCase(); if (mode !== 'folder') { mode = 'folder'; } draw(); });
    // Enter (or Everywhere) searches every folder: names, titles and authors.
    search.addEventListener('keydown', (e) => { if (e.key === 'Enter' && search.value.trim()) everywhere(); });
    let mode = 'folder';
    const everywhere = () => {
      if (!search.value.trim()) { search.focus(); return App.toast('Type what to look for first'); }
      mode = 'search';
      draw();
    };
    const tools = h('div', { class: 'row' },
      h('button', { class: 'btn small', title: 'Search every folder (Enter in the box)', onclick: everywhere }, 'Everywhere'),
      h('button', { class: 'btn small', onclick: () => { mode = 'recent'; draw(); } }, 'Recent'),
      h('button', { class: 'btn small', onclick: () => App.library.collections() }, 'Collections'),
      h('button', { class: 'btn small', onclick: () => App.library.storage() }, 'Storage'));
    filter = find.toLowerCase();
    const sortBox = App.select([['name', 'Sort by name'], ['date', 'Sort by date'], ['size', 'Sort by size']], sort, (v) => { sort = v; save('sort', v); draw(); });
    const groupBox = App.select([['none', 'No groups'], ['author', 'Group by author'], ['series', 'Group by series'], ['status', 'Group by status']],
      group, (v) => { group = v; save('group', v); draw(); });
    const viewTabs = h('div');
    const body = h('div');

    // Titles and covers the Kindle is still reading: looked for again a few times.
    if (bookData.pending) {
      let tries = 0;
      const again = async () => {
        if (!body.isConnected || ++tries > 4) return;
        const more = await App.api('/api/books?path=' + encodeURIComponent(data.path)).catch(() => null);
        if (!more) return;
        Object.assign(books, App.obj(more.books));
        draw();
        if (more.pending) setTimeout(again, 4000);
      };
      setTimeout(again, 4000);
    }
    main.append(
      h('div', { class: 'spread' }, h('div', {}, h('h1', {}, 'Files'), crumbs, placeRow),
        h('div', { class: 'row' },
          elsewhere ? h('button', { class: 'btn primary', title: 'Upload to ' + home, onclick: () => pick(home) }, 'Upload to Home folder') : null,
          h('button', { class: 'btn' + (elsewhere ? '' : ' primary'), onclick: () => pick(data.path) }, elsewhere ? 'Upload here' : 'Upload'),
          h('button', { class: 'btn', title: 'Get a file from a web link into this folder', onclick: () => App.library.fromLink(data.path, progress, reload) }, 'From a link'),
          h('button', { class: 'btn', onclick: newFolder }, 'New folder'), withSel)),
      h('div', { class: 'card', style: 'margin-top:16px' }, drop, progress, fileInput,
        h('div', { class: 'spread', style: 'margin:10px 0' }, viewTabs, h('div', { class: 'row' }, search, sortBox, groupBox, tools)), body),
      ...(App.servers ? [App.servers.card()] : []));
    draw();

    function entries() {
      const list = data.entries.filter((e) => !filter || e.name.toLowerCase().includes(filter) ||
        (bookOf(e) && ((bookOf(e).title || '') + ' ' + (bookOf(e).authors || '')).toLowerCase().includes(filter)));
      const by = {
        name: (a, b) => titleOf(a).localeCompare(titleOf(b), undefined, { numeric: true, sensitivity: 'base' }),
        date: (a, b) => b.mtime - a.mtime,
        size: (a, b) => b.size - a.size,
      }[sort];
      return list.sort((a, b) => (a.dir !== b.dir ? (a.dir ? -1 : 1) : by(a, b)));
    }

    // The folder's entries in groups, as the Kindle's Library groups books:
    // [{ label, list }] (one group without a label when not grouped).
    function groups(list) {
      if (group === 'none') return [{ label: null, list }];
      const dirs = list.filter((e) => e.dir);
      const others = list.filter((e) => !e.dir && !bookOf(e));
      const byKey = new Map();
      const order = { reading: 1, abandoned: 2, new: 3, complete: 4 };
      for (const e of list.filter((x) => !x.dir && bookOf(x))) {
        const b = bookOf(e);
        let key; let label; let rank;
        if (group === 'author') {
          const a = (b.authors || '').split('\n')[0].trim();
          label = a || 'No author';
          rank = a ? a.split(/\s+/).pop().toLowerCase() + ' ' + a.toLowerCase() : '\uffff';
          key = label;
        } else if (group === 'series') {
          label = b.series || 'Not in a series';
          rank = b.series ? b.series.toLowerCase() : '\uffff';
          key = label;
        } else {
          key = b.status || 'reading';
          label = App.library.STATUS[key] || key;
          rank = String(order[key] || 9);
        }
        if (!byKey.has(key)) byKey.set(key, { label, rank, list: [] });
        byKey.get(key).list.push(e);
      }
      const out = [...byKey.values()].sort((x, y) => (x.rank < y.rank ? -1 : x.rank > y.rank ? 1 : 0));
      if (group === 'series') for (const g of out) g.list.sort((x, y) => (bookOf(x).seriesIndex || 0) - (bookOf(y).seriesIndex || 0));
      return [...(dirs.length ? [{ label: 'Folders', list: dirs }] : []), ...out, ...(others.length ? [{ label: 'Other files', list: others }] : [])];
    }

    function draw() {
      viewTabs.replaceChildren(App.tabs([['list', 'List'], ['books', 'Covers']], view, (v) => { view = v; save('view', v); mode = 'folder'; draw(); }));
      if (mode !== 'folder') {
        const into = h('div');
        body.replaceChildren(h('p', {}, h('a', { href: '#', onclick: (e) => { e.preventDefault(); mode = 'folder'; draw(); } }, '← Back to this folder')), into);
        if (mode === 'search') App.library.search(search.value.trim(), into); else App.library.recent(into);
        return;
      }
      const list = entries();
      if (!data.entries.length) { body.replaceChildren(h('div', { class: 'empty' }, 'This folder is empty.')); return; }
      if (!list.length) { body.replaceChildren(h('div', { class: 'empty' }, 'Nothing here matches “' + search.value + '”.')); return; }
      body.replaceChildren(view === 'books' ? grid(list) : table(list));
    }

    function checkbox(p) {
      const box = h('input', { type: 'checkbox', checked: selected.has(p) });
      box.addEventListener('change', () => {
        if (box.checked) selected.add(p); else selected.delete(p);
        withSel.disabled = selected.size === 0;
      });
      return box;
    }

    function table(list) {
      const all = h('input', { type: 'checkbox' });
      const t = h('table', { class: 'list' },
        h('thead', {}, h('tr', {}, h('th', { style: 'width:28px' }, all), h('th', {}, 'Name'), h('th', {}, 'Size'), h('th', {}, 'Changed'), h('th', {}))),
        h('tbody', {}, groups(list).flatMap((g) => [
          g.label ? h('tr', { class: 'group-row' }, h('th', { colspan: 5, style: 'text-align:left;padding-top:14px' }, g.label + ' (' + g.list.length + ')')) : null,
          ...g.list.map(row)])));
      all.addEventListener('change', () => {
        for (const box of t.querySelectorAll('tbody input[type=checkbox]')) { box.checked = all.checked; box.dispatchEvent(new Event('change')); }
      });
      if (data.path !== '/') {
        const upTo = data.path.replace(/\/[^/]+$/, '') || '/';
        t.tBodies[0].prepend(dropOn(h('tr', {}, h('td'), h('td', { colspan: 4 }, h('div', { class: 'name-cell' }, '📁',
          h('a', { href: '#files?path=' + encodeURIComponent(upTo) }, '..')))), upTo));
      }
      return t;
    }

    function link(e, p, text) {
      const isImage = /\.(png|jpe?g|gif|webp|svg)$/i.test(e.name);
      return e.dir
        ? h('a', { href: '#files?path=' + encodeURIComponent(p) }, text)
        : h('a', { href: '/api/files/download?path=' + encodeURIComponent(p) + (isImage || /\.(txt|pdf|md|lua|json|csv|log)$/i.test(e.name) ? '&inline=1' : ''), target: '_blank' }, text);
    }

    function progressLine(b) {
      if (!b) return null;
      return h('span', { class: 'muted small' }, App.library.stateText(b));
    }

    function row(e) {
      const p = join(e.name);
      const b = bookOf(e);
      const isImage = /\.(png|jpe?g|gif|webp|svg)$/i.test(e.name);
      return draggable(h('tr', {},
        h('td', {}, checkbox(p)),
        h('td', {}, h('div', { class: 'name-cell' }, e.dir ? '📁' : (isImage ? '🖼️' : (b ? '📖' : '📄')),
          h('div', {}, link(e, p, b && b.title ? b.title : e.name),
            b && (b.authors || b.title) ? h('div', { class: 'muted small' }, [b.authors, b.title ? e.name : null].filter(Boolean).join(' · ')) : null))),
        h('td', { class: 'muted small' }, e.dir ? '' : App.size(e.size)),
        h('td', { class: 'muted small' }, b ? progressLine(b) : App.when(e.mtime)),
        h('td', { style: 'text-align:right;white-space:nowrap' }, actions(e, p, b))), e, p);
    }

    // Dragging files (all the ticked ones, if this is one of them) onto a
    // folder, a folder in the path at the top, or ".." moves them there.
    function draggable(el, e, p) {
      el.draggable = true;
      el.addEventListener('dragstart', (ev) => {
        const paths = selected.has(p) ? [...selected] : [p];
        ev.dataTransfer.setData('application/x-kindle-paths', JSON.stringify(paths));
        ev.dataTransfer.effectAllowed = 'move';
      });
      return e.dir ? dropOn(el, p) : el;
    }

    function dropOn(el, to) {
      const ours = (ev) => [...ev.dataTransfer.types].includes('application/x-kindle-paths');
      el.addEventListener('dragover', (ev) => { if (ours(ev)) { ev.preventDefault(); el.classList.add('drop-target'); } });
      el.addEventListener('dragleave', () => el.classList.remove('drop-target'));
      el.addEventListener('drop', async (ev) => {
        if (!ours(ev)) return;
        ev.preventDefault();
        ev.stopPropagation();
        el.classList.remove('drop-target');
        const paths = JSON.parse(ev.dataTransfer.getData('application/x-kindle-paths') || '[]').filter((x) => x !== to && !to.startsWith(x + '/'));
        if (!paths.length) return;
        const r = await App.api('/api/files/move', { json: { paths, to } }).catch(App.fail);
        if (r && !r.ok) App.toast('Some could not be moved: ' + r.failed.join(', '), true);
        else if (r) App.toast('Moved ' + (paths.length === 1 ? '“' + paths[0].split('/').pop() + '”' : paths.length + ' items') + ' to ' + to);
        reload();
      });
      return el;
    }

    // The star: a favorite folder (a folder shortcut on the Kindle) or file (KOReader's Favorites).
    function star(e, p) {
      return h('button', { class: 'icon-btn' + (e.fav ? ' on' : ''), title: e.fav ? 'Remove from favorites' : 'Add to favorites',
        onclick: async () => {
          const on = !e.fav;
          await App.api('/api/files/favorite', { json: { path: p, on } }).then(() => {
            App.toast(on ? (e.dir ? 'Added to favorite folders' : 'Added to Favorites') : 'Removed from favorites');
            reload();
          }, App.fail);
        } }, e.fav ? '★' : '☆');
    }

    function actions(e, p, b) {
      return [
        star(e, p),
        b ? h('button', { class: 'icon-btn', title: 'Details, highlights and collections', onclick: () => App.library.details(p, { open: openOnKindle, reload }) }, 'ⓘ') : null,
        b ? h('button', { class: 'icon-btn', title: 'Open on the Kindle', onclick: () => openOnKindle(p, titleOf(e)) }, '▶') : null,
        b ? h('button', { class: 'icon-btn', title: b.status === 'complete' ? 'Mark as reading' : 'Mark as finished',
          onclick: () => setStatus(p, b.status === 'complete' ? 'reading' : 'complete') }, b.status === 'complete' ? '↺' : '✓') : null,
        e.dir ? null : h('a', { class: 'icon-btn', title: 'Download', href: '/api/files/download?path=' + encodeURIComponent(p) }, '⬇'),
        h('button', { class: 'icon-btn', title: 'Rename', onclick: () => rename(p, e.name) }, '✎'),
        h('button', { class: 'icon-btn', title: 'Delete', onclick: () => remove([p]) }, '🗑'),
        h('button', { class: 'icon-btn', title: 'More', onclick: () => more(e, p, b) }, '⋯'),
      ];
    }

    // ⋯: what the Kindle's menu for a book or folder has besides the buttons.
    function more(e, p, b) {
      const back = () => document.querySelector('.modal-back')?.remove();
      const item = (text, fn, mark) => h('div', { class: 'menu-item', style: 'cursor:pointer', onclick: () => { back(); fn(); } },
        h('span', { class: 'mark' }, mark || ''), h('span', {}, text));
      const rows = [];
      if (b) {
        for (const [k, label] of [['reading', 'Reading'], ['abandoned', 'On hold'], ['complete', 'Finished']]) {
          rows.push(item(label, () => setStatus(p, k), b.status === k ? '✓' : ''));
        }
        rows[rows.length - 1].classList.add('sep');
      }
      rows.push(item('Move to…', () => App.library.pickFolder('move', [p], data.path, reload)));
      rows.push(item('Copy to…', () => App.library.pickFolder('copy', [p], data.path, reload)));
      if (!e.dir) rows.push(item('Add to a collection…', () => App.library.addTo([p], reload)));
      App.modal(e.dir ? e.name : titleOf(e), h('div', { class: 'menu-list' }, rows), [{ text: 'Close', result: null }]);
    }

    function grid(list) {
      const card = (e) => {
        const p = join(e.name);
        const b = bookOf(e);
        const pic = e.dir
          ? h('div', { class: 'book-cover blank folder' }, '📁')
          : b && b.cover ? h('img', { class: 'book-cover', loading: 'lazy', alt: '', src: '/api/books/cover?path=' + encodeURIComponent(p) })
            : h('div', { class: 'book-cover blank' }, b ? '📖' : '📄');
        const bar = b && b.status !== 'complete' && b.percent != null
          ? h('div', { class: 'progress' }, h('div', { style: 'width:' + b.percent + '%' })) : null;
        return draggable(h('div', { class: 'book-card' },
          h('div', { class: 'book-check' }, checkbox(p)),
          e.dir ? h('a', { href: '#files?path=' + encodeURIComponent(p) }, pic) : link(e, p, pic),
          h('div', { class: 'book-title' }, e.dir ? link(e, p, e.name) : titleOf(e)),
          b && b.authors ? h('div', { class: 'muted small' }, b.authors) : null,
          b ? progressLine(b) : (e.dir ? null : h('span', { class: 'muted small' }, App.size(e.size))),
          bar,
          h('div', { class: 'row', style: 'gap:2px' }, actions(e, p, b))), e, p);
      };
      const cards = groups(list).flatMap((g) => [
        g.label ? h('h3', { style: 'grid-column:1/-1;margin:10px 0 0' }, g.label + ' (' + g.list.length + ')') : null,
        ...g.list.map(card)]);
      const up = data.path !== '/' ? h('div', { class: 'book-card' },
        h('a', { href: '#files?path=' + encodeURIComponent(data.path.replace(/\/[^/]+$/, '') || '/') }, h('div', { class: 'book-cover blank folder' }, '↩')),
        h('div', { class: 'book-title' }, 'Up a folder')) : null;
      return h('div', { class: 'book-grid' }, up, cards);
    }

    async function openOnKindle(p, title) {
      await App.api('/api/books/open', { json: { path: p } }).then(() => App.toast('Opening “' + title + '” on the Kindle'), App.fail);
    }

    // Reading, On hold or Finished (as on the Kindle).
    async function setStatus(paths, status) {
      if (!Array.isArray(paths)) paths = [paths];
      await App.library.setStatus(paths, status, (out) => {
        for (const [x, book] of Object.entries(out)) books[x.split('/').pop()] = book;
        draw();
      });
    }

    async function upload(files, to) {
      for (const f of files) {
        const bar = h('div');
        const label = h('div', { class: 'small' }, f.name + ' · ' + App.size(f.size));
        const item = h('div', {}, label, h('div', { class: 'progress' }, bar));
        progress.append(item);
        try {
          await new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('PUT', '/api/files/upload?path=' + encodeURIComponent(to) + '&name=' + encodeURIComponent(f.name));
            xhr.upload.onprogress = (ev) => { if (ev.lengthComputable) bar.style.width = (ev.loaded / ev.total * 100) + '%'; };
            xhr.onload = () => (xhr.status < 300 ? resolve() : reject(new Error((JSON.parse(xhr.responseText || '{}').error) || 'Upload failed')));
            xhr.onerror = () => reject(new Error('Upload failed: the Kindle stopped responding'));
            xhr.send(f);
          });
          bar.style.width = '100%';
          label.textContent = f.name + ' · uploaded' + (to !== data.path ? ' to ' + to : '');
        } catch (e) {
          label.textContent = f.name + ' · ' + e.message;
          App.toast(f.name + ': ' + e.message, true);
        }
      }
      setTimeout(reload, 400);
    }

    async function newFolder() {
      const name = await App.prompt('New folder', '', 'Folder name');
      if (!name) return;
      await App.api('/api/files/mkdir', { json: { path: data.path, name } }).then(reload, App.fail);
    }

    async function rename(p, old) {
      const name = await App.prompt('Rename', old);
      if (!name || name === old) return;
      await App.api('/api/files/rename', { json: { path: p, name } }).then(reload, App.fail);
    }

    // Deleted at once, with Undo (as on the Kindle).
    function remove(paths) { App.library.remove(paths, reload); }

    async function selectedAction(v) {
      const paths = [...selected];
      if (v === 'zip') return zipSelected();
      if (v === 'move' || v === 'copy') return App.library.pickFolder(v, paths, data.path, reload);
      if (v === 'delete') return remove(paths);
      if (v === 'collect') return App.library.addTo(paths.filter((x) => !(data.entries.find((e) => join(e.name) === x) || {}).dir), reload);
      if (v === 'complete' || v === 'reading' || v === 'abandoned') {
        const list = paths.filter((x) => books[x.split('/').pop()]);
        if (!list.length) return App.toast('None of those are books', true);
        return setStatus(list, v);
      }
      if (v === 'rename') {
        const plans = paths.map((x) => ({ x, to: App.library.niceName(x.split('/').pop(), books[x.split('/').pop()]) }))
          .filter((r) => r.to && r.to !== r.x.split('/').pop());
        if (!plans.length) return App.toast('Nothing to rename: KOReader has no titles for those (or they already match)', true);
        if (!await App.confirm('Rename from book details', plans.map((r) => r.x.split('/').pop() + ' → ' + r.to).join('\n'), 'Rename ' + plans.length)) return;
        for (const r of plans) await App.api('/api/files/rename', { json: { path: r.x, name: r.to } }).catch(App.fail);
        reload();
      }
    }

    function zipSelected() {
      location.href = '/api/books/zip?paths=' + encodeURIComponent(JSON.stringify([...selected]));
    }

  },
};
