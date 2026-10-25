// System: first what you'd come here to do (updating plugins, what's installed, backups and automatic
// ones, the tabs' order, the password, gestures), then Diagnostics, for when something goes wrong:
// problems (crashes and freezes), health (memory, uptime, detailed logging, a diagnostics file), the
// network and a check, sleep and wake history, the battery and the logs.
App.pages.system = {
  async render(main) {
    const diagnostics = h('div', { id: 'diagnostics', class: 'section-head' },
      h('h2', {}, 'Diagnostics'),
      h('p', { class: 'sub' }, 'For when something goes wrong: crashes and freezes, memory, the network, sleep, the battery and the logs.'));
    main.append(h('h1', {}, 'System'),
      h('p', { class: 'sub' }, 'Keeping the Kindle’s plugins and settings in order. Something wrong? ',
        h('a', { href: '#system', onclick: (e) => { e.preventDefault(); diagnostics.scrollIntoView({ block: 'start' }); } }, 'Diagnostics'), '.'),
      pluginsCard(), versionsCard(), backupCard(), autoBackupCard(), tabsCard(), passwordCard(), gesturesCard(),
      diagnostics,
      problemsCard(), healthCard(), networkCard(), sleepCard(), batteryCard(), logsCard());

    const dur = (s) => {
      const m = Math.round((s || 0) / 60);
      if (m < 60) return m + ' min';
      if (m < 48 * 60) return Math.floor(m / 60) + ' h' + (m % 60 ? ' ' + (m % 60) + ' min' : '');
      return Math.floor(m / 1440) + ' days ' + Math.floor((m % 1440) / 60) + ' h';
    };
    const clock = (t) => (t ? new Date(t * 1000).toLocaleString(undefined, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '–');

    // KOReader's crashes and freezes, read from its log, newest first.
    function problemsCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Problems'));
      App.api('/api/diag/problems').then((r) => {
        const list = App.arr(r.problems);
        if (!list.length) { box.append(h('p', { class: 'muted small' }, 'No crashes or freezes in KOReader’s log. 👍')); return; }
        const icon = { crash: '💥', freeze: '⏸', stopped: '⛔' };
        box.append(h('p', { class: 'muted small' }, 'From KOReader’s log (crash.log), newest first. “Stopped without closing” usually means it froze and was restarted by holding the power button.'),
          h('div', { class: 'stack' }, list.slice(0, 15).map((e) => h('details', {},
            h('summary', {}, (icon[e.kind] || '•') + ' ' + clock(e.time) + ' · ' + e.title + (e.recovered ? ' · then answered again' : '')),
            e.detail ? h('pre', { class: 'log', style: 'max-height:200px' }, e.detail) : null))));
      }).catch(() => box.append(h('p', { class: 'muted small' }, 'Not available.')));
      return box;
    }

    // Memory, uptime, detailed logging, and a file to send when something goes wrong.
    function healthCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Health'));
      const mem = h('div', { class: 'stack' });
      const log = h('div');
      box.append(mem, log,
        h('div', { class: 'row' }, h('a', { class: 'btn', href: '/api/diag/bundle' }, 'Download a diagnostics file'),
          h('span', { class: 'muted small' }, 'The logs, versions, problems, sleep history, memory, battery, network and the last connection check (with each error as it came), to send when something goes wrong. No passwords, keys or sign-ins.')));
      App.api('/api/diag/memory').then((m) => {
        const mb = (kb) => (kb ? Math.round(kb / 1024) + ' MB' : '–');
        mem.append(
          App.setting('KOReader’s memory', h('span', { class: 'muted small' }, mb(m.rss) + (m.peak ? ' (at most ' + mb(m.peak) + ')' : ''))),
          App.setting('Free memory', h('span', { class: 'muted small' }, mb(m.memAvailable) + ' of ' + mb(m.memTotal))),
          App.setting('KOReader running for', h('span', { class: 'muted small' }, m.running != null ? dur(m.running) : '–')),
          App.setting('Kindle on for', h('span', { class: 'muted small' }, m.uptime != null ? dur(m.uptime) : '–')),
          h('p', { class: 'muted small' }, 'If KOReader gets slow and its memory keeps growing, Restart KOReader (the launcher’s ⋮ menu, or Kindle controls on Home) clears it.'));
      }).catch(() => mem.append(h('p', { class: 'muted small' }, 'Memory: not available.')));
      const drawLog = (l) => log.replaceChildren(App.setting('Detailed logging',
        App.toggle(l.on, async (on) => { const r = await App.api('/api/diag/logging', { json: { on } }).catch(App.fail); if (r) drawLog(r); }),
        l.on ? (l.until ? 'On until ' + clock(l.until) + ', then off by itself.' : 'On (turned on in KOReader: stays on until turned off).')
          : 'KOReader writes much more to its log: turn on while tracking down a problem. Turns itself off after a day.'));
      App.api('/api/diag/logging').then(drawLog).catch(() => {});
      return box;
    }

    // Wi-Fi now, and a check of what the Kindle can reach.
    function networkCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Network'));
      const info = h('div', { class: 'stack' });
      // The connection check: every app that's set up, as each app's own Test connection does.
      const check = App.connectionTest(null);
      App.api('/api/diag/network').then((n) => {
        const sig = n.signal;
        const bars = sig && sig.quality != null ? Math.round(sig.quality / 70 * 100) + '%' + (sig.level ? ' (' + sig.level + ' dBm)' : '') : '–';
        info.append(
          App.setting('Wi-Fi', h('span', { class: 'muted small' }, n.wifiOn ? (n.connected ? 'Connected' : 'On, not connected') : 'Off')),
          App.setting('Signal', h('span', { class: 'muted small' }, bars)),
          App.setting('The Kindle’s address', h('span', { class: 'muted small' }, n.ip || '–')));
        // The last check, each app's own last results.
        const conn = App.obj(n.connections);
        const last = Object.values(conn).flatMap((x) => App.arr(x.results));
        if (last.length) check.show(last, Math.max(...Object.values(conn).map((x) => x.at || 0)));
        else if (n.last) check.show(n.last.results, n.last.at);
      }).catch(() => info.append(h('p', { class: 'muted small' }, 'Not available.')));
      box.append(info, h('p', { class: 'muted small' }, 'Tick what to test (your internet connection and the apps set up). Each address is tried on its own (Home Assistant at home and away, each AI service…), the same as each app’s Test connection here and on the Kindle (Settings > Launcher > Connection check). What doesn’t work goes in the log and the diagnostics file.'), check);
      return box;
    }

    // When the Kindle slept and woke, and the battery each time.
    function sleepCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Sleep and wake'));
      App.api('/api/diag/sleep').then((r) => {
        const list = App.arr(r.history);
        if (!list.length) { box.append(h('p', { class: 'muted small' }, 'Nothing yet: it’s noted from now on, each time the Kindle sleeps and wakes.')); return; }
        box.append(h('p', { class: 'muted small' }, 'Newest first. A Kindle that never sleeps, or wakes up again and again, shows here.'),
          h('div', { class: 'list-rows' }, list.map((e) => {
            const span = e.to ? dur(e.to - e.from) : 'now';
            const bat = e.pctFrom != null ? e.pctFrom + '%' + (e.pctTo != null ? ' → ' + e.pctTo + '%' : '') : '';
            return h('div', {},
              h('span', { class: 'grow' }, (e.kind === 'asleep' ? '🌙 Asleep' : (e.started ? '▶ KOReader started' : '☀ Awake')) + ' · ' + clock(e.from) + (e.to ? ' – ' + clock(e.to) : ' – now')),
              h('span', { class: 'muted small' }, span + (bat ? ' · ' + bat : '') + (e.charging ? ' · charging' : '')));
          })));
      }).catch(() => box.append(h('p', { class: 'muted small' }, 'Not available.')));
      return box;
    }

    // KOReader's battery statistics: awake, asleep and charging since the last charge, and what uses power now.
    function batteryCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Battery'));
      const time = (s) => {
        const m = Math.round((s || 0) / 60);
        return m < 60 ? m + ' min' : Math.floor(m / 60) + ' h' + (m % 60 ? ' ' + (m % 60) + ' min' : '');
      };
      const rate = (u) => (u ? Math.round(u.percent) + '% in ' + time(u.seconds) + (u.perHour != null ? ' · ' + u.perHour.toFixed(1) + '% an hour' : '') : '–');
      App.api('/api/battery').then((b) => {
        const left = !b.charging && b.awake && b.awake.perHour > 0 && b.pct != null ? b.pct / b.awake.perHour * 3600 : null;
        box.append(h('div', {}, h('div', { style: 'font-size:28px;font-weight:700' }, b.pct != null ? b.pct + '%' : '–'),
          h('div', { class: 'muted small' }, b.charging ? 'Charging' : left ? 'About ' + time(left) + ' left while awake, at this rate' : 'Not enough use yet to tell how long it will last')));
        if (b.available) {
          box.append(h('h3', {}, 'Since the last charge'),
            App.setting('Awake', h('span', { class: 'muted small' }, rate(b.awake))),
            App.setting('Asleep', h('span', { class: 'muted small' }, rate(b.asleep))),
            App.setting('In all', h('span', { class: 'muted small' }, rate(b.discharging))),
            h('h3', {}, 'The last charge'),
            App.setting('Charged', h('span', { class: 'muted small' }, rate(b.charged))));
        } else {
          box.append(h('p', { class: 'muted small' }, 'KOReader’s Battery statistics plugin is off. Turn it on on the Kindle: Tools > More tools > Plugin management.'));
        }
        box.append(h('h3', {}, 'On now'), h('ul', { class: 'small' }, App.arr(b.on).map((x) => h('li', {}, x))),
          h('p', { class: 'muted small' }, 'Wi-Fi, the light and anything kept running or awake use the most. (The web server is on while you look at this page.)'));
        if (b.available) {
          box.append(h('div', { class: 'row' }, h('button', { class: 'btn', onclick: async () => {
            if (!await App.confirm('Reset battery statistics', 'Clear KOReader’s battery statistics and start counting again?', 'Clear', true)) return;
            await App.api('/api/battery/reset', { json: {} }).then(() => { App.toast('Cleared'); App.route(); }, App.fail);
          } }, 'Reset statistics')));
        }
      }).catch(() => box.append(h('p', { class: 'muted small' }, 'Not available.')));
      return box;
    }

    // Each plugin's version, and what changed lately.
    function versionsCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'What’s installed'));
      App.api('/api/versions').then((v) => {
        const list = App.arr(v.plugins);
        const ours = list.filter((p) => p.version);
        const theirs = list.filter((p) => !p.version);
        box.append(h('div', { class: 'list-rows' }, ours.map((p) => {
          const changes = App.arr(p.changes);
          const more = h('div', { class: 'stack small muted', style: 'display:none;padding:6px 0 4px 4px' }, changes.map((c) => h('div', {}, c)));
          return h('div', { style: 'display:block' },
            h('div', { class: 'spread' }, h('div', {}, h('strong', {}, p.title || p.name.replace(/\.koplugin$/, '')), h('span', { class: 'muted small' }, '  ' + p.version)),
              changes.length ? h('button', { class: 'btn small', onclick: (e) => {
                const open = more.style.display === 'none';
                more.style.display = open ? '' : 'none';
                e.target.textContent = open ? 'Hide changes' : 'What changed';
              } }, 'What changed') : null),
            more);
        })));
        if (!ours.length) box.append(h('p', { class: 'muted small' }, 'No version details yet: they come with the next kindle-plugins.zip.'));
        if (theirs.length) box.append(h('p', { class: 'muted small' }, 'Also installed: ' + theirs.map((p) => p.title || p.name.replace(/\.koplugin$/, '')).join(', ') + '.'));
      }).catch(() => box.append(h('p', { class: 'muted small' }, 'Not available.')));
      return box;
    }

    // Updating plugins: a zip of plugin folders, checked, installed, KOReader restarts.
    function pluginsCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Update plugins'),
        h('p', { class: 'muted small' }, 'Zip one or more plugin folders (such as apps.koplugin), or the whole kindle-install folder, and install it here. Every file is checked first; if anything is wrong, nothing changes. Your own files in a plugin’s folder are kept, and the version it replaces is kept so you can go back, here or on the Kindle (Tools > Web server > Undo a plugin update, or Settings > Launcher > Undo a plugin update).'));
      const file = h('input', { type: 'file', accept: '.zip', style: 'display:none' });
      file.addEventListener('change', async () => {
        const f = file.files[0];
        file.value = '';
        if (!f) return;
        if (!await App.confirm('Update plugins', 'Install the plugins in “' + f.name + '”? KOReader restarts afterwards.', 'Install')) return;
        App.toast('Checking and installing…');
        try {
          const r = await fetch('/api/plugins/install', { method: 'PUT', body: f });
          const j = await r.json().catch(() => ({}));
          if (!r.ok) throw new Error(j.error || 'Install failed');
          App.toast('Installed ' + App.arr(j.installed).map((n) => n.replace(/\.koplugin$/, '')).join(', ') + '. ' + (j.restart ? 'KOReader is restarting…' : 'Restart KOReader to use them.'));
        } catch (e) { App.toast(e.message, true); }
      });
      const back = h('div', { class: 'list-rows' });
      box.append(h('div', {}, h('button', { class: 'btn primary', onclick: () => file.click() }, 'Install a zip…'), file), back);
      App.api('/api/plugins').then((p) => {
        const list = App.arr(p.backups);
        if (!list.length) return;
        back.append(h('div', { class: 'group-head' }, 'Earlier versions kept'));
        for (const b of list) {
          back.append(h('div', {}, h('span', { class: 'grow' }, b.name.replace(/\.koplugin$/, '')),
            h('span', { class: 'small muted' }, b.when ? 'replaced ' + b.when : ''),
            h('button', { class: 'btn small', onclick: async () => {
              if (!await App.confirm('Go back', 'Go back to the earlier version of ' + b.name.replace(/\.koplugin$/, '') + '? KOReader restarts.', 'Go back', true)) return;
              await App.api('/api/plugins/rollback', { json: { name: b.name } }).then((j) => App.toast(j.restart ? 'KOReader is restarting…' : 'Restart KOReader to use it.'), App.fail);
            } }, 'Go back')));
        }
      }).catch(() => {});
      return box;
    }

    // One zip of every plugin's settings and Notes' notebooks; putting one back restarts KOReader.
    function backupCard() {
      const secrets = h('input', { type: 'checkbox' });
      const file = h('input', { type: 'file', accept: '.zip', style: 'display:none' });
      file.addEventListener('change', async () => {
        const f = file.files[0];
        file.value = '';
        if (!f) return;
        if (!await App.confirm('Restore from a backup', 'Put back “' + f.name + '”? It replaces the settings, notebooks and folders it holds, and KOReader restarts.', 'Restore', true)) return;
        try {
          const r = await fetch('/api/backup/restore', { method: 'PUT', body: f });
          const j = await r.json().catch(() => ({}));
          if (!r.ok) throw new Error(j.error || 'Restore failed');
          App.toast('Restored ' + j.files + ' files. ' + (j.restart ? 'KOReader is restarting…' : 'Restart KOReader to use them.'));
        } catch (e) { App.toast(e.message, true); }
      });
      const secretsLabel = h('label', { class: 'switch' }, secrets, h('span'));
      // Which apps it holds, as the Kindle says (each app adds its own).
      const what = h('p', { class: 'muted small' }, 'One zip of every app’s settings and data, and every notebook (folders, trash and pictures too).');
      const secretsHint = h('span', {}, 'Sign-ins and keys. Keep that zip private.');
      App.api('/api/backup/apps').then((r) => {
        const apps = App.arr(r.apps);
        if (!apps.length) return;
        what.textContent = 'One zip of the settings and data of: ' + apps.map((a) => a.name).join(', ') + '. Notes’ notebooks include folders, trash and pictures.';
        const sec = apps.filter((a) => a.secrets).map((a) => a.name);
        if (sec.length) secretsHint.textContent = 'The sign-ins and keys of ' + sec.join(', ') + '. Keep that zip private.';
      }, () => {});
      return h('div', { class: 'card', style: 'margin-top:16px' }, h('h2', {}, 'Backup'),
        what,
        App.setting('Include keys and sign-ins', secretsLabel, secretsHint),
        h('div', { class: 'row', style: 'margin-top:8px' },
          h('button', { class: 'btn primary', onclick: () => { location.href = '/api/backup' + (secrets.checked ? '?secrets=1' : ''); } }, 'Download backup'),
          h('button', { class: 'btn', onclick: () => file.click() }, 'Restore from a backup…'), file));
    }
    // A weekly backup kept on the Kindle (settings and notebooks, no sign-ins).
    function autoBackupCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Automatic backups'));
      const load = () => App.api('/api/autobackup').then((a) => {
        box.replaceChildren(h('h2', {}, 'Automatic backups'),
          App.setting('Weekly backup', App.toggle(a.on, (on) => App.api('/api/autobackup', { json: { on } }).catch(App.fail)),
            'Once a week, a backup of the settings and notebooks (no sign-ins) is saved on the Kindle, in koreader/backups.'),
          App.setting('Keep', App.select([['2', 'The last 2'], ['4', 'The last 4'], ['8', 'The last 8']], String(a.keep), (v) => App.api('/api/autobackup', { json: { keep: Number(v) } }).catch(App.fail))),
          h('div', { class: 'row' }, h('button', { class: 'btn', onclick: async () => {
            App.toast('Making a backup…');
            await App.api('/api/autobackup/now', { json: {} }).then(() => { App.toast('Backup saved on the Kindle'); load(); }, App.fail);
          } }, 'Back up now'), h('span', { class: 'muted small' }, a.last ? 'Last: ' + App.when(a.last) : 'None yet')),
          ...(App.arr(a.backups).length ? [h('div', { class: 'list-rows' }, App.arr(a.backups).map((b) => h('div', {},
            h('span', { class: 'grow' }, b.name), h('span', { class: 'muted small' }, App.size(b.size)),
            h('a', { class: 'btn small', href: '/api/autobackup/file?name=' + encodeURIComponent(b.name) }, 'Download'),
            h('button', { class: 'btn small danger', onclick: async () => {
              if (!await App.confirm('Delete backup', 'Delete ' + b.name + ' from the Kindle?', 'Delete', true)) return;
              await App.api('/api/autobackup/delete', { json: { name: b.name } }).then(load, App.fail);
            } }, 'Delete'))))] : []));
      }).catch(() => box.append(h('p', { class: 'muted small' }, 'Not available.')));
      load();
      return box;
    }

    // KOReader's crash log and the sleep screen updates' log: the end of each, and the whole file.
    function logsCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Logs'));
      const view = h('pre', { class: 'log', style: 'display:none' });
      App.api('/api/logs').then((l) => {
        const logs = App.arr(l.logs);
        if (!logs.length) { box.append(h('p', { class: 'muted small' }, 'No logs yet.')); return; }
        box.append(h('div', { class: 'list-rows' }, logs.map((g) => h('div', {},
          h('span', { class: 'grow' }, g.title), h('span', { class: 'muted small' }, App.size(g.size) + ' · ' + App.when(g.mtime)),
          h('button', { class: 'btn small', onclick: async () => {
            const r = await App.api('/api/logs/view?lines=400&name=' + encodeURIComponent(g.name)).catch(App.fail);
            if (!r) return;
            view.textContent = r.text || '(empty)';
            view.style.display = '';
            view.scrollTop = view.scrollHeight;
          } }, 'Show the end'),
          h('a', { class: 'btn small', href: '/api/logs/view?download=1&name=' + encodeURIComponent(g.name) }, 'Download')))), view);
      }).catch(() => box.append(h('p', { class: 'muted small' }, 'Not available.')));
      return box;
    }

    // What each KOReader gesture does (to look at: they are changed on the Kindle).
    function gesturesCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Gestures'));
      App.api('/api/gestures').then((g) => {
        if (!g.available) { box.append(h('p', { class: 'muted small' }, 'Needs the launcher and KOReader’s Gestures plugin.')); return; }
        let mode = g.current || 'fm';
        const body = h('div');
        const draw = () => {
          const sections = App.arr(g[mode]);
          body.replaceChildren(App.tabs([['fm', 'In the library'], ['reader', 'In a book']], mode, (m) => { mode = m; draw(); }),
            ...(sections.length ? sections.map((s) => h('div', {}, h('h3', {}, s.title),
              h('div', { class: 'list-rows' }, App.arr(s.rows).map((r) => h('div', {}, h('span', { style: 'min-width:9em' }, r.name), h('span', { class: 'muted' }, '→  ' + r.actions))))))
              : [h('div', { class: 'empty' }, 'No gestures are set.')]));
        };
        draw();
        box.append(h('p', { class: 'muted small' }, 'To change one, use the Gestures tile on the Kindle’s launcher, or Settings > Taps and gestures > Gesture manager.'), body);
      }).catch(() => box.append(h('p', { class: 'muted small' }, 'Not available.')));
      return box;
    }

    // The tabs at the top: their order, and the ones hidden (kept on the Kindle, so every
    // phone and computer shows the same). Home and System can't be hidden.
    function tabsCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Tabs'));
      const links = () => [...document.querySelectorAll('#nav a[data-page]')].filter((a) => !a.classList.contains('off'));
      const item = (a) => ({ key: a.dataset.page, name: a.textContent });
      const always = (it) => it.key === 'home' || it.key === 'system';
      const save = (state) => {
        const tabs = { order: [...state.shown, ...state.hidden], hidden: state.hidden };
        App.applyTabs(tabs);
        App.api('/api/tabs', { json: tabs }).catch(App.fail);
      };
      const editor = () => App.visualZones([
        { id: 'shown', title: 'Shown', items: links().filter((a) => !a.classList.contains('hidden-tab')).map(item),
          render: (it) => h('span', { class: 'tab-chip' }, it.name) },
        { id: 'hidden', title: 'Hidden', short: 'Hidden', className: 'tray', empty: 'Drop a tab here to hide it',
          items: links().filter((a) => a.classList.contains('hidden-tab')).map(item),
          render: (it) => h('span', { class: 'tab-chip muted' }, it.name), accept: (it) => !always(it) },
      ], { onChange: save });
      let body = editor();
      box.append(h('p', { class: 'muted small' }, 'Drag tabs to reorder them, or into Hidden. On a phone, tap one. Home and System always show.'), body,
        h('div', { class: 'row' }, h('button', { class: 'btn', onclick: () => {
          App.applyTabs({});
          App.api('/api/tabs', { json: {} }).catch(App.fail);
          const fresh = editor();
          body.replaceWith(fresh);
          body = fresh;
        } }, 'Reset')));
      return box;
    }

    // An optional password for this page (a salted hash is kept on the Kindle).
    function passwordCard() {
      const box = h('div', { class: 'card', style: 'margin-top:16px' }, h('h2', {}, 'Password'));
      App.api('/api/password').then((p) => {
        const pw = h('input', { type: 'password', placeholder: p.set ? 'New password' : 'Password', autocomplete: 'new-password' });
        box.append(
          h('p', { class: 'muted small' }, (p.set ? 'This page asks for a password. ' : 'Anyone on your Wi-Fi can open this page. ') +
            'It’s plain HTTP on your home network: a password keeps casual visitors out, but it isn’t encryption. On the Kindle, Tools > Web server > Remove password removes it.'),
          h('div', { class: 'row' }, pw,
            h('button', { class: 'btn primary', onclick: async () => {
              await App.api('/api/password', { json: { password: pw.value } }).then(() => { App.toast('Password set'); App.route(); }, App.fail);
            } }, p.set ? 'Change' : 'Set'),
            p.set ? h('button', { class: 'btn danger', onclick: async () => {
              if (await App.confirm('Remove password', 'Anyone on your Wi-Fi will be able to open this page.', 'Remove', true)) {
                await App.api('/api/password', { json: { password: '' } }).then(() => { App.toast('Password removed'); App.route(); }, App.fail);
              }
            } }, 'Remove') : null,
            p.set ? h('button', { class: 'btn', onclick: async () => { await App.api('/api/logout', { json: {} }).catch(() => {}); location.href = '/login'; } }, 'Sign out') : null));
      }, App.fail);
      return box;
    }
  },
};
