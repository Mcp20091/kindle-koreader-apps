// Wikipedia: the articles saved on the Kindle (download the EPUB, remove), an article searched (by
// this browser, straight from Wikipedia) and saved to the Kindle (the Kindle downloads it while the
// page checks back), and what was read on the Kindle recently.
App.pages.wikipedia = {
  query: '',
  results: null,

  async render(main) {
    const s = await App.api('/api/wikipedia');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'Wikipedia isn’t installed on this Kindle.')); return; }
    s.saved = App.arr(s.saved);
    s.recent = App.arr(s.recent);
    main.append(...[
      h('div', {}, h('h1', {}, 'Wikipedia'), h('p', { class: 'sub' }, 'Articles saved on the Kindle open there without Wi-Fi.')),
      this.saved(s), this.search(s), this.recent(s), this.settings()].filter(Boolean));
  },

  reload() { App.route(); },

  // The Kindle's Wikipedia settings, in the same words.
  settings() {
    const box = h('div', { class: 'card' }, h('h2', {}, 'Settings'));
    App.api('/api/wikipedia/settings').then((s) => {
      const save = (patch) => App.api('/api/wikipedia/settings', { json: patch }).catch(App.fail);
      const section = (key, text) => App.setting(text, App.toggle(s.sections[key] === true, (on) => save({ sections: { [key]: on } })));
      const folder = h('input', { type: 'text', value: s.folder, style: 'width:100%;max-width:320px', spellcheck: false });
      box.append(
        h('div', { class: 'small muted', style: 'margin-top:8px' }, 'DISPLAY'),
        App.setting('Toolbar', App.select([['left', 'Left'], ['top', 'Top']], s.toolbar, (v) => save({ toolbar: v }))),
        App.setting('Images', App.toggle(s.images, (on) => save({ images: on }))),
        h('div', { class: 'small muted', style: 'margin-top:8px' }, 'ARTICLES'),
        App.setting('Language', App.select(App.arr(s.languages).map((l) => [l.code, l.name])
          .concat(App.arr(s.languages).some((l) => l.code === s.lang) ? [] : [[s.lang, s.lang]]), s.lang, (v) => save({ lang: v }))),
        App.setting('Tap a link', App.select([['preview', 'Preview'], ['open', 'Open']], s.link_tap, (v) => save({ link_tap: v }))),
        App.setting('Save to', h('div', { class: 'row' }, folder, h('button', { class: 'btn', onclick: async () => {
          const r = await save({ folder: folder.value.trim() });
          if (r) { folder.value = r.folder; App.toast('Saved'); }
        } }, 'Use this folder'))),
        h('div', { class: 'small muted', style: 'margin-top:8px' }, 'FRONT PAGE'),
        section('featured', 'Today’s featured article'), section('onthisday', 'On this day'),
        section('news', 'In the news'), section('mostread', 'Most read yesterday'),
        h('div', { class: 'small muted', style: 'margin-top:8px' }, 'RECENT'),
        App.setting('Keep recent', App.select(App.arr(s.keep_choices).map((n) => [String(n), n + ' articles']), s.keep_recent,
          (v) => save({ keep_recent: Number(v) }))),
        App.setting('Clear recent', h('button', { class: 'btn', onclick: async () => {
          if (!(await App.confirm('Clear recent', 'Clear the list of recent articles?', 'Clear', true))) return;
          if (await save({ clear_recent: true })) { App.toast('Cleared'); this.reload(); }
        } }, 'Clear')),
        App.setting('Show in recent books', App.toggle(s.in_history, (on) => save({ in_history: on }))));
    }, App.fail);
    return box;
  },

  when(t) {
    const d = new Date(t * 1000);
    const today = new Date();
    if (d.toDateString() === today.toDateString()) return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
  },

  size(n) {
    return n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB';
  },

  saved(s) {
    const page = this;
    const total = s.saved.reduce((n, a) => n + (a.size || 0), 0);
    const title = h('h2', {}, 'Saved on this Kindle ', s.saved.length
      ? h('span', { class: 'muted small' }, s.saved.length + ' article' + (s.saved.length === 1 ? '' : 's') + ' · ' + page.size(total)) : null);
    if (!s.saved.length) return h('div', { class: 'card' }, title, h('p', { class: 'muted' }, 'No saved articles yet.'));
    return h('div', { class: 'card' }, title, h('div', { class: 'list-rows' }, s.saved.map((a) =>
      h('div', { class: 'spread', style: 'padding:8px 0;border-top:1px solid var(--line)' },
        h('div', {}, h('strong', {}, a.title),
          h('div', { class: 'small muted' }, [a.description, page.when(a.time)].filter(Boolean).join(' · '))),
        h('div', { class: 'row', style: 'white-space:nowrap' },
          h('a', { class: 'btn small', href: '/api/wikipedia/download?file=' + encodeURIComponent(a.file) }, 'Download EPUB'), ' ',
          h('button', { class: 'btn small danger', onclick: () => page.remove(a) }, 'Remove'))))));
  },

  async remove(a) {
    if (!(await App.confirm('Remove article', 'Remove “' + a.title + '” from the Kindle?', 'Remove', true))) return;
    try { await App.api('/api/wikipedia/remove', { json: { file: a.file } }); App.toast('Removed'); this.reload(); } catch (e) { App.fail(e); }
  },

  async save(title, lang, button) {
    const label = button ? button.textContent : '';
    if (button) { button.disabled = true; button.textContent = 'Saving…'; }
    try {
      const { key } = await App.api('/api/wikipedia/save', { json: { title, lang } });
      // The Kindle downloads it in the background: asked every two seconds until done.
      for (let i = 0; i < 330; i++) {
        await new Promise((r) => setTimeout(r, 2000));
        const s = await App.api('/api/wikipedia/save?key=' + encodeURIComponent(key));
        if (s.state === 'saved') { App.toast('Saved ' + s.title + ' on the Kindle'); this.reload(); return; }
        if (s.state === 'failed') throw new Error(s.message || 'Download failed');
      }
      throw new Error('Still downloading on the Kindle; check Saved later');
    } catch (e) {
      App.fail(e);
      if (button) { button.disabled = false; button.textContent = label; }
    }
  },

  // Wikipedia's own search, from this browser (Wikipedia allows it with origin=*).
  async searchWikipedia(lang, q) {
    const url = 'https://' + lang + '.wikipedia.org/w/api.php?' + new URLSearchParams({
      action: 'query', generator: 'search', gsrsearch: q, gsrnamespace: '0', gsrlimit: '15',
      prop: 'description', redirects: '1', format: 'json', formatversion: '2', origin: '*',
    });
    const r = await fetch(url);
    if (!r.ok) throw new Error('Can’t reach Wikipedia');
    const data = await r.json();
    const pages = App.arr(data.query && data.query.pages).slice().sort((a, b) => (a.index || 0) - (b.index || 0));
    return pages.map((p) => ({ title: p.title, description: p.description || '' }));
  },

  search(s) {
    const page = this;
    const input = h('input', { type: 'search', value: page.query, placeholder: 'Search Wikipedia', style: 'width:100%' });
    const run = async () => {
      page.query = input.value.trim();
      if (!page.query) return;
      try {
        page.results = await page.searchWikipedia(s.lang || 'en', page.query);
        page.reload();
      } catch (e) { App.fail(e); }
    };
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') run(); });
    const savedTitles = new Set(s.saved.map((a) => a.lang + ':' + a.title));
    const rows = page.results === null ? null : (page.results.length
      ? page.results.slice(0, 15).map((r) => {
        const saved = savedTitles.has(s.lang + ':' + r.title);
        const btn = saved ? h('span', { class: 'muted small' }, 'Saved')
          : h('button', { class: 'btn small primary', onclick: (e) => page.save(r.title, s.lang, e.target) }, 'Save');
        return h('div', { class: 'spread', style: 'padding:8px 0;border-top:1px solid var(--line)' },
          h('div', {}, h('strong', {}, r.title), r.description ? h('div', { class: 'small muted' }, r.description) : null), btn);
      })
      : h('p', { class: 'muted' }, 'No articles found.'));
    return h('div', { class: 'card' }, h('h2', {}, 'Save an article to this Kindle'),
      h('div', { class: 'row' }, input, h('button', { class: 'btn', onclick: run }, 'Search')),
      rows,
      h('p', { class: 'small muted' }, 'The Kindle downloads it over its own Wi-Fi; it shows under Saved there.'));
  },

  recent(s) {
    const page = this;
    if (!s.recent.length) return null;
    return h('div', { class: 'card' }, h('h2', {}, 'Recent on this Kindle'), s.recent.slice(0, 30).map((e) =>
      h('div', { class: 'spread', style: 'padding:8px 0;border-top:1px solid var(--line)' },
        h('div', {}, e.title, h('span', { class: 'muted small' }, ' · ' + page.when(e.time))),
        h('div', { class: 'row', style: 'white-space:nowrap' },
          h('a', { class: 'small', target: '_blank', rel: 'noopener', href: 'https://' + e.lang + '.wikipedia.org/wiki/' + encodeURIComponent(e.title.replace(/ /g, '_')) }, 'Read on wikipedia.org'),
          e.saved ? h('span', { class: 'muted small' }, 'Saved')
            : h('button', { class: 'btn small', onclick: (ev) => page.save(e.title, e.lang, ev.target) }, 'Save to Kindle')))));
  },
};
