// Fonts, in three tabs as on the Kindle's Fonts screen: Your fonts (each in its own typeface, loaded
// as it scrolls into view; adding files or a zip, removing with Undo, the default for new books),
// Get more (every Google Fonts family to browse: search, a category, a sort and pages; the Kindle
// fetches the one you pick) and Settings. The work is the launcher's appsfonts.lua and
// appsgooglefonts.lua (webfonts.lua has the routes); the Kindle's Fonts screen uses the same code.
App.pages.fonts = {
  tab: 'mine',

  async render(main) {
    main.append(h('h1', {}, 'Fonts'),
      h('p', { class: 'sub' }, 'The fonts books use, as on the Kindle’s Fonts screen.'));
    const tabs = h('div', { class: 'tabs' });
    const box = h('div', { class: 'card stack' });
    main.append(tabs, box);
    const show = (tab) => {
      this.tab = tab;
      tabs.replaceChildren(...[['mine', 'Your fonts'], ['get', 'Get more'], ['settings', 'Settings']].map(([k, label]) =>
        h('button', { class: k === tab ? 'on' : '', onclick: () => show(k) }, label)));
      box.replaceChildren();
      if (tab === 'get') this.browse(box);
      else this.fonts(box, tab);
    };
    show(this.tab);
  },

  // KOReader reads its fonts at start: changes need a restart.
  changedFonts: false,

  restartNotice() {
    return this.changedFonts ? h('div', { class: 'row', style: 'margin:6px 0' },
      h('span', { class: 'small' }, 'KOReader reads its fonts when it starts: restart it to use the change in books.'),
      h('button', { class: 'btn small primary', onclick: async () => {
        if (!await App.confirm('Restart KOReader', 'Restart KOReader? The web server stops; start it again on the Kindle.', 'Restart', true)) return;
        await App.api('/api/kindle/control', { json: { action: 'restart' } }).catch(App.fail);
        App.toast('KOReader is restarting…');
      } }, 'Restart KOReader')) : null;
  },

  // Your fonts (tab "mine") or the font settings (tab "settings").
  async fonts(box, tab) {
    const page = this;
    let data;
    try { data = await App.api('/api/fonts'); } catch (e) { box.append(h('h2', {}, 'Fonts'), h('p', { class: 'muted small' }, 'Not available.')); return; }
    const reload = () => { box.replaceChildren(); page.fonts(box, tab); };
    const changed = () => { page.changedFonts = true; reload(); };

    if (tab === 'settings') {
      // KOReader's font settings: the same ones as its menus (and the Kindle's Fonts > Settings).
      const control = (it) => {
        const post = (value) => App.api('/api/fonts/setting', { json: { key: it.key, value } }).then((r) => {
          App.toast(r && r.message ? r.message : 'Saved');
          reload();
        }, App.fail);
        if (it.kind === 'switch') return App.toggle(it.value === true, post);
        const options = App.arr(it.options);
        return App.select(options.map(([label, value]) => [String(value), label]), String(it.value), (v) => {
          const o = options.find(([, value]) => String(value) === v);
          post(o ? o[1] : v);
        });
      };
      const byKey = Object.fromEntries(App.arr(data.settings).map((it) => [it.key, it]));
      const group = (title, keys, note) => {
        const items = keys.map((k) => byKey[k]).filter(Boolean);
        if (!items.length) return [];
        return [h('h3', {}, title), note ? h('p', { class: 'muted small' }, note) : null,
          ...items.map((it) => App.setting(it.name, control(it), it.note || undefined))];
      };
      box.append(...[h('h2', {}, 'Font settings'),
        ...group('New books', ['font', 'font_size', 'weight', 'embedded'], 'A book you’ve already opened keeps its own.'),
        ...group('Fallback fonts', ['fallback', 'more_fallbacks']),
        ...group('Advanced', ['hinting', 'kerning'])].filter(Boolean));
      return;
    }

    // Adding: files or a zip, dropped or picked.
    const progress = h('div', { class: 'small' });
    const upload = async (files) => {
      let any = false;
      for (const f of files) {
        progress.textContent = 'Adding ' + f.name + '…';
        try {
          const r = await new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('PUT', '/api/fonts/upload?name=' + encodeURIComponent(f.name));
            xhr.upload.onprogress = (ev) => { if (ev.lengthComputable) progress.textContent = 'Adding ' + f.name + ' · ' + Math.round(ev.loaded / ev.total * 100) + '%'; };
            xhr.onload = () => { const j = JSON.parse(xhr.responseText || '{}'); if (xhr.status < 300) resolve(j); else reject(new Error(j.error || 'Upload failed')); };
            xhr.onerror = () => reject(new Error('Upload failed: the Kindle stopped responding'));
            xhr.send(f);
          });
          App.toast('Added ' + App.arr(r.added).join(', '));
          any = true;
        } catch (e) { App.toast(f.name + ': ' + e.message, true); }
      }
      progress.textContent = '';
      if (any) changed();
    };
    const picker = h('input', { type: 'file', multiple: true, accept: '.ttf,.otf,.ttc,.zip', style: 'display:none', onchange: () => upload([...picker.files]) });
    const drop = h('div', { class: 'drop' }, 'Drop TTF or OTF files (or a zip of a family) here, or ',
      h('a', { href: '#', onclick: (e) => { e.preventDefault(); picker.click(); } }, 'pick them'), '.');
    drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('over'); });
    drop.addEventListener('dragleave', () => drop.classList.remove('over'));
    drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('over'); upload([...e.dataTransfer.files]); });

    // The list: a family's name and a line in its own typeface, loaded when it scrolls into view.
    const sample = 'The quick brown fox jumps over the lazy dog. 0123456789';
    const watch = 'IntersectionObserver' in window && 'FontFace' in window ? new IntersectionObserver((seen) => {
      for (const s of seen) {
        if (!s.isIntersecting) continue;
        const el = s.target;
        watch.unobserve(el);
        const name = 'kf' + el.dataset.id;
        new FontFace(name, 'url(/api/fonts/file?id=' + el.dataset.id + ')').load().then((f) => {
          document.fonts.add(f);
          el.querySelectorAll('.font-name,.font-sample').forEach((n) => { n.style.fontFamily = "'" + name + "', serif"; });
        }).catch(() => {});
      }
    }, { rootMargin: '200px' }) : null;
    // Set as default, with Undo (as on the Kindle).
    const setDefault = (family) => {
      const before = data.default;
      App.api('/api/fonts/default', { json: { family } }).then(() => {
        reload();
        if (before) App.undo('New books open in ' + family, () => App.api('/api/fonts/default', { json: { family: before } }).then(reload, App.fail));
      }, App.fail);
    };
    const rows = App.arr(data.families).map((fam) => {
      const faces = App.arr(fam.faces);
      const regular = faces.find((f) => f.style === 'Regular') || faces[0];
      const added = faces.filter((f) => f.added);
      const remove = async () => {
        const tokens = [];
        for (const f of added) {
          const r = await App.api('/api/fonts/remove', { json: { id: f.id } }).catch(App.fail);
          if (r && r.token) tokens.push(r.token);
        }
        if (!tokens.length) return;
        changed();
        App.undo('Removed ' + fam.name, async () => {
          for (const token of tokens) await App.api('/api/fonts/undo', { json: { token } }).catch(App.fail);
          changed();
        });
      };
      // A big font (such as a CJK one) isn't sent for the preview: sending it would hold the Kindle up.
      const tooBig = (regular.size || 0) > 3 * 1024 * 1024;
      const row = h('div', { class: 'font-row', 'data-id': String(regular.id) },
        h('div', { class: 'font-name' }, fam.name),
        h('div', { class: 'font-sample' }, tooBig ? 'Too big to show here (' + App.size(regular.size) + ')' : sample),
        h('div', { class: 'small muted', style: 'margin-bottom:6px' }, [...new Set(faces.map((f) => f.style))].join(' · ')),
        h('div', { class: 'row' },
          h('span', { class: 'pill' + (fam.added ? ' ok' : '') }, fam.added ? 'Added by you' : 'Built-in'),
          fam.default ? h('span', { class: 'pill ok' }, '✓ Default for new books')
            : h('button', { class: 'btn small', onclick: () => setDefault(fam.name) }, 'Set as default'),
          added.length ? h('button', { class: 'btn small danger', onclick: remove }, 'Remove') : null));
      if (watch && !tooBig) watch.observe(row);
      return row;
    });

    // (Empty parts left out: append() would write "null".)
    box.append(...[h('h2', {}, 'Your fonts'),
      h('p', {}, h('span', { class: 'muted' }, 'New books open in '), h('b', {}, data.default || '')),
      h('p', { class: 'muted small' }, 'The fonts KOReader can use for books. Fonts you add are kept in ' + data.dir + '. More from Google Fonts: the Get more tab.'),
      this.restartNotice(),
      drop, picker, progress,
      h('div', { style: 'margin-top:10px' }, rows)].filter(Boolean));
  },

  // Get more: every Google Fonts family, as on the Kindle's Get more tab.
  q: '', cat: 'suggested', sort: 'popular', page: 1,

  async browse(box) {
    const page = this;
    const reload = () => { if (page.tab === 'get' && box.isConnected) { box.replaceChildren(); page.browse(box); } };
    let r, mine, g;
    try {
      [r, mine, g] = await Promise.all([
        App.api('/api/fonts/catalogue?' + new URLSearchParams({ q: page.q, cat: page.cat, sort: page.sort, page: page.page, per: 24 })),
        App.api('/api/fonts').catch(() => ({})),
        App.api('/api/fonts/google').catch(() => ({})),
      ]);
    } catch (e) { box.append(h('h2', {}, 'Get more fonts'), h('p', { class: 'muted small' }, e.message || 'Not available.')); return; }
    const st = App.obj(r.state);
    const have = new Set(App.arr(mine.families).map((f) => String(f.name).toLowerCase()));
    const getting = g.status === 'getting' ? g.family : null;
    // While the list or a family is on its way: look again in a moment.
    if (st.status === 'getting' || getting) setTimeout(reload, 2000);

    const get = async (family) => {
      if (getting) { App.toast('Still getting ' + getting); return; }
      const ok = await App.api('/api/fonts/google', { json: { family } }).catch(App.fail);
      if (!ok) return;
      const poll = async () => {
        const s = await App.api('/api/fonts/google').catch(() => ({}));
        if (s.status === 'getting') { setTimeout(poll, 2000); return; }
        if (s.status === 'done') { page.changedFonts = true; App.toast('Added ' + s.family + ': ' + App.arr(s.files).join(', ')); }
        else if (s.status === 'failed') App.toast(s.message || 'It didn’t work.', true);
        reload();
      };
      reload();
      setTimeout(poll, 2000);
    };
    const go = (field, value) => { page[field] = value; page.page = 1; reload(); };

    // Search, as you type.
    let timer;
    const search = h('input', { type: 'search', value: page.q, style: 'flex:1;min-width:180px',
      placeholder: st.count ? 'Search ' + Number(st.count).toLocaleString() + ' families' : 'Search Google Fonts' });
    search.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => go('q', search.value.trim()), 400); });
    const chips = [['suggested', 'Suggested'], ['all', 'All'], ...App.arr(r.categories)].map(([k, label]) =>
      h('button', { class: 'btn small' + (k === page.cat ? ' primary' : ''), onclick: () => go('cat', k) }, label));
    const sort = (page.cat !== 'suggested' || page.q) ? App.select(App.arr(r.sorts), page.sort, (v) => go('sort', v)) : null;
    const listLine = st.status === 'getting' ? h('span', { class: 'small muted' }, 'Getting the list…')
      : st.at ? h('span', { class: 'small muted' }, 'List from ' + new Date(st.at * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) + ' · ',
        h('a', { href: '#', onclick: (e) => {
          e.preventDefault();
          App.api('/api/fonts/catalogue/update', { json: {} }).then(() => setTimeout(reload, 1000), App.fail);
        } }, 'Update')) : null;

    // A family's name in its own typeface, straight from Google Fonts (just the letters of its name).
    const preview = (name) => {
      const id = 'gf-' + name.replace(/[^A-Za-z0-9]/g, '');
      if (!document.getElementById(id)) {
        document.head.append(h('link', { id, rel: 'stylesheet',
          href: 'https://fonts.googleapis.com/css2?family=' + encodeURIComponent(name) + '&text=' + encodeURIComponent(name) + '&display=swap' }));
      }
      return "'" + name + "', sans-serif";
    };
    const row = (name, detail) => h('div', { class: 'font-row row', style: 'justify-content:space-between' },
      h('div', {}, h('div', { class: 'font-name', style: 'font-family:' + preview(name) }, name),
        detail ? h('div', { class: 'small muted' }, detail) : null),
      have.has(name.toLowerCase()) ? h('span', { class: 'pill ok' }, 'Installed')
        : getting === name ? h('span', { class: 'pill' }, 'Getting…')
          : h('button', { class: 'btn small', onclick: () => get(name) }, 'Get'));

    const rows = [];
    if (page.q && !r.exact) rows.push(row(page.q, 'Get it by its name from Google Fonts'));
    for (const e of App.arr(r.items)) {
      const parts = [e.category, e.styles, e.note].filter(Boolean);
      rows.push(row(e.name, parts.join(' · ')));
    }
    let empty = null;
    if (!r.total && !(page.cat === 'suggested' && !page.q)) {
      empty = st.status === 'getting' ? 'Getting the list of every family from Google Fonts…'
        : !st.count ? (st.message || 'The list of every family comes from Google Fonts, over the Kindle’s Wi-Fi.')
          : page.q ? 'Nothing in the list matches “' + page.q + '”.' : 'No families here.';
    }
    const pages = r.pages || 1;
    const pager = pages > 1 ? h('div', { class: 'row', style: 'justify-content:center;margin-top:10px' },
      h('button', { class: 'btn small', disabled: page.page <= 1, onclick: () => { page.page -= 1; reload(); } }, '‹ Previous'),
      h('span', { class: 'small muted' }, 'Page ' + page.page + ' of ' + pages),
      h('button', { class: 'btn small', disabled: page.page >= pages, onclick: () => { page.page += 1; reload(); } }, 'Next ›')) : null;

    box.append(...[h('h2', {}, 'Get more fonts'),
      h('p', { class: 'muted small' }, 'Free from ', App.link('Google Fonts', 'https://fonts.google.com'),
        ': the Kindle gets the family’s regular, bold and italic styles (as many as it has) over its Wi-Fi.'),
      this.restartNotice(),
      h('div', { class: 'row' }, search),
      h('div', { class: 'row', style: 'flex-wrap:wrap;gap:6px' }, chips),
      h('div', { class: 'row', style: 'justify-content:space-between' }, sort || h('span'), listLine),
      h('div', {}, rows),
      empty ? h('p', { class: 'muted' }, empty) : null,
      !st.count && st.status !== 'getting' && page.cat !== 'suggested' ? h('button', { class: 'btn', onclick: () =>
        App.api('/api/fonts/catalogue/update', { json: {} }).then(() => setTimeout(reload, 1000), App.fail) }, 'Get the list') : null,
      pager].filter(Boolean));
    if (page.q) { search.focus(); search.setSelectionRange(search.value.length, search.value.length); }
  },
};
