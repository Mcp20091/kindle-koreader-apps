// pfSense (the optional pfSense plugin): the firewall's health, gateways, interfaces and services (start,
// stop, restart); devices (Wake), DHCP static mappings and DNS host overrides (add, delete), firewall rules on
// or off, reboot and update; and its settings. The page reads the state again every 60 seconds while it's open.
App.pages.pfsense = {
  timer: null,

  async render(main) {
    clearTimeout(this.timer);
    const s = await App.api('/api/pfsense');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'pfSense isn’t installed on this Kindle. It’s an optional app: Settings > Updates > Optional apps on the Kindle, or System > Update from GitHub here.')); return; }
    ['gateways', 'interfaces', 'services', 'devices', 'rules', 'statics', 'overrides', 'aliases', 'nat', 'routes', 'wgpeers',
      'certs', 'gwchoices'].forEach((k) => { s[k] = App.arr(s[k]); });
    s.skipped = App.obj(s.skipped);
    main.append(
      h('div', {}, h('h1', {}, 'pfSense'), h('p', { class: 'sub' }, 'Your firewall, over the ',
        App.link('pfSense REST API package', 'https://pfrest.org'), '.')),
      ...[this.status(s), this.gateways(s), this.services(s), this.devices(s), this.statics(s), this.overrides(s),
        this.aliases(s), this.nat(s), this.vpn(s), this.certs(s),
        this.rules(s), this.more(s), this.settings(s)].filter(Boolean));
    if (s.configured) {
      this.timer = setTimeout(() => {
        if (main.isConnected && location.hash.startsWith('#pfsense') && !document.querySelector('.modal')) this.reload();
      }, 60000);
    }
  },

  reload() { App.route(); },

  async act(name, args, done) {
    try {
      await App.api('/api/pfsense/act', { json: { name, args } });
      if (done) App.toast(done);
      setTimeout(() => this.reload(), 2500);
    } catch (e) { App.fail(e); }
  },

  pill(on, yes, no) { return h('span', { class: 'pill ' + (on ? 'ok' : 'bad') }, on ? yes : no); },

  row(name, line, ...right) {
    return h('div', { class: 'spread', style: 'padding:6px 0;border-top:1px solid var(--line);gap:10px' },
      h('div', {}, h('div', {}, name), line ? h('div', { class: 'small muted' }, line) : null),
      h('div', { class: 'row', style: 'gap:10px;white-space:nowrap' }, ...right.filter(Boolean)));
  },

  button(text, fn) { return h('button', { class: 'btn small', onclick: fn }, text); },

  // What each list is searched for (its key -> the words), while the page is open.
  find: {},

  // A list's Search box and, for one that sorts, Name or IP address and Reverse: the same sort as
  // the Kindle's (one setting), the search on this page only.
  tools(s, list) {
    const page = this;
    const sort = App.obj(App.obj(s.sort)[list]);
    const search = h('input', { type: 'search', value: this.find[list] || '', placeholder: 'Search: a name, an address, a MAC address' });
    search.addEventListener('change', () => { page.find[list] = search.value.trim(); page.reload(); });
    return h('div', { class: 'row', style: 'gap:8px;flex-wrap:wrap;margin:4px 0 8px' }, search,
      App.select([['name', 'Name'], ['ip', 'IP address']], sort.by || 'name',
        (v) => page.act('sort', { list, by: v, reverse: !!sort.reverse })),
      h('label', { class: 'small row', style: 'gap:6px' }, 'Reverse',
        App.toggle(!!sort.reverse, (v) => page.act('sort', { list, by: sort.by || 'name', reverse: v }))));
  },

  // Which items show: all, only online ones, or only offline ones (devices and static mappings).
  only: {},

  onlineFilter(list) {
    const page = this;
    return App.select([['', 'All'], ['on', 'Online'], ['off', 'Offline']], this.only[list] || '', (v) => { page.only[list] = v; page.reload(); });
  },

  // The items with the words searched for in any of their fields (a MAC typed with dashes too),
  // and only the online (or offline) ones when chosen.
  found(items, list) {
    const only = this.only[list];
    if (only) items = items.filter((x) => !!x.online === (only === 'on'));
    const q = (this.find[list] || '').toLowerCase();
    if (!q) return items;
    const q2 = /^[0-9a-f]{2}[-:]/.test(q) ? q.replace(/-/g, ':') : q;
    return items.filter((x) => Object.values(x).some((v) => typeof v === 'string' && (v.toLowerCase().includes(q) || v.toLowerCase().includes(q2))));
  },

  notAllowed(s, key, priv) {
    if (s.skipped[key] === 'missing' || s.skipped[key] === 'notfound') return h('p', { class: 'muted small' }, 'This pfSense doesn’t have it (a package it needs isn’t installed).');
    return h('p', { class: 'muted small' }, 'The API key can’t read these. Give the key’s user the ' + priv + ' privilege (or page-all) in System > User Manager.');
  },

  // A form in a pop-up: fields [[key, label, placeholder, value]]; resolves to { key: value } or null.
  form(title, fields, ok) {
    const inputs = {};
    const body = h('div', {}, ...fields.map(([k, label, ph, v]) => {
      inputs[k] = h('input', { type: 'text', value: v || '', placeholder: ph || '', style: 'width:100%' });
      return h('label', { class: 'small', style: 'display:block;margin:6px 0' }, label, inputs[k]);
    }));
    const values = () => { const o = {}; Object.keys(inputs).forEach((k) => { o[k] = inputs[k].value.trim(); }); return o; };
    return App.modal(title, body, [{ text: 'Cancel', result: null }, { text: ok || 'Add', primary: true, value: values }]);
  },

  status(s) {
    const page = this;
    if (!s.configured) {
      return h('div', { class: 'card' }, h('h2', { style: 'margin-top:0' }, 'pfSense isn’t set up yet'),
        h('p', { class: 'muted' }, 'Install the REST API package on pfSense, allow API keys (System > REST API > Settings) and make a key (System > REST API > Keys). Then enter the firewall’s address and the key below, or use Set up in pfSense on the Kindle.'));
    }
    if (!s.summary) {
      return h('div', { class: 'card' }, h('h2', { style: 'margin-top:0' }, s.name),
        h('p', { class: 'muted' }, s.why || 'Reading pfSense…'),
        h('button', { class: 'btn', onclick: () => page.act('refresh', {}) }, 'Try again'));
    }
    const y = App.obj(s.system);
    const pct = (v) => (v === undefined || v === null ? '–' : Math.round(v) + '%');
    const parts = ['CPU ' + pct(y.cpu), 'Memory ' + pct(y.mem), 'Disk ' + pct(y.disk)];
    if (y.temp) parts.push(Math.round(y.temp) + ' °C');
    return h('div', { class: 'card' },
      h('div', { class: 'spread' },
        h('div', {}, h('h2', { style: 'margin:0' }, s.name),
          h('div', { style: 'font-size:22px;font-weight:700;margin-top:6px' }, s.summary),
          h('div', { class: 'muted small' }, [y.version ? 'pfSense ' + y.version : '', y.uptime ? 'Up ' + y.uptime : ''].filter(Boolean).join(' · ')),
          h('div', { class: 'muted small' }, parts.join(' · '))),
        h('div', { class: 'row', style: 'white-space:nowrap;gap:6px' },
          page.button('Refresh', () => page.act('refresh', {}, 'Reading pfSense…')))),
      h('p', { class: 'small muted' }, (s.read ? 'Read ' + App.ago(s.read) : '') + (s.why ? ' · ' + s.why : '')));
  },

  gateways(s) {
    if (!s.summary) return null;
    const page = this;
    const dg = App.obj(s.defaultgw);
    const choose = (family) => App.select([['', 'Automatic'], ...s.gwchoices.filter((g) => g.family === family)
      .map((g) => [g.name, g.group ? g.name + ' (group)' : g.name])], dg[family] || '', async (v) => {
      if (!(await App.confirm('Change the default gateway?', 'Traffic to the internet goes out through ' + (v || 'the one pfSense picks') + ' from now on.', 'Change', false))) { page.reload(); return; }
      page.act('default_gw', { family, name: v }, 'Default gateway changed');
    });
    return h('div', { class: 'card' }, h('h2', {}, 'Gateways and interfaces'),
      s.defaultgw ? App.setting('Default gateway (IPv4)', choose('inet')) : null,
      s.defaultgw ? App.setting('Default gateway (IPv6)', choose('inet6')) : null,
      ...s.gateways.map((g) => this.row(g.name, g.line, this.pill(g.state !== 'down', 'Up', 'Down'))),
      ...s.interfaces.map((i) => this.row(i.name, i.line, i.enabled ? this.pill(i.up, 'Up', 'Down') : h('span', { class: 'pill' }, 'Disabled'))),
      s.routes.length ? h('h3', {}, 'Static routes') : null,
      ...s.routes.map((r) => this.row(r.name, r.line, h('label', { class: 'small row', style: 'gap:6px' }, 'Enabled',
        App.toggle(!!r.on, (v) => page.act('route_enabled', { id: r.id, on: v }, v ? 'Route on' : 'Route off'))))));
  },

  services(s) {
    if (!s.summary) return null;
    const page = this;
    if (s.skipped.services) return h('div', { class: 'card' }, h('h2', {}, 'Services'), this.notAllowed(s, 'services', 'api-v2-status-services-get'));
    return h('div', { class: 'card' }, h('h2', {}, 'Services'),
      ...s.services.map((x) => this.row(x.name, x.key !== x.name ? x.key : '',
        x.running ? page.button('Restart', () => page.act('service', { name: x.key, action: 'restart' }, x.name + ': restarting')) : null,
        x.running ? page.button('Stop', async () => {
          if (!(await App.confirm('Stop ' + x.name + '?', 'What it does stops until it’s started again. Stopping some services (such as the DNS Resolver or the web interface) can cut off the Kindle too.', 'Stop', true))) return;
          page.act('service', { name: x.key, action: 'stop' }, x.name + ': stopping');
        }) : page.button('Start', () => page.act('service', { name: x.key, action: 'start' }, x.name + ': starting')),
        x.enabled || x.running ? this.pill(x.running, 'Running', 'Stopped') : h('span', { class: 'pill' }, 'Disabled'))));
  },

  devices(s) {
    if (!s.summary) return null;
    const page = this;
    if (s.skipped.leases) return h('div', { class: 'card' }, h('h2', {}, 'Devices'), this.notAllowed(s, 'leases', 'api-v2-status-dhcp-server-leases-get'));
    if (!s.devices.length) return null;
    const list = this.found(s.devices, 'leases');
    return h('div', { class: 'card' }, h('h2', {}, 'Devices (DHCP leases)'), this.tools(s, 'leases'), this.onlineFilter('leases'),
      list.length ? null : h('p', { class: 'muted' }, 'None like that now.'),
      ...list.map((d) => this.row(d.name, d.line + ' · ' + d.mac,
        d.iface ? page.button('Wake', () => page.act('wake', { iface: d.iface, mac: d.mac }, 'Wake-on-LAN sent')) : null,
        page.button('Close connections', async () => {
          if (!(await App.confirm('Close ' + d.name + '’s connections?', 'Everything it has open is cut off now, so a block (a rule or an alias) works at once. It can connect again where it’s allowed to.', 'Close all', true))) return;
          page.act('kill_states', { ip: d.ip }, 'Connections closed');
        }),
        this.pill(d.online, 'Online', 'Offline'))),
      h('p', { class: 'small muted' }, 'A device’s connections, Ping, the ARP table, logs, config history and packages are on the Kindle.'));
  },

  statics(s) {
    if (!s.summary) return null;
    const page = this;
    const head = h('div', { class: 'spread' }, h('h2', {}, 'DHCP static mappings'),
      s.skipped.statics ? null : page.button('Add', async () => {
        const ifaces = s.interfaces.filter((i) => i.key !== 'wan' && i.enabled);
        const v = await page.form('Add a static mapping', [
          ['parent', 'Interface (' + ifaces.map((i) => i.key).join(', ') + ')', 'lan', ifaces.length ? (ifaces.find((i) => i.key === 'lan') || ifaces[0]).key : 'lan'],
          ['mac', 'MAC address', 'aa:bb:cc:dd:ee:ff'], ['ip', 'IP address', '192.168.1.20'], ['hostname', 'Hostname', 'nas'], ['descr', 'Description', '']]);
        if (v) page.act('static_add', v, 'Static mapping added');
      }));
    if (s.skipped.statics) return h('div', { class: 'card' }, head, this.notAllowed(s, 'statics', 'api-v2-services-dhcp-server-static-mappings-get'));
    const online = {};
    s.devices.forEach((d) => { online[d.mac] = d.online; });
    s.statics.forEach((x) => { x.online = !!online[x.mac]; });
    const list = this.found(s.statics, 'statics');
    return h('div', { class: 'card' }, head, s.statics.length ? this.tools(s, 'statics') : null, s.statics.length ? this.onlineFilter('statics') : null,
      s.statics.length ? (list.length ? null : h('p', { class: 'muted' }, 'Nothing has those words.')) : h('p', { class: 'muted' }, 'No static mappings yet.'),
      ...list.map((x) => this.row(x.name, [x.parent.toUpperCase(), x.ip, x.mac].filter(Boolean).join(' · '),
        page.button('Wake', () => page.act('wake', { iface: x.parent, mac: x.mac }, 'Wake-on-LAN sent')),
        page.button('Delete', async () => {
          if (!(await App.confirm('Delete ' + x.name + '?', 'Its static mapping goes; the device gets an address from the pool next time.', 'Delete', true))) return;
          page.act('static_delete', { parent: x.parent, id: x.id, mac: x.mac }, 'Static mapping deleted');
        }))));
  },

  overrides(s) {
    if (!s.summary) return null;
    const page = this;
    const head = h('div', { class: 'spread' }, h('h2', {}, 'DNS host overrides'),
      s.skipped.overrides ? null : page.button('Add', async () => {
        const v = await page.form('Add a host override', [['host', 'Host', 'nas'], ['domain', 'Domain', 'home.example.com'],
          ['ips', 'IP addresses (commas between)', '192.168.1.20'], ['aliases', 'Aliases (commas between)', 'files.home.example.com'], ['descr', 'Description', '']]);
        if (v) page.act('override_add', v, 'Host override added');
      }));
    if (s.skipped.overrides) return h('div', { class: 'card' }, head, this.notAllowed(s, 'overrides', 'api-v2-services-dns-resolver-host-overrides-get'));
    const list = this.found(s.overrides, 'overrides');
    return h('div', { class: 'card' }, head, s.overrides.length ? this.tools(s, 'overrides') : null,
      s.overrides.length ? (list.length ? null : h('p', { class: 'muted' }, 'Nothing has those words.')) : h('p', { class: 'muted' }, 'No host overrides yet.'),
      ...list.map((o) => this.row(o.name, [o.ips, o.aliases ? 'Aliases: ' + o.aliases : '', o.descr].filter(Boolean).join(' · '),
        page.button('Delete', async () => {
          if (!(await App.confirm('Delete ' + o.name + '?', 'The name stops resolving to ' + o.ips + '.', 'Delete', true))) return;
          page.act('override_delete', { id: o.id, host: o.host, domain: o.domain }, 'Host override deleted');
        }))));
  },

  rules(s) {
    if (!s.summary) return null;
    const page = this;
    if (s.skipped.rules) return h('div', { class: 'card' }, h('h2', {}, 'Firewall rules'), this.notAllowed(s, 'rules', 'api-v2-firewall-rules-get'));
    if (!s.rules.length) return null;
    return h('div', { class: 'card' }, h('h2', {}, 'Firewall rules'),
      ...s.rules.map((r) => this.row(r.name, r.line,
        h('label', { class: 'small row', style: 'gap:6px', title: 'Applied at once' }, 'Enabled',
          App.toggle(!!r.on, (v) => page.act('rule_enabled', { id: r.id, tracker: r.tracker, on: v }, v ? 'Rule on' : 'Rule off'))))));
  },

  aliases(s) {
    if (!s.summary || !s.aliases.length) return null;
    const page = this;
    return h('div', { class: 'card' }, h('h2', {}, 'Aliases'),
      h('p', { class: 'small muted' }, 'The lists of addresses, networks or ports that firewall rules use. A change is applied at once.'),
      ...s.aliases.map((a) => this.row(a.name, a.line + (a.entries ? ' · ' + a.entries : ''),
        page.button('Edit', async () => {
          const v = await page.form('Edit ' + a.name, [['addresses', 'Entries (commas between)', '192.168.1.20, 192.168.1.42', a.entries]], 'Save');
          if (v) page.act('alias_set', { id: a.id, name: a.name, addresses: v.addresses }, 'Alias saved');
        }))));
  },

  nat(s) {
    if (!s.summary || (!s.nat.length && !s.natmode)) return null;
    const page = this;
    const names = { forward: 'Port forward', outbound: 'Outbound', onetoone: '1:1' };
    return h('div', { class: 'card' }, h('h2', {}, 'NAT'),
      s.natmode ? App.setting('Outbound NAT mode', h('span', {}, s.natmode)) : null,
      ...s.nat.map((r) => this.row(r.name, names[r.kind] + ' · ' + r.line, h('label', { class: 'small row', style: 'gap:6px', title: 'Applied at once' }, 'Enabled',
        App.toggle(!!r.on, (v) => page.act('nat_enabled', { kind: r.kind, id: r.id, on: v }, v ? 'Turned on' : 'Turned off'))))));
  },

  vpn(s) {
    if (!s.summary || !s.wgpeers.length) return null;
    const page = this;
    return h('div', { class: 'card' }, h('h2', {}, 'WireGuard peers'),
      ...s.wgpeers.map((w) => this.row(w.name, w.line, h('label', { class: 'small row', style: 'gap:6px' }, 'Enabled',
        App.toggle(!!w.on, (v) => page.act('wg_enabled', { key: w.key, on: v }, v ? 'Peer on' : 'Peer off'))))),
      h('p', { class: 'small muted' }, 'OpenVPN and IPsec status, and disconnecting an OpenVPN client, are on the Kindle.'));
  },

  certs(s) {
    if (!s.summary || !s.certs.length) return null;
    return h('div', { class: 'card' }, h('h2', {}, 'Certificates'),
      ...s.certs.map((c) => this.row(c.name, c.line, this.pill(!c.soon, 'OK', 'Soon'))));
  },

  more(s) {
    if (!s.summary) return null;
    const page = this;
    return h('div', { class: 'card' }, h('h2', {}, 'System'),
      h('div', { class: 'row', style: 'gap:8px' },
        page.button('Update pfSense', async () => {
          if (!(await App.confirm('Update pfSense?', 'pfSense looks for a newer version, installs it and restarts by itself. The network is down meanwhile, sometimes for several minutes. Nothing happens when it’s up to date.', 'Update', true))) return;
          page.act('update', {}, 'pfSense is updating');
        }),
        page.button('Reboot', async () => {
          if (!(await App.confirm('Reboot pfSense?', 'The network is down for a few minutes while it restarts, the Kindle’s Wi-Fi too if it goes through this firewall.', 'Reboot', true))) return;
          page.act('reboot', {}, 'pfSense is restarting');
        })));
  },

  settings(s) {
    const page = this;
    const save = (args, done) => App.api('/api/pfsense/act', { json: { name: 'settings', args } })
      .then(() => { App.toast(done || 'Saved'); setTimeout(() => page.reload(), 1500); }).catch(App.fail);
    const url = h('input', { type: 'text', value: s.url || '', placeholder: 'https://192.168.1.1' });
    const key = h('input', { type: 'password', value: '', placeholder: s.hasKey ? 'Saved: type to change' : 'The API key' });
    return h('div', { class: 'card' }, h('h2', {}, 'Settings'),
      App.setting('Read every', App.select([[15, '15 seconds'], [30, '30 seconds'], [60, '1 minute'], [120, '2 minutes'], [300, '5 minutes']],
        s.interval || 60, (v) => save({ interval: Number(v) })), 'While pfSense is open on the Kindle. Nothing is read once it closes.'),
      App.setting('Gateways, interfaces and services going down', App.toggle(s.notify !== false, (v) => save({ notify: v })), 'A notification on the Kindle, seen while pfSense is read; it goes when they’re back.'),
      h('h3', {}, 'Connection'),
      App.setting('Address', url, 'The firewall’s web interface, such as https://192.168.1.1 (its own certificate is fine).'),
      App.setting('API key', key, 'From pfSense: System > REST API > Keys. API keys must be allowed in System > REST API > Settings.'),
      h('div', { class: 'row', style: 'gap:8px;margin-top:10px' },
        h('button', { class: 'btn primary', onclick: () => save({ url: url.value.trim(), key: key.value.trim() }, 'Saved. Reading pfSense…') }, 'Save'),
        s.configured ? App.connectionTest('pfsense') : null));
  },
};
