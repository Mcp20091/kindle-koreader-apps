// Crosswords: the books of crosswords on the Kindle (each puzzle's day, state and time; open on the
// Kindle, remove), puzzles picked by day and downloaded by the Kindle, .puz/.ipuz files imported,
// and Crossword settings.
App.pages.crosswords = {
  book: null,
  src: 'usa',
  kind: 'quick',
  from: 0,
  // #crosswords?book=nb…&puzzle=usa/20261021 (from the Kindle's Open on the web page): that book, the puzzle marked.
  async render(main, params = {}) {
    const s = await App.api('/api/crosswords');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'Notes with crosswords isn’t installed on this Kindle.')); return; }
    s.books = App.arr(s.books);
    s.sources = App.arr(s.sources);
    s.settings = App.obj(s.settings);
    s.puzzleButtons = App.arr(s.puzzleButtons);
    const page = this;
    if (params.book && params.book !== page.linked) {
      page.linked = params.book;
      page.book = params.book;
      page.puzzle = params.puzzle || null;
      page.scrollTo = page.puzzle;
    }
    if (!s.books.some((b) => b.id === page.book)) page.book = s.books.length ? s.books[0].id : null;
    main.append(
      h('div', { class: 'spread' },
        h('div', {}, h('h1', {}, 'Crosswords'), h('p', { class: 'sub' }, 'Your crossword books on the Kindle. Downloads are done by the Kindle.')),
        h('div', { class: 'row' }, page.importButton())),
      page.books(s), page.getter(s), page.settings(s), page.toolbar(s));
  },

  reload() { App.route(); },

  // The books as cards, the one picked listed below.
  books(s) {
    const page = this;
    if (!s.books.length) return h('div', { class: 'card' }, h('p', { class: 'muted' }, 'No crosswords yet. Get some below.'));
    const cards = h('div', { class: 'grid' }, s.books.map((b) => {
      const puzzles = App.arr(b.puzzles);
      const started = puzzles.filter((p) => p.state === 'started').length;
      const done = puzzles.filter((p) => p.state === 'done').length;
      const line = puzzles.length + ' puzzle' + (puzzles.length === 1 ? '' : 's') + (started ? ' · ' + started + ' started' : '') + (done ? ' · ' + done + ' done' : '');
      return h('button', { class: 'card book' + (b.id === page.book ? ' on' : ''), onclick: () => { page.book = b.id; page.reload(); } },
        h('strong', {}, b.name), h('div', { class: 'small muted' }, line));
    }));
    const b = s.books.find((x) => x.id === page.book);
    const rows = App.arr(b && b.puzzles).map((p) => {
      const state = { done: 'Done', started: 'Started', new: 'Not started' }[p.state] || p.state;
      const mins = p.secs ? (p.secs < 60 ? 'under a minute' : Math.round(p.secs / 60) + ' min') : '';
      const clues = p.ticked && p.clues ? p.ticked + ' of ' + p.clues + ' clues' : '';
      const row = h('tr', { class: p.key === page.puzzle ? 'marked' : '' },
        h('td', {}, p.label, p.hidden ? h('span', { class: 'muted small' }, ' (hidden)') : null),
        h('td', {}, h('span', { class: 'pill' + (p.state === 'done' ? ' ok' : '') }, state)),
        h('td', { class: 'muted' }, [clues, mins].filter(Boolean).join(' · ')),
        h('td', { style: 'text-align:right;white-space:nowrap' },
          h('button', { class: 'btn small', onclick: () => page.open(b, p) }, 'Open on Kindle'), ' ',
          h('button', { class: 'btn small', onclick: () => page.editTime(b, p) }, 'Edit time'), ' ',
          h('button', { class: 'btn small danger', onclick: () => page.remove(b, p) }, 'Remove')));
      // Scrolled to once, when the page is on screen.
      if (p.key === page.scrollTo) {
        page.scrollTo = null;
        const scroll = (n) => row.isConnected ? row.scrollIntoView({ block: 'center' }) : n < 40 && setTimeout(() => scroll(n + 1), 50);
        scroll(0);
      }
      return row;
    });
    return h('div', { class: 'stack' }, cards,
      b ? h('div', { class: 'card' }, h('h2', {}, b.name),
        rows.length ? h('table', { class: 'list' }, h('tbody', {}, rows)) : h('p', { class: 'muted' }, 'This book is empty.')) : null);
  },

  async open(b, p) {
    try { await App.api('/api/crosswords/open', { json: { book: b.id, key: p.key } }); App.toast('Opened on the Kindle'); } catch (e) { App.fail(e); }
  },

  // The time it took, put right (left open by mistake), in minutes.
  async editTime(b, p) {
    const v = await App.prompt('Edit time: ' + p.label + ' (minutes)', String(Math.round((p.secs || 0) / 60)));
    if (v == null) return;
    const minutes = Number(v);
    if (!isFinite(minutes) || minutes < 0) return App.toast('Enter the minutes as a number', true);
    try { await App.api('/api/crosswords/time', { json: { book: b.id, key: p.key, minutes } }); App.toast('Time saved'); this.reload(); } catch (e) { App.fail(e); }
  },

  async remove(b, p) {
    if (!await App.confirm('Remove puzzle', 'Remove ' + p.label + ' from ' + b.name + '? Its pages and your writing on them go.', 'Remove', true)) return;
    try { await App.api('/api/crosswords/remove', { json: { book: b.id, key: p.key } }); App.toast('Removed'); this.reload(); } catch (e) { App.fail(e); }
  },

  // Pick a source (and the Guardian's kind), tick days, and the Kindle downloads them.
  getter(s) {
    const page = this;
    const box = h('div', { class: 'card' });
    const list = h('div', { class: 'stack' }, h('p', { class: 'muted small' }, 'Loading…'));
    const sources = [['usa', 'USA Today'], ['universal', 'Universal'], ['wapo', 'Washington Post (Sundays)'], ['tny', 'New Yorker (weekdays)'], ['guardian', 'The Guardian']];
    const picked = new Set();
    let items = [];
    const getBtn = h('button', { class: 'btn primary', disabled: true, onclick: async () => {
      const want = items.filter((it) => picked.has(it.key));
      getBtn.disabled = true;
      getBtn.textContent = 'Getting ' + want.length + '…';
      try {
        let r = await App.api('/api/crosswords/get', { json: { src: page.src, items: want } });
        // The Kindle downloads in the background: asked how it's going until done.
        while (r.job) {
          await new Promise((ok) => setTimeout(ok, 1500));
          const j = await App.api('/api/crosswords/job?id=' + encodeURIComponent(r.job));
          if (j.state !== 'running') r = j;
        }
        App.toast('Added ' + r.got + ' crossword' + (r.got === 1 ? '' : 's') + (App.arr(r.missed).length ? ' (none for ' + App.arr(r.missed).join(', ') + ')' : ''));
        page.reload();
      } catch (e) { App.fail(e); getBtn.disabled = false; getBtn.textContent = 'Get'; }
    } }, 'Get');
    const count = () => {
      getBtn.disabled = picked.size === 0;
      getBtn.textContent = picked.size ? 'Get ' + picked.size + ' crossword' + (picked.size === 1 ? '' : 's') : 'Get';
    };
    const load = async () => {
      list.replaceChildren(h('p', { class: 'muted small' }, 'Asking the Kindle…'));
      picked.clear();
      count();
      try {
        const q = '/api/crosswords/choices?src=' + page.src + '&kind=' + page.kind + '&from=' + page.from;
        let r = await App.api(q);
        // (The Guardian's list is fetched by the Kindle in the background.)
        for (let tries = 0; r.loading && tries < 60; tries++) {
          await new Promise((ok) => setTimeout(ok, 1500));
          r = await App.api(q);
        }
        items = App.arr(r.items);
        const rows = items.map((it) => {
          const cb = h('input', { type: 'checkbox', disabled: !!it.had, onchange: () => { cb.checked ? picked.add(it.key) : picked.delete(it.key); count(); } });
          return h('label', { class: 'row small' }, cb, it.label, it.had ? h('span', { class: 'muted' }, ' (in the book)') : null);
        });
        const nav = h('div', { class: 'row' },
          h('button', { class: 'btn small', disabled: page.from === 0, onclick: () => { page.from = Math.max(0, page.from - (page.src === 'guardian' ? 5 : 7)); load(); } }, '‹ Newer'),
          h('button', { class: 'btn small', disabled: !r.more, onclick: () => { page.from += page.src === 'guardian' ? 5 : 7; load(); } }, 'Older ›'));
        list.replaceChildren(h('div', { class: 'days' }, rows.length ? rows : h('p', { class: 'muted' }, 'Nothing here.')), nav);
      } catch (e) { list.replaceChildren(h('p', { class: 'muted' }, e.message || String(e))); }
    };
    const kinds = page.src === 'guardian'
      ? App.select([['quick', 'Quick'], ['cryptic', 'Cryptic'], ['quiptic', 'Quiptic'], ['prize', 'Prize']], page.kind, (v) => { page.kind = v; page.from = 0; load(); })
      : null;
    const srcSel = App.select(sources, page.src, (v) => { page.src = v; page.from = 0; page.reload(); });
    box.append(h('h2', {}, 'Get crosswords'), h('div', { class: 'row' }, srcSel, kinds, getBtn), list,
      // Whether the Kindle reaches the sites it gets puzzles from.
      App.connectionTest ? h('div', { style: 'margin-top:12px' }, App.connectionTest('crosswords')) : null);
    load();
    return box;
  },

  // Files from this computer: a PDF of puzzles becomes a puzzle book in Crosswords; a .puz or .ipuz
  // crossword goes into the Imported crosswords book.
  importButton() {
    const page = this;
    const input = h('input', { type: 'file', accept: '.pdf,.puz,.ipuz', multiple: true, style: 'display:none', onchange: async () => {
      let n = 0;
      for (const f of input.files) {
        try {
          if (/\.pdf$/i.test(f.name)) {
            App.toast('Sending ' + f.name + '…');
            const r = await App.api('/api/crosswords/pdf?name=' + encodeURIComponent(f.name), { method: 'PUT', body: f });
            App.toast('Added the puzzle book ' + r.name + ' (' + r.pages + ' pages)');
          } else {
            const r = await App.api('/api/crosswords/import', { method: 'POST', body: await f.arrayBuffer() });
            App.toast('Imported ' + (r.name || f.name));
          }
          n++;
        } catch (e) { App.toast(f.name + ': ' + (e.message || e), true); }
      }
      input.value = '';
      if (n) page.reload();
    } });
    return h('span', {}, input, h('button', { class: 'btn', onclick: () => input.click() }, 'Import PDF, .puz or .ipuz'));
  },

  // A puzzle's toolbar buttons (Toolbar buttons in the Kindle's Crossword settings), drawn as they look
  // there under the tools, to drag into order or to Not shown; a tap menu does the same.
  toolbar(s) {
    const st = s.settings;
    const box = h('div', { class: 'stack' });
    const by = {};
    s.puzzleButtons.forEach((b) => { by[b.key] = b; });
    const on = App.arr(st.puzzle_buttons).filter((k) => by[k]);
    const draw = (svgs) => {
      const btn = (b) => {
        const sp = h('span', { class: 'tile-icon' });
        if (svgs[b.icon]) sp.innerHTML = svgs[b.icon];
        return h('div', { class: 've-tile', style: 'width:290px;height:48px;flex-direction:row;align-items:center;justify-content:flex-start;gap:12px' }, sp, h('b', {}, b.label));
      };
      const items = (keys) => keys.map((k) => ({ key: k, name: by[k].label, label: by[k].label, icon: by[k].icon }));
      box.replaceChildren(App.visualZones([
        { id: 'on', title: 'On the toolbar', short: 'Shown', empty: 'Drop buttons here to add them', items: items(on), render: btn },
        { id: 'off', title: 'Not shown', short: 'Not shown', className: 'tray', empty: 'Every button is on the toolbar', items: items(s.puzzleButtons.map((b) => b.key).filter((k) => !on.includes(k))), render: btn },
      ], { onChange: (z) => {
        App.api('/api/crosswords/settings', { json: { puzzle_buttons: z.on } }).then(() => { st.puzzle_buttons = z.on; }, App.fail);
      } }));
    };
    draw({});
    App.api('/api/notes/icons?names=' + encodeURIComponent(s.puzzleButtons.map((b) => b.icon).join(',')))
      .then((r) => draw((r && r.icons) || {}), () => {});
    return h('div', { class: 'card stack' }, h('h2', {}, 'Toolbar buttons'),
      h('p', { class: 'muted small' }, 'Things from a puzzle’s ⋯ menu to add to its toolbar, under the tools. Drag one to move it, or click it to move or remove it.'),
      box);
  },

  settings(s) {
    const st = s.settings;
    const save = async (k, v) => {
      try { await App.api('/api/crosswords/settings', { json: { [k]: v } }); st[k] = v; App.toast('Saved'); } catch (e) { App.fail(e); }
    };
    const todayChoices = [['last', 'The one last opened in Get a crossword']].concat(s.sources.map((x) => [x.key, x.name]));
    const auto = new Set(App.arr(st.crossword_auto));
    const autoBoxes = h('div', { class: 'days' }, s.sources.map((x) => {
      const cb = h('input', { type: 'checkbox', checked: auto.has(x.key), onchange: () => {
        cb.checked ? auto.add(x.key) : auto.delete(x.key);
        save('crossword_auto', s.sources.map((y) => y.key).filter((k) => auto.has(k)));
      } });
      return h('label', { class: 'row small' }, cb, x.name);
    }));
    return h('div', { class: 'card' }, h('h2', {}, 'Crossword settings'),
      App.setting('Today’s crossword', App.select(todayChoices, st.crossword_today || 'last', (v) => save('crossword_today', v)),
        'What the gesture and the Crosswords tile on the launcher open.'),
      App.setting('Clue size', App.select([['normal', 'Normal'], ['large', 'Large']], st.crossword_clues === 'large' ? 'large' : 'normal', (v) => save('crossword_clues', v)),
        'The books are laid out again on the Kindle.'),
      App.setting('Clue boxes', App.toggle(st.crossword_boxes !== false, (v) => save('crossword_boxes', v)),
        'A tick box before each clue: tap it, or draw through it, with the pen.'),
      App.setting('Clue card', App.select([['other', 'Clues on other pages'], ['all', 'Every clue']], st.crossword_card === 'other' ? 'other' : 'all', (v) => save('crossword_card', v === 'other' ? 'other' : '')),
        'The card a number in the grid opens: only for clues on another page, or for every clue.'),
      App.setting('Undo after a tick', App.select([['0', 'Off'], ['2', '2 seconds'], ['3', '3 seconds'], ['5', '5 seconds'], ['8', '8 seconds']], st.crossword_undo || '3', (v) => save('crossword_undo', v === '3' ? '' : v)),
        'How long Undo shows after ticking a clue on its card.'),
      App.setting('Tap a number to find it', App.toggle(st.crossword_find !== false, (v) => save('crossword_find', v)),
        'Tap a clue’s number with the pen to outline its squares, or a number in the grid to outline its clue.'),
      App.setting('Timer', App.toggle(st.crossword_timer !== false, (v) => save('crossword_timer', v)),
        'Each puzzle times itself while it is open and being written on.'),
      App.setting('Finished puzzles', App.select([['keep', 'Keep'], ['hide', 'Hide after 7 days'], ['remove', 'Remove after 30 days']], st.crossword_finished || 'keep', (v) => save('crossword_finished', v))),
      h('h3', {}, 'Get new ones automatically'),
      h('p', { class: 'small muted' }, 'When Crosswords opens or Wi-Fi comes on. Up to the last 3 days.'),
      autoBoxes);
  },
};
