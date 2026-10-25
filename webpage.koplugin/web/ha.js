// Home Assistant: connection and sign-in, devices and Quick tiles, order, settings, backup.
App.pages.ha = {
  tab: 'connection',
  async render(main, params) {
    const s = await App.api('/api/ha');
    // The launcher's icons (Lucide, as Home Assistant's), for the Order tab's pictures.
    this.icons = App.arr((await App.api('/api/apps/icons?all=1').catch(() => ({}))).icons);
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'The Home Assistant plugin isn’t installed on this Kindle.')); return; }
    for (const k of ['devices', 'rooms', 'quick', 'sections', 'cameras', 'shortcuts', 'dashSections', 'dashQuick', 'dashScenes', 'securityCams', 'cameraList', 'graphSensors', 'routines', 'routineDevices', 'sleepAlerts', 'sleepAlertChoices']) s[k] = App.arr(s[k]);
    s.prefs = App.obj(s.prefs);
    if (params.signin === 'ok') { App.toast('Signed in to Home Assistant'); history.replaceState(null, '', '#ha'); this.tab = 'devices'; }
    if (params.signin === 'failed') { App.toast('Signing in did not work' + (params.why ? ': ' + params.why : ''), true); history.replaceState(null, '', '#ha'); }
    const page = this;
    const body = h('div');
    const tabs = [['connection', 'Connection'], ['devices', 'Devices'], ['order', 'Order'], ['routines', 'Routines'], ['settings', 'Settings'], ['backup', 'Backup']];
    const draw = () => {
      body.innerHTML = '';
      body.append(App.tabs(tabs, page.tab, (k) => { page.tab = k; draw(); }), page[page.tab](s));
    };
    main.append(
      h('div', { class: 'spread' },
        h('div', {}, h('h1', {}, 'Home Assistant'),
          h('p', { class: 'sub' }, s.signedIn ? (s.method === 'token' ? 'Connected with a token' : 'Signed in') +
            (s.updated ? ' · last refreshed ' + App.ago(s.updated) : '') : 'Not signed in')),
        s.signedIn ? h('button', { class: 'btn', onclick: refresh }, 'Refresh devices') : null),
      body);
    draw();
    async function refresh() {
      await App.api('/api/ha/refresh', { json: {} }).catch(App.fail);
      App.toast('Refreshing from Home Assistant…');
      setTimeout(App.route, 4000);
    }
  },

  connection(s) {
    const home = h('input', { type: 'url', value: s.home, placeholder: 'http://192.168.1.10:8123' });
    const away = h('input', { type: 'url', value: s.away, placeholder: 'https://ha.example.com (optional)' });
    const token = h('textarea', { rows: 3, placeholder: 'eyJ… (Home Assistant > Profile > Security > Long-lived access tokens)' });
    return h('div', {},
      h('div', { class: 'card stack' },
        h('h2', {}, 'URLs'),
        h('label', { class: 'field' }, h('span', {}, 'Internal URL (tried first)'), home),
        h('label', { class: 'field' }, h('span', {}, 'External URL (optional; won’t work behind a proxy login page)'), away),
        h('div', {}, h('button', { class: 'btn primary', onclick: save }, 'Save addresses')),
        s.home || s.away ? h('p', { class: 'muted small', style: 'margin:0' }, 'Test connection tries the Internal URL and the External URL separately, so you know which one works.') : null,
        s.home || s.away ? App.connectionTest('homeassistant') : null),
      h('div', { class: 'card stack' },
        h('h2', {}, 'Sign in'),
        h('p', { class: 'muted small' }, 'Opens Home Assistant’s sign-in page (two-factor codes supported) and returns here. This Kindle will appear in Home Assistant under Profile > Security.'),
        h('div', { class: 'row' },
          h('button', { class: 'btn primary', onclick: signIn }, 'Sign in with Home Assistant'),
          s.signedIn ? h('button', { class: 'btn danger', onclick: signOut }, 'Sign out') : null)),
      h('div', { class: 'card stack' },
        h('h2', {}, 'Or use a long-lived access token'),
        h('p', { class: 'muted small' }, 'Make one in Home Assistant: ', s.home || s.away
          ? App.link('Profile > Security > Long-lived access tokens', (s.home || s.away).replace(/\/+$/, '') + '/profile/security')
          : 'Profile > Security > Long-lived access tokens', '.'),
        token,
        h('div', {}, h('button', { class: 'btn', onclick: saveToken }, 'Save token'))));

    async function save() {
      await App.api('/api/ha/addresses', { json: { home: home.value, away: away.value } }).then(() => App.toast('Saved'), App.fail);
    }
    async function signIn() {
      await save();
      const r = await App.api('/api/ha/signin?base=' + encodeURIComponent(home.value || away.value)).catch(App.fail);
      if (r && r.url) location.href = r.url;
    }
    async function saveToken() {
      if (!token.value.trim()) return;
      await save();
      await App.api('/api/ha/token', { json: { token: token.value.trim() } }).then(() => {
        App.toast('Connected');
        setTimeout(App.route, 3000);
      }, App.fail);
    }
    async function signOut() {
      if (!await App.confirm('Sign out', 'Sign this Kindle out of Home Assistant?', 'Sign out', true)) return;
      await App.api('/api/ha/signout', { json: {} }).then(App.route, App.fail);
    }
  },

  devices(s) {
    if (!s.devices.length) return h('div', { class: 'empty' }, s.signedIn ? 'No devices yet. Click “Refresh devices”, or open Home Assistant on the Kindle once.' : 'Sign in first.');
    const search = h('input', { type: 'search', placeholder: 'Search names, rooms and ids', style: 'flex:1;min-width:200px' });
    let filter = 'all';
    const list = h('div');
    const quick = new Set(s.devices.filter((d) => d.quick).map((d) => d.id));
    const draw = () => {
      const q = search.value.trim().toLowerCase();
      const shown = s.devices.filter((d) => (filter === 'all' || (filter === 'shown') === d.visible) &&
        (!q || (d.name + ' ' + d.area + ' ' + d.id).toLowerCase().includes(q)));
      const groups = {};
      for (const d of shown) (groups[d.area || 'Everything Else'] = groups[d.area || 'Everything Else'] || []).push(d);
      list.innerHTML = '';
      if (!shown.length) list.append(h('div', { class: 'empty' }, 'Nothing matches.'));
      for (const [area, devices] of Object.entries(groups)) {
        list.append(h('div', { class: 'group-head' }, area));
        list.append(h('div', { class: 'list-rows' }, devices.map((d) => {
          const box = h('input', { type: 'checkbox', checked: d.visible });
          box.addEventListener('change', () => setVisible([d], box.checked));
          const star = h('button', { class: 'star' + (quick.has(d.id) ? ' on' : ''), title: 'Quick tile' }, '★');
          star.addEventListener('click', () => toggleQuick(d, star));
          return h('div', {}, box, h('span', { class: 'grow', style: d.visible ? '' : 'color:var(--muted)' }, d.name),
            h('span', { class: 'small muted' }, d.state), h('span', { class: 'pill' }, d.domain.replace('_', ' ')), star);
        })));
      }
      return shown;
    };
    search.addEventListener('input', draw);
    const pick = App.select([['all', 'All'], ['shown', 'Shown'], ['hidden', 'Hidden']], filter, (v) => { filter = v; draw(); });
    draw();
    return h('div', { class: 'card' },
      h('p', { class: 'muted small', style: 'margin-top:0' }, 'Checked devices appear on the Kindle. ★ adds a Quick tile. Configuration switches (LEDs, firmware, detection) are unchecked by default.'),
      h('div', { class: 'row', style: 'margin-bottom:10px' }, search, pick,
        h('button', { class: 'btn small', onclick: () => setVisible(draw(), true) }, 'Show all'),
        h('button', { class: 'btn small', onclick: () => setVisible(draw(), false) }, 'Hide all')),
      list);

    async function setVisible(devices, on) {
      const changes = devices.map((d) => ({ id: d.id, visible: on }));
      await App.api('/api/ha/devices', { json: { changes } }).then(() => {
        devices.forEach((d) => { d.visible = on; });
        draw();
      }, App.fail);
    }
    async function toggleQuick(d, star) {
      const ids = s.quick.map((q) => q.id);
      const at = ids.indexOf(d.id);
      if (at >= 0) ids.splice(at, 1); else ids.push(d.id);
      await App.api('/api/ha/prefs', { json: { quick: ids } }).then(() => {
        if (at >= 0) { quick.delete(d.id); s.quick.splice(at, 1); } else { quick.add(d.id); s.quick.push({ id: d.id, name: d.name }); }
        star.classList.toggle('on', quick.has(d.id));
      }, App.fail);
    }
  },

  order(s) {
    const page = this;
    const box = h('div');
    const sectionOrder = s.sections.map((x) => x.key);
    const hiddenSections = new Set(s.sections.filter((x) => x.hidden).map((x) => x.key));
    const saveSections = () => App.api('/api/ha/prefs', { json: { sections: sectionOrder, hidden_sections: [...hiddenSections] } }).catch(App.fail);
    const roomOrder = s.rooms.map((r) => r.name);
    const hiddenRooms = new Set(s.rooms.filter((r) => r.hidden).map((r) => r.name));
    const saveRooms = () => App.api('/api/ha/prefs', { json: { rooms: roomOrder, hidden_rooms: [...hiddenRooms] } }).catch(App.fail);
    const shortcutOrder = s.shortcuts.map((x) => x.key);
    const hiddenShortcuts = new Set(s.shortcuts.filter((x) => x.hidden).map((x) => x.key));
    const saveShortcuts = () => App.api('/api/ha/prefs', { json: { shortcuts: shortcutOrder, hidden_shortcuts: [...hiddenShortcuts] } }).catch(App.fail);
    let quickOrder = s.quick.map((q) => q.id);
    const saveQuick = () => App.api('/api/ha/prefs', { json: { quick: quickOrder } }).catch(App.fail);
    const hideToggle = (set, save) => (r) => App.toggle(!set.has(r.key), (on) => { if (on) set.delete(r.key); else set.add(r.key); save(); });

    // Home drawn as it looks, top to bottom: its sections, the shortcut buttons, the
    // Quick tiles and the rooms. Drag (or tap for a menu) to reorder or hide.
    const icons = App.arr(page.icons);
    const svg = (name) => { const sp = h('span', { class: 'tile-icon' }); const i = icons.find((x) => x.name === name); if (i) sp.innerHTML = i.svg; return sp; };
    const DOMAIN_ICON = { light: 'lightbulb', switch: 'toggle-right', fan: 'fan', climate: 'thermometer', lock: 'lock', cover: 'blinds',
      media_player: 'speaker', camera: 'camera', scene: 'sparkles', script: 'play', sensor: 'activity', binary_sensor: 'eye', vacuum: 'house', input_boolean: 'toggle-right' };
    const iconOf = (id) => DOMAIN_ICON[(id || '').split('.')[0]] || 'house';
    const two = (shownKeys, hiddenKeys, items, render, opts) => App.visualZones([
      { id: 'shown', title: opts.title, short: 'Shown', items: items.filter((x) => shownKeys.includes(x.key)), render, className: opts.cls || '' },
      { id: 'hidden', title: 'Hidden', short: 'Hidden', className: 'tray ' + (opts.cls || ''), empty: 'Drop here to hide', items: items.filter((x) => hiddenKeys.includes(x.key)), render },
    ], { onChange: (st) => opts.save(st.shown.concat(st.hidden), st.hidden) });
    const bar = (x) => h('div', { class: 've-bar' }, x.name);
    const chip = (x) => h('div', { class: 'qpill' }, svg(x.icon || 'house'), h('span', {}, x.name));
    const qtile = (x) => h('div', { class: 've-tile', style: 'width:190px;height:72px' }, svg(iconOf(x.key)), h('b', {}, x.name));
    const roomCard = (x) => h('div', { class: 've-bar' }, svg('door-open'), x.name, h('span', { class: 'muted small', style: 'font-weight:400' }, ' ' + x.count + ' devices'));
    const sectionItems = s.sections.map((x) => ({ key: x.key, name: x.name }));
    const shortcutItems = s.shortcuts.map((x) => ({ key: x.key, name: x.name, icon: x.icon }));
    const quickItems = s.quick.map((q) => ({ key: q.id, name: q.name }));
    const roomItems = s.rooms.map((r) => ({ key: r.name, name: r.name, count: r.count }));
    box.append(
      h('div', { class: 'card stack' }, h('h2', {}, 'Home sections'),
        h('p', { class: 'muted small' }, 'Home, top to bottom. Drag a section to reorder it or to Hidden, or tap one for a menu.'),
        two(sectionItems.filter((x) => !hiddenSections.has(x.key)).map((x) => x.key), [...hiddenSections], sectionItems, bar, {
          title: 'Home', cls: 'column', save: (order, hidden) => {
            sectionOrder.splice(0, sectionOrder.length, ...order); hiddenSections.clear(); hidden.forEach((k) => hiddenSections.add(k)); saveSections();
          } })),
      s.shortcuts.length ? h('div', { class: 'card stack' }, h('h2', {}, 'Shortcuts'),
        h('p', { class: 'muted small' }, 'The buttons at the top of Home (Lights, Climate, Sensors…), as they look there.'),
        two(shortcutItems.filter((x) => !hiddenShortcuts.has(x.key)).map((x) => x.key), [...hiddenShortcuts], shortcutItems, chip, {
          title: 'Top of Home', save: (order, hidden) => {
            shortcutOrder.splice(0, shortcutOrder.length, ...order); hiddenShortcuts.clear(); hidden.forEach((k) => hiddenShortcuts.add(k)); saveShortcuts();
          } })) : null,
      h('div', { class: 'card stack' }, h('div', { class: 'spread' }, h('h2', {}, 'Quick tiles'),
        h('button', { class: 'btn small', onclick: async () => { await App.api('/api/ha/prefs', { json: { quick: false } }).catch(App.fail); App.route(); } }, 'Reset to default')),
        h('p', { class: 'muted small' }, 'As Home shows them. Drag to reorder; tap one to move it or take it off (star devices under Devices to add more).'),
        quickItems.length ? App.visualZones([{ id: 'quick', title: 'Quick tiles', items: quickItems, render: qtile }], {
          onChange: (st) => { quickOrder = st.quick; saveQuick(); },
          actions: (x) => [{ text: 'Remove from Quick', danger: true, fn: async () => { quickOrder = quickOrder.filter((k) => k !== x.key); await saveQuick(); App.route(); } }],
        }) : h('div', { class: 'empty' }, 'No Quick tiles yet. Star devices under Devices.')),
      h('div', { class: 'card stack' }, h('h2', {}, 'Rooms'),
        h('p', { class: 'muted small' }, 'Their order on Home and the dashboard. Drag to reorder or to Hidden.'),
        two(roomItems.filter((x) => !hiddenRooms.has(x.key)).map((x) => x.key), [...hiddenRooms], roomItems, roomCard, {
          title: 'Rooms', cls: 'column', save: (order, hidden) => {
            roomOrder.splice(0, roomOrder.length, ...order); hiddenRooms.clear(); hidden.forEach((k) => hiddenRooms.add(k)); saveRooms();
          } })));

    // The dashboard and Security (a newer Home Assistant plugin has them).
    if (s.dashSections.length) {
      const dashOrder = s.dashSections.map((x) => x.key);
      const hiddenDash = new Set(s.dashSections.filter((x) => x.hidden).map((x) => x.key));
      const saveDash = () => App.api('/api/ha/prefs', { json: { dash_sections: dashOrder, dash_hidden: [...hiddenDash] } }).catch(App.fail);
      box.append(
        h('div', { class: 'card' }, h('h2', {}, 'Dashboard sections'),
          h('p', { class: 'muted small' }, 'For the Clock and info style. Drag or use the arrows to reorder. The switch shows or hides each section. Next up and Now playing only show when there is something; the camera takes the room the others leave.'),
          App.reorder(s.dashSections.map((x) => ({ key: x.key, label: x.name })),
            (keys) => { dashOrder.splice(0, dashOrder.length, ...keys); saveDash(); }, hideToggle(hiddenDash, saveDash))),
        pickList('Dashboard Quick tiles', 'dash_quick', s.dashQuick, s.devices.filter((d) => d.visible && d.domain !== 'scene' && d.domain !== 'script'),
          'Tiles along the bottom of the dashboard. Until changed, the same as Home’s Quick tiles.'),
        pickList('Dashboard scenes', 'dash_scenes', s.dashScenes, s.devices.filter((d) => d.visible && (d.domain === 'scene' || d.domain === 'script')),
          'Buttons in the dashboard’s Scenes section. Until changed, every scene and script shown.'));
    }
    if (s.cameraList.length) {
      const order = s.cameraList.map((x) => x.id);
      const hiddenCams = new Set(s.cameraList.filter((x) => x.hidden).map((x) => x.id));
      const saveCams = () => App.api('/api/ha/prefs', { json: { camera_order: order, cameras_hidden: [...hiddenCams] } }).catch(App.fail);
      box.append(h('div', { class: 'card' }, h('h2', {}, 'Cameras'),
        h('p', { class: 'muted small' }, 'The Cameras screen, and the dashboard when it rotates through them. Drag or use the arrows to reorder. The switch shows or hides each one.'),
        App.reorder(s.cameraList.map((x) => ({ key: x.id, label: x.name })),
          (keys) => { order.splice(0, order.length, ...keys); saveCams(); }, hideToggle(hiddenCams, saveCams))));
    }
    if (s.securityCams.length) {
      const camOrder = s.securityCams.map((x) => x.id);
      const hiddenCams = new Set(s.securityCams.filter((x) => x.hidden).map((x) => x.id));
      const saveCams = () => App.api('/api/ha/prefs', { json: { security_cams: camOrder, security_hidden: [...hiddenCams] } }).catch(App.fail);
      box.append(h('div', { class: 'card' }, h('h2', {}, 'Security cameras'),
        h('p', { class: 'muted small' }, 'Cameras on Security and the Security dashboard. Drag or use the arrows to reorder. The switch shows or hides each one. A 3D printer’s camera starts hidden here; it stays in Cameras.'),
        App.reorder(s.securityCams.map((x) => ({ key: x.id, label: x.name })),
          (keys) => { camOrder.splice(0, camOrder.length, ...keys); saveCams(); }, hideToggle(hiddenCams, saveCams))));
    }
    if (s.sleepAlertChoices.length) {
      box.append(pickList('Sleep screen alerts', 'sleep_alerts', s.sleepAlerts, s.sleepAlertChoices,
        'Shown at the bottom of the Kindle’s sleep screen when they need attention (a lock unlocked, a door open, a leak); a sensor always shows its value.'));
    }
    return box;

    // A list of devices to reorder, remove from and add to (saved as `key`).
    function pickList(title, key, items, choices, hint) {
      let order = items.map((q) => q.id);
      const save = () => App.api('/api/ha/prefs', { json: { [key]: order } }).catch(App.fail);
      const add = h('select', {}, h('option', { value: '' }, 'Add…'),
        choices.filter((d) => !order.includes(d.id)).map((d) => h('option', { value: d.id }, d.name + (d.area ? ' · ' + d.area : ''))));
      add.addEventListener('change', async () => {
        if (!add.value) return;
        order.push(add.value);
        await save();
        App.route();
      });
      return h('div', { class: 'card' }, h('div', { class: 'spread' }, h('h2', {}, title),
          h('div', { class: 'row' }, add,
            h('button', { class: 'btn small', onclick: async () => { await App.api('/api/ha/prefs', { json: { [key]: false } }).catch(App.fail); App.route(); } }, 'Reset to default'))),
        h('p', { class: 'muted small' }, hint),
        items.length ? App.reorder(items.map((q) => ({ key: q.id, label: q.name })), (keys) => { order = keys; save(); },
          (r) => h('button', { class: 'icon-btn', title: 'Remove', onclick: (e) => {
            order = order.filter((k) => k !== r.key);
            e.target.closest('[data-key]').remove();
            save();
          } }, '✕'))
          : h('div', { class: 'empty' }, 'None yet. Use Add.'));
    }
  },

  settings(s) {
    const p = s.prefs;
    const set = (key) => (value) => App.api('/api/ha/prefs', { json: { [key]: value } }).then(() => { p[key] = value; }, App.fail);
    const on = (key) => p[key] !== false;
    const num = (key) => (v) => set(key)(Number(v));
    return h('div', {},
      // The same sections, in the same order, as the settings on the Kindle.
      h('div', { class: 'card' }, h('h2', {}, 'Display'),
        App.setting('Start screen', App.select([['home', 'Home'], ['dashboard', 'Dashboard']], p.start || 'home', set('start'))),
        App.setting('Layout', App.select([['cards', 'Cards'], ['big', 'Big tiles'], ['list', 'List'], ['minimal', 'Minimal']], p.layout || 'cards', set('layout')))),
      h('div', { class: 'card' }, h('h2', {}, 'Dashboard'),
        App.setting('Style', App.select([['clock', 'Clock and info'], ['security', 'Security'], ['info', 'Info cards'], ['camera', 'Camera'], ['clockonly', 'Clock only']], p.dash_layout || 'clock', set('dash_layout'))),
        App.setting('Camera', App.select([['cycle', 'Rotate through all'], ['none', 'None'], ...s.cameras.map((c) => [c.id, c.name])], p.dash_camera || 'cycle', set('dash_camera'))),
        s.dashSections.length ? h('p', { class: 'muted small' }, 'Sections, Quick tiles and scenes: the Order tab.')
          : [App.setting('Room temperatures', App.toggle(on('dash_temps'), set('dash_temps'))),
            App.setting('Status bar', App.toggle(on('dash_attention'), set('dash_attention')))],
        s.graphSensors.length ? App.setting('Graph', App.select([['auto', 'Auto'], ...s.graphSensors.map((g) => [g.id, g.name])], p.dash_graph || 'auto', set('dash_graph'))) : null,
        App.setting('Auto brightness', App.toggle(p.auto_light === true, set('auto_light')), 'Uses the Kindle’s light sensor while the dashboard shows.'),
        App.setting('Doorbell alerts', App.select([['motion', 'Ring and motion'], ['ring', 'Ring only'], ['off', 'Off']], p.doorbell || 'motion', set('doorbell')), 'Shows the doorbell camera full screen for a minute.'),
        App.setting('Update interval', App.select([['1', 'Every minute'], ['5', 'Every 5 min'], ['10', 'Every 10 min'], ['15', 'Every 15 min'], ['30', 'Every 30 min']], p.dash_minutes ?? 5, num('dash_minutes'))),
        App.setting('Keep awake', App.select([['charging', 'While charging'], ['always', 'Always'], ['never', 'Never']], p.dash_awake || 'charging', set('dash_awake')))),
      h('div', { class: 'card' }, h('h2', {}, 'Home'),
        App.setting('Keep turned off in On now', App.select([['0', 'Off'], ['1', '1 min'], ['3', '3 min'], ['5', '5 min'], ['10', '10 min']], p.keep_off ?? 3, num('keep_off')),
          'A device turned off on the Kindle stays in On now a while (shown as off), so a tap turns it back on.'),
        s.weathers.length ? App.setting('Weather', App.select([['auto', 'Auto'], ...s.weathers.map((w) => [w.id, w.name])], p.weather || 'auto', set('weather')), 'For the dashboard, the Weather screen and the launcher.') : null,
        App.setting('Wake alerts', App.toggle(p.wake_warning !== false, set('wake_warning')), 'When the Kindle wakes: a lock, the garage or a door left open.'),
        h('p', { class: 'muted small' }, 'Routines (one tap runs several actions) are on the Routines tab.')),
      h('div', { class: 'card' }, h('h2', {}, 'Confirm'),
        App.setting('Unlock doors', App.toggle(on('ask_unlock'), set('ask_unlock'))),
        App.setting('Open or close garage', App.toggle(on('ask_garage'), set('ask_garage'))),
        App.setting('Run scripts', App.toggle(on('ask_scripts'), set('ask_scripts')))),
      s.cameras.length ? h('div', { class: 'card' }, h('h2', {}, 'Camera placeholders'),
        h('p', { class: 'muted small' }, 'Placeholder image shown while a camera loads or if it’s unavailable. Automatic picks one from the camera’s name.'),
        s.cameras.map((cam) => {
          const now = (App.arr(s.placeholders).find((x) => x.id === cam.id) || {}).value || 'auto';
          return App.setting(cam.name, App.select([['auto', 'Automatic'], ['door', 'Doorway'], ['garage', 'Garage'], ['room', 'Room'], ['printer', '3D printer']], now,
            (v) => App.api('/api/ha/prefs', { json: { placeholders: { [cam.id]: v } } }).catch(App.fail)));
        })) : null,
      h('div', { class: 'card' }, h('h2', {}, 'Connection'),
        App.setting('Update interval', App.select([['1', 'Every minute'], ['2', 'Every 2 min'], ['5', 'Every 5 min'], ['10', 'Every 10 min'], ['0', 'Manual only']], p.refresh_minutes ?? 1, num('refresh_minutes')))));
  },

  // Routines: one tap runs several actions. Kept on the Kindle, nothing in Home Assistant.
  routines(s) {
    if (!s.signedIn) return h('div', { class: 'empty' }, 'Sign in first.');
    const list = s.routines.map((r) => ({ id: r.id, name: r.name, steps: App.arr(r.steps) }));
    const devices = s.routineDevices;
    const box = h('div');
    const save = async () => {
      const r = await App.api('/api/ha/routines', { json: { routines: list } }).catch(App.fail);
      if (r) { list.splice(0, list.length, ...App.arr(r.routines).map((x) => ({ id: x.id, name: x.name, steps: App.arr(x.steps) }))); draw(); }
    };
    const nameOf = (id) => (devices.find((d) => d.id === id) || {}).name || id;
    const risky = (r) => r.steps.some((st) => st.service === 'lock.unlock' || st.service === 'cover.open_cover' || st.service === 'script.turn_on');
    const draw = () => {
      box.innerHTML = '';
      box.append(h('p', { class: 'muted small' }, 'They show on Home and in the dashboard’s Scenes section on the Kindle. Steps run one after another.'));
      for (const r of list) {
        const device = App.select([['', 'Device…'], ...devices.map((d) => [d.id, d.name + (d.area ? ' · ' + d.area : '')])], '', (v) => {
          const d = devices.find((x) => x.id === v);
          action.innerHTML = '';
          for (const [label, service] of (d ? App.arr(d.actions) : [])) action.append(h('option', { value: service }, label));
        });
        const action = h('select', {});
        box.append(h('div', { class: 'card stack' },
          h('div', { class: 'spread' },
            h('input', { type: 'text', value: r.name, style: 'font-weight:600;flex:1', onchange: (e) => { if (e.target.value.trim()) { r.name = e.target.value; save(); } } }),
            h('div', { class: 'row' },
              h('button', { class: 'btn primary', onclick: async () => {
                if (risky(r) && !await App.confirm('Run ' + r.name, 'It unlocks a door, opens the garage or runs a script.', 'Run')) return;
                await App.api('/api/ha/routines/run', { json: { id: r.id } }).then(() => App.toast('Running ' + r.name), App.fail);
              } }, 'Run'),
              h('button', { class: 'btn danger', onclick: async () => {
                if (!await App.confirm('Delete routine', 'Delete ' + r.name + '?', 'Delete', true)) return;
                list.splice(list.indexOf(r), 1);
                save();
              } }, 'Delete'))),
          r.steps.length
            ? App.reorder(r.steps.map((st, i) => ({ key: String(i), label: nameOf(st.id) + ': ' + (st.label || st.service) })),
              (keys) => { r.steps = keys.map((k) => r.steps[Number(k)]); save(); },
              (row) => h('button', { class: 'icon-btn', title: 'Remove', onclick: () => { r.steps.splice(Number(row.key), 1); save(); } }, '✕'))
            : h('div', { class: 'empty' }, 'No steps yet.'),
          h('div', { class: 'row' }, device, action, h('button', { class: 'btn', onclick: () => {
            if (!device.value || !action.value) return;
            r.steps.push({ id: device.value, service: action.value, label: action.options[action.selectedIndex].text });
            save();
          } }, 'Add step'))));
      }
      const name = h('input', { type: 'text', placeholder: 'Leaving' });
      box.append(h('div', { class: 'card' }, h('h2', {}, 'New routine'),
        h('div', { class: 'row' }, name, h('button', { class: 'btn primary', onclick: () => {
          if (!name.value.trim()) return;
          list.push({ id: '', name: name.value.trim(), steps: [] });
          save();
        } }, 'Add'))));
    };
    draw();
    return box;
  },

  backup() {
    const file = h('input', { type: 'file', accept: '.json,application/json', style: 'display:none' });
    file.addEventListener('change', async () => {
      const f = file.files[0];
      if (!f) return;
      try {
        await App.api('/api/ha/restore', { json: JSON.parse(await f.text()) });
        App.toast('Settings restored');
        App.route();
      } catch (e) { App.fail(e); }
    });
    return h('div', { class: 'card stack' },
      h('h2', {}, 'Backup'),
      h('p', { class: 'muted small' }, 'Saves the addresses and all settings (not the sign-in). Import it on another Kindle or after a reset.'),
      h('div', { class: 'row' },
        h('button', { class: 'btn primary', onclick: async () => {
          const data = await App.api('/api/ha/backup').catch(App.fail);
          if (data) App.download(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }), 'koreader-homeassistant.json');
        } }, 'Export'),
        h('button', { class: 'btn', onclick: () => file.click() }, 'Import'), file));
  },
};
