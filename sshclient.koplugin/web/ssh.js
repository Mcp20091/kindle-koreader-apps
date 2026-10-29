// SSH: the hosts the Kindle connects to (address, user, port, a key or a password), each host's saved
// commands, the command list, and keys (upload a private key file, create one on the Kindle, copy a
// public key for a device's authorized_keys). Passwords are sent to the Kindle but never shown again.
App.pages.ssh = {
  async render(main) {
    const s = await App.api('/api/ssh');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'SSH isn’t installed on this Kindle.')); return; }
    s.hosts = App.arr(s.hosts);
    s.keys = App.arr(s.keys);
    s.commands = App.arr(s.commands);
    s.oses = App.arr(s.oses);
    s.icons = App.arr(s.icons);
    s.ops = App.arr(s.ops);
    s.sensorKinds = App.arr(s.sensorKinds);
    s.settings = s.settings || {};
    s.settings.every = App.arr(s.settings.every);
    // (an empty table comes as [], a list as one)
    const obj = (v) => (v && !Array.isArray(v) ? v : {});
    s.hosts.forEach((x) => {
      x.commands = App.arr(x.commands);
      x.groups = App.arr(x.groups);
      x.sensors = App.arr(x.sensors);
      x.customAlerts = App.arr(x.customAlerts);
      x.statList = App.arr(x.statList);
      x.alertList = App.arr(x.alertList);
      x.watchList = App.arr(x.watchList);
      x.quickList = App.arr(x.quickList);
      x.quickNow = App.arr(x.quickNow);
      x.stats = obj(x.stats);
      x.alerts = obj(x.alerts);
      x.quickIcons = obj(x.quickIcons);
    });
    this.s = s;
    main.append(...[
      h('div', {}, h('h1', {}, 'SSH'), h('p', { class: 'sub' }, 'Connect from the Kindle to your other devices and run commands. Set up hosts and keys here; connect on the Kindle (SSH).')),
      s.dbclient ? null : h('div', { class: 'card' }, h('p', { class: 'muted' }, 'dbclient wasn’t found on the Kindle. It comes with KOReader for Kindle (koreader/dbclient).')),
      this.hosts(s), this.settings(s), s.ai && s.ai.available ? this.aiHelp(s) : null, this.keys(s), this.commandList(s)].filter(Boolean));
  },

  // SSH's settings, as on the Kindle (SSH settings): each change is saved at once.
  settings(s) {
    const st = s.settings;
    const save = async (args) => {
      try {
        await App.api('/api/ssh/act', { json: { name: 'saveSettings', args } });
        App.toast('Saved');
      } catch (e) { App.fail(e); }
    };
    const row = (title, hint, control) => h('div', { class: 'spread', style: 'padding:8px 0;border-top:1px solid var(--line);margin-top:8px;gap:16px' },
      h('div', { style: 'flex:1;min-width:0' }, h('strong', {}, title), h('div', { class: 'small muted' }, hint)), control);
    const every = h('select', {}, st.every.map((e) => h('option', { value: e[0] }, e[1])));
    if (!st.every.some((e) => e[0] === st.check_every)) every.append(h('option', { value: st.check_every }, 'Every ' + st.check_every + ' min'));
    every.value = st.check_every;
    every.addEventListener('change', () => save({ check_every: Number(every.value) }));
    const toggle = (key, on) => {
      const box = h('input', { type: 'checkbox' });
      box.checked = on;
      box.addEventListener('change', () => save({ [key]: box.checked }));
      return box;
    };
    const size = h('select', {}, [10, 12, 14, 16, 18, 20, 22, 24].map((n) => h('option', { value: n }, n === 14 ? n + ' (default)' : String(n))));
    size.value = st.text_size;
    size.addEventListener('change', () => save({ text_size: Number(size.value) }));
    return h('div', { class: 'card' },
      h('h2', { style: 'margin:0' }, 'SSH settings'),
      row('Check hosts', 'Their status and alerts, while the Kindle is awake and on Wi-Fi. A host can have its own.', every),
      row('Stats under each host', 'Its first two, such as up 3 days · 52 °C', toggle('main_stats', st.main_stats)),
      row('Dark terminal', 'Also in a live session’s Keys', toggle('dark', st.dark)),
      row('Text size', 'The next live session opens with it (the same as KOReader’s Terminal emulator)', size));
  },

  // AI help (the launcher's AI, Settings > AI): explain or summarize output (pasted, or the last output on
  // the Kindle), write a command from a description, and ask more about the same thing. Secrets are
  // blanked on the Kindle before anything is sent. Nothing runs from here: a suggested command can be copied
  // or saved on a host, and run on the Kindle.
  aiHelp(s) {
    const page = this;
    const host = h('select', {}, h('option', { value: '' }, 'No host (any system)'), s.hosts.map((x) => h('option', { value: x.id }, x.name || x.address)));
    const cmd = h('input', { type: 'text', placeholder: 'df -h', style: 'font-family:monospace' });
    const output = h('textarea', { rows: 8, spellcheck: 'false', placeholder: 'Paste what the command printed (or the error).',
      style: 'width:100%;font-family:monospace;font-size:12px' });
    const want = h('input', { type: 'text', placeholder: 'Show the 10 largest folders in /var' });
    const answer = h('div', { style: 'margin-top:12px' });
    let conv = null;
    const fill = () => {
      const l = s.last;
      host.value = l.host || '';
      cmd.value = l.cmd || '';
      output.value = l.text || '';
    };
    const save = async (c) => {
      const x = s.hosts.find((x) => x.id === host.value);
      const name = await App.prompt(x ? 'Save on ' + (x.name || x.address) : 'Save in the command list', '', 'Name');
      if (name === null) return;
      try {
        await App.api('/api/ssh/act', { json: { name: 'addCommand', args: { id: x ? x.id : undefined, name, cmd: c } } });
        App.toast('Saved');
      } catch (e) { App.fail(e); }
    };
    const show = (r) => {
      const more = h('input', { type: 'text', placeholder: 'That didn’t work; it says…', style: 'flex:1;min-width:0' });
      const ask = () => {
        if (!more.value.trim()) return;
        conv.turns.push({ answer: r.raw, question: more.value.trim() });
        send();
      };
      more.addEventListener('keydown', (e) => { if (e.key === 'Enter') ask(); });
      answer.replaceChildren(
        // (the suggested commands show below, each with its buttons)
        h('div', { style: 'white-space:pre-wrap;border-top:1px solid var(--line);padding-top:10px' },
          String(r.answer || '').split('\n').filter((l) => !(l.startsWith('$ ') && App.arr(r.commands).includes(l.slice(2)))).join('\n').trim()),
        ...App.arr(r.commands).map((c) => h('div', { class: 'spread', style: 'margin-top:8px' },
          h('code', { style: 'flex:1;min-width:0;word-break:break-all' }, c),
          h('div', { class: 'row', style: 'white-space:nowrap' },
            h('button', { class: 'btn small', onclick: async () => {
              try { await navigator.clipboard.writeText(c); App.toast('Copied'); } catch (e) { App.prompt('Command', c); }
            } }, 'Copy'), ' ',
            h('button', { class: 'btn small', onclick: () => save(c) }, host.value ? 'Save on host' : 'Save in command list')))),
        h('p', { class: 'small muted' }, 'Answered by ' + (r.service || 'the AI') + '. AI suggestions can be wrong: run a command only if you understand what it does. You run it at your own risk.'),
        h('div', { class: 'row', style: 'margin-top:8px;flex-wrap:nowrap' }, more, ' ', h('button', { class: 'btn small', onclick: ask }, 'Ask more')));
    };
    const send = async () => {
      answer.replaceChildren(h('p', { class: 'muted' }, 'Asking…'));
      try {
        const { key } = await App.api('/api/ssh/ai', { json: { ...conv.args, turns: conv.turns } });
        const until = Date.now() + 5 * 60 * 1000;
        for (;;) {
          await new Promise((r) => setTimeout(r, 1500));
          const r = await App.api('/api/ssh/ai?key=' + encodeURIComponent(key));
          if (r.status === 'done') {
            if (r.why) { answer.replaceChildren(h('p', { class: 'muted' }, r.why)); return; }
            show(r);
            return;
          }
          if (Date.now() > until) { answer.replaceChildren(h('p', { class: 'muted' }, 'No answer came.')); return; }
        }
      } catch (e) { answer.replaceChildren(); App.fail(e); }
    };
    const start = (kind) => {
      if (kind === 'write' ? !want.value.trim() : !output.value.trim()) {
        App.toast(kind === 'write' ? 'Describe the command first' : 'Paste the output first', true);
        return;
      }
      conv = { args: { kind, host: host.value || undefined, cmd: cmd.value, output: output.value, want: want.value }, turns: [] };
      send();
    };
    const f = (label, input) => h('label', { class: 'field', style: 'margin-top:10px' }, h('span', {}, label), input);
    return h('div', { class: 'card' },
      h('div', { class: 'spread' }, h('h2', { style: 'margin:0' }, 'AI help'),
        s.last ? h('button', { class: 'btn small', onclick: fill }, 'Use the last output on the Kindle') : null),
      h('p', { class: 'small muted' }, 'Explain or summarize a command’s output, or write a command, with ' + (s.ai.service || 'the AI') +
        ' (which AI: the AI tab). Passwords, keys and tokens in it are blanked on the Kindle before it’s sent. Nothing runs from here.'),
      s.ai.ready ? null : h('p', { class: 'small' }, 'The AI for SSH isn’t set up yet: choose it on the AI tab.'),
      f('Host', host), f('Command', cmd), f('Output', output),
      h('div', { class: 'row', style: 'margin-top:10px' },
        h('button', { class: 'btn primary small', onclick: () => start('explain') }, 'Explain'), ' ',
        h('button', { class: 'btn small', onclick: () => start('summary') }, 'Summarize')),
      f('Write a command', want),
      h('div', { class: 'row', style: 'margin-top:10px' }, h('button', { class: 'btn small', onclick: () => start('write') }, 'Write a command')),
      answer);
  },

  reload() { App.route(); },

  async act(name, args, done) {
    try {
      const r = await App.api('/api/ssh/act', { json: { name, args } });
      if (done) App.toast(done);
      this.reload();
      return r.result || {};
    } catch (e) { App.fail(e); return null; }
  },

  // A system's name; a command's system: undefined any system, 'linux' any Linux.
  osName(id) {
    if (!id) return 'Any system';
    if (id === 'linux') return 'Any Linux';
    const o = (this.s.oses || []).find((o) => o.id === id);
    return o ? o.name : id;
  },

  // Whether a command fits a system (as the Kindle decides it).
  fits(c, os) {
    if (!os || !c.os || c.os === os) return true;
    if (c.os === 'linux') return !['windows', 'macos', 'freebsd', 'pfsense', 'truenascore'].includes(os);
    return c.os === 'debian' && os === 'raspberrypi';
  },

  systemLine(x) {
    if (x.os && x.os !== 'auto') return this.osName(x.os);
    return x.detected ? this.osName(x.detected) + ' (detected)' : 'System not detected yet';
  },

  authLine(x, s) {
    if (x.auth === 'key') {
      const k = s.keys.find((k) => k.id === x.key);
      return 'Key: ' + (k ? k.name : 'none chosen');
    }
    if (x.auth === 'password') return x.hasPassword ? 'Password (saved)' : 'Password (not saved)';
    return 'Asks for the password';
  },

  hosts(s) {
    const page = this;
    const label = (x) => x.user + '@' + x.address + (x.port && x.port !== 22 ? ':' + x.port : '');
    return h('div', { class: 'card' },
      h('div', { class: 'spread' }, h('h2', { style: 'margin:0' }, 'Hosts'),
        h('div', { class: 'row' },
          h('button', { class: 'btn small', onclick: () => page.importConfig() }, 'Import ~/.ssh/config'), ' ',
          h('button', { class: 'btn primary small', onclick: () => page.editHost(null) }, 'Add host'))),
      s.hosts.length ? s.hosts.map((x) => h('div', { class: 'spread', style: 'padding:8px 0;border-top:1px solid var(--line);margin-top:8px' },
        h('div', { style: 'flex:1;min-width:0' },
          h('strong', {}, x.name || x.address), h('span', { class: 'muted small' }, ' · ', label(x)),
          h('div', { class: 'small muted' }, page.systemLine(x), ' · ', page.authLine(x, s), ' · ', x.known ? 'Host key trusted' : 'Host key not trusted yet (the Kindle asks on the first connection)',
            ' · ', x.commands.length + (x.commands.length === 1 ? ' saved command' : ' saved commands'))),
        h('div', { class: 'row', style: 'white-space:nowrap' },
          h('button', { class: 'btn small', onclick: () => page.editCommands(x) }, 'Commands'), ' ',
          h('button', { class: 'btn small', onclick: () => page.editHost(x) }, 'Edit'))))
        : h('p', { class: 'muted' }, 'No hosts yet. Add your PC, NAS or Raspberry Pi: its address, your user name on it, and a key or password.'));
  },

  // Import ~/.ssh/config: its hosts added (the ones already here skipped), signing in with the first key on the Kindle,
  // or asking for the password when there's none.
  async importConfig() {
    const text = h('textarea', { rows: 12, spellcheck: 'false', style: 'width:100%;font-family:monospace;font-size:12px',
      placeholder: 'Host nas\n  HostName 192.168.1.5\n  User admin\n  Port 2222' });
    const body = h('div', {},
      h('p', { class: 'small muted' }, 'Paste your computer’s SSH config (on the computer: cat ~/.ssh/config, or open %USERPROFILE%\\.ssh\\config on Windows). Each Host with a User becomes a host on the Kindle; patterns like Host * are left out. Keys aren’t copied: upload them under Keys.'),
      text);
    const v = await App.modal('Import ~/.ssh/config', body,
      [{ text: 'Cancel', result: null }, { text: 'Import', primary: true, value: () => text.value }], true);
    if (!v || !v.trim()) return;
    const r = await this.act('importConfig', { text: v });
    if (r) App.toast('Added ' + (r.added || 0) + (r.added === 1 ? ' host' : ' hosts') + (r.skipped ? ' (' + r.skipped + ' skipped)' : ''));
  },

  async editHost(x) {
    const s = this.s;
    const f = (label, input) => h('label', { class: 'field', style: 'margin-top:10px' }, h('span', {}, label), input);
    const name = h('input', { type: 'text', value: x ? x.name : '', placeholder: 'Raspberry Pi' });
    const address = h('input', { type: 'text', value: x ? x.address : '', placeholder: '192.168.1.20 or nas.local' });
    const user = h('input', { type: 'text', value: x ? x.user : '', placeholder: 'pi' });
    const port = h('input', { type: 'number', value: x ? x.port : 22, min: 1, max: 65535 });
    const auth = h('select', {}, [['key', 'Key'], ['password', 'Password'], ['ask', 'Ask for the password each time']].map(([v, t]) => h('option', { value: v }, t)));
    auth.value = x ? x.auth : (s.keys.length ? 'key' : 'password');
    const key = h('select', {}, s.keys.map((k) => h('option', { value: k.id }, k.name + ' (' + k.type.replace('ssh-', '') + ')')));
    if (x && x.key) key.value = x.key;
    const password = h('input', { type: 'password', autocomplete: 'new-password',
      placeholder: x && x.hasPassword ? 'Saved; type a new one to change it' : '' });
    const system = h('select', {}, h('option', { value: 'auto' }, 'Detect automatically' + (x && x.os === 'auto' && x.detected ? ' (' + this.osName(x.detected) + ')' : '')),
      s.oses.map((o) => h('option', { value: o.id }, o.name)));
    system.value = x && x.os ? x.os : 'auto';
    const keyField = f('Key', s.keys.length ? key : h('div', { class: 'small muted' }, 'No keys yet: upload or create one under Keys, below.'));
    const pwField = f('Password', password);
    const pwHint = h('div', { class: 'small muted', style: 'margin-top:4px' }, 'Kept on the Kindle, in KOReader’s settings folder. It isn’t shown here again.');
    const show = () => {
      keyField.style.display = auth.value === 'key' ? '' : 'none';
      pwField.style.display = pwHint.style.display = auth.value === 'password' ? '' : 'none';
    };
    auth.addEventListener('change', show);
    show();
    // On the SSH page, Status and Wake on LAN (as on the Kindle's Edit host)
    const groups = h('input', { type: 'text', value: x ? x.groups.join(', ') : '', placeholder: 'Home, Servers' });
    const all = s.settings.check_every;
    const everyName = (n) => { const e = s.settings.every.find((e) => e[0] === n); return e ? e[1] : 'Every ' + n + ' min'; };
    const check = h('select', {}, h('option', { value: -1 }, 'Like every host (' + everyName(all).toLowerCase() + ')'),
      s.settings.every.map((e) => h('option', { value: e[0] }, e[1])));
    check.value = x && x.check !== undefined && x.check !== null ? x.check : -1;
    const readOnOpen = h('input', { type: 'checkbox' });
    readOnOpen.checked = !x || x.readOnOpen !== false;
    const mac = h('input', { type: 'text', value: x && x.mac ? x.mac : '', placeholder: x && x.macSeen ? x.macSeen : 'dc:a6:32:01:02:03' });
    // What the two boxes below change, kept until Save
    const draft = { stats: null, quick: null };
    const heading = (t) => h('h3', {}, t);
    const hint = (t) => h('div', { class: 'small muted', style: 'margin-top:4px' }, t);
    const boxes = x ? h('div', {}) : hint('Save the host first, then choose its stats, alerts and quick commands.');
    if (x) {
      const label = (text, n) => h('span', {}, text, h('span', { class: 'muted' }, ' · ' + n));
      const statsBtn = h('button', { class: 'btn small' });
      const quickBtn = h('button', { class: 'btn small' });
      const refresh = () => {
        const st = this.statsView(x, draft.stats);
        statsBtn.replaceChildren(label('Stats and alerts', st.shown + ' shown'));
        quickBtn.replaceChildren(label('Quick commands', (draft.quick ? draft.quick.list.length : x.quickNow.length) + ' shown'));
      };
      statsBtn.addEventListener('click', async () => {
        const v = await this.statsBox(x, draft.stats);
        if (v) { draft.stats = v; refresh(); }
      });
      quickBtn.addEventListener('click', async () => {
        const v = await this.quickBox(x, draft.quick);
        if (v) { draft.quick = v; refresh(); }
      });
      refresh();
      boxes.append(h('div', { class: 'row', style: 'margin-top:8px' }, statsBtn, ' ', quickBtn));
    }
    const wake = x && (x.mac || x.macSeen) ? h('button', { class: 'btn small', style: 'margin-top:8px', onclick: async () => {
      try { await App.api('/api/ssh/act', { json: { name: 'wakeHost', args: { id: x.id } } }); App.toast('Wake on LAN sent'); } catch (e) { App.fail(e); }
    } }, 'Wake it now') : null;
    const body = h('div', {},
      heading('Connection'),
      f('Name', name), f('Address', address), f('User', user), f('Port', port), f('System', system), f('Sign in with', auth), keyField, pwField, pwHint,
      heading('On the SSH page'),
      f('Groups', groups), hint('Separated by commas. They filter the SSH page and Run on several hosts.'),
      heading('Status'),
      f('Check it', check), hint('While the Kindle is awake and on Wi-Fi'),
      h('label', { class: 'row', style: 'margin-top:10px;gap:8px' }, readOnOpen, h('span', {}, 'Read when its page opens'), h('span', { class: 'small muted' }, ' · Otherwise only with ⟳ and the checks')),
      boxes,
      heading('Wake on LAN'),
      f('MAC address', mac), hint('To wake it when it’s off or asleep (Wake on LAN on in its BIOS or settings). Empty: read on the next connection.'), wake,
      x ? heading('Host key and host') : null,
      x ? h('div', { class: 'row', style: 'margin-top:14px' },
        x.known ? h('button', { class: 'btn small', onclick: async () => {
          if (!(await App.confirm('Forget host key', 'Forget the trusted key of ' + x.address + '? The Kindle asks to trust it again on the next connection.', 'Forget'))) return;
          document.querySelector('.modal-back').remove();
          this.act('forgetHost', { id: x.id }, 'Host key forgotten');
        } }, 'Forget host key') : null,
        h('button', { class: 'btn small danger', onclick: async () => {
          if (!(await App.confirm('Delete host', 'Delete ' + (x.name || x.address) + ' and its saved commands?', 'Delete', true))) return;
          document.querySelector('.modal-back').remove();
          this.act('deleteHost', { id: x.id }, 'Deleted');
        } }, 'Delete host')) : null);
    const v = await App.modal(x ? 'Edit host' : 'Add host', body,
      [{ text: 'Cancel', result: null }, { text: 'Save', primary: true, value: () => true }]);
    if (!v) return;
    const args = { name: name.value.trim(), address: address.value.trim(), user: user.value.trim(), port: port.value, auth: auth.value,
      key: auth.value === 'key' ? key.value : '', os: system.value };
    if (x) args.id = x.id;
    if (auth.value === 'password' && password.value !== '') args.password = password.value;
    if (auth.value !== 'password') args.password = '';
    args.groups = groups.value;
    args.mac = mac.value.trim();
    args.check = Number(check.value);
    args.readOnOpen = readOnOpen.checked;
    // (the host first; then the boxes' choices, for a host that exists)
    try {
      const call = (name, a) => App.api('/api/ssh/act', { json: { name, args: a } });
      await call('saveHost', args);
      if (x && draft.stats) await call('saveHostStats', { id: x.id, ...draft.stats });
      if (x && draft.quick) {
        await call('saveHostQuick', { id: x.id, quick: draft.quick.usual ? false : draft.quick.list, quickIcons: draft.quick.icons });
      }
      App.toast('Saved');
      this.reload();
    } catch (e) { App.fail(e); }
  },

  // A host's stats as the box shows them: what is shown now (the draft, if the box was used) and how many.
  statsView(x, d) {
    const stats = d ? d.stats : x.stats;
    const sensors = d ? d.sensors : x.sensors;
    const shown = (st) => (stats[st.id] !== undefined ? stats[st.id] : st.on);
    return {
      stats, sensors,
      shown: x.statList.filter((st) => !st.section && shown(st)).length + sensors.filter((c) => stats['cs_' + c.id] !== false).length,
      isShown: shown,
    };
  },

  // A custom alert in words: "Load (1 minute) above 4".
  alertText(a, watch) {
    const w = watch.find((w) => w.id === a.what);
    const op = this.s.ops.find((o) => o.id === a.op);
    return (w ? w.name : a.what) + ' ' + (op ? op.name : a.op) + ' ' + a.value + (w && w.unit && !w.text ? ' ' + w.unit : '');
  },

  // Stats and alerts: which stats show, custom sensors, alerts and custom alerts (the Kindle's Stats and
  // alerts page). Gives { stats, sensors, alerts, customAlerts } to save, or nothing when cancelled.
  async statsBox(x, draft) {
    const page = this;
    const d = draft ? JSON.parse(JSON.stringify(draft)) : {
      stats: { ...x.stats }, sensors: JSON.parse(JSON.stringify(x.sensors)), alerts: { ...x.alerts },
      customAlerts: JSON.parse(JSON.stringify(x.customAlerts)),
    };
    // (sensor ids are made here, as on the Kindle: s1, s2…)
    let top = 0;
    d.sensors.forEach((c) => { const n = Number(String(c.id).replace(/^s/, '')); if (n > top) top = n; });
    const statOn = (st) => (d.stats[st.id] !== undefined ? d.stats[st.id] : st.on);
    const sensorName = (c) => (c.name || '').trim() || c.cmd;
    const kindName = (k) => { const e = page.s.sensorKinds.find((e) => e.id === k); return e ? e.name : k; };
    // what a custom alert can watch: the usual ones, then the sensors
    const watch = () => [...x.watchList.filter((w) => !String(w.id).startsWith('cs_')),
      ...d.sensors.map((c) => ({ id: 'cs_' + c.id, name: sensorName(c), unit: c.kind === 'number' ? c.unit : (c.kind === 'percent' ? '%' : undefined),
        text: c.kind === 'text' || c.kind === 'ok' }))];
    const body = h('div', {});
    const btn = (text, fn, cls) => h('button', { class: 'btn small' + (cls ? ' ' + cls : ''), onclick: fn }, text);
    const check = (on, fn) => { const c = h('input', { type: 'checkbox' }); c.checked = on; c.addEventListener('change', () => fn(c.checked)); return c; };
    const line = (control, title, sub, buttons) => h('div', { class: 'spread', style: 'padding:6px 0;border-top:1px solid var(--line);gap:10px' },
      h('label', { class: 'row', style: 'flex:1;min-width:0;gap:8px' }, control, h('span', { style: 'min-width:0;word-break:break-word' }, title, sub ? h('div', { class: 'small muted' }, sub) : null)),
      buttons ? h('div', { class: 'row', style: 'white-space:nowrap' }, buttons) : null);
    const editSensor = async (c) => {
      const e = c ? { ...c } : { kind: 'number' };
      const name = h('input', { type: 'text', value: e.name || '', placeholder: 'Pool temperature, Backup done, …' });
      const cmd = h('input', { type: 'text', value: e.cmd || '', style: 'font-family:monospace' });
      const kind = h('select', {}, page.s.sensorKinds.map((k) => h('option', { value: k.id }, k.name + ' · ' + k.sub)));
      kind.value = e.kind;
      const unit = h('input', { type: 'text', value: e.unit || '', placeholder: '°C, GB, rpm… (or nothing)' });
      const unitField = h('label', { class: 'field', style: 'margin-top:10px' }, h('span', {}, 'Unit'), unit);
      const showUnit = () => { unitField.style.display = kind.value === 'number' ? '' : 'none'; };
      kind.addEventListener('change', showUnit);
      showUnit();
      const f = (label, input) => h('label', { class: 'field', style: 'margin-top:10px' }, h('span', {}, label), input);
      const v = await App.modal(c ? 'Edit custom sensor' : 'Add a custom sensor', h('div', {}, f('Name', name), f('The sensor’s command', cmd), f('What it gives', kind), unitField),
        [{ text: 'Cancel', result: null }, { text: 'Save', primary: true, value: () => ({ name: name.value.trim(), cmd: cmd.value, kind: kind.value, unit: unit.value.trim() }) }]);
      if (!v) return;
      if (!v.cmd.trim()) { App.toast('Enter the command', true); return; }
      if (c) Object.assign(c, v); else { top += 1; d.sensors.push({ id: 's' + top, ...v }); }
      render();
    };
    const editAlert = async (a) => {
      const w = watch();
      const e = a ? { ...a } : { what: w[0].id, op: 'gt', value: '' };
      const what = h('select', {}, w.map((x) => h('option', { value: x.id }, x.name)));
      what.value = e.what;
      const op = h('select', {}, page.s.ops.map((o) => h('option', { value: o.id }, o.name)));
      op.value = e.op;
      const value = h('input', { type: 'text', value: e.value === undefined ? '' : String(e.value) });
      const f = (label, input) => h('label', { class: 'field', style: 'margin-top:10px' }, h('span', {}, label), input);
      const v = await App.modal(a ? 'Edit custom alert' : 'Add a custom alert', h('div', {}, f('Alert when', what), f('Test', op), f('Value', value)),
        [{ text: 'Cancel', result: null }, { text: 'Save', primary: true, value: () => ({ what: what.value, op: op.value, value: value.value.trim() }) }]);
      if (!v) return;
      if (!v.value) { App.toast('Enter a value', true); return; }
      if ((v.op === 'gt' || v.op === 'lt') && Number.isNaN(Number(v.value))) { App.toast('Above and below need a number', true); return; }
      v.value = Number.isNaN(Number(v.value)) ? v.value : Number(v.value);
      if (a) Object.assign(a, v);
      else {
        const id = d.customAlerts.reduce((m, c) => Math.max(m, Number(c.id) || 0), 0) + 1;
        d.customAlerts.push({ id, ...v });
      }
      render();
    };
    const render = () => {
      const parts = [];
      parts.push(h('h3', {}, 'Shown'));
      x.statList.forEach((st) => parts.push(line(check(statOn(st), (on) => { d.stats[st.id] = on; }), st.name, st.sub)));
      parts.push(h('h3', {}, 'Custom sensors'));
      d.sensors.forEach((c) => parts.push(line(check(d.stats['cs_' + c.id] !== false, (on) => { d.stats['cs_' + c.id] = on; }),
        sensorName(c), c.cmd + ' · ' + kindName(c.kind), [btn('Edit', () => editSensor(c)), ' ',
          btn('Delete', () => {
            d.sensors.splice(d.sensors.indexOf(c), 1);
            delete d.alerts['cs_' + c.id];
            delete d.stats['cs_' + c.id];
            // (an alert on it goes too)
            d.customAlerts = d.customAlerts.filter((a) => a.what !== 'cs_' + c.id);
            render();
          }, 'danger')])));
      parts.push(btn('Add a custom sensor', () => editSensor(null)));
      parts.push(h('p', { class: 'small muted' }, 'A command of yours, shown as a number, a percent, text or OK.'));
      parts.push(h('h3', {}, 'Alerts · a notification'));
      x.alertList.forEach((a) => {
        const on = d.alerts[a.id];
        if (a.yesno) { parts.push(line(check(on === true, (v) => { if (v) d.alerts[a.id] = true; else delete d.alerts[a.id]; }), a.name)); return; }
        const steps = a.unit === '°C' ? [50, 60, 65, 70, 75, 80, 85] : [50, 70, 80, 85, 90, 95];
        if (on && !steps.includes(on)) steps.push(on);
        const sel = h('select', {}, h('option', { value: 0 }, 'Off'), steps.sort((p, q) => p - q).map((n) => h('option', { value: n }, 'Over ' + n + ' ' + a.unit)));
        sel.value = on || 0;
        sel.addEventListener('change', () => { if (Number(sel.value) > 0) d.alerts[a.id] = Number(sel.value); else delete d.alerts[a.id]; });
        parts.push(h('div', { class: 'spread', style: 'padding:6px 0;border-top:1px solid var(--line)' }, h('span', {}, a.name), sel));
      });
      d.sensors.forEach((c) => {
        const id = 'cs_' + c.id;
        if (c.kind === 'ok') parts.push(line(check(d.alerts[id] === true, (v) => { if (v) d.alerts[id] = true; else delete d.alerts[id]; }), sensorName(c) + ' failing'));
        else if (c.kind !== 'text') {
          const n = h('input', { type: 'number', value: d.alerts[id] === undefined ? '' : d.alerts[id], placeholder: 'Empty: no alert', style: 'width:9em' });
          n.addEventListener('input', () => { if (n.value.trim() !== '') d.alerts[id] = Number(n.value); else delete d.alerts[id]; });
          parts.push(h('div', { class: 'spread', style: 'padding:6px 0;border-top:1px solid var(--line)' }, h('span', {}, sensorName(c), h('span', { class: 'muted' }, ' · alert when over')), n));
        }
      });
      parts.push(h('h3', {}, 'Custom alerts'));
      d.customAlerts.forEach((a) => parts.push(h('div', { class: 'spread', style: 'padding:6px 0;border-top:1px solid var(--line);gap:10px' },
        h('span', {}, page.alertText(a, watch())),
        h('div', { class: 'row', style: 'white-space:nowrap' }, btn('Edit', () => editAlert(a)), ' ',
          btn('Delete', () => { d.customAlerts.splice(d.customAlerts.indexOf(a), 1); render(); }, 'danger')))));
      parts.push(btn('Add a custom alert', () => editAlert(null)));
      parts.push(h('p', { class: 'small muted' }, 'Any stat or sensor: above, below, is, isn’t or contains a value.'));
      body.replaceChildren(...parts);
    };
    render();
    return App.modal('Stats and alerts · ' + (x.name || x.address), body,
      [{ text: 'Cancel', result: null }, { text: 'Done', primary: true, value: () => d }], true);
  },

  // Quick commands: which show and in what order, more for this system, your own (the Kindle's Quick commands page).
  // Gives { usual, list, icons } to save, or nothing when cancelled.
  async quickBox(x, draft) {
    const page = this;
    const d = draft ? JSON.parse(JSON.stringify(draft)) : { usual: false, list: [...x.quickNow], icons: { ...x.quickIcons } };
    const byId = {};
    x.quickList.forEach((q) => { byId[q.id] = q; });
    const own = (id) => { const m = String(id).match(/^cmd:([\s\S]*)\|([^|]*)$/); return m ? { name: m[2] || m[1], sub: m[1] } : null; };
    const info = (id) => byId[id] || own(id);
    const body = h('div', {});
    const btn = (text, fn) => h('button', { class: 'btn small', onclick: fn }, text);
    const addOwn = (cmd, name, icon) => {
      const id = 'cmd:' + cmd + '|' + name;
      if (!d.list.includes(id)) d.list.push(id);
      if (icon) d.icons[id] = icon;
      d.usual = false;
      render();
    };
    const render = () => {
      const parts = [h('h3', {}, 'Shown, in this order')];
      d.list.forEach((id, i) => {
        const q = info(id);
        if (!q) return;
        parts.push(h('div', { class: 'spread', style: 'padding:6px 0;border-top:1px solid var(--line);gap:10px' },
          h('label', { class: 'row', style: 'flex:1;min-width:0;gap:8px' },
            (() => { const c = h('input', { type: 'checkbox' }); c.checked = true; c.addEventListener('change', () => { d.list.splice(i, 1); d.usual = false; render(); }); return c; })(),
            h('span', { style: 'min-width:0;word-break:break-word' }, q.name, h('div', { class: 'small muted', style: 'font-family:monospace' }, q.sub || ''))),
          h('div', { class: 'row', style: 'white-space:nowrap' },
            h('button', { class: 'icon-btn', title: 'Move up', onclick: () => { if (i > 0) { d.list.splice(i - 1, 0, d.list.splice(i, 1)[0]); d.usual = false; render(); } } }, '↑'), ' ',
            h('button', { class: 'icon-btn', title: 'Move down', onclick: () => { if (i < d.list.length - 1) { d.list.splice(i + 1, 0, d.list.splice(i, 1)[0]); d.usual = false; render(); } } }, '↓'))));
      });
      const more = x.quickList.filter((q) => !d.list.includes(q.id));
      if (more.length) parts.push(h('h3', {}, 'More for this system'));
      more.forEach((q) => {
        const c = h('input', { type: 'checkbox' });
        c.addEventListener('change', () => { d.list.push(q.id); d.usual = false; render(); });
        parts.push(h('label', { class: 'row', style: 'padding:6px 0;border-top:1px solid var(--line);gap:8px' }, c,
          h('span', {}, q.name, h('div', { class: 'small muted', style: 'font-family:monospace' }, q.sub || ''))));
      });
      // your own: a new one (name, command, icon), or one of the saved commands
      const from = [...x.commands, ...page.s.commands.filter((c) => !x.commands.some((y) => y.cmd === c.cmd))];
      const pick = from.length ? h('select', { style: 'margin-left:6px' }, h('option', { value: '' }, 'Add one of your commands…'),
        from.map((c, i) => h('option', { value: i }, c.name || c.cmd))) : null;
      if (pick) pick.addEventListener('change', () => { const c = from[Number(pick.value)]; if (c) addOwn(c.cmd, c.name || c.cmd); });
      parts.push(h('div', { class: 'row', style: 'margin-top:12px' },
        btn('New quick command', async () => {
          const f = (label, input) => h('label', { class: 'field', style: 'margin-top:10px' }, h('span', {}, label), input);
          const name = h('input', { type: 'text', placeholder: 'Backup, Logs…' });
          const cmd = h('input', { type: 'text', style: 'font-family:monospace' });
          const icon = h('select', {}, page.s.icons.map((i) => h('option', { value: i.id }, i.name)));
          const v = await App.modal('New quick command', h('div', {}, f('Name', name), h('div', { class: 'small muted' }, 'Short: it goes under the icon, such as Backup or Logs'),
            f('The command', cmd), f('Its icon', icon)),
          [{ text: 'Cancel', result: null }, { text: 'Save', primary: true, value: () => ({ name: name.value.trim(), cmd: cmd.value.trim(), icon: icon.value }) }]);
          if (!v) return;
          if (!v.cmd) { App.toast('Enter the command', true); return; }
          addOwn(v.cmd, v.name, v.icon);
        }), pick,
        btn('Back to the usual ones', () => { d.usual = true; d.list = [...x.quickUsual]; d.icons = {}; render(); })));
      body.replaceChildren(...parts);
    };
    render();
    return App.modal('Quick commands · ' + (x.name || x.address), body,
      [{ text: 'Cancel', result: null }, { text: 'Done', primary: true, value: () => d }], true);
  },

  // An editable list of commands (name, command, system), with ⧉ (copy) ↑ ↓ ✕, Add command and (for a
  // host) Add from command list; get() reads it back.
  commandRows(list, from_list) {
    const page = this;
    const box = h('div', { class: 'stack' });
    const systems = () => [['', 'Any system'], ['linux', 'Any Linux'], ...page.s.oses.filter((o) => o.id !== 'linux').map((o) => [o.id, o.name])];
    const row = (c) => {
      const sel = h('select', { title: 'System', style: 'flex:0 0 auto;max-width:9em' }, systems().map(([v, t]) => h('option', { value: v }, t)));
      sel.value = c.os || '';
      const r = h('div', { class: 'row', style: 'margin-top:6px;flex-wrap:nowrap' },
        h('input', { type: 'text', value: c.name || '', placeholder: 'Name', style: 'flex:1;min-width:0' }),
        h('input', { type: 'text', value: c.cmd || '', placeholder: 'Command', style: 'flex:2;min-width:0;font-family:monospace' }),
        sel,
        h('button', { class: 'icon-btn', title: 'Copy (edit the copy below)', onclick: () => {
          const [n, c2] = r.querySelectorAll('input');
          const copy = row({ name: n.value, cmd: c2.value, os: sel.value });
          box.insertBefore(copy, r.nextSibling);
          copy.querySelector('input').focus();
        } }, '⧉'),
        h('button', { class: 'icon-btn', title: 'Up', onclick: () => { if (r.previousElementSibling) box.insertBefore(r, r.previousElementSibling); } }, '↑'),
        h('button', { class: 'icon-btn', title: 'Down', onclick: () => { if (r.nextElementSibling) box.insertBefore(r.nextElementSibling, r); } }, '↓'),
        h('button', { class: 'icon-btn', title: 'Remove', onclick: () => r.remove() }, '✕'));
      r.dataset.id = c.id || '';
      r.dataset.builtIn = c.builtIn ? '1' : '';
      box.appendChild(r);
      return r;
    };
    list.forEach(row);
    // Add from command list: a copy of one of those, to change here.
    const from = from_list && from_list.length ? h('select', { style: 'margin-top:10px;margin-left:6px' },
      h('option', { value: '' }, 'Add from command list…'), from_list.map((c, i) => h('option', { value: i }, c.name || c.cmd))) : null;
    if (from) {
      from.addEventListener('change', () => {
        const c = from_list[Number(from.value)];
        from.value = '';
        if (!c) return;
        row({ name: c.name, cmd: c.cmd, os: c.os }).querySelectorAll('input')[1].focus();
      });
    }
    return {
      el: h('div', {}, box, h('button', { class: 'btn small', style: 'margin-top:10px', onclick: () => row({}) }, 'Add command'), from),
      box,
      get: () => [...box.children].map((r) => {
        const [n, c] = r.querySelectorAll('input');
        const os = r.querySelector('select').value;
        return { id: r.dataset.id || undefined, name: n.value.trim(), cmd: c.value, os: os || undefined };
      }).filter((c) => c.cmd.trim() !== ''),
    };
  },

  async editCommands(x) {
    const rows = this.commandRows(x.commands, this.s.commands);
    const v = await App.modal('Saved commands · ' + (x.name || x.address),
      h('div', {}, h('p', { class: 'small muted' }, 'One tap runs these on the Kindle (on the host’s page, and from a gesture).'), rows.el),
      [{ text: 'Cancel', result: null }, { text: 'Save', primary: true, value: () => rows.get() }], true);
    if (!v) return;
    await this.act('saveHostCommands', { id: x.id, list: v }, 'Saved');
  },

  commandList(s) {
    const page = this;
    const rows = this.commandRows(s.commands);
    // Show: hides the others (they're still saved)
    const show = h('select', {}, [['all', 'All'], ['custom', 'Custom'], ...s.oses.map((o) => [o.id, o.name])].map(([v, t]) => h('option', { value: v }, t)));
    show.addEventListener('change', () => {
      for (const r of rows.box.children) {
        const c = { os: r.querySelector('select').value || undefined };
        const ok = show.value === 'all' || (show.value === 'custom' ? !r.dataset.builtIn : page.fits(c, show.value));
        r.style.display = ok ? '' : 'none';
      }
    });
    return h('div', { class: 'card' },
      h('div', { class: 'spread' }, h('h2', { style: 'margin:0' }, 'Command list'), h('label', { class: 'row small' }, 'Show ', show)),
      h('p', { class: 'small muted' }, 'On the Kindle, Commands pastes one of these into the command box or a live session, on any host. It shows the commands for the host’s system first; Custom is your own.'),
      rows.el,
      h('div', { class: 'row', style: 'margin-top:12px' },
        h('button', { class: 'btn primary', onclick: () => this.act('saveCommands', { list: rows.get() }, 'Command list saved') }, 'Save'), ' ',
        h('button', { class: 'btn', onclick: async () => {
          const r = await this.act('addBuiltIn', {});
          if (r) App.toast(r.added ? 'Added ' + r.added + ' commands' : 'All built-in commands are in the list');
        } }, 'Restore built-in commands')));
  },

  keys(s) {
    const page = this;
    const copy = async (text) => {
      try { await navigator.clipboard.writeText(text); App.toast('Public key copied'); } catch (e) { App.prompt('Public key', text); }
    };
    const file = h('input', { type: 'file', style: 'display:none' });
    file.addEventListener('change', async () => {
      const f = file.files[0];
      file.value = '';
      if (!f) return;
      if (f.size > 64 * 1024) { App.toast('That isn’t a private key file.', true); return; }
      const text = await f.text();
      const name = await App.prompt('Key name', f.name.replace(/\.(pem|key)$/, ''));
      if (name === null) return;
      page.act('importKey', { name, text }, 'Key uploaded');
    });
    // Paste key: the private key file's text (from cat ~/.ssh/id_ed25519 on the computer).
    const paste = async () => {
      const name = h('input', { type: 'text', placeholder: 'PC key', style: 'width:100%' });
      const text = h('textarea', { rows: 9, spellcheck: 'false', style: 'width:100%;font-family:monospace;font-size:12px',
        placeholder: '-----BEGIN OPENSSH PRIVATE KEY-----\n…\n-----END OPENSSH PRIVATE KEY-----' });
      const body = h('div', {},
        h('label', { class: 'field' }, h('span', {}, 'Name'), name),
        h('label', { class: 'field', style: 'margin-top:10px' }, h('span', {}, 'Private key'), text),
        h('p', { class: 'small muted' }, 'Paste the whole private key file, including the BEGIN and END lines (on the computer: cat ~/.ssh/id_ed25519, or open the file in a text editor). Not the .pub file.'));
      const v = await App.modal('Paste key', body,
        [{ text: 'Cancel', result: null }, { text: 'Save', primary: true, value: () => ({ name: name.value.trim(), text: text.value.trim() + '\n' }) }], true);
      if (!v || v.text.trim() === '') return;
      page.act('importKey', v, 'Key saved');
    };
    const create = async () => {
      const name = await App.prompt('New key on the Kindle', 'Kindle');
      if (name === null) return;
      const r = await page.act('createKey', { name }, 'Key created');
      if (r && r.public) copy(r.public);
    };
    return h('div', { class: 'card' },
      h('div', { class: 'spread' }, h('h2', { style: 'margin:0' }, 'Keys'),
        h('div', { class: 'row' },
          h('button', { class: 'btn small', onclick: () => file.click() }, 'Upload key file'), ' ',
          h('button', { class: 'btn small', onclick: paste }, 'Paste key'), ' ',
          h('button', { class: 'btn small primary', onclick: create }, 'Create key'), file)),
      h('p', { class: 'small muted' }, 'Upload or paste a private key (id_ed25519, id_rsa, id_ecdsa; OpenSSH or Dropbear format, without a passphrase), or create one on the Kindle. Then add the public key to ~/.ssh/authorized_keys on each device. Private keys stay on the Kindle, in KOReader’s settings folder.'),
      s.keys.length ? s.keys.map((k) => {
        // The public key line, hidden until Show (private keys never leave the Kindle).
        const line = h('code', { class: 'small', style: 'display:none;word-break:break-all;margin-top:6px' }, k.public);
        const show = h('button', { class: 'btn small', onclick: () => {
          const hidden = line.style.display === 'none';
          line.style.display = hidden ? 'block' : 'none';
          show.textContent = hidden ? 'Hide' : 'Show';
        } }, 'Show');
        return h('div', { style: 'padding:8px 0;border-top:1px solid var(--line)' },
        h('div', { class: 'spread' },
          h('div', {}, h('strong', {}, k.name), h('span', { class: 'muted small' }, ' · ', k.type)),
          h('div', { class: 'row', style: 'white-space:nowrap' },
            show, ' ',
            h('button', { class: 'btn small', onclick: () => copy(k.public) }, 'Copy public key'), ' ',
            h('button', { class: 'btn small', onclick: async () => {
              const name = await App.prompt('Key name', k.name);
              if (name) page.act('renameKey', { id: k.id, name }, 'Renamed');
            } }, 'Rename'), ' ',
            h('button', { class: 'btn small danger', onclick: async () => {
              const users = s.hosts.filter((x) => x.auth === 'key' && x.key === k.id).map((x) => x.name || x.address);
              const text = 'Delete ' + k.name + ' from the Kindle?' + (users.length ? ' These hosts use it: ' + users.join(', ') + '.' : '');
              if (await App.confirm('Delete key', text, 'Delete', true)) page.act('deleteKey', { id: k.id }, 'Deleted');
            } }, 'Delete'))),
        line);
      })
        : h('p', { class: 'muted' }, 'No keys yet.'));
  },
};
