// Syncthing: on/off, requests to accept or ignore (devices, folders offered), the folders (rescan,
// pause) and devices (pause), and this Kindle's ID to copy. While Syncthing runs the page reads the
// status again every 5 seconds.
App.pages.syncthing = {
  timer: null,

  async render(main) {
    clearTimeout(this.timer);
    const s = await App.api('/api/syncthing');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'Syncthing isn’t installed on this Kindle.')); return; }
    ['folders', 'devices', 'pendingDevices', 'pendingFolders'].forEach((k) => { s[k] = App.arr(s[k]); });
    main.append(
      h('div', {}, h('h1', {}, 'Syncthing'), h('p', { class: 'sub' }, 'Keeps folders on the Kindle in sync with your computer or phone, over Wi-Fi.')),
      ...[this.status(s), this.requests(s), this.folders(s), this.devices(s)].filter(Boolean));
    if (s.running) {
      this.timer = setTimeout(() => {
        if (main.isConnected && location.hash.startsWith('#syncthing') && !document.querySelector('.modal')) this.reload();
      }, 5000);
    }
  },

  reload() { App.route(); },

  async act(name, args, done) {
    try {
      await App.api('/api/syncthing/act', { json: { name, args } });
      if (done) App.toast(done);
      setTimeout(() => this.reload(), 1000);
    } catch (e) { App.fail(e); }
  },

  status(s) {
    const page = this;
    const power = async (on) => {
      try { await App.api('/api/syncthing/power', { json: { on } }); App.toast(on ? 'Starting Syncthing…' : 'Syncthing is off'); } catch (e) { App.fail(e); }
      setTimeout(() => page.reload(), on ? 3000 : 300);
    };
    const syncOff = async () => {
      try {
        await App.api('/api/syncthing/syncoff', { json: {} });
        App.toast('Syncthing turns off once everything is up to date');
      } catch (e) { App.fail(e); }
      setTimeout(() => page.reload(), 1000);
    };
    const setPassword = async () => {
      if (!s.running) { App.toast('Turn Syncthing on first'); return; }
      const input = h('input', { type: 'password', style: 'width:100%', autocomplete: 'new-password' });
      input.addEventListener('keydown', (e) => { if (e.key === 'Enter') input.closest('.modal').querySelector('.btn.primary').click(); });
      const pw = await App.modal('Web GUI password', h('div', {}, h('p', { class: 'small muted' }, 'For Syncthing’s own web page. User name: syncthing.'), input),
        [{ text: 'Cancel', result: null }, { text: 'Set', primary: true, value: () => input.value }]);
      if (!pw) return;
      page.act('password', { password: pw }, 'Password set');
    };
    const setPort = async () => {
      if (s.running) { App.toast('Turn Syncthing off to change the port'); return; }
      const v = await App.prompt('Port', String(s.port), 'Syncthing’s web GUI and API (8384 unless something else uses it).');
      if (v === null) return;
      try { await App.api('/api/syncthing/settings', { json: { port: v } }); App.toast('Port set'); } catch (e) { App.fail(e); }
      setTimeout(() => page.reload(), 300);
    };
    const line = !s.program ? 'The syncthing program is missing from the plugin’s folder.'
      : s.running ? (s.turnsOff ? 'Turns off when up to date' : (s.summary || 'Starting…')) : (s.withWifi ? 'Off · starts when Wi-Fi connects' : 'Off');
    const copy = async () => {
      try { await navigator.clipboard.writeText(s.id); App.toast('ID copied'); } catch (e) { App.prompt('This Kindle’s ID', s.id); }
    };
    return h('div', { class: 'card' },
      h('div', { class: 'spread' },
        h('div', {}, h('h2', { style: 'margin:0' }, 'Syncthing ', h('span', { class: 'muted small' }, s.running ? 'On' : 'Off')),
          h('div', { class: 'muted' }, line)),
        h('div', { class: 'row', style: 'white-space:nowrap' },
          s.running ? h('button', { class: 'btn small', onclick: () => page.act('rescan', {}, 'Rescanning all folders') }, 'Rescan all') : null, ' ',
          s.program && !s.turnsOff ? h('button', { class: 'btn small', onclick: syncOff }, 'Sync now, then turn off') : null, ' ',
          h('button', { class: 'btn' + (s.running ? '' : ' primary'), disabled: !s.program, onclick: () => power(!s.running) }, s.running ? 'Turn off' : 'Turn on'))),
      s.id ? h('div', { class: 'small', style: 'margin-top:10px' }, 'This Kindle’s ID: ',
        h('code', { style: 'word-break:break-all' }, s.id), ' ', h('button', { class: 'btn small', onclick: copy }, 'Copy')) : null,
      App.setting('Start with Wi-Fi', App.toggle(!!s.withWifi, async (v) => {
        try { await App.api('/api/syncthing/settings', { json: { withWifi: v } }); } catch (e) { App.fail(e); }
      }), 'Starts when the Kindle’s Wi-Fi connects and stops before it goes off.'),
      App.setting('Turn off when up to date', App.toggle(!!s.offWhenSynced, async (v) => {
        try { await App.api('/api/syncthing/settings', { json: { offWhenSynced: v } }); } catch (e) { App.fail(e); }
        setTimeout(() => page.reload(), 300);
      }), 'Turns Syncthing off once every folder is up to date with the connected devices, or after 30 minutes.'),
      App.setting('Warn about stuck sync and conflicts', App.toggle(s.warn !== false, async (v) => {
        try { await App.api('/api/syncthing/settings', { json: { warn: v } }); } catch (e) { App.fail(e); }
      }), 'In the notifications: a folder that hasn’t got any closer to done for half an hour, and files with a conflict.'),
      App.setting('Web GUI password', h('span', {}, s.passwordSet === undefined || s.passwordSet === null ? '' : (s.passwordSet ? 'Set' : 'Not set'), ' ',
        h('button', { class: 'btn small', onclick: setPassword }, 'Set password')), 'For Syncthing’s own web page. User name: syncthing.'),
      App.setting('Port', h('span', {}, String(s.port), ' ', h('button', { class: 'btn small', disabled: s.running, onclick: setPort }, 'Change')),
        'Syncthing’s web GUI and API (8384 unless something else uses it). Turn Syncthing off to change it.'),
      s.gui ? h('p', { class: 'small muted' }, 'Syncthing’s own web page (for settings not here): ',
        h('a', { href: s.gui, target: '_blank', rel: 'noopener' }, s.gui), ' · user name syncthing.') : null);
  },

  requests(s) {
    const page = this;
    if (!s.pendingDevices.length && !s.pendingFolders.length) return null;
    const row = (title, sub, accept, ignore) => h('div', { class: 'spread', style: 'padding:8px 0;border-top:1px solid var(--line)' },
      h('div', {}, title, h('div', { class: 'small muted' }, sub)),
      h('div', { class: 'row', style: 'white-space:nowrap' },
        h('button', { class: 'btn small', onclick: ignore }, 'Ignore'), ' ',
        h('button', { class: 'btn small primary', onclick: accept }, 'Accept')));
    return h('div', { class: 'card' }, h('h2', {}, 'Requests'),
      s.pendingDevices.map((d) => row(h('span', {}, h('strong', {}, d.name || d.id.split('-')[0]), ' wants to connect'),
        d.id + (d.address ? ' · ' + d.address : ''),
        async () => {
          const name = await App.prompt('Add device', d.name || '', 'Name');
          if (name === null) return;
          page.act('acceptDevice', { device: d.id, name }, 'Added ' + (name || 'the device') + '. Share a folder with this Kindle from it, then accept it here.');
        },
        async () => {
          if (!(await App.confirm('Ignore device', 'Ignore ' + (d.name || d.id) + '? Syncthing won’t ask about it again.', 'Ignore', true))) return;
          page.act('ignoreDevice', { device: d.id, name: d.name, address: d.address });
        })),
      s.pendingFolders.map((f) => row(h('span', {}, h('strong', {}, f.fromName), ' shares “' + f.label + '”'), 'Save to ' + f.path,
        async () => {
          const path = await App.prompt('Add “' + f.label + '” — folder on the Kindle', f.path);
          if (!path) return;
          page.act('acceptFolder', { folder: f.id, label: f.label, from: f.from, path }, 'Added ' + f.label);
        },
        async () => {
          if (!(await App.confirm('Ignore folder', 'Ignore “' + f.label + '” from ' + f.fromName + '? Syncthing won’t ask about it again.', 'Ignore', true))) return;
          page.act('ignoreFolder', { folder: f.id, label: f.label, from: f.from });
        })));
  },

  folders(s) {
    const page = this;
    if (!s.folders.length) {
      return h('div', { class: 'card' }, h('h2', {}, 'Folders'), h('p', { class: 'muted' },
        'No folders yet. Share a folder with this Kindle from Syncthing on another device; it shows above under Requests.'));
    }
    return h('div', { class: 'card' }, h('h2', {}, 'Folders'), s.folders.map((f) => {
      const info = [f.path, f.files !== undefined ? f.files + ' files' : null, f.bytes].filter(Boolean).join(' · ');
      const last = f.busy ? (f.need + (f.need === 1 ? ' file' : ' files') + ' left')
        : (f.lastFile ? 'Last: ' + f.lastFile + (f.lastAt ? ', ' + f.lastAt.toLowerCase() : '') : '');
      return h('div', { class: 'spread', style: 'padding:8px 0;border-top:1px solid var(--line)' },
        h('div', { style: 'flex:1;min-width:0' },
          h('strong', {}, f.label), s.running ? h('span', { class: 'muted small' }, ' · ', f.busy ? h('strong', { style: 'color:var(--text)' }, f.state) : f.state) : null,
          h('div', { class: 'small muted', style: 'overflow-wrap:anywhere' }, info),
          f.progress !== undefined && f.progress !== null ? h('div', { class: 'progress', style: 'margin:6px 0;max-width:420px' }, h('div', { style: 'width:' + Math.round(f.progress * 100) + '%' })) : null,
          last ? h('div', { class: 'small muted' }, last) : null),
        s.running ? h('div', { class: 'row', style: 'white-space:nowrap' },
          h('button', { class: 'btn small', disabled: f.paused, onclick: () => page.act('rescan', { folder: f.id }, 'Rescanning ' + f.label) }, 'Rescan'), ' ',
          h('button', { class: 'btn small' + (f.paused ? ' primary' : ''), onclick: () => page.act('pauseFolder', { folder: f.id, paused: !f.paused }) }, f.paused ? 'Resume' : 'Pause'))
          : (f.paused ? h('span', { class: 'muted small' }, 'Paused') : null));
    }));
  },

  devices(s) {
    const page = this;
    return h('div', { class: 'card' }, h('h2', {}, 'Devices'), s.devices.length ? s.devices.map((d) =>
      h('div', { class: 'spread', style: 'padding:8px 0;border-top:1px solid var(--line)' },
        h('div', {}, h('strong', {}, d.name), s.running ? h('span', { class: 'muted small' }, ' · ', d.connected ? h('strong', { style: 'color:var(--text)' }, d.state) : d.state) : null,
          h('div', { class: 'small muted', style: 'overflow-wrap:anywhere' }, d.id)),
        s.running ? h('button', { class: 'btn small' + (d.paused ? ' primary' : ''), onclick: () => page.act('pauseDevice', { device: d.id, paused: !d.paused }) }, d.paused ? 'Resume' : 'Pause')
          : (d.paused ? h('span', { class: 'muted small' }, 'Paused') : null)))
      : h('p', { class: 'muted' }, 'No devices yet. In Syncthing on your computer or phone, add this Kindle with its ID (above), then accept it here.'));
  },
};
