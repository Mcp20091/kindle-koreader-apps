// The Files tab's Servers and catalogs card (the Kindle's Library app): FTP and WebDAV servers and OPDS
// catalogs, the same lists as KOReader's Cloud storage and OPDS catalog: add, edit, Test, delete with Undo;
// the suggested catalogs a click away; the folder downloads go to. Passwords are sent, never shown.
App.servers = (() => {
  const TYPES = [['ftp', 'FTP'], ['webdav', 'WebDAV']];
  const act = (name, args) => App.api('/api/servers/act', { json: { name, args } });

  // Test in the background on the Kindle, then what it found.
  async function test(args, out) {
    out.replaceChildren(h('span', { class: 'muted small' }, 'Connecting…'));
    try {
      const { key } = await App.api('/api/servers/test', { json: args });
      for (let i = 0; i < 70; i++) {
        await new Promise((r) => setTimeout(r, 1000));
        const t = await App.api('/api/servers/test?key=' + encodeURIComponent(key));
        if (t.status !== 'done') continue;
        if (!t.ok) {
          out.replaceChildren(h('span', { class: 'small', style: 'color:var(--danger)' }, t.why === '530' ? "It didn't accept the user and password."
            : "Couldn't connect. Check the address, the user and password, and the Kindle's Wi-Fi."));
          return;
        }
        const n = (k, one, many) => (k === 1 ? one : k + ' ' + many);
        out.replaceChildren(h('span', { class: 'small' }, args.kind === 'catalog'
          ? 'Connected: ' + (t.books ? n(t.books, '1 book', 'books') : n(t.sections, '1 section', 'sections')) + (t.search ? ', with search' : '')
          : 'Connected: ' + n(t.folders, '1 folder', 'folders') + ', ' + n(t.books, '1 book', 'books')));
        return;
      }
      out.replaceChildren(h('span', { class: 'small', style: 'color:var(--danger)' }, 'No answer in time.'));
    } catch (e) { out.replaceChildren(h('span', { class: 'small', style: 'color:var(--danger)' }, e.message)); }
  }

  // A form in a dialog: fields [key, label, type, value, hint]; buttons Test (optional), Cancel, Save.
  function form(title, fields, onTest) {
    const inputs = {};
    const rows = fields.map(([k, label, type, value, hint]) => {
      let input;
      if (type === 'select') {
        input = h('select', {}, value.options.map(([v, t]) => h('option', { value: v }, t)));
        input.value = value.value;
      } else {
        input = h('input', { type, value: value ?? '', placeholder: hint || '', style: 'width:100%', autocomplete: type === 'password' ? 'new-password' : 'off' });
      }
      inputs[k] = input;
      return h('label', { style: 'display:flex;flex-direction:column;gap:4px;margin:8px 0' }, h('span', { class: 'small muted' }, label), input);
    });
    const out = h('div', { style: 'min-height:1.4em;margin-top:6px' });
    const read = () => Object.fromEntries(Object.entries(inputs).map(([k, i]) => [k, i.value.trim()]));
    const body = h('div', {}, rows, onTest ? h('div', { class: 'row', style: 'margin-top:8px' },
      h('button', { class: 'btn small', onclick: () => onTest(read(), out) }, 'Test'), out) : null);
    return App.modal(title, body, [{ text: 'Cancel', result: null }, { text: 'Save', primary: true, value: read }]).then((v) => ({ v, inputs }));
  }

  async function editServer(s, done) {
    const fields = [
      ['type', 'Type', 'select', { options: TYPES, value: s ? s.type : 'ftp' }],
      ['name', 'Name', 'text', s ? s.name : '', 'Home NAS'],
      ['address', 'Address', 'text', s ? s.address : '', 'ftp://192.168.1.20 or https://dav.example.org/webdav'],
      ['port', 'Port', 'number', s ? s.port : '', 'Empty: 21 for FTP, 443 or 80 for WebDAV'],
      ['username', 'User', 'text', s ? s.username : '', 'Empty for anonymous'],
      ['password', 'Password', 'password', '', s && s.hasPassword ? 'Saved (leave empty to keep it)' : ''],
      ['url', 'Starting folder', 'text', s ? s.url : '', '/Books'],
    ];
    const withPassword = (f) => {
      const a = { ...f, kind: 'server', index: s ? s.index : undefined };
      if (s && s.hasPassword && !f.password) delete a.password;
      return a;
    };
    const { v } = await form(s ? 'Edit server' : 'Add a server', fields, (f, out) => test(withPassword(f), out));
    if (!v) return;
    if (!v.address) return App.toast('Type the address first', true);
    try {
      await act('saveServer', withPassword(v));
      App.toast(s ? 'Server saved' : 'Server added');
      done();
    } catch (e) { App.fail(e); }
  }

  async function editCatalog(c, done) {
    const fields = [
      ['title', 'Name', 'text', c ? c.title : '', 'My library'],
      ['url', 'Address', 'text', c ? c.url : '', 'https://example.org/opds'],
      ['username', 'User', 'text', c ? c.username : '', 'Only for a catalog that asks, such as Calibre'],
      ['password', 'Password', 'password', '', c && c.hasPassword ? 'Saved (leave empty to keep it)' : ''],
    ];
    const withPassword = (f) => {
      const a = { ...f, kind: 'catalog', index: c ? c.index : undefined };
      if (c && c.hasPassword && !f.password) delete a.password;
      return a;
    };
    const { v } = await form(c ? 'Edit catalog' : 'Add a catalog', fields, (f, out) => test(withPassword(f), out));
    if (!v) return;
    if (!v.url) return App.toast('Type the address first', true);
    try {
      await act('saveCatalog', withPassword(v));
      App.toast(c ? 'Catalog saved' : 'Catalog added');
      done();
    } catch (e) { App.fail(e); }
  }

  async function remove(name, index, what, done) {
    try {
      const r = await act(name, { index });
      done();
      App.undo('Deleted “' + what + '”', async () => { await act('restore', { key: r.undo }).catch(App.fail); done(); });
    } catch (e) { App.fail(e); }
  }

  // The card, filled in once the Kindle answers (nothing without the Library app).
  function card() {
    const el = h('div', { class: 'card', style: 'margin-top:16px' });
    const draw = async () => {
      let d;
      try { d = await App.api('/api/servers'); } catch (e) { el.replaceChildren(h('div', { class: 'empty' }, e.message)); return; }
      if (!d.installed) { el.remove(); return; }
      const servers = App.arr(d.servers);
      const catalogs = App.arr(d.catalogs);
      const suggested = App.arr(d.suggested);
      const testOut = {};
      const row = (main, sub, buttons, out) => h('div', { class: 'spread', style: 'padding:8px 0;border-top:1px solid var(--line)' },
        h('div', {}, h('div', {}, main), h('div', { class: 'small muted' }, sub), out), h('div', { class: 'row' }, buttons));
      el.replaceChildren(h('div', {},
        h('div', { class: 'spread' }, h('div', {}, h('h2', { style: 'margin:0' }, 'Servers and catalogs'),
          h('div', { class: 'small muted' }, "Places the Kindle's Library opens books from: Folders > Servers and catalogs. " +
            "The same lists as KOReader's Cloud storage and OPDS catalog."))),
        h('h3', {}, 'FTP and WebDAV servers'),
        servers.length ? servers.map((s) => {
          const out = h('div');
          testOut[s.index] = out;
          return row(s.name, s.label + (s.username ? ' · ' + s.username : ''), [
            h('button', { class: 'btn small', onclick: () => test({ kind: 'server', index: s.index }, out) }, 'Test'),
            h('button', { class: 'btn small', onclick: () => editServer(s, draw) }, 'Edit'),
            h('button', { class: 'btn small', onclick: () => remove('deleteServer', s.index, s.name, draw) }, 'Delete')], out);
        }) : h('div', { class: 'muted small' }, 'None yet.'),
        h('div', { class: 'row', style: 'margin-top:8px' }, h('button', { class: 'btn small primary', onclick: () => editServer(null, draw) }, 'Add a server')),
        d.opds ? [
          h('h3', {}, 'OPDS catalogs'),
          catalogs.map((c) => {
            const out = h('div');
            return row(c.title, c.label + (c.username ? ' · ' + c.username : ''), [
              h('button', { class: 'btn small', onclick: () => test({ kind: 'catalog', index: c.index }, out) }, 'Test'),
              h('button', { class: 'btn small', onclick: () => editCatalog(c, draw) }, 'Edit'),
              h('button', { class: 'btn small', onclick: () => remove('deleteCatalog', c.index, c.title, draw) }, 'Delete')], out);
          }),
          h('div', { class: 'row', style: 'margin-top:8px' },
            h('button', { class: 'btn small primary', onclick: () => editCatalog(null, draw) }, 'Add a catalog'),
            suggested.map((s) => h('button', { class: 'btn small', title: s.about, onclick: async () => {
              try { await act('addSuggested', { url: s.url }); App.toast('Added ' + s.title); draw(); } catch (e) { App.fail(e); }
            } }, '+ ' + s.title))),
        ] : null,
        h('h3', {}, 'Downloads'),
        App.setting('Download folder', h('div', { class: 'row' }, h('a', { href: '#files?path=' + encodeURIComponent(d.downloadDir) }, d.downloadDir),
          h('button', { class: 'btn small', onclick: async () => {
            const to = await App.prompt('Download folder', d.downloadDir, '/documents/Downloads');
            if (!to) return;
            try { await act('setDownloadDir', { path: to }); App.toast('Downloads go to ' + to); draw(); } catch (e) { App.fail(e); }
          } }, 'Change')), 'Where books from servers and catalogs go')));
    };
    draw();
    return el;
  }

  return { card };
})();
