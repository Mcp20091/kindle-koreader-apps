// Pangolin (the optional Pangolin plugin): the organization's sites, public and private resources and
// clients; resources on or off, sign-in, clients blocked or archived, the bandwidth counters reset; and its
// settings. The page reads the state again every 30 seconds while it's open.
App.pages.pangolin = {
  timer: null,

  async render(main) {
    clearTimeout(this.timer);
    const s = await App.api('/api/pangolin');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'Pangolin isn’t installed on this Kindle. It’s an optional app: copy pangolin.koplugin to koreader/plugins.')); return; }
    ['sites', 'resources', 'private', 'clients'].forEach((k) => { s[k] = App.arr(s[k]); });
    s.skipped = App.obj(s.skipped);
    main.append(
      h('div', {}, h('h1', {}, 'Pangolin'), h('p', { class: 'sub' }, 'Your ',
        App.link('Pangolin', 'https://docs.pangolin.net/self-host/advanced/integration-api'),
        ' server’s organization, over its Integration API.')),
      ...[this.status(s), this.sites(s), this.resources(s), this.privates(s), this.clients(s), this.settings(s)].filter(Boolean));
    if (s.configured) {
      this.timer = setTimeout(() => {
        if (main.isConnected && location.hash.startsWith('#pangolin') && !document.querySelector('.modal')) this.reload();
      }, 30000);
    }
  },

  reload() { App.route(); },

  async act(name, args, done) {
    try {
      await App.api('/api/pangolin/act', { json: { name, args } });
      if (done) App.toast(done);
      setTimeout(() => this.reload(), 2000);
    } catch (e) { App.fail(e); }
  },

  pill(on, yes, no) { return h('span', { class: 'pill ' + (on ? 'ok' : 'bad') }, on ? yes : no); },

  row(name, line, ...right) {
    return h('div', { class: 'spread', style: 'padding:6px 0;border-top:1px solid var(--line);gap:10px' },
      h('div', {}, h('div', {}, name), line ? h('div', { class: 'small muted' }, line) : null),
      h('div', { class: 'row', style: 'gap:10px;white-space:nowrap' }, ...right.filter(Boolean)));
  },

  notAllowed(perm) { return h('p', { class: 'muted small' }, 'The API key can’t list these. Give it the ' + perm + ' permission in Pangolin’s dashboard.'); },

  status(s) {
    const page = this;
    if (!s.configured) {
      return h('div', { class: 'card' }, h('h2', { style: 'margin-top:0' }, 'Pangolin isn’t set up yet'),
        h('p', { class: 'muted' }, 'Turn on Pangolin’s Integration API and make an organization API key in its dashboard. Then enter the API URL, the key and the organization ID below, or use Set up in Pangolin on the Kindle.'));
    }
    if (!s.summary) {
      return h('div', { class: 'card' }, h('h2', { style: 'margin-top:0' }, s.name),
        h('p', { class: 'muted' }, s.why || 'Reading Pangolin…'),
        h('button', { class: 'btn', onclick: () => page.act('refresh', {}) }, 'Try again'));
    }
    const c = App.obj(s.counts);
    const parts = [c.sitesOnline + ' of ' + c.sites + ' sites online'];
    if (!s.skipped.resources) parts.push((c.resources - c.resourcesDown - c.resourcesDegraded) + ' of ' + c.resources + ' public resources healthy');
    if (!s.skipped.machines) parts.push(c.clientsOnline + ' of ' + c.clients + ' clients online');
    return h('div', { class: 'card' },
      h('div', { class: 'spread' },
        h('div', {}, h('h2', { style: 'margin:0' }, s.name),
          h('div', { style: 'font-size:22px;font-weight:700;margin-top:6px' }, s.summary),
          h('div', { class: 'muted small' }, parts.join(' · '))),
        h('div', { class: 'row', style: 'white-space:nowrap;gap:6px' },
          h('button', { class: 'btn small', onclick: () => page.act('refresh', {}, 'Reading Pangolin…') }, 'Refresh'),
          h('button', { class: 'btn small', onclick: async () => {
            if (!(await App.confirm('Reset bandwidth?', 'Every site’s data in and out goes back to zero. The counts so far can’t be put back.', 'Reset', true))) return;
            page.act('reset_bandwidth', {}, 'Bandwidth reset');
          } }, 'Reset bandwidth'))),
      h('p', { class: 'small muted' }, (s.read ? 'Read ' + App.ago(s.read) : '') + (s.why ? ' · ' + s.why : '')));
  },

  sites(s) {
    if (!s.summary) return null;
    return h('div', { class: 'card' }, h('h2', {}, 'Sites'),
      s.sites.length ? null : h('p', { class: 'muted' }, 'No sites yet.'),
      ...s.sites.map((x) => this.row(x.name, x.line,
        h('span', { class: 'small muted' }, x.dataIn + ' in · ' + x.dataOut + ' out'),
        this.pill(x.online, 'Online', 'Offline'))));
  },

  resources(s) {
    if (!s.summary) return null;
    const page = this;
    if (s.skipped.resources) return h('div', { class: 'card' }, h('h2', {}, 'Public resources'), this.notAllowed('List Resources'));
    return h('div', { class: 'card' }, h('h2', {}, 'Public resources'),
      s.resources.length ? null : h('p', { class: 'muted' }, 'No public resources yet.'),
      ...s.resources.map((r) => this.row(r.name, [r.domain, 'Protection: ' + r.protection].filter(Boolean).join(' · '),
        r.enabled ? this.pill(r.health === 'healthy', r.healthText, r.healthText) : h('span', { class: 'pill' }, 'Disabled'),
        h('label', { class: 'small row', style: 'gap:6px', title: 'Pangolin’s sign-in page before the resource' }, 'Sign-in',
          App.toggle(!!r.sso, async (v) => {
            if (!v && !(await App.confirm('Turn off sign-in?', 'Anyone who knows ' + (r.domain || r.name) + ' can reach it without signing in, unless it has a password, PIN or other protection.', 'Turn off', true))) { page.reload(); return; }
            page.act('resource_sso', { id: r.id, on: v }, v ? 'Sign-in turned on' : 'Sign-in turned off');
          })),
        h('label', { class: 'small row', style: 'gap:6px' }, 'Enabled',
          App.toggle(!!r.enabled, (v) => page.act('resource_enabled', { id: r.id, on: v }, v ? 'Resource enabled' : 'Resource disabled'))))),
      h('p', { class: 'small muted' }, 'Block access and each target’s health are on the Kindle (the resource’s page).'));
  },

  privates(s) {
    if (!s.summary) return null;
    const page = this;
    if (s.skipped.private) return h('div', { class: 'card' }, h('h2', {}, 'Private resources'), this.notAllowed('List Site Resources'));
    if (!s.private.length) return null;
    return h('div', { class: 'card' }, h('h2', {}, 'Private resources'),
      ...s.private.map((r) => this.row(r.name, r.line,
        h('label', { class: 'small row', style: 'gap:6px' }, 'Enabled',
          App.toggle(!!r.enabled, (v) => page.act('private_enabled', { id: r.id, on: v }, v ? 'Resource enabled' : 'Resource disabled'))))));
  },

  clients(s) {
    if (!s.summary) return null;
    const page = this;
    if (s.skipped.machines) return h('div', { class: 'card' }, h('h2', {}, 'Clients'), this.notAllowed('List Clients'));
    if (!s.clients.length) return null;
    return h('div', { class: 'card' }, h('h2', {}, 'Clients'),
      ...s.clients.map((c) => this.row(c.name, c.line,
        h('label', { class: 'small row', style: 'gap:6px' }, 'Blocked',
          App.toggle(!!c.blocked, (v) => page.act('client_blocked', { id: c.id, on: v }, v ? 'Client blocked' : 'Client unblocked'))),
        h('label', { class: 'small row', style: 'gap:6px' }, 'Archived',
          App.toggle(!!c.archived, (v) => page.act('client_archived', { id: c.id, on: v }, v ? 'Client archived' : 'Client unarchived'))))));
  },

  settings(s) {
    const page = this;
    const save = (args, done) => App.api('/api/pangolin/act', { json: { name: 'settings', args } })
      .then(() => { App.toast(done || 'Saved'); setTimeout(() => page.reload(), 1500); }).catch(App.fail);
    const url = h('input', { type: 'text', value: s.url || '', placeholder: 'https://api.example.com' });
    const key = h('input', { type: 'password', value: '', placeholder: s.hasKey ? 'Saved' + (s.keyId ? ' (ID ' + s.keyId + ')' : '') + ': type to change' : 'id.secret' });
    const org = h('input', { type: 'text', value: s.org || '', placeholder: 'home' });
    return h('div', { class: 'card' }, h('h2', {}, 'Settings'),
      App.setting('Read every', App.select([[10, '10 seconds'], [15, '15 seconds'], [30, '30 seconds'], [60, '1 minute'], [120, '2 minutes'], [300, '5 minutes']],
        s.interval || 30, (v) => save({ interval: Number(v) })), 'While Pangolin is open on the Kindle. Nothing is read once it closes.'),
      App.setting('Sites and resources going offline', App.toggle(s.notify !== false, (v) => save({ notify: v })), 'A notification on the Kindle, seen while Pangolin is read; it goes when they’re back.'),
      h('h3', {}, 'Connection'),
      App.setting('API URL', url, 'Pangolin’s Integration API, such as https://api.example.com (/v1 is added).'),
      App.setting('API key', key, 'From Pangolin’s dashboard: the organization’s Settings > API Keys.'),
      App.setting('Organization ID', org, 'It’s in the dashboard’s address.'),
      h('div', { class: 'row', style: 'gap:8px;margin-top:10px' },
        h('button', { class: 'btn primary', onclick: () => save({ url: url.value.trim(), key: key.value.trim(), org: org.value.trim() }, 'Saved. Reading Pangolin…') }, 'Save'),
        s.configured ? App.connectionTest('pangolin') : null));
  },
};
