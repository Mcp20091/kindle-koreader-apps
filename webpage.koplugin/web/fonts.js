// Fonts: every font KOReader can use, each in its own typeface (loaded as it scrolls into view);
// adding (files, a zip, or a Google Fonts family the Kindle fetches), removing with Undo,
// the default for new books and the font settings. The work is the launcher's appsfonts.lua
// (webfonts.lua has the routes); the Kindle's Fonts screen uses the same code.
App.pages.fonts = {
  async render(main) {
    main.append(h('h1', {}, 'Fonts'),
      h('p', { class: 'sub' }, 'The fonts books use, as on the Kindle’s Fonts screen.'));
    const box = h('div', { class: 'card stack' });
    main.append(box);
    this.fonts(box);
  },

  // KOReader reads its fonts at start: changes need a restart.
  changedFonts: false,

  async fonts(box) {
    const page = this;
    let data;
    try { data = await App.api('/api/fonts'); } catch (e) { box.append(h('h2', {}, 'Fonts'), h('p', { class: 'muted small' }, 'Not available.')); return; }
    const reload = () => { box.replaceChildren(); page.fonts(box); };
    const changed = () => { page.changedFonts = true; reload(); };

    // After a change: KOReader shows it after a restart.
    const restart = page.changedFonts ? h('div', { class: 'row', style: 'margin:6px 0' },
      h('span', { class: 'small' }, 'KOReader reads its fonts when it starts: restart it to use the change in books.'),
      h('button', { class: 'btn small primary', onclick: async () => {
        if (!await App.confirm('Restart KOReader', 'Restart KOReader? The web server stops; start it again on the Kindle.', 'Restart', true)) return;
        await App.api('/api/kindle/control', { json: { action: 'restart' } }).catch(App.fail);
        App.toast('KOReader is restarting…');
      } }, 'Restart KOReader')) : null;

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

    // Google Fonts: the Kindle gets the family itself.
    const gName = h('input', { type: 'text', placeholder: 'A family name, such as Lora', style: 'flex:1;min-width:160px' });
    const gStatus = h('div', { class: 'small muted' });
    const poll = async () => {
      const g = await App.api('/api/fonts/google').catch(() => ({}));
      if (g.status === 'getting') { gStatus.textContent = 'Getting ' + g.family + ' from Google Fonts…'; setTimeout(poll, 2000); return; }
      if (g.status === 'done') { App.toast('Added ' + g.family + ': ' + App.arr(g.files).join(', ')); changed(); }
      else if (g.status === 'failed') gStatus.textContent = g.message || 'It didn’t work.';
    };
    const getGoogle = async () => {
      const family = gName.value.trim();
      if (!family) return;
      const r = await App.api('/api/fonts/google', { json: { family } }).catch(App.fail);
      if (r) poll();
    };
    gName.addEventListener('keydown', (e) => { if (e.key === 'Enter') getGoogle(); });

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
      const setDefault = () => App.api('/api/fonts/default', { json: { family: fam.name } })
        .then(() => { App.toast(fam.name + ' is now the default for new books'); reload(); }, App.fail);
      // A big font (such as a CJK one) isn't sent for the preview: sending it would hold the Kindle up.
      const tooBig = (regular.size || 0) > 3 * 1024 * 1024;
      const row = h('div', { class: 'font-row', 'data-id': String(regular.id) },
        h('div', { class: 'font-name' }, fam.name),
        h('div', { class: 'font-sample' }, tooBig ? 'Too big to show here (' + App.size(regular.size) + ')' : sample),
        h('div', { class: 'small muted', style: 'margin-bottom:6px' }, [...new Set(faces.map((f) => f.style))].join(' · ')),
        h('div', { class: 'row' },
          h('span', { class: 'pill' + (fam.added ? ' ok' : '') }, fam.added ? 'Added by you' : 'Built-in'),
          fam.default ? h('span', { class: 'pill ok' }, 'Default for new books')
            : h('button', { class: 'btn small', onclick: setDefault }, 'Set as default'),
          added.length ? h('button', { class: 'btn small danger', onclick: remove }, 'Remove') : null));
      if (watch && !tooBig) watch.observe(row);
      return row;
    });

    // KOReader's font settings: the same ones as its menus (and the Kindle's Common settings).
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
    const settings = App.arr(data.settings);
    const plain = settings.filter((it) => !it.advanced);
    const advanced = settings.filter((it) => it.advanced);
    const settingsBox = settings.length ? h('div', {},
      h('p', { class: 'muted small' }, 'Except the fallback fonts, these are the defaults for books you haven’t opened yet: a book you’ve already opened keeps its own.'),
      ...plain.map((it) => App.setting(it.name, control(it), it.note || undefined)),
      advanced.length ? h('details', {}, h('summary', { class: 'small' }, 'Advanced'),
        ...advanced.map((it) => App.setting(it.name, control(it), it.note || undefined))) : null) : null;

    box.append(h('h2', {}, 'Font settings'),
      ...(settingsBox ? [settingsBox] : []),
      h('h3', {}, 'Your fonts'),
      h('p', { class: 'muted small' }, 'The fonts KOReader can use for books. Fonts you add are kept in ' + data.dir + '.'),
      ...(restart ? [restart] : []),
      drop, picker, progress,
      h('div', { class: 'row', style: 'margin-top:10px' }, gName,
        h('button', { class: 'btn', onclick: getGoogle }, 'Get from Google Fonts')),
      gStatus,
      h('p', { class: 'muted small' }, 'The Kindle downloads the family’s regular, bold and italic styles (as many as it has) from ',
        App.link('Google Fonts', 'https://fonts.google.com'), ' (browse the families there), then adds them.'),
      h('div', { style: 'margin-top:10px' }, rows));
  },
};
