// pfSense (the optional pfSense plugin): the firewall's health, gateways, interfaces and services (start,
// stop, restart); devices (Wake), DHCP static mappings and DNS host overrides (add, delete), firewall rules on
// or off, reboot and update; and its settings. The page reads the state again every 60 seconds while it's open.
// Read only when asked (each card's Read): the DHCP server's and DNS Resolver's settings, pf tables, SSH, NTP,
// the service watchdog, cron jobs and packages (install, remove).
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
        this.rules(s), this.dhcp(s), this.dnsres(s), this.tables(s), this.system2(s), this.packages(s),
        this.more(s), this.settings(s)].filter(Boolean));
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

  // A card read only when asked (packages, pf tables, the settings): Read (or Read again) in its head, and
  // why it couldn't be read. got: what was read (undefined until then).
  lazy(title, what, got, why, ...body) {
    const page = this;
    return h('div', { class: 'card' },
      h('div', { class: 'spread' }, h('h2', {}, title),
        page.button(got === undefined ? 'Read' : 'Read again', () => page.act('read', { what }, 'Reading…'))),
      why ? h('p', { class: 'muted small' }, why) : null,
      got === undefined ? (why ? null : h('p', { class: 'muted small' }, 'Read from pfSense when you ask.')) : null,
      ...(got === undefined ? [] : body.filter(Boolean)));
  },

  cfg(s, name) { const c = App.obj(App.obj(s.config)[name]); return { value: c.value, why: c.why }; },

  packages(s) {
    if (!s.summary) return null;
    const page = this;
    const p = App.obj(s.packages);
    const av = App.obj(s.available);
    const list = p.list === undefined ? undefined : App.arr(p.list);
    const install = h('div', { class: 'row', style: 'gap:8px;flex-wrap:wrap;margin:8px 0' },
      av.list === undefined
        ? page.button('Packages to install', () => page.act('read', { what: 'available' }, 'Asking pfSense’s package server…'))
        : App.select([['', 'Install a package…'], ...App.arr(av.list).map((x) => [x.name, x.short + ' ' + x.version])], '', async (v) => {
          if (!v) return;
          const x = App.arr(av.list).find((y) => y.name === v);
          if (!(await App.confirm('Install ' + x.short + '?', 'pfSense downloads it and sets it up, which can take a few minutes. ' + (x.descr || ''), 'Install', false))) { page.reload(); return; }
          page.act('pkg_install', { name: v }, 'Installing ' + x.short + '…');
        }),
      av.why ? h('span', { class: 'muted small' }, av.why) : null);
    return this.lazy('Packages', 'packages', list, p.why, install,
      ...(list || []).map((x) => this.row(x.short, x.update ? x.installed + ' → ' + x.latest + ' (update in pfSense’s web interface)' : x.installed,
        page.button('Remove', async () => {
          if (!(await App.confirm('Remove ' + x.short + '?', 'pfSense uninstalls it: what it does stops. Its settings are usually kept, for when it’s installed again.', 'Remove', true))) return;
          page.act('pkg_remove', { name: x.name }, 'Removing ' + x.short + '…');
        }),
        x.update ? this.pill(false, '', 'Update') : null)));
  },

  tables(s) {
    if (!s.summary) return null;
    const page = this;
    const t = App.obj(s.tables);
    const lk = App.obj(s.lookup);
    const flush = async (name) => {
      if (!(await App.confirm('Empty ' + name + '?', 'Every address in it goes now, so none of them is blocked (or passed) by it until it’s filled again: pfBlockerNG and Snort fill theirs as they update. The REST API can’t take out one address on its own.', 'Empty', true))) return;
      page.act('table_flush', { name }, name + ' emptied');
    };
    const ip = h('input', { type: 'text', placeholder: '192.168.1.20', value: lk.ip || '' });
    const look = h('div', { class: 'row', style: 'gap:8px;margin:8px 0' }, ip, page.button('Look up', () => page.act('lookup', { ip: ip.value.trim() }, 'Looking…')));
    const found = lk.ip ? (lk.why ? h('p', { class: 'muted small' }, lk.why)
      : (App.arr(lk.hits).length ? h('div', {}, ...App.arr(lk.hits).map((x) => this.row(x.name, lk.ip + ' as ' + App.arr(x.entries).join(', '), page.button('Empty', () => flush(x.name)))))
        : h('p', { class: 'muted small' }, lk.ip + ' isn’t in any table.'))) : null;
    const list = t.list === undefined ? undefined : App.arr(t.list);
    return this.lazy('pf tables', 'tables', list, t.why, look, found,
      ...(list || []).map((x) => this.row(x.name, x.count + (x.count === 1 ? ' entry' : ' entries'), page.button('Empty', () => flush(x.name)))),
      h('p', { class: 'small muted' }, 'The block lists pfBlockerNG or Snort fill, and the aliases’ addresses. The REST API can only empty a whole table.'));
  },

  dhcp(s) {
    if (!s.summary) return null;
    const page = this;
    const c = this.cfg(s, 'dhcp');
    const v = App.obj(c.value);
    const set = (iface, field, value, done) => page.act('dhcp_set', { iface, field, value }, done || 'Saved');
    const edit = (srv, field, label, value) => page.button(label, async () => {
      const r = await page.form(label, [['v', label, '', value]], 'Save');
      if (r) set(srv.id, field, r.v);
    });
    return this.lazy('DHCP server', 'dhcp', c.value, c.why, ...App.arr(v.servers).map((x) => h('div', {},
      h('h3', {}, x.id.toUpperCase()),
      App.setting('DHCP server', App.toggle(!!x.enabled, async (on) => {
        if (!on && !(await App.confirm('Turn this DHCP server off?', 'Devices on this network stop getting addresses as their leases run out, and new ones get none.', 'Turn off', true))) { page.reload(); return; }
        set(x.id, 'enable', on, on ? 'DHCP on' : 'DHCP off');
      }), 'Applied at once.'),
      this.row('Range', (x.from || '–') + ' – ' + (x.to || '–'), edit(x, 'range_from', 'From', x.from), edit(x, 'range_to', 'To', x.to)),
      this.row('DNS servers', App.arr(x.dns).join(', ') || 'pfSense’s', edit(x, 'dnsserver', 'Change', App.arr(x.dns).join(', '))),
      this.row('Gateway', x.gateway || 'The interface’s address', edit(x, 'gateway', 'Change', x.gateway)),
      this.row('Domain', x.domain || 'pfSense’s', edit(x, 'domain', 'Change', x.domain)),
      this.row('Lease time (seconds)', x.lease ? String(x.lease) : 'Default', edit(x, 'defaultleasetime', 'Change', x.lease ? String(x.lease) : '')),
      this.row('Longest lease (seconds)', x.maxLease ? String(x.maxLease) : 'Default', edit(x, 'maxleasetime', 'Change', x.maxLease ? String(x.maxLease) : '')),
      ...App.arr(x.pools).map((p) => this.row('Pool', p.name, page.button('Delete', async () => {
        if (!(await App.confirm('Delete the pool ' + p.name + '?', 'Its addresses aren’t given out any more.', 'Delete', true))) return;
        page.act('pool_delete', { parent: p.parent, id: p.id }, 'Pool deleted');
      }))),
      ...App.arr(x.options).map((o) => this.row('Option ' + o.number, o.type + ' · ' + o.value, page.button('Delete', async () => {
        if (!(await App.confirm('Delete option ' + o.number + '?', 'Devices don’t get it any more.', 'Delete', true))) return;
        page.act('option_delete', { parent: o.parent, id: o.id }, 'Option deleted');
      }))),
      h('div', { class: 'row', style: 'gap:8px;margin-top:6px' },
        page.button('Add a pool', async () => {
          const r = await page.form('Add a pool on ' + x.id.toUpperCase(), [['from', 'From', '192.168.1.42'], ['to', 'To', '192.168.1.50']]);
          if (r) page.act('pool_add', { parent: x.id, from: r.from, to: r.to }, 'Pool added');
        }),
        page.button('Add an option', async () => {
          const r = await page.form('Add a DHCP option on ' + x.id.toUpperCase(), [['number', 'Number', '66'], ['type', 'Type (text, string, boolean, ip-address, unsigned integer 8…)', 'text', 'text'], ['value', 'Value', '']]);
          if (r) page.act('option_add', { parent: x.id, number: r.number, type: r.type, value: r.value }, 'Option added');
        })))));
  },

  dnsres(s) {
    if (!s.summary) return null;
    const page = this;
    const c = this.cfg(s, 'dnsres');
    const v = App.obj(c.value);
    const sw = (field, label, hint, asks) => App.setting(label, App.toggle(!!v[field === 'enable' ? 'enabled' : field], async (on) => {
      if (!on && asks && !(await App.confirm(asks[0], asks[1], 'Turn off', true))) { page.reload(); return; }
      page.act('dnsres_set', { field, value: on }, on ? 'Turned on' : 'Turned off');
    }), hint);
    return this.lazy('DNS Resolver', 'dnsres', c.value, c.why,
      sw('enable', 'DNS Resolver', 'Port ' + (v.port || '53') + '. Applied at once.', ['Turn the DNS Resolver off?', 'Devices that use pfSense for names (most on your network, maybe the Kindle) can’t look any up until it’s on again.']),
      sw('dnssec', 'DNSSEC', 'Checks the answers are signed.'),
      sw('forwarding', 'Forwarding mode', 'Asks pfSense’s DNS servers (System > General) instead of the root servers.'),
      sw('regdhcp', 'Names from DHCP leases'), sw('regdhcpstatic', 'Names from DHCP static mappings'), sw('regovpnclients', 'Names of OpenVPN clients'));
  },

  system2(s) {
    if (!s.summary) return null;
    const page = this;
    const ssh = this.cfg(s, 'ssh');
    const ntp = this.cfg(s, 'ntp');
    const wd = this.cfg(s, 'watchdog');
    const cron = this.cfg(s, 'cron');
    const sv = App.obj(ssh.value);
    const nv = App.obj(ntp.value);
    return h('div', {},
      this.lazy('SSH', 'ssh', ssh.value, ssh.why,
        App.setting('SSH server', App.toggle(!!sv.enabled, async (on) => {
          if (!on && !(await App.confirm('Turn SSH off?', 'pfSense stops taking SSH connections, and ones open now may be cut off. The REST API keeps working.', 'Turn off', true))) { page.reload(); return; }
          page.act('ssh_set', { enable: on }, on ? 'SSH on' : 'SSH off');
        }), 'Applied at once.'),
        this.row('Port', sv.port, page.button('Change', async () => {
          const r = await page.form('SSH port', [['port', 'Port', '22', sv.port]], 'Save');
          if (r) page.act('ssh_set', { port: r.port }, 'Saved');
        }))),
      this.lazy('NTP (time)', 'ntp', ntp.value, ntp.why,
        App.setting('NTP server', App.toggle(!!nv.enabled, async (on) => {
          if (!on && !(await App.confirm('Turn the NTP server off?', 'Devices that ask pfSense for the time stop getting it.', 'Turn off', true))) { page.reload(); return; }
          page.act('ntp_enabled', { on }, on ? 'NTP on' : 'NTP off');
        }), 'pfSense gives the time to the network.'),
        ...App.arr(nv.servers).map((x) => this.row(x.server, x.type, page.button('Delete', async () => {
          if (!(await App.confirm('Delete ' + x.server + '?', 'pfSense stops getting the time from it (NTP restarts).', 'Delete', true))) return;
          page.act('ntp_delete', { id: x.id }, 'Time server deleted');
        }))),
        page.button('Add a time server', async () => {
          const r = await page.form('Add a time server', [['server', 'Name or address', '0.pool.ntp.org'], ['type', 'Type (server, pool or peer)', 'pool', 'pool']]);
          if (r) page.act('ntp_add', r, 'Time server added');
        })),
      this.lazy('Service watchdog', 'watchdog', wd.value, wd.why,
        ...App.arr(wd.value).map((w) => this.row(w.title, w.title !== w.name ? w.name : '',
          h('label', { class: 'small row', style: 'gap:6px' }, 'Notify', App.toggle(!!w.notify, (on) => page.act('watchdog_notify', { id: w.id, on }, on ? 'Notifications on' : 'Notifications off'))),
          page.button('Stop watching', () => page.act('watchdog_delete', { id: w.id }, w.title + ' not watched')))),
        App.select([['', 'Watch a service…'], ...s.services.filter((x) => !App.arr(wd.value).some((w) => w.name === x.key)).map((x) => [x.key, x.name])], '', (v) => {
          if (!v) return;
          const x = s.services.find((y) => y.key === v);
          page.act('watchdog_add', { name: v, description: x ? x.name : v, notify: true }, 'Watched');
        }),
        h('p', { class: 'small muted' }, 'pfSense starts a watched service again when it stops (the Service Watchdog package).')),
      this.lazy('Cron jobs', 'cron', cron.value, cron.why,
        ...App.arr(cron.value).map((c) => this.row(c.command, [c.minute, c.hour, c.mday, c.month, c.wday].join(' ') + ' · ' + c.who, page.button('Delete', async () => {
          if (!(await App.confirm('Delete this cron job?', c.command, 'Delete', true))) return;
          page.act('cron_delete', { id: c.id }, 'Cron job deleted');
        }))),
        page.button('Add', async () => {
          const r = await page.form('Add a cron job', [['minute', 'Minute (or @daily, @reboot…)', '0', '0'], ['hour', 'Hour', '3', '3'], ['mday', 'Day of the month', '*', '*'],
            ['month', 'Month', '*', '*'], ['wday', 'Day of the week', '*', '*'], ['who', 'User', 'root', 'root'], ['command', 'Command (full path)', '/usr/local/bin/backup.sh']]);
          if (r) page.act('cron_add', r, 'Cron job added');
        })));
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
