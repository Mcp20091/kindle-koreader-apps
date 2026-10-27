// The front page: the reader's state and the sections.
App.pages.home = {
  async render(main) {
    const s = await App.api('/api/home');
    const used = s.storage.total ? (s.storage.total - s.storage.available) / s.storage.total : 0;
    main.append(
      h('h1', {}, s.model || 'Kindle'),
      h('p', { class: 'sub' }, 'KOReader ' + (s.koreader || '') + (s.awake ? ' · Kindle stays awake while the web server is running' : '')),
      h('div', { class: 'grid' },
        h('div', { class: 'card' }, h('h3', { style: 'margin-top:0' }, 'Battery'),
          h('div', { style: 'font-size:28px;font-weight:700' }, s.battery != null ? s.battery + '%' : '–'),
          h('div', { class: 'muted small' }, s.charging ? 'Charging' : 'On battery')),
        h('div', { class: 'card' }, h('h3', { style: 'margin-top:0' }, 'Storage'),
          h('div', { style: 'font-size:28px;font-weight:700' }, App.size(s.storage.available) || '–'),
          h('div', { class: 'muted small' }, 'free of ' + App.size(s.storage.total)),
          h('div', { class: 'progress', style: 'margin-top:8px' }, h('div', { style: 'width:' + Math.round(used * 100) + '%' })))),
      h('h3', {}, 'On this page'),
      h('div', { class: 'grid' },
        // In the order of the tabs at the top.
        card('#dashboard', 'Dashboard', 'Your own page: parts from the other tabs, in your order.', true),
        card('#files', 'Files', 'Upload, download and organize books and other files.', true),
        card('#reading', 'Reading', 'Reading time, days in a row and each book.', true),
        card('#apps', 'Launcher', 'Tiles, shortcuts and settings.', s.plugins.apps),
        card('#ha', 'Home Assistant', 'Connection, devices, Quick tiles, layout, settings and backup.', s.plugins.homeassistant),
        card('#todo', 'To Do', 'Lists and tasks, import and export, account and options.', s.plugins.todo),
        card('#notes', 'Notes', 'Notebooks in their folders, settings, OneNote and AI.', s.plugins.notes),
        card('#crosswords', 'Crosswords', 'Puzzle books, and getting new crosswords.', s.plugins.crosswords),
        card('#wikipedia', 'Wikipedia', 'Saved articles, and saving new ones to the Kindle.', s.plugins.wikipedia),
        card('#syncthing', 'Syncthing', 'Folders, devices and requests.', s.plugins.syncthing),
        card('#ssh', 'SSH', 'Hosts, the command list and keys.', s.plugins.sshclient),
        // (an optional app: its card only when it's installed)
        s.plugins.flashforge ? card('#flashforge', 'FlashForge', 'Your 3D printer: the print, pause and cancel, the light and settings.', true) : null,
        s.plugins.pangolin ? card('#pangolin', 'Pangolin', 'Your Pangolin server: sites, resources and clients, and turning them on or off.', true) : null,
        card('#fonts', 'Fonts', 'Your fonts, getting more, the default and the font settings.', s.plugins.apps),
        card('#koreader', 'KOReader', 'Folders, common settings and KOReader’s whole menu.', true),
        card('#system', 'System', 'Update plugins, backups, logs, gestures and the password.', true)),
      ...[App.kindleControls(), screenCard(), sendCard(), sleepCard()].filter(Boolean));

    // The sleep screen To Do, Home Assistant and Apps share.
    function sleepCard() {
      const box = h('div', { class: 'card', style: 'margin-top:16px' }, h('h2', {}, 'Sleep screen'));
      App.api('/api/sleep').then((sl) => {
        const post = (json) => App.api('/api/sleep', { json }).catch(App.fail);
        if (!sl.supported) {
          box.append(h('p', { class: 'muted small' }, 'On this Kindle KOReader doesn’t draw the sleep screen (Amazon’s lock-screen ads are on), so these apps can’t show anything there.'));
          return;
        }
        box.append(
          App.setting('Sleep screen', App.select(App.arr(sl.choices), sl.app, (v) => post({ app: v }))),
          App.setting('Sleep screen updates',
            App.select([['0', 'Off'], ['15', 'Every 15 min'], ['30', 'Every 30 min'], ['60', 'Every hour']], String(sl.update), (v) => post({ update: Number(v) })),
            'The Kindle wakes briefly to draw it again.'),
          h('p', { class: 'muted small' }, 'Each wake is noted in koreader/sleep-update.log, with the battery level.'));
      }).catch(() => box.append(h('p', { class: 'muted small' }, 'Not available.')));
      return box;
    }

    // Text typed here, onto the Kindle: into the box open there (as its keyboard would,
    // then Enter if ticked), a To Do task (the first line its title, the rest its notes)
    // or a new Notes page.
    function sendCard() {
      const text = h('textarea', { rows: 3, placeholder: 'Text for the Kindle: a search, a task, a note…' });
      const to = h('select', {}, h('option', { value: 'type' }, 'The box open on the Kindle'));
      const enter = h('input', { type: 'checkbox' });
      const enterLabel = h('label', { class: 'row small', style: 'gap:6px' }, enter, 'Then press Enter');
      const showEnter = () => { enterLabel.style.display = to.value === 'type' ? '' : 'none'; };
      to.addEventListener('change', showEnter);
      if (s.sendNotes) to.append(h('option', { value: 'notes' }, 'Notes: a new page'));
      if (s.plugins.todo) {
        App.api('/api/todo').then((t) => {
          const lists = App.arr(t.lists).filter((l) => !l.flagged);
          lists.forEach((l, i) => to.insertBefore(h('option', { value: 'todo:' + l.id }, 'To Do: ' + l.name), to.options[i + 1] || null));
        }).catch(() => {});
      }
      showEnter();
      return h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Send to the Kindle'),
        text,
        h('div', { class: 'row' }, to, enterLabel, h('button', { class: 'btn primary', onclick: send }, 'Send')));
      async function send() {
        if (to.value === 'type') {
          // (As typed: spaces kept; empty with Enter just presses Enter.)
          if (!text.value && !enter.checked) return;
          const r = await App.api('/api/kindle/type', { json: { text: text.value, enter: enter.checked } }).catch(App.fail);
          if (r) { App.toast(r.title ? 'Typed into “' + r.title + '”' : 'Typed on the Kindle'); text.value = ''; }
          return;
        }
        const value = text.value.trim();
        if (!value || !to.value) return;
        if (to.value === 'notes') {
          const r = await App.api('/api/send/notes', { json: { text: value } }).catch(App.fail);
          if (r) { App.toast('Sent to Notes' + (r.where ? ': ' + r.where : '')); text.value = ''; }
          return;
        }
        const [title, ...rest] = value.split('\n');
        const r = await App.api('/api/todo/task', { json: { op: 'add', list: to.value.slice(5), title: title.trim(), notes: rest.join('\n').trim() } }).catch(App.fail);
        if (r) { App.toast('Sent to To Do'); text.value = ''; }
      }
    }

    // The Kindle's screen as a picture, and a remote (App.remote).
    function screenCard() { return App.remote(); }
    function card(href, title, text, on) {
      return h('a', { href: on ? href : undefined, class: 'card', style: 'text-decoration:none;display:block' + (on ? '' : ';opacity:.5') },
        h('div', { style: 'font-weight:700;margin-bottom:4px' }, title), h('div', { class: 'muted small' }, on ? text : 'Plugin not installed.'));
    }
  },
};

// The Kindle's light, warmth and night mode, and a refresh, Wi-Fi, sleep and restart.
App.kindleControls = function () {
  const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Kindle'));
  const control = (json) => App.api('/api/kindle/control', { json }).catch(App.fail);
  App.api('/api/kindle').then((k) => {
    if (k.light) {
      const slider = h('input', { type: 'range', min: k.light.min, max: k.light.max, value: k.light.value, style: 'width:220px' });
      slider.addEventListener('change', () => control({ action: 'light', value: Number(slider.value) }));
      box.append(App.setting('Light', h('div', { class: 'row' }, slider,
        App.toggle(k.light.on, (on) => control({ action: 'light', on })))));
    }
    if (k.warmth) {
      const warm = h('input', { type: 'range', min: k.warmth.min, max: k.warmth.max, value: k.warmth.value, style: 'width:220px' });
      warm.addEventListener('change', () => control({ action: 'warmth', value: Number(warm.value) }));
      box.append(App.setting('Warmth', warm));
    }
    box.append(App.setting('Night mode', App.toggle(k.night, () => control({ action: 'night' }))));
    const ask = async (title, text, ok, json, done) => {
      if (!await App.confirm(title, text, ok, true)) return;
      await control(json);
      if (done) App.toast(done);
    };
    box.append(h('div', { class: 'row' },
      h('button', { class: 'btn', onclick: () => control({ action: 'refresh' }) }, 'Refresh screen'),
      k.wifi ? h('button', { class: 'btn', onclick: () => ask('Turn off Wi-Fi', 'This page stops working until Wi-Fi is on again and the web server is started on the Kindle.', 'Turn off', { action: 'wifi_off' }, 'Turning off Wi-Fi…') }, 'Turn off Wi-Fi') : null,
      h('button', { class: 'btn', onclick: () => ask('Sleep', 'Put the Kindle to sleep? This page stops working until it wakes.', 'Sleep', { action: 'sleep' }, 'Going to sleep…') }, 'Sleep'),
      h('button', { class: 'btn', onclick: () => ask('Restart KOReader', 'Restart KOReader? The web server stops; start it again on the Kindle.', 'Restart', { action: 'restart' }, 'KOReader is restarting…') }, 'Restart KOReader')));
  }).catch(() => box.append(h('p', { class: 'muted small' }, 'Not available.')));
  return box;
};
