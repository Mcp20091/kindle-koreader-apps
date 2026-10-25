// KOReader: its folders (home, downloads, screenshots… and your folder shortcuts), its most-used settings
// (the launcher's appskosettings.lua), and KOReader's whole menu as it is now on the Kindle (switches flip here; dialogs open on the Kindle).
App.pages.koreader = {
  menuPath: [],

  async render(main) {
    const page = this;
    main.append(h('h1', {}, 'KOReader'),
      h('p', { class: 'sub' }, 'KOReader’s own settings, as on the Kindle.'));
    const folders = h('div', { class: 'card stack' }, h('h2', {}, 'Folders'));
    const common = h('div', { class: 'card stack', style: 'margin-top:16px' });
    const menu = h('div', { class: 'card stack', style: 'margin-top:16px' });
    main.append(folders, common,
      h('p', { class: 'muted small', style: 'margin-top:16px' }, 'Fonts have their own tab: ', h('a', { href: '#fonts' }, 'Fonts'), '.'),
      menu);
    this.folders(folders);
    this.common(common);
    this.menu(menu);
  },

  // ------------------------------------------------------------------ common settings

  // The same list as the Kindle's Settings > KOReader (with the launcher); without it, Sleep alone.
  async common(box) {
    const page = this;
    const c = await App.api('/api/koreader/common').catch(() => ({}));
    if (!c.available) { box.append(h('h2', {}, 'Sleep')); return this.power(box); }
    box.append(h('h2', {}, 'Common settings'));
    const post = (key, value) => App.api('/api/koreader/common', { json: { key, value } }).then((r) => {
      if (r && r.message) App.toast(r.message); else App.toast('Saved');
      box.replaceChildren(); page.common(box);
    }, App.fail);
    for (const it of App.arr(c.items)) {
      let control;
      if (it.kind === 'switch') {
        control = App.toggle(it.value === true, (on) => post(it.key, on));
      } else {
        const options = App.arr(it.options);
        control = App.select(options.map(([label, value]) => [String(value), label]), String(it.value), (v) => {
          const o = options.find(([, value]) => String(value) === v);
          post(it.key, o ? o[1] : v);
        });
      }
      box.append(App.setting(it.name, control, it.note || undefined));
    }
  },

  // ------------------------------------------------------------------ folders

  async folders(box) {
    const page = this;
    let f;
    try { f = await App.api('/api/koreader/folders'); } catch (e) { box.append(h('p', { class: 'muted small' }, 'Not available.')); return; }
    const post = async (json) => {
      const r = await App.api('/api/koreader/folders', { json }).catch(App.fail);
      if (r) { box.replaceChildren(h('h2', {}, 'Folders')); page.folders(box); }
    };
    box.append(
      h('div', { class: 'list-rows' }, App.arr(f.folders).map((d) => h('div', {},
        h('div', { class: 'grow' }, h('div', {}, d.name), h('div', { class: 'muted small' }, d.path || 'Not set')),
        h('button', { class: 'btn small', onclick: async () => {
          const path = await App.pickFolder(d.name, d.path, f.root);
          if (path) post({ key: d.key, path });
        } }, 'Change…')))),
      App.setting('Lock home folder', App.toggle(f.lock === true, (on) => post({ lock: on })), 'The library can’t go above the home folder.'),
      h('h3', {}, 'Folder shortcuts'),
      App.arr(f.shortcuts).length ? h('div', { class: 'list-rows' }, App.arr(f.shortcuts).map((s) => h('div', {},
        h('div', { class: 'grow' }, h('div', {}, s.name), h('div', { class: 'muted small' }, s.folder)),
        h('button', { class: 'btn small', onclick: async () => {
          const name = await App.prompt('Rename shortcut', s.name);
          if (name) post({ rename: { folder: s.folder, name } });
        } }, 'Rename'),
        h('button', { class: 'btn small danger', onclick: async () => {
          if (await App.confirm('Remove shortcut', 'Remove the shortcut “' + s.name + '”? The folder stays.', 'Remove', true)) post({ remove: s.folder });
        } }, 'Remove')))) : h('p', { class: 'muted small' }, 'None yet.'),
      h('div', {}, h('button', { class: 'btn', onclick: async () => {
        const folder = await App.pickFolder('Add a folder shortcut', null, f.root);
        if (!folder) return;
        const name = await App.prompt('Shortcut name', folder.replace(/\/+$/, '').split('/').pop());
        if (name !== null) post({ add: { folder, name } });
      } }, 'Add shortcut…')));
  },

  // ------------------------------------------------------------------ power

  async power(box) {
    const p = await App.api('/api/koreader/power').catch(() => ({}));
    if (!p.available) { box.append(h('p', { class: 'muted small' }, 'KOReader’s Autosuspend isn’t available on this device.')); return; }
    // On a Kindle its power manager sleeps after 10 minutes without KOReader's timer: no Never there.
    const choices = [...(p.kindle ? [] : [[-1, 'Never']]), [300, 'After 5 min'], [600, 'After 10 min'], [900, 'After 15 min'], [1200, 'After 20 min'],
      [1800, 'After 30 min'], [2700, 'After 45 min'], [3600, 'After 1 hour'], [7200, 'After 2 hours']];
    const now = p.suspend > 0 ? p.suspend : -1;
    if (now > 0 && !choices.find((c) => c[0] === now)) choices.push([now, 'After ' + Math.round(now / 60) + ' min']);
    box.append(App.setting('Sleep after', App.select(choices.map(([v, t]) => [String(v), t]), String(now),
      (v) => App.api('/api/koreader/power', { json: { suspend: Number(v) } }).then(() => App.toast('Saved'), App.fail)),
      'How long the Kindle waits with nothing happening before it goes to sleep. The Home Assistant dashboard and the web server can keep it awake.'));
  },

  // ------------------------------------------------------------------ the menu

  async menu(box) {
    const page = this;
    const draw = async () => {
      let m;
      try { m = await App.api('/api/koreader/menu?path=' + page.menuPath.join('.')); } catch (e) {
        if (page.menuPath.length) { page.menuPath = []; return draw(); }
        box.replaceChildren(h('h2', {}, 'KOReader’s menu'), h('p', { class: 'muted small' }, e.message));
        return;
      }
      const tabs = App.arr(m.tabs);
      if (!page.menuPath.length) page.menuPath = [Math.max(1, tabs.findIndex((t) => t === 'Settings') + 1)];
      if (!m.items) return draw();
      const trail = App.arr(m.trail);
      const crumbs = h('div', { class: 'row small' }, trail.map((t, i) => [i ? ' › ' : null,
        i < trail.length - 1 ? h('a', { href: '#koreader', onclick: (e) => { e.preventDefault(); page.menuPath = page.menuPath.slice(0, i + 1); draw(); } }, t) : h('strong', {}, t)]));
      const rows = App.arr(m.items).map((it, i) => {
        if (!it) return null;
        const path = page.menuPath.concat(i + 1);
        const mark = it.checked != null ? (it.radio ? (it.checked ? '◉' : '○') : (it.checked ? '☑' : '☐')) : '';
        const row = h('div', { class: 'menu-item' + (it.enabled ? '' : ' off') + (it.separator ? ' sep' : '') },
          h('span', { class: 'mark' }, mark),
          h('span', { class: 'grow' }, it.text),
          it.help ? h('span', { class: 'muted small', title: it.help }, 'ⓘ') : null,
          it.hold ? h('button', { class: 'icon-btn', title: 'Long-press (as holding it on the Kindle)', onclick: (e) => { e.stopPropagation(); tap(path, true); } }, '⋯') : null,
          it.sub ? h('span', { class: 'muted' }, '›') : null);
        if (it.enabled && (it.sub || it.action)) {
          row.classList.add('tappable');
          row.addEventListener('click', () => {
            if (it.sub) { page.menuPath = path; draw(); } else tap(path, false);
          });
        }
        return row;
      });
      box.replaceChildren(...[
        h('div', { class: 'spread' }, h('h2', {}, 'KOReader’s menu'),
          App.tabs(tabs.map((t, i) => [String(i + 1), t]), String(page.menuPath[0]), (k) => { page.menuPath = [Number(k)]; draw(); })),
        h('p', { class: 'muted small' }, (m.book ? 'The menu of the book open on the Kindle. ' : 'The library’s menu. ') +
          'Switches change here; a choice that opens a dialog opens it on the Kindle, shown below to finish with the remote.'),
        crumbs,
        page.menuPath.length > 1 ? h('div', {}, h('button', { class: 'btn small', onclick: () => { page.menuPath.pop(); draw(); } }, '‹ Back')) : null,
        h('div', { class: 'menu-list' }, rows),
        remote].filter(Boolean));
    };
    const remote = h('div');
    const tap = async (path, hold) => {
      const r = await App.api('/api/koreader/menu/tap', { json: { path: path.join('.'), hold } }).catch(App.fail);
      if (!r) return;
      if (r.opened) {
        remote.replaceChildren(App.remote({ show: true, title: 'On the Kindle', hint: 'That opened on the Kindle. Finish it here: click the picture to tap the Kindle there.' }));
        remote.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
      setTimeout(draw, r.opened ? 400 : 0);
    };
    box.append(h('h2', {}, 'KOReader’s menu'), h('p', { class: 'muted small' }, 'Loading…'));
    draw();
  },
};

// A folder on the Kindle, picked by browsing (null when cancelled). start: an absolute path to begin in; root: the storage root.
App.pickFolder = function (title, start, root) {
  const rel = (p) => (p && root && p.startsWith(root) ? (p.slice(root.length) || '/') : '/');
  let at = rel(start);
  const list = h('div', { class: 'list-rows', style: 'max-height:50vh;overflow:auto' });
  const where = h('div', { class: 'small muted' });
  const load = async () => {
    const d = await App.api('/api/files?path=' + encodeURIComponent(at)).catch(() => null);
    if (!d) { at = '/'; return load(); }
    at = d.path;
    where.textContent = root + (at === '/' ? '' : at);
    const dirs = App.arr(d.entries).filter((e) => e.dir);
    list.replaceChildren(
      at !== '/' ? h('div', { class: 'tappable', onclick: () => { at = at.replace(/\/[^/]+$/, '') || '/'; load(); } }, '↩  Up a folder') : null,
      ...dirs.map((e) => h('div', { class: 'tappable', onclick: () => { at = (at === '/' ? '' : at) + '/' + e.name; load(); } }, '📁  ' + e.name)),
      dirs.length ? null : h('div', { class: 'muted small' }, 'No folders inside.'));
  };
  load();
  return App.modal(title, h('div', { class: 'stack' }, where, list),
    [{ text: 'Cancel', result: null }, { text: 'Choose this folder', primary: true, value: () => root + (at === '/' ? '' : at) }], true);
};
