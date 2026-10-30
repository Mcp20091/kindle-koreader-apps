// The Files tab's library tools: search every folder, recent files, KOReader's collections, a book's
// details and highlights (with a download), what uses the space, getting a file from a link, and what
// the Kindle's Library app does to files: Move to… and Copy to… (a folder picker), Delete with Undo,
// and Reading, On hold or Finished.
App.library = (() => {
  const time = (s) => {
    const m = Math.round((s || 0) / 60);
    if (m < 60) return m + ' min';
    return Math.floor(m / 60) + ' h' + (m % 60 ? ' ' + (m % 60) + ' min' : '');
  };
  const folderOf = (p) => p.replace(/\/[^/]+$/, '') || '/';
  // A long title cut short (for headings).
  const short = (t, n = 80) => (t && t.length > n ? t.slice(0, n - 1).trimEnd() + '…' : t);
  const nameOf = (p) => p.split('/').pop();
  // A link that opens the file's folder with the file picked out (or a folder itself).
  const goTo = (p, dir, text) => h('a', {
    href: dir ? '#files?path=' + encodeURIComponent(p) : '#files?path=' + encodeURIComponent(folderOf(p)) + '&find=' + encodeURIComponent(nameOf(p)),
    onclick: () => document.querySelector('.modal-back')?.remove(),
  }, text || nameOf(p));

  // Search results or recent files, as a table.
  function results(list, empty) {
    if (!list.length) return h('div', { class: 'empty' }, empty);
    return h('table', { class: 'list' },
      h('thead', {}, h('tr', {}, h('th', {}, 'Name'), h('th', {}, 'Folder'), h('th', {}, 'Size'), h('th', {}, 'Changed'))),
      h('tbody', {}, list.map((e) => h('tr', {},
        h('td', {}, h('div', { class: 'name-cell' }, e.dir ? '📁' : '📄', h('div', {}, goTo(e.path, e.dir, e.title || e.name),
          e.title || e.authors ? h('div', { class: 'muted small' }, [e.authors, e.title ? e.name : null].filter(Boolean).join(' · ')) : null))),
        h('td', { class: 'muted small' }, goTo(folderOf(e.path), true, folderOf(e.path))),
        h('td', { class: 'muted small' }, e.dir ? '' : App.size(e.size)),
        h('td', { class: 'muted small' }, App.when(e.mtime))))));
  }

  async function search(q, into) {
    into.replaceChildren(h('div', { class: 'muted small' }, 'Searching every folder…'));
    const r = await App.api('/api/library/search?q=' + encodeURIComponent(q)).catch((e) => { into.replaceChildren(h('div', { class: 'empty' }, e.message)); return null; });
    if (!r) return;
    const list = App.arr(r.results);
    into.replaceChildren(h('p', { class: 'muted small' }, list.length + (list.length === 1 ? ' match' : ' matches') + ' for “' + q + '” in every folder (names, titles and authors)' +
      (r.partial ? '. Not every folder was looked through: there are a great many files.' : '.')),
    results(list, 'Nothing anywhere matches “' + q + '”.'));
  }

  async function recent(into) {
    into.replaceChildren(h('div', { class: 'muted small' }, 'Looking…'));
    const r = await App.api('/api/library/recent').catch(App.fail);
    if (!r) return;
    into.replaceChildren(h('p', { class: 'muted small' }, 'The newest files in every folder (KOReader’s own folders left out).'),
      results(App.arr(r.files), 'No files yet.'));
  }

  // What uses the space.
  async function storage() {
    const r = await App.api('/api/library/usage').catch(App.fail);
    if (!r) return;
    const folders = App.arr(r.folders);
    const files = App.arr(r.files);
    const top = Math.max(1, ...folders.map((f) => f.size), ...files.map((f) => f.size));
    const bar = (size) => h('div', { class: 'progress', style: 'margin-top:4px' }, h('div', { style: 'width:' + Math.max(1, Math.round(size / top * 100)) + '%' }));
    const used = r.total && r.free != null ? r.total - r.free : null;
    App.modal('What uses the space', h('div', { class: 'stack' },
      used != null ? h('div', {}, h('div', {}, App.size(r.free) + ' free of ' + App.size(r.total)),
        h('div', { class: 'progress', style: 'margin-top:6px' }, h('div', { style: 'width:' + Math.round(used / r.total * 100) + '%' }))) : null,
      r.partial ? h('p', { class: 'muted small' }, 'Not every folder was counted: there are a great many files.') : null,
      h('h3', {}, 'Biggest folders'),
      h('div', { class: 'list-rows' }, folders.map((f) => h('div', {}, h('div', { class: 'grow' }, goTo(f.path, true, f.path), bar(f.size)),
        h('div', { class: 'muted small' }, App.size(f.size))))),
      h('h3', {}, 'Biggest files'),
      h('div', { class: 'list-rows' }, files.map((f) => h('div', {}, h('div', { class: 'grow' }, goTo(f.path, false), h('div', { class: 'muted small' }, folderOf(f.path)), bar(f.size)),
        h('div', { class: 'muted small' }, App.size(f.size)))))),
    [{ text: 'Close', result: null }], true);
  }

  // KOReader's collections, each with its files.
  async function collections() {
    const r = await App.api('/api/library/collections').catch(App.fail);
    if (!r) return;
    const list = App.arr(r.collections);
    const body = h('div', { class: 'stack' },
      h('p', { class: 'muted small' }, 'KOReader’s collections, as on the Kindle. Add files with ☆ (Favorites), or tick files and use With selected > Add to a collection.'),
      list.length ? list.map((c) => {
        const files = App.arr(c.files);
        return h('details', {}, h('summary', {}, c.label + ' (' + files.length + ')'),
          files.length ? h('div', { class: 'list-rows' }, files.map((f) => h('div', {}, h('div', { class: 'grow' }, goTo(f.path, false, f.name), h('div', { class: 'muted small' }, folderOf(f.path))),
            h('button', { class: 'icon-btn', title: 'Take out of ' + c.label, onclick: async (ev) => {
              await App.api('/api/library/collections', { json: { paths: [f.path], name: c.name, on: false } }).catch(App.fail);
              ev.target.closest('div').remove();
            } }, '✕')))) : h('p', { class: 'muted small' }, 'Empty.'));
      }) : h('div', { class: 'empty' }, 'No collections yet.'));
    App.modal('Collections', body, [{ text: 'Close', result: null }], true);
  }

  // Ticks for the collections to put `paths` in (a new one can be named).
  async function addTo(paths, done) {
    const r = await App.api('/api/library/collections').catch(App.fail);
    if (!r) return;
    const list = App.arr(r.collections);
    const ticks = list.map((c) => {
      const inIt = paths.every((p) => App.arr(c.files).some((f) => f.path === p));
      return { c, box: h('input', { type: 'checkbox', checked: inIt }), was: inIt };
    });
    const fresh = h('input', { type: 'text', placeholder: 'A new collection’s name', style: 'width:100%' });
    const ok = await App.modal(paths.length === 1 ? 'Collections for “' + nameOf(paths[0]) + '”' : 'Collections for ' + paths.length + ' files',
      h('div', { class: 'stack' }, ticks.map((t) => h('label', { class: 'row' }, t.box, t.c.label)), fresh),
      [{ text: 'Cancel', result: false }, { text: 'Save', primary: true, result: true }]);
    if (!ok) return;
    for (const t of ticks) {
      if (t.box.checked !== t.was) await App.api('/api/library/collections', { json: { paths, name: t.c.name, on: t.box.checked } }).catch(App.fail);
    }
    const name = fresh.value.trim();
    if (name) await App.api('/api/library/collections', { json: { paths, name, on: true, create: true } }).catch(App.fail);
    App.toast('Collections saved');
    if (done) done();
  }

  // "Title – Author.epub" for a book, or null without a title.
  function niceName(name, book) {
    if (!book || !book.title) return null;
    const ext = (name.match(/\.[^.]+$/) || [''])[0];
    const clean = (s) => s.replace(/[\/\\:*?"<>|]+/g, ' ').replace(/\s+/g, ' ').trim();
    const authors = book.authors ? clean(book.authors.split('\n').join(', ')) : '';
    const out = clean(book.title) + (authors ? ' – ' + authors : '');
    return out ? out.slice(0, 180) + ext : null;
  }

  // KOReader's statuses, in the Kindle's words.
  const STATUS = { new: 'To read', reading: 'Reading', abandoned: 'On hold', complete: 'Finished' };
  // What a book's second line says: "42% read", "To read", "Finished", "On hold · 31%".
  function stateText(b) {
    if (!b) return '';
    if (b.status === 'complete') return 'Finished';
    if (b.status === 'new') return 'To read';
    if (b.status === 'abandoned') return 'On hold · ' + (b.percent || 0) + '%';
    return (b.percent || 0) + '% read';
  }
  // A date with its year (first read, added): "Oct 19, 2026".
  const date = (s) => (s ? new Date(s * 1000).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }) : null);
  const language = (code) => {
    if (!code) return null;
    try { return new Intl.DisplayNames(['en'], { type: 'language' }).of(code.toLowerCase().match(/^[a-z]{2,3}/)[0]) || code; } catch (e) { return code; }
  };
  const plural = (n, one, many) => (n === 1 ? one : many.replace('%1', n));

  // Reading, On hold or Finished for books (paths); `done(books)` gets { [path]: book }.
  async function setStatus(paths, status, done) {
    const out = {};
    for (const p of paths) {
      const r = await App.api('/api/books/status', { json: { path: p, status } }).catch(App.fail);
      if (r) out[p] = r.book;
    }
    const n = Object.keys(out).length;
    if (!n) return;
    const word = STATUS[status].toLowerCase();
    App.toast(n === 1 ? 'Marked as ' + word : n + ' marked as ' + word);
    if (done) done(out);
  }

  // Move to… / Copy to…: folders only, then Move here (Copy here).
  async function pickFolder(mode, paths, start, done) {
    let at = start || folderOf(paths[0]);
    const moving = new Set(paths);
    const list = h('div', { class: 'list-rows', style: 'max-height:50vh;overflow:auto' });
    const where = h('div', { class: 'muted small' });
    const show = async () => {
      where.textContent = at;
      const r = await App.api('/api/files?path=' + encodeURIComponent(at)).catch(App.fail);
      if (!r) return;
      at = r.path;
      where.textContent = at;
      // (a folder can't go inside itself)
      const dirs = App.arr(r.entries).filter((e) => e.dir).map((e) => (at === '/' ? '' : at) + '/' + e.name)
        .filter((d) => ![...moving].some((m) => d === m || d.startsWith(m + '/')));
      const row = (icon, text, to) => h('div', { class: 'tappable', style: 'cursor:pointer', onclick: () => { at = to; show(); } },
        h('span', {}, icon), h('div', { class: 'grow' }, text), to !== folderOf(at) ? h('span', { class: 'muted' }, '›') : null);
      list.replaceChildren(...[
        at !== '/' ? row('↩', 'Up one folder', folderOf(at)) : null,
        ...dirs.map((d) => row('📁', nameOf(d), d)),
        dirs.length ? null : h('p', { class: 'muted small' }, 'No folders in here.')].filter(Boolean));
    };
    const newFolder = h('button', { class: 'btn small', onclick: async () => {
      const name = await App.prompt('New folder', '', 'Folder name');
      if (!name) return;
      await App.api('/api/files/mkdir', { json: { path: at, name } }).then(() => { at = (at === '/' ? '' : at) + '/' + name; show(); }, App.fail);
    } }, 'New folder');
    show();
    const n = paths.length;
    const ok = await App.modal(mode === 'move' ? plural(n, 'Move 1 item', 'Move %1 items') : plural(n, 'Copy 1 item', 'Copy %1 items'),
      h('div', { class: 'stack' }, where, list, h('div', {}, newFolder)),
      [{ text: 'Cancel', result: false }, { text: mode === 'move' ? 'Move here' : 'Copy here', primary: true, result: true }]);
    if (!ok) return;
    const r = await App.api('/api/files/move', { json: { paths, to: at, copy: mode === 'copy' } }).catch(App.fail);
    if (!r) return;
    const name = at === '/' ? at : nameOf(at);
    if (!r.ok) App.toast((mode === 'move' ? 'Not moved: ' : 'Not copied: ') + App.arr(r.failed).join(', '), true);
    else if (r.done) App.toast((mode === 'move' ? 'Moved to ' : 'Copied to ') + name);
    if (done) done();
  }

  // Delete at once, with Undo for a few seconds (as on the Kindle); gone for good when the Undo goes.
  async function remove(paths, done) {
    const r = await App.api('/api/files/delete', { json: { paths } }).catch(App.fail);
    if (!r) return;
    if (r.failed && r.failed.length) App.toast('Couldn’t delete: ' + r.failed.map(nameOf).join(', '), true);
    if (done) done();
    if (!r.key) return;
    const what = r.deleted === 1 ? 'Deleted “' + nameOf(paths.find((x) => !App.arr(r.failed).includes(x)) || paths[0]) + '”' : 'Deleted ' + r.deleted + ' items';
    App.undo(what, async () => {
      await App.api('/api/files/undo', { json: { key: r.key } }).catch(App.fail);
      if (done) done();
    }, 6, () => App.api('/api/files/purge', { json: { key: r.key } }).catch(() => {}));
  }

  // A book's details: its reading, the book itself and the file, as the Kindle's book page.
  async function details(p, actions) {
    const d = await App.api('/api/library/details?path=' + encodeURIComponent(p)).catch(App.fail);
    if (!d) return;
    const line = (label, value) => value != null && value !== '' ? h('div', { class: 'setting' }, h('div', { class: 'muted small' }, label), h('div', {}, value)) : null;
    const section = (title, rows) => (rows.some(Boolean) ? [h('h3', { style: 'margin:6px 0 0' }, title), ...rows] : []);
    const closeAnd = (fn) => () => { document.querySelector('.modal-back')?.remove(); fn(); };
    const better = niceName(d.name, d);
    let left = null;
    if (d.pace && d.percent != null && d.pages && d.status !== 'complete') {
      const secs = d.pages * (1 - d.percent / 100) / d.pace * 3600;
      if (secs > 60) left = 'About ' + time(secs) + ' left';
    }
    // Status: To read only while it has never been opened (KOReader has no way back to it).
    const chips = h('div', { class: 'row', style: 'gap:6px' }, [['new', 'To read'], ['reading', 'Reading'], ['abandoned', 'On hold'], ['complete', 'Finished']]
      .filter(([k]) => k !== 'new' || d.status === 'new')
      .map(([k, label]) => h('button', { class: 'btn small' + (d.status === k ? ' primary' : ''), disabled: k === 'new',
        onclick: k === d.status ? null : () => setStatus([p], k, () => { document.querySelector('.modal-back')?.remove(); actions.reload(); details(p, actions); }) }, label)));
    const pagesRead = d.readPages ? (d.pages ? d.readPages + ' of ' + d.pages : String(d.readPages)) : null;
    const body = h('div', { class: 'stack' },
      h('div', { class: 'row', style: 'align-items:flex-start;gap:16px;flex-wrap:nowrap' },
        d.cover ? h('img', { class: 'book-cover', style: 'width:110px;flex:none', alt: '', src: '/api/books/cover?path=' + encodeURIComponent(p) }) : null,
        h('div', { class: 'stack', style: 'gap:4px' },
          h('div', { style: 'font-size:18px;font-weight:700' }, short(d.title || d.name, 160)),
          d.authors ? h('div', {}, d.authors.split('\n').join(', ')) : null,
          h('div', { class: 'muted small' }, [stateText(d), left].filter(Boolean).join(' · ')),
          chips)),
      ...section('Reading', [
        line('First read', date(d.firstRead)),
        line('Last read', d.lastRead ? App.when(d.lastRead) : null),
        line('Time reading', d.readTime ? time(d.readTime) : null),
        line('Days reading it', d.readDays ? String(d.readDays) : null),
        line('Pace', d.pace ? d.pace + ' pages an hour' : null),
        line('Pages read', pagesRead),
        line('Highlights and notes', (d.highlights || d.notes) ? d.highlights + ' · ' + d.notes : null),
      ]),
      ...section('Book', [
        line('Series', d.series ? d.series + (d.seriesIndex ? ' · Book ' + d.seriesIndex : '') : null),
        line('Authors', d.authors ? d.authors.split('\n').join(', ') : null),
        line('Published', d.published),
        line('Publisher', d.publisher),
        line('Language', language(d.language)),
        line('Pages', d.pages),
        line('Subjects', d.subjects),
        line('ISBN', d.isbn),
      ]),
      d.description ? h('h3', { style: 'margin:6px 0 0' }, 'Description') : null,
      d.description ? h('div', { class: 'small', style: 'white-space:pre-wrap;max-height:220px;overflow:auto' }, d.description) : null,
      ...section('File', [
        line('Name', d.name),
        line('Format', (d.name.match(/\.([^.]+)$/) || ['', ''])[1].toUpperCase() || null),
        line('Size', App.size(d.size)),
        line('Added', date(d.added)),
        line('Folder', d.folder ? goTo(d.folder, true, d.folder) : null),
        line('Collections', App.arr(d.collections).length ? d.collections.join(', ') : 'None'),
      ]),
      h('div', { class: 'row' },
        h('button', { class: 'btn primary', onclick: () => actions.open(p, d.title || d.name) }, '▶ Open on the Kindle'),
        h('button', { class: 'btn', disabled: !(d.highlights || d.notes), onclick: () => highlights(p) }, 'Highlights and notes'),
        h('button', { class: 'btn', onclick: () => addTo([p], closeAnd(() => { actions.reload(); details(p, actions); })) }, 'Add to a collection…'),
        h('button', { class: 'btn', onclick: closeAnd(() => pickFolder('move', [p], null, actions.reload)) }, 'Move to…'),
        h('button', { class: 'btn', onclick: closeAnd(() => pickFolder('copy', [p], null, actions.reload)) }, 'Copy to…'),
        better && better !== d.name ? h('button', { class: 'btn', title: 'Rename to “' + better + '”', onclick: async () => {
          await App.api('/api/files/rename', { json: { path: p, name: better } }).then(() => {
            App.toast('Renamed');
            document.querySelector('.modal-back')?.remove();
            actions.reload();
          }, App.fail);
        } }, 'Rename from details') : null,
        h('button', { class: 'btn danger', onclick: closeAnd(() => remove([p], actions.reload)) }, 'Delete')));
    App.modal('Book details', body, [{ text: 'Close', result: null }], true);
  }

  // A book's highlights and notes, with a download as Markdown or text.
  async function highlights(p) {
    const r = await App.api('/api/library/highlights?path=' + encodeURIComponent(p)).catch(App.fail);
    if (!r) return;
    const items = App.arr(r.items);
    const when = (dt) => (dt ? String(dt).slice(0, 10) : '');
    const save = (kind) => {
      const lines = [];
      let chapter = null;
      if (kind === 'md') {
        lines.push('# ' + r.title, r.authors ? '*' + r.authors.split('\n').join(', ') + '*' : '', '');
        for (const it of items) {
          if (it.chapter && it.chapter !== chapter) { chapter = it.chapter; lines.push('## ' + chapter, ''); }
          if (it.text) lines.push(it.text.split('\n').map((l) => '> ' + l).join('\n'));
          if (it.note) lines.push('', it.note);
          lines.push('', '— ' + [it.page ? 'page ' + it.page : null, when(it.datetime)].filter(Boolean).join(', '), '');
        }
      } else {
        lines.push(r.title, r.authors ? r.authors.split('\n').join(', ') : '', '');
        for (const it of items) {
          if (it.chapter && it.chapter !== chapter) { chapter = it.chapter; lines.push(chapter.toUpperCase(), ''); }
          if (it.text) lines.push('“' + it.text + '”');
          if (it.note) lines.push('Note: ' + it.note);
          lines.push('(' + [it.page ? 'page ' + it.page : null, when(it.datetime)].filter(Boolean).join(', ') + ')', '');
        }
      }
      const blob = new Blob([lines.join('\n')], { type: kind === 'md' ? 'text/markdown' : 'text/plain' });
      const a = h('a', { href: URL.createObjectURL(blob), download: (r.title || 'highlights').replace(/[\/\\:*?"<>|]+/g, ' ') + ' – highlights.' + kind });
      document.body.append(a);
      a.click();
      a.remove();
    };
    let chapter = null;
    const list = h('div', { class: 'stack' }, items.length ? items.flatMap((it) => {
      const out = [];
      if (it.chapter && it.chapter !== chapter) { chapter = it.chapter; out.push(h('h3', {}, chapter)); }
      out.push(h('div', { class: 'card stack', style: 'gap:6px' },
        it.text ? h('div', { style: 'white-space:pre-wrap' }, '“' + it.text + '”') : null,
        it.note ? h('div', { class: 'small', style: 'white-space:pre-wrap' }, '✎ ' + it.note) : null,
        h('div', { class: 'muted small' }, [it.page ? 'Page ' + it.page : null, when(it.datetime)].filter(Boolean).join(' · '))));
      return out;
    }) : h('div', { class: 'empty' }, 'No highlights or notes yet.'));
    App.modal('Highlights: ' + short(r.title), h('div', { class: 'stack' },
      h('div', { class: 'row' }, h('button', { class: 'btn', onclick: () => save('md') }, 'Download as Markdown'), h('button', { class: 'btn', onclick: () => save('txt') }, 'Download as text')),
      h('div', { style: 'max-height:60vh;overflow:auto' }, list)),
    [{ text: 'Close', result: null }], true);
  }

  // A file from a web link, into `folder` (the Kindle gets it in the background).
  async function fromLink(folder, progress, done) {
    const url = await App.prompt('Get a file from a link', '', 'https://… (an EPUB, PDF or any file)');
    if (!url) return;
    const r = await App.api('/api/library/fetch', { json: { url, path: folder } }).catch(App.fail);
    if (!r) return;
    const label = h('div', { class: 'small' }, 'Getting ' + url + ' …');
    progress.append(label);
    const ask = async () => {
      const s = await App.api('/api/library/fetch?key=' + encodeURIComponent(r.key)).catch(() => null);
      if (s && s.status === 'done') { label.textContent = s.name + ' · saved to ' + folder; App.toast('Saved “' + s.name + '”'); if (done) done(); return; }
      if (s && s.status === 'failed') { label.textContent = url + ' · ' + (s.message || 'failed'); App.toast(s.message || 'Couldn’t get it', true); return; }
      setTimeout(ask, 2000);
    };
    setTimeout(ask, 1500);
  }

  // The Library app's settings, as on the Kindle (Library settings).
  function settingsCard() {
    const el = h('div', { class: 'card', style: 'margin-top:16px' });
    App.api('/api/library/settings').then((s) => {
      if (!s.installed) { el.remove(); return; }
      const save = (patch) => App.api('/api/library/settings', { json: patch }).catch(App.fail);
      el.replaceChildren(h('h2', {}, 'Library settings'),
        App.setting('Show books as', App.select([['covers', 'Covers'], ['list', 'List']], s.view, (v) => save({ view: v }))),
        App.setting('Open on', App.select([['home', 'Home'], ['last', 'Where you left off']], s.start, (v) => save({ start: v }))),
        App.setting('Home starts with', App.select([['places', 'Servers and folders'], ['books', 'Books']], s.home_first, (v) => save({ home_first: v })),
          'What comes first on Home, after Continue reading and Recent'),
        App.setting('Keep rows in place', App.toggle(s.stable_lists !== false, (on) => save({ stable_lists: on })),
          'After you change a book’s status, it stays where it is until you leave the screen or refresh it'),
        App.setting('Show hidden files', App.toggle(s.hidden === true, (on) => save({ hidden: on })), 'Names starting with a dot'),
        App.setting('Browse books with', App.select([['library', 'Library'], ['koreader', 'KOReader’s file browser']], s.browser, (v) => save({ browser: v })),
          'What Back from a book and the launcher’s Library open'));
    }, (e) => el.replaceChildren(h('div', { class: 'empty' }, e.message)));
    return el;
  }

  return { settingsCard, search, recent, storage, collections, addTo, details, highlights, fromLink, niceName, STATUS, stateText, setStatus, pickFolder, remove };
})();
