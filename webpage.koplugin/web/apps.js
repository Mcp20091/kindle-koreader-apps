// The launcher's tiles and shortcuts, and its settings (as in Settings > Edit home screen and Launcher on the Kindle).
App.pages.apps = {
  async render(main) {
    const s = await App.api('/api/apps');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'The launcher isn’t installed on this Kindle.')); return; }
    const st = App.obj(s.settings);
    const tiles = App.arr(s.tiles);
    const choices = App.obj(s.choices);
    const post = (path, json) => App.api(path, { json }).catch(App.fail);
    const set = (key) => (value) => post('/api/apps/settings', { [key]: value }).then(() => { st[key] = value; });
    const reload = () => App.route();

    // Where a tile is: the main page, a group, or a new group.
    const groups = App.arr(s.groups);
    const groupPick = (r) => App.select([['', 'Main page'], ...groups.map((g) => [g.id, g.name]), ['+', 'New group…']], r.group || '', async (v) => {
      if (v === '+') {
        const name = prompt('New group name');
        if (name && name.trim()) await post('/api/apps/tiles', { newGroup: name, key: r.key });
        return reload();
      }
      await post('/api/apps/tiles', { move: r.key, group: v || false });
    });

    // A group's icon: the launcher's icons in a grid, the current one outlined.
    let icons = null;
    const svgOf = (name) => {
      const i = (icons || []).find((x) => x.name === name);
      const span = h('span', { class: 'tile-icon' });
      if (i) span.innerHTML = i.svg;
      return span;
    };
    const iconPick = async (r) => {
      const g = groups.find((x) => x.id === r.groupTile);
      let chosen = (g && g.icon) || 'folder';
      const grid = h('div', { class: 'icon-grid' }, (icons || []).map((i) => {
        const b = h('button', { class: 'icon-btn' + (i.name === chosen ? ' on' : ''), title: i.name, onclick: () => {
          chosen = i.name;
          grid.querySelectorAll('.icon-btn').forEach((x) => x.classList.toggle('on', x === b));
        } }, svgOf(i.name));
        return b;
      }));
      const ok = await App.modal('Icon for ' + r.label.replace(/ \(group\)$/, ''), grid, [{ text: 'Cancel', result: false }, { text: 'Save', primary: true, result: true }], true);
      if (ok) { await post('/api/apps/tiles', { groupIcon: r.groupTile, icon: chosen }); reload(); }
    };
    if (groups.length) icons = App.arr((await App.api('/api/apps/icons').catch(() => ({}))).icons);

    // A shortcut to add: pick a place, then Add.
    const adder = (kind, label) => {
      const list = App.arr(choices[kind]);
      if (!list.length) return null;
      const pick = App.select(list.map((c) => [c.key, c.name]), list[0].key, () => {});
      return App.setting(label, h('div', { class: 'row' }, pick,
        h('button', { class: 'btn', onclick: async () => { await post('/api/apps/tiles', { add: pick.value }); reload(); } }, 'Add')));
    };

    // The quick buttons: drawn as on the Kindle (those past two rows are under More), dragged
    // into order or onto a group, a click for Remove and the rest, and a list to add from.
    const allIcons = App.arr((await App.api('/api/apps/icons?all=1').catch(() => ({}))).icons);
    const iconSvg = (name) => {
      const i = allIcons.find((x) => x.name === name);
      const span = h('span', { class: 'tile-icon' });
      if (i) span.innerHTML = i.svg;
      return span;
    };
    function quickCard() {
      if (!s.quick) return null;
      let list = JSON.parse(JSON.stringify(App.arr(s.quick)));
      list.forEach((e) => { if (e.items) e.items = App.arr(e.items); });
      const save = () => post('/api/apps/quick', { list }).then(reload);
      const find = (key) => {
        for (let i = 0; i < list.length; i++) {
          if (list[i].key === key) return [list, i];
          const items = list[i].items || [];
          for (let j = 0; j < items.length; j++) if (items[j].key === key) return [items, j, list[i]];
        }
        return [];
      };
      const take = (key) => { const [l, i] = find(key); return l ? l.splice(i, 1)[0] : null; };
      let dragging = null;
      const pill = (e, inGroup) => {
        const b = h('div', { class: 'qpill' + (e.here === false ? ' gone' : ''), draggable: 'true', title: e.here === false ? 'Not on this Kindle (its app isn’t installed)' : e.name },
          iconSvg(e.icon), h('span', {}, e.name), e.kind === 'group' ? h('span', { class: 'muted' }, ' ▾') : null);
        b.addEventListener('dragstart', (ev) => { dragging = e.key; ev.dataTransfer.effectAllowed = 'move'; b.classList.add('dragging'); });
        b.addEventListener('dragend', () => b.classList.remove('dragging'));
        b.addEventListener('dragover', (ev) => { if (dragging && dragging !== e.key) { ev.preventDefault(); b.classList.add('drop-before'); } });
        b.addEventListener('dragleave', () => b.classList.remove('drop-before'));
        b.addEventListener('drop', (ev) => {
          ev.preventDefault(); ev.stopPropagation(); b.classList.remove('drop-before');
          const moving = find(dragging)[0] && dragging;
          if (!moving || moving === e.key) return;
          const m = take(moving);
          if (m.kind === 'group' && inGroup) { list.push(m); return save(); }
          const [l, i] = find(e.key);
          l.splice(i, 0, m);
          save();
        });
        b.addEventListener('click', () => menu(e, inGroup));
        return b;
      };
      const menu = async (e, inGroup) => {
        const groups = list.filter((g) => g.kind === 'group' && g.key !== e.key);
        const actions = [{ text: 'Cancel', result: null }, { text: 'Move up', result: 'up' }, { text: 'Move down', result: 'down' }, { text: 'Remove', danger: true, result: 'remove' }];
        if (inGroup) actions.splice(1, 0, { text: 'Out of the group', result: 'out' });
        if (e.kind === 'group') actions.splice(1, 0, { text: 'Rename', result: 'rename' });
        const into = !inGroup && e.kind !== 'group' && groups.length ? App.select([['', 'Move to a group…'], ...groups.map((g) => [g.key, g.name])], '', () => {}) : null;
        const body = h('div', { class: 'stack' },
          h('p', { class: 'muted small' }, e.kind === 'group' ? 'A group: one button that drops down its own. Removing it takes its buttons out too.' : 'Tap on the Kindle does the quick thing; hold opens what’s behind it.'),
          into);
        if (into) actions.splice(1, 0, { text: 'Move', result: 'into' });
        const r = await App.modal(e.name, body, actions);
        if (r === 'up' || r === 'down') {
          const [l, i] = find(e.key);
          const j = Math.max(0, Math.min(l.length - 1, i + (r === 'up' ? -1 : 1)));
          l.splice(j, 0, l.splice(i, 1)[0]);
          save();
        } else if (r === 'remove') { take(e.key); save(); }
        else if (r === 'out') { const m = take(e.key); list.push(m); save(); }
        else if (r === 'into' && into.value) { const m = take(e.key); find(into.value)[0][find(into.value)[1]].items.push(m); save(); }
        else if (r === 'rename') { const name = await App.prompt('Rename group', e.name); if (name) { e.name = name; save(); } }
      };
      // Where they show, as the Kindle works it out: the first `homeN` on the home screen
      // (two rows under the clock, then More), the rest only in the control center; and
      // the built-ins every control center has (click one to add it and place it).
      const onHome = st.toggles !== false;
      const homeN = onHome ? Number(s.quickHome || 0) : 0;
      const zone = (cls) => h('div', { class: 'qarea' + (cls ? ' ' + cls : '') });
      const homeArea = zone(), area = zone(), coreArea = zone('core');
      // Dropped on a section's empty space: to the end of that section.
      const dropTo = (box, at) => {
        box.addEventListener('dragover', (ev) => { if (dragging) ev.preventDefault(); });
        box.addEventListener('drop', (ev) => {
          ev.preventDefault();
          if (!find(dragging)[0]) return;
          const m = take(dragging);
          // Into the home section: its last place (what was last there may move past the line).
          const j = at === 'home' ? Math.max(0, homeN - 1) : list.length;
          list.splice(Math.max(0, j), 0, m);
          save();
        });
      };
      dropTo(homeArea, 'home');
      dropTo(area, 'end');
      const groupsBox = h('div', { class: 'stack' });
      const draw = () => {
        const more = homeN > 0 && list.length > homeN ? h('span', { class: 'qpill gone', title: 'Opens the control center' }, 'More ▾') : null;
        homeArea.replaceChildren(...list.slice(0, homeN).map((e) => pill(e, false)), ...(more ? [more] : []));
        if (!homeN) homeArea.replaceChildren(h('span', { class: 'muted small' }, onHome ? 'Drop buttons here to show them on the home screen.' : 'Show on the home screen is off.'));
        area.replaceChildren(...list.slice(homeN).map((e) => pill(e, false)));
        if (list.length <= homeN) area.replaceChildren(h('span', { class: 'muted small' }, 'None. Buttons that don’t fit on the home screen go here.'));
        coreArea.replaceChildren(...App.arr(s.quickCore).map((x) => {
          const b = h('button', { class: 'qpill gone', title: 'Add to your buttons' }, iconSvg(x.icon), h('span', {}, x.name));
          b.addEventListener('click', () => { list.push({ key: x.key, name: x.name, icon: x.icon, kind: 'b' }); save(); });
          return b;
        }));
        // Each group's buttons, in a box of its own (drop buttons here to put them in it).
        groupsBox.replaceChildren(...list.filter((g) => g.kind === 'group').map((g) => {
          const box = h('div', { class: 'qgroup-items' }, (g.items || []).length ? g.items.map((x) => pill(x, true)) : h('span', { class: 'muted small' }, 'Drop buttons here'));
          box.addEventListener('dragover', (ev) => { if (dragging && dragging !== g.key) { ev.preventDefault(); box.classList.add('drop-on'); } });
          box.addEventListener('dragleave', () => box.classList.remove('drop-on'));
          box.addEventListener('drop', (ev) => {
            ev.preventDefault(); ev.stopPropagation(); box.classList.remove('drop-on');
            const m = find(dragging)[0] && take(dragging);
            if (!m || m.kind === 'group') { if (m) list.push(m); return save(); }
            g.items = g.items || []; g.items.push(m); save();
          });
          return h('div', { class: 'qgroup' }, h('div', { class: 'small', style: 'font-weight:600' }, iconSvg(g.icon), ' ', g.name), box);
        }));
      };
      draw();
      // Adding: built-ins, then the shortcut kinds, then a new group.
      const have = new Set();
      list.forEach((e) => { have.add(e.key); (e.items || []).forEach((x) => have.add(x.key)); });
      const ch = App.obj(s.choices);
      const groupsOpt = [['Built-in', App.arr(s.quickBuiltins)], ['Home Assistant', App.arr(ch.ha)], ['To Do', App.arr(ch.todo)],
        ['Notebook', App.arr(ch.note)], ['Notes folder', App.arr(ch.notefolder)], ['Crossword', App.arr(ch.crossword)], ['KOReader action', App.arr(ch.action)]];
      // Other apps' buttons (a Home Assistant device...), one list per group (a room).
      App.arr(s.quickApps).forEach((qa) => {
        const byGroup = {};
        App.arr(qa.choices).forEach((x) => { const g = x.group || ''; (byGroup[g] = byGroup[g] || []).push(x); });
        Object.keys(byGroup).forEach((g) => groupsOpt.push([qa.name + (g ? ' · ' + g : ''), byGroup[g]]));
      });
      const pick = h('select', {}, groupsOpt.map(([label, items]) => {
        const left = items.filter((x) => !have.has(x.key));
        return left.length ? h('optgroup', { label }, left.map((x) => h('option', { value: x.key }, x.name))) : null;
      }));
      return h('div', { class: 'card stack' }, h('h2', {}, 'Quick buttons'),
        h('p', { class: 'muted small' }, 'Drawn as on the Kindle. Drag to reorder, between sections, or onto a group to put it there; click one to remove it or move it. On the Kindle, tap does the quick thing and hold opens what’s behind it.'),
        App.setting('Show on the home screen', App.toggle(onHome, set('toggles')), 'Your first buttons, two rows under the clock, then More.'),
        h('div', { class: 'small', style: 'font-weight:600;margin-top:6px' }, onHome ? 'On the home screen' : 'On the home screen: none'),
        h('p', { class: 'muted small', style: 'margin:0' }, onHome ? 'Two rows under the clock, then More. Also in the control center.' : 'Turn on Show on the home screen to have your first buttons there.'),
        homeArea,
        h('div', { class: 'small', style: 'font-weight:600;margin-top:6px' }, homeN ? 'Only in the control center' : 'In the control center'),
        h('p', { class: 'muted small', style: 'margin:0' }, homeN ? 'More on the home screen opens these. Drag one up to put it on the home screen.' : 'Tap the time and battery at the top of any screen.'),
        area,
        App.arr(s.quickCore).length ? h('div', { class: 'small', style: 'font-weight:600;margin-top:6px' }, 'Always in the control center') : null,
        App.arr(s.quickCore).length ? h('p', { class: 'muted small', style: 'margin:0' }, 'Built in. Click one to add it to your buttons and place it yourself.') : null,
        App.arr(s.quickCore).length ? coreArea : null,
        groupsBox,
        h('div', { class: 'row' }, pick,
          h('button', { class: 'btn', onclick: () => {
            if (!pick.value) return;
            const all = groupsOpt.flatMap(([, items]) => items);
            const x = all.find((i) => i.key === pick.value);
            list.push({ key: x.key, name: x.name, icon: x.icon || 'app-window', kind: x.key.startsWith('b:') ? 'b' : x.key.startsWith('a:') ? 'app' : 'pin' });
            save();
          } }, 'Add'),
          h('button', { class: 'btn', onclick: async () => {
            const name = await App.prompt('New group', '', 'Group name');
            if (name) { list.push({ key: 'g:' + Date.now(), name, icon: 'folder', kind: 'group', items: [] }); save(); }
          } }, 'New group')));
    }

    // The tiles drawn as the launcher shows them (its layout and columns): the main
    // page, each group's page, and Hidden. Drag (or tap for a menu) to reorder, to
    // move into or out of a group, or to hide.
    function tilesCard() {
      const layout = st.layout || 'tiles';
      const cols = layout === 'list' ? 1 : layout === 'icons' ? 5 : (st.columns || 2);
      const tw = Math.floor((596 - (cols - 1) * 10) / cols);
      const tile = (t) => {
        const cls = 've-tile' + (layout === 'list' ? ' list' : layout === 'icons' ? ' icons' : '');
        return h('div', { class: cls, style: layout === 'icons' ? '' : 'width:' + tw + 'px' },
          iconSvg(t.groupTile ? ((groups.find((g) => g.id === t.groupTile) || {}).icon || 'folder') : (t.icon || 'app-window')),
          h('b', {}, t.name + (t.groupTile ? ' ▸' : '')));
      };
      const isGroup = (t) => !!t.groupTile;
      const zones = [{ id: 'main', title: 'Main page', short: 'Main page', items: tiles.filter((t) => !t.hidden && !t.group), render: tile }];
      groups.forEach((g) => zones.push({ id: 'g:' + g.id, title: 'In ' + g.name, short: g.name, empty: 'Drop tiles here to put them in this group',
        // (A group sorted A–Z on the Kindle shows its tiles by name.)
        items: tiles.filter((t) => !t.hidden && t.group === g.id).sort((a, b) => (g.sort === 'az' ? String(a.name || '').toLowerCase().localeCompare(String(b.name || '').toLowerCase()) : 0)),
        render: tile, accept: (t) => !isGroup(t) }));
      zones.push({ id: 'hidden', title: 'Hidden', short: 'Hidden', className: 'tray', empty: 'Drop tiles here to hide them',
        items: tiles.filter((t) => t.hidden), render: tile, accept: (t) => !isGroup(t) });
      const save = (state) => {
        const order = [];
        const grouped = {};
        Object.keys(state).forEach((id) => state[id].forEach((k) => {
          order.push(k);
          if (id.startsWith('g:')) grouped[k] = id.slice(2);
        }));
        post('/api/apps/tiles', { layout: { order, hidden: state.hidden, grouped } });
      };
      const actions = (t) => {
        if (t.groupTile) {
          return [
            { text: 'Rename', fn: async () => { const name = await App.prompt('Group name', t.name); if (name) { await post('/api/apps/tiles', { renameGroup: t.groupTile, name }); reload(); } } },
            { text: 'Icon', fn: () => iconPick({ groupTile: t.groupTile, label: t.name }) },
            { text: 'Delete group', danger: true, fn: async () => { await post('/api/apps/tiles', { deleteGroup: t.groupTile }); reload(); } },
          ];
        }
        if (t.pin) return [{ text: 'Remove', danger: true, fn: async () => { await post('/api/apps/tiles', { remove: t.key }); reload(); } }];
        return [];
      };
      return h('div', { class: 'card stack' }, h('h2', {}, 'Home screen'),
        h('p', { class: 'muted small' }, 'As the launcher shows them, in its layout and columns, left to right. Drag a tile to reorder it, into a group, or to Hidden; or tap one for the same as a menu (and Rename, Icon or Delete for a group, Remove for a shortcut).'),
        App.visualZones(zones, { onChange: save, actions }),
        h('div', { class: 'row' }, h('button', { class: 'btn', onclick: async () => {
          const name = await App.prompt('New group', '', 'Group name');
          if (name) { await post('/api/apps/tiles', { newGroup: name }); reload(); }
        } }, 'New group')));
    }

    // The widgets sleep screen: its parts as cards, top to bottom, and the ones switched off.
    function widgetsCard() {
      if (!s.widgets) return null;
      const SAMPLE = {
        clock: ['', '9:41 PM · Saturday, October 24'], book: ['READING', 'Your book, its cover and how far in'],
        todo: ['TODAY', 'The tasks due today'], ha: ['HOME', 'Home Assistant’s alerts: doors, locks, batteries'],
        notifications: ['NOTIFICATIONS', 'The latest few'],
      };
      const items = App.arr(s.widgets).map((w) => ({ key: w.key, name: w.name, on: w.on }));
      const card = (w) => h('div', { class: 've-card' }, h('div', { class: 'k' }, (SAMPLE[w.key] || [])[0] || w.name.toUpperCase()),
        h('div', { style: 'font-weight:600' }, w.key === 'clock' ? '9:41 PM' : w.name), h('div', { class: 'muted small' }, (SAMPLE[w.key] || [])[1] || ''));
      return h('div', { class: 'card stack' }, h('h2', {}, 'Widgets sleep screen'),
        h('p', { class: 'muted small' }, 'Its parts, top to bottom, when the sleep screen is Widgets (the Home tab picks the sleep screen). Drag to reorder or to Off, or tap one for a menu.'),
        App.visualZones([
          { id: 'on', title: 'On the sleep screen', short: 'On', className: 'column', items: items.filter((w) => w.on), render: card },
          { id: 'off', title: 'Off', short: 'Off', className: 'column tray', empty: 'Drop parts here to leave them out', items: items.filter((w) => !w.on), render: card },
        ], { onChange: (z) => {
          const shown = {};
          z.on.forEach((k) => { shown[k] = true; });
          z.off.forEach((k) => { shown[k] = false; });
          post('/api/apps/settings', { sleep_widgets_order: z.on.concat(z.off), sleep_widgets: shown });
        } }));
    }

    // The weather for At a glance, the widgets sleep screen and the Weather tile. The place is
    // looked up here, in the browser, with Open-Meteo's free place search.
    function weatherCard() {
      const place = App.obj(st.weather_place);
      const placeText = h('span', { class: 'muted' }, place.name ? [place.name, place.region, place.country].filter(Boolean).join(', ') : 'Not set');
      const change = async () => {
        const name = await App.prompt('Your town or city', place.name || '', 'Town or city');
        if (!name) return;
        let found;
        try {
          const r = await fetch('https://geocoding-api.open-meteo.com/v1/search?count=8&format=json&name=' + encodeURIComponent(name));
          found = App.arr((await r.json()).results);
        } catch (e) { return App.toast('Couldn’t look it up', true); }
        if (!found.length) return App.toast('No place called “' + name + '” was found', true);
        const pick = App.select(found.map((m, i) => [String(i), [m.name, m.admin1, m.country].filter(Boolean).join(', ')]), '0', () => {});
        if (!await App.modal('Which one?', pick, [{ text: 'Cancel', result: false }, { text: 'Save', primary: true, result: true }])) return;
        const m = found[Number(pick.value)];
        await post('/api/apps/settings', { weather_place: { name: m.name, region: m.admin1, country: m.country, cc: m.country_code, lat: m.latitude, lon: m.longitude } });
        App.toast('Saved. The Kindle loads the forecast when Wi-Fi is on.');
        reload();
      };
      const units = st.weather_units || ((place.cc || 'US') === 'US' ? 'f' : 'c');
      return h('div', { class: 'card' }, h('h2', {}, 'Weather'),
        h('p', { class: 'muted small' }, 'For At a glance, the widgets sleep screen and the Weather tile. ', App.link('Open-Meteo', 'https://open-meteo.com'),
          ' is a free forecast with no account; in the US, alerts come from the ', App.link('National Weather Service', 'https://www.weather.gov'), '.'),
        App.setting('Weather from', App.select([['auto', 'Automatic'], ['ha', 'Home Assistant'], ['openmeteo', 'Open-Meteo (free)'], ['off', 'Off']], st.weather || 'auto', set('weather')),
          'Automatic: Home Assistant’s when it has weather, else Open-Meteo once a place is set.'),
        App.setting('Place', h('span', { class: 'row' }, placeText, h('button', { class: 'btn small', onclick: change }, place.name ? 'Change' : 'Set'))),
        App.setting('Units', App.select([['f', '°F'], ['c', '°C']], units, set('weather_units'))),
        st.weather !== 'off' ? App.connectionTest('weather') : null);
    }

    main.append(
      h('h1', {}, 'Launcher'),
      h('p', { class: 'sub' }, 'The Kindle’s launcher: its tiles, shortcuts and settings.'),
      tilesCard(),
      h('div', { class: 'card' }, h('h2', {}, 'Add shortcut'),
        h('p', { class: 'muted small' }, 'A tile that opens straight to a Home Assistant screen or room, a To Do view (Today, Agenda…) or list, a notebook or a Notes folder, or runs a KOReader action (the ones gestures can run, such as Calibre wireless connect or Push progress).'),
        adder('ha', 'Home Assistant'), adder('todo', 'To Do'), adder('note', 'Notebook'), adder('notefolder', 'Notes folder'), adder('action', 'KOReader action')),
      h('div', { class: 'card' }, h('h2', {}, 'Display'),
        App.setting('Layout', App.select([['tiles', 'Tiles'], ['bold', 'Bold tiles'], ['compact', 'Compact'], ['list', 'List'], ['icons', 'Icons']], st.layout || 'tiles', set('layout'))),
        App.setting('Clock', App.select([['large', 'Large'], ['small', 'Small']], st.clock === 'small' ? 'small' : 'large', set('clock')), 'Small puts the time and date on one line, leaving more room for tiles.'),
        App.setting('Columns', App.select([['1', '1'], ['2', '2'], ['3', '3']], st.columns || 2, (v) => set('columns')(Number(v)))),

        App.setting('24-hour clock', App.toggle(st.clock_24h === true, set('clock_24h'))),
        App.setting('Button labels', App.toggle(st.button_labels !== false, set('button_labels')), 'The pop-ups’ buttons in every app: an icon over a label, or just the icon.'),
        ...App.arr(s.buttonLabelApps).map((ap) => App.setting('Button labels: ' + ap.name,
          App.select([['default', 'Default'], ['on', 'On'], ['off', 'Off']], ap.value, (v) => post('/api/apps/settings', { button_labels_app: { key: ap.key, value: v } }).then(reload)))),
        App.setting('Page bar', App.select([['parts', 'Numbered parts'], ['next', 'Parts and Next'], ['words', 'Words']], st.page_bar || 'parts', set('page_bar')),
          'At the foot of every app’s pages when there are several: a part per page to tap, the parts and a Next button, or “Page 1 of 4 · Next page”.'),
        App.setting('At a glance', App.toggle(st.today !== false, set('today')), 'The weather, what’s next and the tasks due, under the clock.'),
        App.setting('Recent books', App.toggle(st.recent !== false, set('recent'))),
        App.plugins && !App.plugins.notes ? null : App.setting('Recent notebooks', App.toggle(st.recent_notes !== false, set('recent_notes'))),
        App.plugins && !App.plugins.notes ? null : App.setting('Recent crosswords', App.toggle(st.recent_crosswords !== false, set('recent_crosswords'))),
        App.setting('Recent items', App.select([['together', 'One row'], ['separate', 'Separate rows']], st.recent_together !== false ? 'together' : 'separate', (v) => set('recent_together')(v === 'together')),
          'One row shows just the newest book, notebook and crossword side by side.')),
      quickCard(),
      weatherCard(),
      widgetsCard(),
      h('div', { class: 'card' }, h('h2', {}, 'Start'),
        App.setting('Open at startup', App.toggle(st.at_start === true, set('at_start')))),
      h('div', { class: 'card' }, h('h2', {}, 'Wi-Fi'),
        App.setting('Turn off when idle', App.select([['0', 'Off'], ['5', 'After 5 min'], ['15', 'After 15 min'], ['30', 'After 30 min']], String(st.wifi_idle || 0), (v) => set('wifi_idle')(Number(v))),
          'With no network use for that long. Not while the web server is on.')));
  },
};
