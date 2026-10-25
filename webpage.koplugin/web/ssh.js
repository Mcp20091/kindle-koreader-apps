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
    s.hosts.forEach((x) => { x.commands = App.arr(x.commands); });
    s.oses = App.arr(s.oses);
    this.s = s;
    main.append(...[
      h('div', {}, h('h1', {}, 'SSH'), h('p', { class: 'sub' }, 'Connect from the Kindle to your other devices and run commands. Set up hosts and keys here; connect on the Kindle (SSH).')),
      s.dbclient ? null : h('div', { class: 'card' }, h('p', { class: 'muted' }, 'dbclient wasn’t found on the Kindle. It comes with KOReader for Kindle (koreader/dbclient).')),
      this.hosts(s), s.ai && s.ai.available ? this.aiHelp(s) : null, this.keys(s), this.commandList(s)].filter(Boolean));
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
    const body = h('div', {},
      f('Name', name), f('Address', address), f('User', user), f('Port', port), f('System', system), f('Sign in with', auth), keyField, pwField, pwHint,
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
    await this.act('saveHost', args, 'Saved');
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
