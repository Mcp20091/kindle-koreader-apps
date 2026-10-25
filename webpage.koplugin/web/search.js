// Search: notebooks (Notes' own search), To Do's tasks and the crosswords, from the box in the header,
// and this page's own cards and settings (their names, read from each tab's script).

// The cards and settings on each tab shown: [{ page, tab, label, kind }]. Read once from the tabs'
// scripts (each card's h2 and each App.setting's label), so a new one is found without a list to keep.
App.pageIndex = async function () {
  if (App._pageIndex) return App._pageIndex;
  const tabs = [...document.querySelectorAll('#nav a[data-page]')].filter((a) => !a.classList.contains('off'));
  const unq = (s) => s.replace(/\\(.)/g, '$1');
  const all = await Promise.all(tabs.map(async (a) => {
    const page = a.dataset.page;
    const src = await fetch('/static/' + page + '.js').then((r) => (r.ok ? r.text() : '')).catch(() => '');
    const out = [{ page, tab: a.textContent, label: a.textContent, kind: 'Tab' }];
    const seen = new Set();
    const add = (label, kind) => {
      label = unq(label);
      if (label.length < 3 || seen.has(label.toLowerCase())) return;
      seen.add(label.toLowerCase());
      out.push({ page, tab: a.textContent, label, kind });
    };
    // (Only whole names: one with more joined on, 'Port: ' + n, is left out.)
    for (const m of src.matchAll(/h\('h2', \{[^}]*\}, '((?:[^'\\]|\\.)+)'\s*[,)]/g)) add(m[1], 'Card');
    for (const m of src.matchAll(/App\.setting\('((?:[^'\\]|\\.)+)'\s*[,)]/g)) add(m[1], 'Setting');
    return out;
  }));
  App._pageIndex = all.flat();
  return App._pageIndex;
};

// Opens a tab and brings the card or setting called `label` into view (once the tab has drawn it).
App.openAt = function (page, label) {
  location.hash = '#' + page;
  const until = Date.now() + 4000;
  const look = () => {
    const el = [...document.querySelectorAll('#main h2, #main .setting > div > div:first-child')]
      .find((e) => e.textContent.trim() === label);
    if (el) {
      const box = el.closest('.setting') || el.closest('.card') || el;
      box.scrollIntoView({ block: 'center' });
      box.classList.add('found');
      setTimeout(() => box.classList.remove('found'), 2500);
    } else if (Date.now() < until) setTimeout(look, 150);
  };
  setTimeout(look, 100);
};

App.pages.search = {
  async render(main, params) {
    const q = (params.q || '').trim();
    const box = document.getElementById('search');
    if (box && box.value !== q) box.value = q;
    main.append(h('h1', {}, 'Search'));
    if (q.length < 2) {
      main.append(h('p', { class: 'sub' }, 'Type at least two letters in the search box: notebooks’ text, To Do tasks, crosswords, and this page’s settings.'));
      return;
    }
    const enc = encodeURIComponent(q);
    const lq = q.toLowerCase();
    const [kindle, notes, index] = await Promise.all([
      App.api('/api/search?q=' + enc).catch(() => ({})),
      App.plugins && App.plugins.notes === false ? Promise.resolve(null)
        : App.api('/api/notes/search?q=' + enc).catch(() => null),
      App.pageIndex().catch(() => []),
    ]);
    const here = index.filter((x) => x.label.toLowerCase().includes(lq)).slice(0, 30);
    const todo = kindle.todo == null ? null : App.arr(kindle.todo);
    const crosswords = kindle.crosswords == null ? null : App.arr(kindle.crosswords);
    const nbs = notes == null ? null : App.arr(notes);
    const total = (todo || []).length + (crosswords || []).length + (nbs || []).length + here.length;
    main.append(h('p', { class: 'sub' }, total === 0 ? 'Nothing found for “' + q + '”.' : total + ' found for “' + q + '”.'));
    const section = (title, items, row) => {
      if (!items || !items.length) return;
      main.append(h('div', { class: 'card' }, h('h2', {}, title + ' (' + items.length + ')'),
        h('div', { class: 'list-rows' }, items.map(row))));
    };
    const line = (href, title, sub, snippet) => h('a', { class: 'result', href },
      h('div', { class: 'grow' }, h('div', {}, h('strong', {}, title), sub ? h('span', { class: 'muted small' }, '  ·  ' + sub) : null),
        snippet ? h('div', { class: 'muted small' }, snippet) : null));
    // Where it matched: the page (typed text or handwriting), or the name.
    const where = (r) => [r.page ? 'page ' + r.page : null, r.kind === 'handwriting' ? 'handwriting' : r.kind === 'name' ? 'name' : null]
      .filter(Boolean).join(' · ') || null;
    section('On this page', here, (x) => h('a', { class: 'result', href: '#' + x.page, onclick: (e) => { e.preventDefault(); App.openAt(x.page, x.label); } },
      h('div', { class: 'grow' }, h('div', {}, h('strong', {}, x.label),
        h('span', { class: 'muted small' }, '  ·  ' + (x.kind === 'Tab' ? 'Tab' : x.kind + ' on ' + x.tab))))));
    section('Notebooks', nbs, (r) => line('#notes?nb=' + encodeURIComponent(r.nb), r.name, where(r), r.kind === 'name' ? null : r.snippet));
    section('To Do', todo, (r) => line('#todo?list=' + encodeURIComponent(r.listId), (r.done ? '✓ ' : '') + r.title,
      r.list + (r.due ? ' · due ' + r.due : ''), r.snippet));
    section('Crosswords', crosswords, (r) => line('#notes?nb=' + encodeURIComponent(r.nb), r.name, r.book + ', page ' + r.page, r.snippet));
  },
};

// The header's box: Enter searches.
(function () {
  const box = document.getElementById('search');
  if (!box) return;
  box.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    const q = box.value.trim();
    location.hash = '#search?q=' + encodeURIComponent(q);
  });
})();
