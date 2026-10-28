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
      githubCard(), pluginsCard(), versionsCard(), backupCard(), autoBackupCard(), tabsCard(), passwordCard(), httpsCard(), gesturesCard(),
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

    // How far an install has got: a line and a bar, shown once one starts.
    function installProgress() {
      const text = h('div', { class: 'small' });
      const bar = h('progress', { max: 100, style: 'width:100%' });
      const panel = h('div', { class: 'stack', style: 'display:none;margin-top:8px' }, text, bar);
      return { panel, show(t, pct, failed) {
        panel.style.display = '';
        text.textContent = t;
        text.style.color = failed ? 'var(--danger)' : '';
        if (pct == null) bar.removeAttribute('value'); else bar.value = pct;
        bar.style.display = failed ? 'none' : '';
      } };
    }
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

    // The zip sent with the browser counting what has gone (fetch can't tell).
    function upload(f, p) {
      return new Promise((resolve, reject) => {
        const x = new XMLHttpRequest();
        x.open('PUT', '/api/plugins/install');
        p.show('Uploading ' + f.name + '… 0%', 0);
        x.upload.onprogress = (e) => {
          if (!e.lengthComputable) return;
          const pct = Math.round(100 * e.loaded / e.total);
          p.show('Uploading ' + f.name + '… ' + pct + '%', pct);
        };
        x.onload = () => {
          let j = {};
          try { j = JSON.parse(x.responseText); } catch (e) { /* not JSON */ }
          if (x.status >= 200 && x.status < 300) resolve(j); else reject(new Error(j.error || 'The install failed'));
        };
        x.onerror = () => reject(new Error('The upload stopped. Check the Kindle’s Wi-Fi and try again.'));
        x.send(f);
      });
    }

    // Then the Kindle's own steps (checking and installing a plugin at a time), KOReader
    // restarting, and this page again once the Kindle answers (it starts the web server itself).
    async function followInstall(p) {
      for (;;) {
        let j = null;
        try { j = await App.api('/api/plugins/progress'); } catch (e) { /* restarting already */ }
        if (j && j.stage === 'failed') throw new Error('The update didn’t go through, so nothing changed. ' + (j.error || ''));
        if (j && j.stage === 'done') { p.show('Installed. Restart KOReader to use it.', 100); return; }
        if (j && (j.stage === 'receiving' || j.stage === 'downloading')) p.show(j.text || 'Getting the update…', j.total ? Math.round(100 * j.done / j.total) : null);
        if (j && (j.stage === 'checking' || j.stage === 'installing')) p.show(j.text || 'Installing…', j.total ? Math.round(100 * j.done / j.total) : null);
        if (!j || j.stage === 'restarting') break;
        await sleep(1000);
      }
      p.show('Installed. KOReader is restarting: don’t turn the Kindle off. This page comes back by itself.', null);
      let down = false;
      const until = Date.now() + 4 * 60 * 1000;
      while (Date.now() < until) {
        await sleep(2000);
        try {
          const r = await fetch('/api/plugins/progress', { cache: 'no-store' });
          const j = await r.json().catch(() => ({}));
          if (down || j.stage === 'none' || r.status === 401) { location.reload(); return; }
        } catch (e) { down = true; }
      }
      p.show('KOReader hasn’t answered yet. Once the Kindle shows its library again, start the web server there and reload this page.', null, true);
    }

    // Updates, as on the Kindle (Settings > Updates): the repository updates come from, a version
    // to install (test versions too with Show test versions on, past a warning), and the optional
    // apps with Install or Remove. A Kindle installed from a branch (as could be done before) gets
    // Back to the releases.
    function githubCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Updates'));
      App.api('/api/update').then((u) => {
        if (!u.launcher) { box.append(h('p', { class: 'muted small' }, 'Needs the launcher (apps.koplugin).')); return; }
        const repo = h('input', { type: 'text', value: u.repo, placeholder: 'owner/repository, such as ' + u.default, spellcheck: false, style: 'min-width:260px' });
        const version = h('select', { disabled: true, style: 'min-width:200px' }, h('option', {}, 'Looking up…'));
        const versionGo = h('button', { class: 'btn primary', disabled: true }, 'Install');
        const note = h('div', { class: 'small muted' });
        const p = installProgress();
        const also = h('div', { class: 'small muted' });
        const optional = h('div', { class: 'list-rows' });
        const repoName = () => repo.value.trim() || u.default;
        const busy = (on) => { for (const el of box.querySelectorAll('button, select, input')) el.disabled = on; };
        const run = async (start) => {
          busy(true);
          try {
            p.show('Starting…', null);
            await start();
            await followInstall(p);
          } catch (e) { p.show(e.message, 0, true); }
          busy(false);
        };
        // The optional apps of the test version installed, else of the latest release.
        let oseq = 0, latest = null, optTag = null;
        const lookOptional = async () => {
          const mine = ++oseq;
          also.textContent = '';
          optional.replaceChildren(h('div', { class: 'small muted' }, 'Looking them up…'));
          const from = { tag: optTag };
          try {
            let o = await App.api('/api/update/optional', { json: from });
            while (o.pending && mine === oseq) { await sleep(1000); o = await App.api('/api/update/optional'); }
            if (mine !== oseq) return;
            if (o.error) throw new Error(o.error);
            const apps = App.arr(o.apps);
            const mine2 = apps.filter((a) => a.installed).map((a) => a.title);
            also.textContent = mine2.length ? 'Also updates: ' + mine2.join(', ') + '.' : '';
            optional.replaceChildren();
            if (!apps.length) optional.append(h('div', {}, h('span', { class: 'small muted grow' }, 'None in ' + o.tag + '.')));
            for (const a of apps) {
              optional.append(h('div', {},
                h('span', { class: 'grow' }, h('div', {}, a.title), a.description ? h('div', { class: 'small muted' }, a.description) : null),
                // (Installed but older than the launcher, so it has no tile: Update, not Remove.)
                a.old
                  ? h('button', { class: 'btn small primary', onclick: async () => {
                      if (!await App.confirm('Update ' + a.title, 'This copy of ' + a.title + ' is older than the launcher, so it has no tile. Install it again from ' + o.tag + '? KOReader restarts after.', 'Update')) return;
                      run(() => App.api('/api/update/install', { json: { ...from, optional: a.folder } }));
                    } }, 'Update')
                : a.installed
                  ? h('button', { class: 'btn small danger', onclick: async () => {
                      if (!await App.confirm('Remove ' + a.title, a.title + ' is taken off the Kindle; Undo a plugin update can bring it back. KOReader restarts after.', 'Remove', true)) return;
                      run(() => App.api('/api/update/remove', { json: { folder: a.folder } }));
                    } }, 'Remove')
                  : h('button', { class: 'btn small primary', onclick: async () => {
                      if (!await App.confirm('Install ' + a.title, (a.description ? a.description + ' ' : '') + 'From ' + o.tag + '. KOReader restarts after.', 'Install')) return;
                      run(() => App.api('/api/update/install', { json: { ...from, optional: a.folder } }));
                    } }, 'Install')));
            }
          } catch (e) {
            if (mine !== oseq) return;
            optional.replaceChildren(h('div', {}, h('span', { class: 'small muted grow' }, 'Couldn’t look them up: ' + e.message)));
          }
        };
        let seq = 0;
        const look = async () => {
          const mine = ++seq;
          for (const el of [version, versionGo]) el.disabled = true;
          version.replaceChildren(h('option', {}, 'Looking up ' + repoName() + '…'));
          note.textContent = '';
          try {
            let l = await App.api('/api/update/list', { json: { repo: repo.value } });
            while (l.pending && mine === seq) { await sleep(1000); l = await App.api('/api/update/list'); }
            if (mine !== seq) return;
            if (l.error) throw new Error(l.error);
            // (Test versions only with Show test versions on, or the one installed.)
            const all = App.arr(l.releases);
            const rel = all.filter((r) => !r.pre || u.tests || (!u.branch && r.tag === u.installed));
            latest = (all.find((r) => !r.pre) || {}).tag || null;
            optTag = !u.branch && u.installed && u.installed.includes('-') && all.some((r) => r.tag === u.installed) ? u.installed : latest;
            if (rel.length) {
              version.replaceChildren(...rel.map((r) => h('option', { value: r.tag },
                r.tag + (r.tag === latest ? ' · latest' : '') + (r.pre ? ' · test' : '') + (!u.branch && r.tag === u.installed ? ' · installed' : ''))));
              if (latest) version.value = latest;
            } else {
              version.replaceChildren(h('option', {}, 'No releases'));
              note.textContent = l.repo + ' has no releases with kindle-plugins.zip.';
            }
            version.disabled = versionGo.disabled = !rel.length;
            if (back) back.disabled = !latest;
            if (optTag) lookOptional();
          } catch (e) {
            if (mine !== seq) return;
            version.replaceChildren(h('option', {}, 'Couldn’t look it up'));
            note.textContent = e.message;
          }
        };
        let t;
        repo.addEventListener('input', () => { clearTimeout(t); t = setTimeout(look, 800); });
        // (Installed from a branch: back to the latest release.)
        const back = u.branch ? h('button', { class: 'btn', disabled: true, onclick: async () => {
          if (!latest) return;
          if (!await App.confirm('Install ' + latest, 'Back to the releases: ' + latest + ' is installed in place of the ' + u.branch + ' branch, and updates come from the releases again. KOReader restarts after.', 'Install')) return;
          run(() => App.api('/api/update/install', { json: { tag: latest } }));
        } }, 'Back to the releases') : null;
        // Show test versions: on only past a warning, as on the Kindle.
        const tests = App.toggle(!!u.tests, async (on) => {
          if (on && !await App.confirm('Show test versions', 'Test versions are for trying changes before they’re released. They may have bugs or be unfinished, and aren’t offered as updates: you pick one in Select version. Select version or Undo a plugin update takes you back to a release.', 'Show them')) {
            tests.querySelector('input').checked = false;
            return;
          }
          try {
            u.tests = (await App.api('/api/update/tests', { json: { on } })).tests;
          } catch (e) { tests.querySelector('input').checked = !on; note.textContent = e.message; return; }
          look();
        });
        versionGo.addEventListener('click', async () => {
          const tag = version.value;
          if (!await App.confirm('Install ' + tag, 'Download ' + tag + ' from ' + repoName() + ' and install it? KOReader restarts after. Installed now: ' + (u.installed || 'not known') + '.', 'Install')) return;
          run(() => App.api('/api/update/install', { json: { tag } }));
        });
        box.append(...[
          h('p', { class: 'muted small' }, 'Installed: ' + (u.installed || 'not known') + '. Everything is checked before anything is put in place; the version replaced is kept (Undo a plugin update can go back).'),
          App.setting('Repository', repo),
          back ? App.setting('Branch', back, 'This Kindle has the ' + u.branch + ' branch. Updates come from its newer commits until it goes back to the releases.') : null,
          App.setting('Select version', h('div', { class: 'row' }, version, versionGo), 'The latest or a previous one.'),
          App.setting('Show test versions', tests, 'Versions for trying changes before they’re released, in Select version.'),
          also, note,
          h('div', { class: 'group-head' }, 'Optional apps'),
          h('div', { class: 'small muted' }, 'Install optional apps here. Once installed, they update automatically with each new version of the primary apps.'),
          optional, p.panel].filter(Boolean));
        look();
      }, () => box.append(h('p', { class: 'muted small' }, 'Not available.')));
      return box;
    }

    // Updating plugins: a zip of plugin folders, checked, installed, KOReader restarts.
    function pluginsCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Update plugins'),
        h('p', { class: 'muted small' }, 'Zip one or more plugin folders (such as apps.koplugin), or the whole kindle-install folder, and install it here. Every file is checked first; if anything is wrong, nothing changes. Your own files in a plugin’s folder are kept, and the version it replaces is kept so you can go back, here or on the Kindle (Tools > Web server > Undo a plugin update, or Settings > Updates > Undo a plugin update).'));
      const file = h('input', { type: 'file', accept: '.zip', style: 'display:none' });
      const p = installProgress();
      const pick = h('button', { class: 'btn primary', onclick: () => file.click() }, 'Install a zip…');
      file.addEventListener('change', async () => {
        const f = file.files[0];
        file.value = '';
        if (!f) return;
        if (!await App.confirm('Update plugins', 'Install the plugins in “' + f.name + '”? KOReader restarts afterwards.', 'Install')) return;
        pick.disabled = true;
        try {
          await upload(f, p);
          await followInstall(p);
        } catch (e) { p.show(e.message, 0, true); }
        pick.disabled = false;
      });
      const back = h('div', { class: 'list-rows' });
      box.append(h('div', {}, pick, file), p.panel, back);
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
            (location.protocol === 'https:' ? 'The page is encrypted (HTTPS), the password with it. '
              : 'It’s plain HTTP on your home network: a password keeps casual visitors out, but it isn’t encryption (HTTPS, below, is). ') +
            'On the Kindle, Tools > Web server > Remove password removes it.'),
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

    // HTTPS: on or off, the Kindle's own certificate or yours (pasted, or read from
    // files here in the browser and sent as text). A change starts the server again;
    // the page then goes to the address it answered with.
    function httpsCard() {
      const box = h('div', { class: 'card', style: 'margin-top:16px' }, h('h2', {}, 'HTTPS'));
      const moveTo = (r, what) => {
        App.toast(what + '. The web server is starting again…');
        setTimeout(() => { location.href = r.address + '/' + location.hash; }, 3000);
      };
      const until = (c) => !c ? 'none yet' : (c.daysLeft < 0 ? 'ended ' + c.until : 'until ' + c.until + (c.daysLeft < 30 ? ' (' + c.daysLeft + ' days left)' : ''));
      App.api('/api/https').then((s) => {
        const notRunning = s.on && !s.running
          ? h('p', { class: 'small', style: 'color:var(--danger)' }, 'HTTPS is on but didn’t start (the Kindle said why): the page is on plain HTTP. Use the Kindle’s own certificate, put yours in again, or turn HTTPS off.')
          : null;
        // Yours: two boxes to paste into, each with a file button that fills it.
        const area = (placeholder) => h('textarea', { rows: 4, placeholder, spellcheck: false, style: 'width:100%;font-family:monospace;font-size:12px' });
        const certText = area('-----BEGIN CERTIFICATE-----\n… (your certificate, then its chain if it has one)');
        const keyText = area('-----BEGIN PRIVATE KEY-----\n… (its key, without a passphrase)');
        const fileButton = (target, label) => {
          const file = h('input', { type: 'file', accept: '.pem,.crt,.cer,.key,.txt', style: 'display:none' });
          file.addEventListener('change', async () => {
            if (file.files[0]) target.value = await file.files[0].text();
            file.value = '';
          });
          return h('span', {}, file, h('button', { class: 'btn', onclick: () => file.click() }, label));
        };
        const plain = location.protocol !== 'https:';
        box.append(...[
          h('p', { class: 'muted small' }, 'Encrypts the page and everything on it, the password too. The Kindle makes its own certificate: '
            + 'browsers warn about it once (Advanced > Proceed). With a certificate of yours for a name your network knows, they don’t. '
            + 'No HSTS: turned off, the page works over plain HTTP again. On the Kindle: Tools > Web server > HTTPS.'),
          notRunning,
          App.setting('HTTPS', App.toggle(s.on, async (on) => {
            await App.api('/api/https', { json: { on } }).then((r) => moveTo(r, on ? 'HTTPS on' : 'HTTPS off'), App.fail);
          }), s.on ? 'Now at ' + s.address : 'Off: plain HTTP'),
          App.setting('Certificate', App.select([['kindle', 'The Kindle’s own'], ['own', 'Yours']], s.own ? 'own' : 'kindle', async (v) => {
            await App.api('/api/https', { json: { own: v === 'own' } }).then((r) => moveTo(r, 'Certificate changed'), (e) => { App.fail(e); App.route(); });
          }), 'The Kindle’s own: ' + until(s.kindle) + ' (made again 30 days before it ends). Yours: '
            + (s.yours ? until(s.yours) + (s.yours.names.length ? ', for ' + s.yours.names.join(', ') : '') : 'none') + '.'),
          h('div', { class: 'row', style: 'margin-top:8px' },
            h('button', { class: 'btn', onclick: async () => {
              if (await App.confirm('New certificate', 'The Kindle makes a new certificate of its own and uses it. Browsers warn about it once more.', 'Make it')) {
                await App.api('/api/https/new', { json: {} }).then((r) => (s.on ? moveTo(r, 'New certificate') : (App.toast('New certificate'), App.route())), App.fail);
              }
            } }, 'New certificate'),
            s.yours ? h('button', { class: 'btn danger', onclick: async () => {
              if (await App.confirm('Remove your certificate', 'Your certificate and key are deleted from the Kindle. HTTPS uses the Kindle’s own.', 'Remove', true)) {
                await App.api('/api/https/forget', { json: {} }).then((r) => (s.on && s.own ? moveTo(r, 'Removed') : (App.toast('Removed'), App.route())), App.fail);
              }
            } }, 'Remove yours') : null),
          h('h3', { style: 'margin-top:16px' }, 'Use your own certificate'),
          plain ? h('p', { class: 'small', style: 'color:var(--danger)' }, 'This page is on plain HTTP: the key would cross your Wi-Fi unencrypted. Turn HTTPS on first (with the Kindle’s own), then put yours in.') : null,
          h('div', { class: 'row' }, fileButton(certText, 'Certificate file…')), certText,
          h('div', { class: 'row', style: 'margin-top:8px' }, fileButton(keyText, 'Key file…')), keyText,
          h('div', { class: 'row', style: 'margin-top:8px' },
            h('button', { class: 'btn primary', onclick: async () => {
              await App.api('/api/https/cert', { json: { cert: certText.value, key: keyText.value } })
                .then((r) => moveTo(r, 'Your certificate is in use until ' + r.yours.until), App.fail);
            } }, 'Save and apply')),
        ].filter(Boolean));   // (append writes a null out as "null")
      }, App.fail);
      return box;
    }
  },
};
