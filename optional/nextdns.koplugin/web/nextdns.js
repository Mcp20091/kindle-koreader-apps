// NextDNS (the optional NextDNS plugin): the profile's numbers for today, the domains blocked most, whether
// the Kindle goes through NextDNS, the query log (All, Blocked or Allowed, and a search), the denylist and
// allowlist, the protection switches, the profile, and its settings. The Kindle reads NextDNS; the page reads
// the Kindle's state again every 60 seconds while it's open, and a moment after each change.
App.pages.nextdns = {
  timer: null,
  asked: false,

  async render(main) {
    clearTimeout(this.timer);
    const s = await App.api('/api/nextdns');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'NextDNS isn’t installed on this Kindle. It’s an optional app: copy nextdns.koplugin to koreader/plugins.')); return; }
    ['top', 'deny', 'allow', 'switches', 'profiles'].forEach((k) => { s[k] = App.arr(s[k]); });
    s.logs = App.obj(s.logs);
    main.append(
      h('div', {}, h('h1', {}, 'NextDNS'), h('p', { class: 'sub' }, 'Your ',
        App.link('NextDNS', 'https://nextdns.io'), ' profile, over NextDNS’s API.')),
      ...[this.status(s), this.top(s), this.logs(s), this.list(s, 'deny'), this.list(s, 'allow'), this.protection(s), this.settings(s)].filter(Boolean));
    // (the query log is read by the Kindle once, when the tab first opens)
    if (s.summary && !s.logs.items && !s.logs.reading && !this.asked) {
      this.asked = true;
      this.act('logs', {});
    }
    if (s.configured) {
      this.timer = setTimeout(() => {
        if (main.isConnected && location.hash.startsWith('#nextdns') && !document.querySelector('.modal')) this.reload();
      }, s.logs.reading ? 2000 : 60000);
    }
  },

  reload() { App.route(); },

  async act(name, args, done) {
    try {
      await App.api('/api/nextdns/act', { json: { name, args } });
      if (done) App.toast(done);
      setTimeout(() => this.reload(), 2000);
    } catch (e) { App.fail(e); }
  },

  row(name, line, ...right) {
    return h('div', { class: 'spread', style: 'padding:6px 0;border-top:1px solid var(--line);gap:10px' },
      h('div', {}, h('div', {}, name), line ? h('div', { class: 'small muted' }, line) : null),
      h('div', { class: 'row', style: 'gap:10px;white-space:nowrap' }, ...right.filter(Boolean)));
  },

  status(s) {
    const page = this;
    if (!s.configured) {
      return h('div', { class: 'card' }, h('h2', { style: 'margin-top:0' }, 'NextDNS isn’t set up yet'),
        h('p', { class: 'muted' }, 'Enter your NextDNS account’s API key below (on NextDNS’s website: Account, then API at the bottom), then pick the profile. Or use Set up in NextDNS on the Kindle.'));
    }
    if (!s.summary) {
      return h('div', { class: 'card' }, h('h2', { style: 'margin-top:0' }, s.name),
        h('p', { class: 'muted' }, s.why || 'Reading NextDNS…'),
        h('button', { class: 'btn', onclick: () => page.act('refresh', {}) }, 'Try again'));
    }
    const st = App.obj(s.stats);
    const k = App.obj(s.kindle);
    return h('div', { class: 'card' },
      h('div', { class: 'spread' },
        h('div', {}, h('h2', { style: 'margin:0' }, s.name),
          h('div', { style: 'font-size:22px;font-weight:700;margin-top:6px' }, s.summary),
          h('div', { class: 'muted small' }, st.totalText + ' queries today · ' + st.blockedText + ' blocked (' + st.percent + ')')),
        h('div', { class: 'row', style: 'white-space:nowrap;gap:6px' },
          h('button', { class: 'btn small', onclick: () => page.act('refresh', {}, 'Reading NextDNS…') }, 'Refresh'))),
      h('p', {}, h('span', { class: 'pill ' + (k.using ? 'ok' : 'bad') }, k.text || 'Not checked yet'),
        h('span', { class: 'small muted' }, ' This Kindle' + (k.sub ? ' · ' + k.sub : ''))),
      h('p', { class: 'small muted' }, (s.read ? 'Read ' + App.ago(s.read) : '') + (s.why ? ' · ' + s.why : '')));
  },

  // Block or allow a domain (from the top blocked or the log).
  domainButtons(s, domain) {
    const on = (list) => s[list].some((e) => e.id === domain || e.domain === domain);
    return [
      on('deny') ? null : h('button', { class: 'btn small', onclick: () => this.act('list_add', { list: 'deny', domain }, domain + ' blocked') }, 'Block'),
      on('allow') ? null : h('button', { class: 'btn small', onclick: () => this.act('list_add', { list: 'allow', domain }, domain + ' allowed') }, 'Allow'),
    ];
  },

  top(s) {
    if (!s.summary || !s.top.length) return null;
    return h('div', { class: 'card' }, h('h2', {}, 'Blocked most today'),
      ...s.top.map((x) => this.row(x.domain, null, h('span', { class: 'small muted' }, x.queries), ...this.domainButtons(s, x.domain))));
  },

  logs(s) {
    if (!s.summary) return null;
    const page = this;
    const L = s.logs;
    const search = h('input', { type: 'text', value: L.search || '', placeholder: 'example' });
    const run = () => page.act('logs', { search: search.value.trim() });
    search.addEventListener('keydown', (e) => { if (e.key === 'Enter') run(); });
    const items = App.arr(L.items);
    return h('div', { class: 'card' }, h('h2', {}, 'Recent queries'),
      App.tabs([['all', 'All'], ['blocked', 'Blocked'], ['allowed', 'Allowed']], L.filter || 'all', (f) => page.act('logs', { filter: f })),
      h('div', { class: 'row', style: 'gap:8px;margin:10px 0' }, search,
        h('button', { class: 'btn', onclick: run }, 'Search'),
        L.search ? h('button', { class: 'btn', onclick: () => page.act('logs', { search: '' }) }, 'Clear') : null,
        h('button', { class: 'btn', onclick: () => page.act('logs', {}) }, 'Refresh')),
      L.reading && !items.length ? h('p', { class: 'muted' }, 'Reading the queries…') : null,
      L.why ? h('p', { class: 'muted small' }, L.why) : null,
      L.items && !items.length ? h('p', { class: 'muted' }, L.search ? 'No queries with “' + L.search + '”.' : 'No queries yet.') : null,
      ...items.map((e) => this.row(e.domain, e.line,
        e.statusText ? h('span', { class: 'pill ' + (e.status === 'blocked' ? 'bad' : 'ok') }, e.statusText) : null,
        ...this.domainButtons(s, e.domain))),
      L.more ? h('button', { class: 'btn', style: 'margin-top:8px', onclick: () => page.act('logs', { more: true }) }, 'Show more') : null);
  },

  list(s, which) {
    if (!s.summary) return null;
    const page = this;
    const name = which === 'deny' ? 'Denylist' : 'Allowlist';
    const other = which === 'deny' ? 'allow' : 'deny';
    const add = h('input', { type: 'text', placeholder: 'example.com' });
    const doAdd = () => { if (add.value.trim()) page.act('list_add', { list: which, domain: add.value.trim() }, add.value.trim() + ' added'); };
    add.addEventListener('keydown', (e) => { if (e.key === 'Enter') doAdd(); });
    return h('div', { class: 'card' }, h('h2', {}, name),
      h('p', { class: 'small muted' }, which === 'deny' ? 'Blocked with all their subdomains.' : 'Never blocked, with all their subdomains.'),
      s[which].length ? null : h('p', { class: 'muted' }, 'Nothing on the ' + name.toLowerCase() + ' yet.'),
      ...s[which].map((e) => this.row(e.domain, null,
        h('button', { class: 'btn small', onclick: () => page.act('list_add', { list: other, domain: e.domain })
          .then(() => page.act('list_delete', { list: which, domain: e.domain }, 'Moved to the ' + (other === 'deny' ? 'denylist' : 'allowlist'))) }, 'Move'),
        h('button', { class: 'btn small', onclick: () => {
          page.act('list_delete', { list: which, domain: e.domain });
          App.undo(e.domain + ' deleted', () => page.act('list_add', { list: which, domain: e.domain, active: e.active }));
        } }, 'Delete'),
        App.toggle(!!e.active, (v) => page.act('list_active', { list: which, domain: e.domain, on: v }, e.domain + (v ? ' turned on' : ' turned off'))))),
      h('div', { class: 'row', style: 'gap:8px;margin-top:10px' }, add, h('button', { class: 'btn', onclick: doAdd }, 'Add')));
  },

  protection(s) {
    if (!s.summary) return null;
    const page = this;
    const groups = [['security', 'Security'], ['privacy', 'Privacy'], ['parentalControl', 'Parental control']];
    return h('div', { class: 'card' }, h('h2', {}, 'Protection'),
      ...groups.flatMap(([g, title]) => [h('h3', {}, title),
        ...s.switches.filter((x) => x.group === g).map((x) => App.setting(x.name,
          App.toggle(!!x.on, (v) => page.act('switch', { key: x.key, on: v }, x.name + (v ? ': on' : ': off'))), x.sub))]),
      h('p', { class: 'small muted' }, 'The rest (blocklists, native tracking, the services and categories of parental control) is on ',
        App.link('NextDNS’s website', 'https://my.nextdns.io'), '.'));
  },

  settings(s) {
    const page = this;
    const save = (args, done) => App.api('/api/nextdns/act', { json: { name: 'settings', args } })
      .then(() => { App.toast(done || 'Saved'); setTimeout(() => page.reload(), 1500); }).catch(App.fail);
    const key = h('input', { type: 'password', value: '', placeholder: s.hasKey ? 'Saved (' + s.keyHint + '): type to change' : 'Your API key' });
    const profile = s.profiles.length
      ? App.select(s.profiles.map((p) => [p.id, p.name + ' · ' + p.id]), s.profile, (v) => page.act('profile', { id: v }, 'Profile changed'))
      : h('button', { class: 'btn', onclick: () => page.act('profiles', {}) }, s.profile ? (s.name + ' · ' + s.profile + ': change') : 'Pick');
    return h('div', { class: 'card' }, h('h2', {}, 'Settings'),
      App.setting('Read every', App.select([[30, '30 seconds'], [60, '1 minute'], [120, '2 minutes'], [300, '5 minutes'], [600, '10 minutes']],
        s.interval || 60, (v) => save({ interval: Number(v) })), 'While NextDNS is open on the Kindle. Nothing is read once it closes.'),
      h('h3', {}, 'Connection'),
      App.setting('API key', key, 'On NextDNS’s website: Account, then API at the bottom.'),
      s.hasKey ? App.setting('Profile', profile, 'The profile the Kindle shows and changes.') : null,
      h('div', { class: 'row', style: 'gap:8px;margin-top:10px' },
        h('button', { class: 'btn primary', onclick: () => { if (key.value.trim()) save({ key: key.value.trim() }, 'Saved'); } }, 'Save'),
        s.configured ? App.connectionTest('nextdns') : null));
  },
};
