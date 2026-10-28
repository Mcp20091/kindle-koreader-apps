// FlashForge (the optional FlashForge plugin): the printer's state, pause, resume, cancel, clear, the
// light and the air filter, and its settings. While a print runs, the page reads the state again every
// 10 seconds. Starting a print and the camera are on the Kindle only.
App.pages.flashforge = {
  timer: null,

  async render(main) {
    clearTimeout(this.timer);
    const s = await App.api('/api/flashforge');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'FlashForge isn’t installed on this Kindle. It’s an optional app: copy flashforge.koplugin to koreader/plugins.')); return; }
    s.lines = App.arr(s.lines); s.temps = App.arr(s.temps); s.slots = App.arr(s.slots);
    main.append(
      h('div', {}, h('h1', {}, 'FlashForge'), h('p', { class: 'sub' }, 'Your FlashForge 3D printer, straight over the Wi-Fi (its LAN-only mode).')),
      ...[this.status(s), this.station(s), this.settings(s)].filter(Boolean));
    if (s.configured) {
      this.timer = setTimeout(() => {
        if (main.isConnected && location.hash.startsWith('#flashforge') && !document.querySelector('.modal')) this.reload();
      }, s.canCancel ? 10000 : 30000);
    }
  },

  reload() { App.route(); },

  async act(name, args, done) {
    try {
      await App.api('/api/flashforge/act', { json: { name, args } });
      if (done) App.toast(done);
      setTimeout(() => this.reload(), 2000);
    } catch (e) { App.fail(e); }
  },

  status(s) {
    const page = this;
    if (!s.configured) {
      return h('div', { class: 'card' }, h('h2', { style: 'margin-top:0' }, 'No printer set up yet'),
        h('p', { class: 'muted' }, 'Turn on LAN-only mode on the printer (Settings > Network) and note the check code it shows. Then enter its address, serial number and check code below, or use Find printers in FlashForge on the Kindle.'));
    }
    if (!s.state) {
      return h('div', { class: 'card' }, h('h2', { style: 'margin-top:0' }, s.name),
        h('p', { class: 'muted' }, s.why || 'Reading the printer…'),
        h('button', { class: 'btn', onclick: () => page.act('refresh', {}) }, 'Try again'));
    }
    const buttons = [];
    const btn = (text, fn, primary) => h('button', { class: 'btn small' + (primary ? ' primary' : ''), onclick: fn }, text);
    if (s.canPause) buttons.push(btn('Pause', () => page.act('pause', {}, 'Pausing…')));
    if (s.canResume) buttons.push(btn('Resume', () => page.act('resume', {}, 'Resuming…'), true));
    if (s.canCancel) buttons.push(btn('Cancel print', async () => {
      if (!(await App.confirm('Cancel print?', (s.file || 'The print') + ' stops and can’t be resumed.', 'Cancel print', true))) return;
      page.act('cancel', {}, 'Print cancelled');
    }));
    if (s.canClear) buttons.push(btn('Clear', () => page.act('clear', {}, 'Ready for the next print')));
    return h('div', { class: 'card' },
      h('div', { class: 'spread' },
        h('div', {}, h('h2', { style: 'margin:0' }, s.name, ' ', h('span', { class: 'muted small' }, s.model || '')),
          h('div', { style: 'font-size:22px;font-weight:700;margin-top:6px' }, s.summary),
          s.file && s.canCancel ? h('div', {}, s.file) : null,
          ...s.lines.map((l) => h('div', { class: 'muted small' }, l)),
          s.error ? h('div', { class: 'small' }, 'Error code ' + s.error) : null),
        h('div', { class: 'row', style: 'white-space:nowrap;gap:6px' }, ...buttons)),
      s.canCancel ? h('div', { class: 'progress', style: 'margin-top:10px' }, h('div', { style: 'width:' + Math.round((s.progress || 0) * 100) + '%' })) : null,
      h('div', { class: 'row', style: 'flex-wrap:wrap;gap:4px 18px;margin-top:12px' },
        ...s.temps.map((t) => h('div', { class: 'small' }, h('span', { class: 'muted' }, t.name + ' '), h('strong', {}, t.value)))),
      s.hasLight ? App.setting('Light', App.toggle(!!s.light, (v) => page.act('light', { on: v }))) : null,
      s.hasFiltration ? App.setting('Air filter', App.select([['off', 'Off'], ['internal', 'Internal (filters the air inside)'], ['external', 'External (vents the air out)']],
        s.filtration || 'off', (v) => page.act('filtration', { mode: v }))) : null,
      h('p', { class: 'small muted' }, (s.read ? 'Read ' + App.ago(s.read) : '') + (s.why ? ' · ' + s.why : '') +
        ' · Starting a print and the camera are in FlashForge on the Kindle.'));
  },

  station(s) {
    if (!s.slots.length) return null;
    return h('div', { class: 'card' }, h('h2', {}, 'Material Station'),
      s.slots.map((x) => h('div', { class: 'spread', style: 'padding:6px 0;border-top:1px solid var(--line)' },
        h('div', { class: 'row', style: 'gap:10px' },
          h('span', { style: 'display:inline-block;width:18px;height:18px;border-radius:4px;border:1px solid var(--line);background:' +
            (!x.empty && /^#[0-9a-fA-F]{6}$/.test(x.color || '') ? x.color : 'transparent') }),
          h('span', {}, 'Slot ' + x.id), h('span', { class: 'muted' }, x.text)),
        x.current ? h('span', { class: 'small' }, 'In use') : null)));
  },

  settings(s) {
    const page = this;
    const save = (args, done) => App.api('/api/flashforge/act', { json: { name: 'settings', args } })
      .then(() => { App.toast(done || 'Saved'); setTimeout(() => page.reload(), 1500); }).catch(App.fail);
    const ip = h('input', { type: 'text', value: s.ip || '', placeholder: '192.168.1.50' });
    const serial = h('input', { type: 'text', value: '', placeholder: s.configured ? 'Saved (type to change)' : 'SN…' });
    const code = h('input', { type: 'password', value: '', placeholder: s.hasCode ? 'Saved (type to change)' : 'From LAN-only mode' });
    return h('div', { class: 'card' }, h('h2', {}, 'Settings'),
      App.setting('Read every', App.select([[5, '5 seconds'], [10, '10 seconds'], [15, '15 seconds'], [30, '30 seconds'], [60, '1 minute'], [120, '2 minutes'], [300, '5 minutes']],
        s.interval || 10, (v) => save({ interval: Number(v) })), 'While FlashForge is open on the Kindle. Nothing is read once it closes.'),
      App.setting('Level the bed first', App.toggle(!!s.leveling, (v) => save({ leveling: v })), 'Before each print started from the Kindle.'),
      h('h3', {}, 'Printer'),
      App.setting('IP address', ip, 'On the printer: Settings > Network shows it.'),
      App.setting('Serial number', serial, 'On the printer: Settings > About. Include the SN at the start.'),
      App.setting('Check code', code, 'On the printer: Settings > Network > LAN-only mode shows it.'),
      h('div', { class: 'row', style: 'gap:8px;margin-top:10px' },
        h('button', { class: 'btn primary', onclick: () => save({ ip: ip.value.trim(), serial: serial.value.trim(), code: code.value.trim() }, 'Saved. Reading the printer…') }, 'Save'),
        s.configured ? App.connectionTest('flashforge') : null));
  },
};
