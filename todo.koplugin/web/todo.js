// To Do: lists and tasks (sent to Microsoft To Do at the reader's next sync), CSV, options, app ID, sign-in.
App.pages.todo = {
  listId: null,
  showDone: false,  // Completed (n) open
  // Keep rows in place: after Done, a star or a new date the next draw keeps the rows
  // where they were (keepNext, used once); layout is the last draw's { list, ids }.
  keepNext: false,
  layout: null,
  tab: 'tasks',
  async render(main, params) {
    const s = await App.api('/api/todo');
    // The launcher's icons (Lucide, as To Do's), for the Home tiles' pictures.
    this.icons = App.arr((await App.api('/api/apps/icons?all=1').catch(() => ({}))).icons);
    // From a search: that task's list.
    if (params && params.list) { this.listId = params.list; this.tab = 'tasks'; }
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'The To Do plugin isn’t installed on this Kindle.')); return; }
    s.lists = App.arr(s.lists);
    for (const l of s.lists) {
      l.tasks = App.arr(l.tasks);
      for (const t of l.tasks) t.steps = App.arr(t.steps);
    }
    s.options = App.obj(s.options);
    const page = this;
    page.keepOn = page.keepNext && s.options.stable_lists !== false;
    page.keepNext = false;
    if (!s.lists.find((l) => l.id === page.listId)) page.listId = (s.lists.find((l) => l.default) || s.lists[0] || {}).id;
    const body = h('div');
    const draw = () => {
      body.innerHTML = '';
      body.append(App.tabs([['tasks', 'Tasks'], ['settings', 'Settings and sign-in'], ['csv', 'Import / export']], page.tab, (k) => { page.tab = k; draw(); }),
        page[page.tab](s));
    };
    main.append(
      h('div', { class: 'spread' },
        h('div', {}, h('h1', {}, 'To Do'),
          h('p', { class: 'sub' }, s.signedIn ? 'Synced ' + App.ago(s.syncedAt) + (s.pending ? ' · ' + s.pending + ' change(s) waiting to be sent' : '') : 'Not signed in · lists on this Kindle only')),
        s.signedIn ? h('div', { class: 'row' },
          h('button', { class: 'btn primary', onclick: () => sync(false) }, 'Sync now'),
          h('button', { class: 'btn', onclick: () => sync(true) }, 'Download only')) : null),
      body);
    draw();
    async function sync(downloadOnly) {
      await App.api('/api/todo/sync', { json: { downloadOnly } }).catch(App.fail);
      App.toast('Syncing…');
      setTimeout(App.route, 6000);
    }
  },

  async change(json) {
    this.keepNext = ['done', 'star', 'skip'].includes(json.op);
    await App.api('/api/todo/task', { json }).catch(App.fail);
    App.route();
  },

  tasks(s) {
    const page = this;
    const list = s.lists.find((l) => l.id === page.listId);
    // To Do's lists, then the ones on this Kindle (never synced).
    const kindle = s.lists.filter((l) => l.onKindle);
    const groups = [[s.signedIn ? 'Microsoft To Do' : null, s.lists.filter((l) => !l.onKindle)], [kindle.length && s.signedIn ? 'On this Kindle' : null, kindle]];
    const newList = (onKindle) => h('button', { class: 'btn small', onclick: async () => {
      const name = await App.prompt(onKindle ? 'New list on this Kindle' : 'New list', '', 'List name');
      if (name) { await App.api('/api/todo/list', { json: { op: 'add', name, onKindle } }).catch(App.fail); App.route(); }
    } }, onKindle && s.signedIn ? '+ New list on this Kindle' : '+ New list');
    const side = h('div', { class: 'card side' },
      groups.map(([heading, lists]) => [heading && lists.length ? h('div', { class: 'muted small', style: 'margin:8px 0 4px' }, heading) : null, lists.map((l) => {
        const open = l.tasks.filter((t) => !t.completed).length;
        const item = h('a', { href: '#todo', class: 'item' + (l.id === page.listId ? ' on' : ''), onclick: (e) => { e.preventDefault(); page.listId = l.id; App.route(); } },
          h('span', {}, (l.pinned ? '📌 ' : '') + l.name + (l.hidden ? ' (hidden)' : '')), h('span', { class: 'count' }, open));
        // A task dragged here moves to this list.
        if (l.id !== page.listId && !l.flagged) {
          item.addEventListener('dragover', (e) => { if (page.dragging) { e.preventDefault(); item.classList.add('drop-on'); } });
          item.addEventListener('dragleave', () => item.classList.remove('drop-on'));
          item.addEventListener('drop', (e) => {
            e.preventDefault();
            item.classList.remove('drop-on');
            const d = page.dragging;
            page.dragging = null;
            if (d) page.change({ op: 'move', list: d.list, id: d.id, to: l.id }).then(() => App.toast('Moved to ' + l.name));
          });
        }
        return item;
      })]),
      // Deleted lists wait until the next sync, as on the Kindle.
      App.arr(s.deletedLists).length ? h('div', { style: 'margin-top:12px' },
        h('div', { class: 'muted small' }, 'Deleted lists (until the next sync)'),
        App.arr(s.deletedLists).map((d) => h('div', { class: 'spread small' }, h('span', {}, d.title),
          h('button', { class: 'btn small', onclick: async () => { await App.api('/api/todo/list', { json: { op: 'restore', id: d.id } }).catch(App.fail); App.route(); } }, 'Put back')))) : null,
      h('div', { class: 'row', style: 'margin-top:10px' }, s.signedIn ? newList(false) : null, s.options.local_lists !== false || !s.signedIn ? newList(true) : null));
    if (!list) return h('div', { class: 'two' }, side, h('div', { class: 'empty' }, 'No lists yet. Sign in and sync, or create one.'));

    const title = h('input', { type: 'text', placeholder: 'What needs doing?', style: 'flex:1;min-width:200px' });
    const due = h('input', { type: 'date' });
    const star = h('input', { type: 'checkbox' });
    const notes = h('textarea', { rows: 2, placeholder: 'Notes (optional)' });
    const steps = h('textarea', { rows: 2, placeholder: 'Steps, one per line (optional)' });
    const more = h('div', { class: 'stack', style: 'display:none;margin-top:8px' }, notes, steps);
    const add = async () => {
      const typed = title.value.trim();
      if (!typed) return;
      const change = { op: 'add', list: list.id, title: typed, due: due.value || null, important: star.checked,
        notes: notes.value.trim(), steps: steps.value.split('\n').map((x) => x.trim()).filter(Boolean) };
      // A date or time in the words ("Pay rent Friday 9am"): what was understood is shown first.
      const u = await App.api('/api/todo/understand?text=' + encodeURIComponent(typed)).catch(() => ({ none: true }));
      if (u && !u.none) {
        const use = await App.modal('Add task', h('div', { class: 'stack' }, h('div', { style: 'font-weight:600' }, '“' + u.title + '”'), h('div', {}, u.text)),
          [{ text: 'Cancel', result: null }, { text: 'Keep as typed', result: false }, { text: 'Add', result: true, primary: true }]);
        if (use === null || use === undefined) return;
        if (use) Object.assign(change, { title: u.title, due: u.due, minute: u.minute });
      }
      await page.change(change);
    };
    title.addEventListener('keydown', (e) => { if (e.key === 'Enter') add(); });

    let tasks = list.tasks;
    // Keep rows in place: the rows in the last draw's order, each up to date (a ticked
    // one stays, done), new ones after them.
    if (page.keepOn && page.layout && page.layout.list === list.id) {
      const byId = new Map(list.tasks.concat(App.arr(list.completed)).map((t) => [t.id, t]));
      const kept = page.layout.ids.map((id) => byId.get(id)).filter(Boolean);
      const seen = new Set(kept.map((t) => t.id));
      tasks = kept.concat(list.tasks.filter((t) => !seen.has(t.id)));
    }
    page.layout = { list: list.id, ids: tasks.map((t) => t.id) };
    const done = App.arr(list.completed);
    const listMenu = h('div', { class: 'row' },
      h('button', { class: 'btn small', onclick: async () => {
        const name = await App.prompt('Rename list', list.name);
        if (name) { await App.api('/api/todo/list', { json: { op: 'rename', id: list.id, name } }).catch(App.fail); App.route(); }
      } }, 'Rename'),
      h('button', { class: 'btn small', onclick: () => listOp('pin', !list.pinned) }, list.pinned ? 'Unpin' : 'Pin'),
      h('button', { class: 'btn small', onclick: () => listOp('hide', !list.hidden) }, list.hidden ? 'Show on Kindle' : 'Hide on Kindle'),
      list.default ? h('span', { class: 'pill' }, 'Default list') : h('button', { class: 'btn small', onclick: () => listOp('default', true) }, 'Make default'),
      list.onKindle && s.signedIn ? h('button', { class: 'btn small', onclick: async () => {
        if (await App.confirm('Move to Microsoft To Do', 'Move “' + list.name + '” to Microsoft To Do? Its tasks become To Do tasks and sync to your account. The list on the Kindle goes under Deleted lists.', 'Move')) listOp('toTodo');
      } }, 'Move to Microsoft To Do') : null,
      h('button', { class: 'btn small danger', onclick: async () => {
        const where = list.onKindle ? 'It waits under Deleted lists, where you can put it back.' : 'Until the next sync it waits under Deleted lists, where you can put it back; the sync deletes it in To Do.';
        if (await App.confirm('Delete list', 'Delete “' + list.name + '” and its tasks? ' + where, 'Delete', true)) listOp('delete');
      } }, 'Delete'));

    const main = h('div', {},
      h('div', { class: 'card' },
        h('div', { class: 'spread' }, h('h2', { style: 'margin:0' }, list.name), listMenu),
        h('div', { class: 'row', style: 'margin-top:12px' }, title, due,
          h('label', { class: 'row small' }, star, 'Starred'),
          h('button', { class: 'btn small', onclick: () => { more.style.display = more.style.display === 'none' ? '' : 'none'; } }, 'Notes & steps'),
          h('button', { class: 'btn primary', onclick: add }, 'Add')),
        more),
      h('div', { class: 'card' },
        tasks.length ? tasks.map((t) => page.taskRow(s, list, t)) : h('div', { class: 'empty' }, 'Nothing to do here.'),
        // Done tasks, as Completed (n) on the Kindle: Not done brings one back.
        done.length ? h('div', { style: 'margin-top:14px' },
          h('button', { class: 'btn small', onclick: () => { page.showDone = !page.showDone; App.route(); } },
            'Completed (' + done.length + ')' + (page.showDone ? ' ▴' : ' ▾')),
          page.showDone ? done.map((d) => h('div', { class: 'spread', style: 'margin-top:6px' }, h('span', { class: 'muted' }, d.title),
            h('button', { class: 'btn small', onclick: () => page.change({ op: 'done', list: list.id, id: d.id }) }, 'Not done'))) : null) : null,
        // Deleted tasks wait until the next sync, as on the Kindle.
        App.arr(list.deleted).length ? h('div', { style: 'margin-top:14px' },
          h('div', { class: 'muted small' }, 'Deleted (' + App.arr(list.deleted).length + ') · until the next sync'),
          App.arr(list.deleted).map((d) => h('div', { class: 'spread' }, h('span', { class: 'muted' }, d.title + (d.completed ? ' (completed)' : '')),
            h('button', { class: 'btn small', onclick: () => page.change({ op: 'restore', list: list.id, id: d.id }) }, 'Put back')))) : null));
    return h('div', { class: 'two' }, side, main);

    async function listOp(op, on) {
      await App.api('/api/todo/list', { json: { op, id: list.id, on } }).catch(App.fail);
      App.route();
    }
  },

  taskRow(s, list, t) {
    const page = this;
    const box = h('input', { type: 'checkbox', checked: t.completed });
    box.addEventListener('change', () => page.change({ op: 'done', list: list.id, id: t.id }));
    const meta = [];
    if (t.due) meta.push((t.due < s.today && !t.completed ? 'Overdue ' : 'Due ') + t.due);
    if (t.repeat) meta.push('↻ ' + t.repeat);
    if (t.steps.length) meta.push(t.steps.filter((x) => x.checked).length + '/' + t.steps.length + ' steps');
    if (t.notes) meta.push('notes');
    const row = h('div', { class: 'task' + (t.completed ? ' done' : ''), draggable: 'true', title: 'Drag onto a list to move it' }, box,
      h('div', { class: 'grow' }, h('div', { class: 'title', onclick: () => page.edit(s, list, t) }, t.title),
        meta.length ? h('div', { class: 'meta' }, meta.join(' · ')) : null),
      h('button', { class: 'star' + (t.important ? ' on' : ''), title: 'Star', onclick: () => page.change({ op: 'star', list: list.id, id: t.id, on: !t.important }) }, '★'));
    row.addEventListener('dragstart', (e) => { page.dragging = { list: list.id, id: t.id }; e.dataTransfer.effectAllowed = 'move'; row.classList.add('dragging'); });
    row.addEventListener('dragend', () => { row.classList.remove('dragging'); setTimeout(() => { page.dragging = null; }, 0); });
    return row;
  },

  async edit(s, list, t) {
    const page = this;
    const title = h('input', { type: 'text', value: t.title, style: 'width:100%' });
    const due = h('input', { type: 'date', value: t.due || '' });
    const notes = h('textarea', { rows: 4 }, t.notes);
    const move = App.select(s.lists.map((l) => [l.id, l.name]), list.id, () => {});
    const stepRows = h('div', { class: 'list-rows' }, t.steps.map((st) => {
      const b = h('input', { type: 'checkbox', checked: st.checked });
      b.addEventListener('change', () => App.api('/api/todo/task', { json: { op: 'stepToggle', list: list.id, id: t.id, step: st.id } }).catch(App.fail));
      return h('div', {}, b, h('span', { class: 'grow' }, st.title),
        h('button', { class: 'icon-btn', onclick: async (e) => {
          await App.api('/api/todo/task', { json: { op: 'stepDelete', list: list.id, id: t.id, step: st.id } }).catch(App.fail);
          e.target.closest('div').remove();
        } }, '✕'));
    }));
    const newStep = h('input', { type: 'text', placeholder: 'Add a step', style: 'flex:1' });
    const addStep = async () => {
      if (!newStep.value.trim()) return;
      await App.api('/api/todo/task', { json: { op: 'stepAdd', list: list.id, id: t.id, title: newStep.value.trim() } }).catch(App.fail);
      stepRows.append(h('div', {}, h('input', { type: 'checkbox', disabled: true }), h('span', { class: 'grow' }, newStep.value.trim())));
      newStep.value = '';
    };
    newStep.addEventListener('keydown', (e) => { if (e.key === 'Enter') addStep(); });
    const priv = App.toggle(t.private, (on) => App.api('/api/todo/task', { json: { op: 'private', id: t.id, on } }).catch(App.fail));
    const body = h('div', { class: 'stack' },
      h('label', { class: 'field' }, h('span', {}, 'Title'), title),
      h('div', { class: 'row' }, h('label', { class: 'field grow' }, h('span', {}, 'Due'), due),
        h('label', { class: 'field grow' }, h('span', {}, 'List'), move)),
      t.repeat ? h('div', { class: 'row small' }, '↻ ' + t.repeat,
        h('button', { class: 'btn small', onclick: () => { close(); page.change({ op: 'skip', list: list.id, id: t.id }); } }, 'Skip to current'),
        h('button', { class: 'btn small', onclick: () => { close(); page.change({ op: 'removeRepeat', list: list.id, id: t.id }); } }, 'Remove repeat')) : null,
      h('label', { class: 'field' }, h('span', {}, 'Notes'), notes),
      h('div', {}, h('div', { class: 'small muted' }, 'Steps'), stepRows, h('div', { class: 'row', style: 'margin-top:6px' }, newStep, h('button', { class: 'btn small', onclick: addStep }, 'Add'))),
      App.setting('Hide on sleep', priv, 'Keeps this task off the sleep screen.'),
      h('div', {}, h('button', { class: 'btn danger small', onclick: async () => {
        if (await App.confirm('Delete task', 'Delete “' + t.title + '”?', 'Delete', true)) { close(); page.change({ op: 'delete', list: list.id, id: t.id }); }
      } }, 'Delete task')));
    let close = () => {};
    const result = App.modal('Task', body, [{ text: 'Cancel', result: false }, { text: 'Save', primary: true, result: true }], true);
    close = () => document.querySelector('.modal-back')?.remove();
    if (!await result) return App.route();
    const changes = [];
    if (title.value.trim() && title.value.trim() !== t.title) changes.push({ op: 'rename', title: title.value.trim() });
    if ((due.value || null) !== (t.due || null)) changes.push({ op: 'due', due: due.value || null });
    if (notes.value !== (t.notes || '')) changes.push({ op: 'notes', notes: notes.value });
    if (move.value !== list.id) changes.push({ op: 'move', to: move.value });
    // (Only a new date, name or notes: the rows stay where they are, with Keep rows in place.)
    page.keepNext = changes.length > 0 && changes.every((c) => ['due', 'rename', 'notes'].includes(c.op));
    for (const c of changes) {
      await App.api('/api/todo/task', { json: Object.assign({ list: list.id, id: t.id }, c) }).catch(App.fail);
    }
    App.route();
  },

  // Home's tiles (Today, Agenda, Starred, Calendar, Search) as they look there; drag to
  // reorder or to Hidden, or tap one for a menu.
  homeTiles(s) {
    const icons = App.arr(this.icons);
    const svg = (name) => { const sp = h('span', { class: 'tile-icon' }); const i = icons.find((x) => x.name === name); if (i) sp.innerHTML = i.svg; return sp; };
    const items = App.arr(s.homeTiles).map((t) => ({ key: t.key, name: t.name, icon: t.icon, on: t.on }));
    const tile = (t) => h('div', { class: 've-tile', style: 'width:290px;height:56px;flex-direction:row;align-items:center;justify-content:flex-start;gap:12px' }, svg(t.icon), h('b', {}, t.name));
    return h('div', { class: 'stack', style: 'margin-bottom:12px' },
      App.visualZones([
        { id: 'on', title: 'Home tiles', short: 'Shown', items: items.filter((t) => t.on), render: tile },
        { id: 'off', title: 'Hidden', short: 'Hidden', className: 'tray', empty: 'Drop tiles here to hide them', items: items.filter((t) => !t.on), render: tile },
      ], { onChange: (z) => App.api('/api/todo/tiles', { json: { tiles: z.on.map((key) => ({ key, on: true })).concat(z.off.map((key) => ({ key, on: false }))) } }).catch(App.fail) }));
  },

  // The lists in their order on the Kindle (Settings > Lists); drag to reorder or to Hidden, or tap one for a menu.
  listOrder(s) {
    const items = s.lists.map((l) => ({ key: l.id, name: l.name, on: !l.hidden }));
    const row = (l) => h('div', { class: 've-tile', style: 'width:290px;height:44px;flex-direction:row;align-items:center;justify-content:flex-start' }, h('b', {}, l.name));
    return h('div', { class: 'stack', style: 'margin-bottom:12px' },
      App.visualZones([
        { id: 'on', title: 'Lists', short: 'Shown', items: items.filter((l) => l.on), render: row },
        { id: 'off', title: 'Hidden', short: 'Hidden', className: 'tray', empty: 'Drop lists here to hide them', items: items.filter((l) => !l.on), render: row },
      ], { onChange: (z) => App.api('/api/todo/listorder', { json: { lists: z.on.map((id) => ({ id, on: true })).concat(z.off.map((id) => ({ id, on: false }))) } }).catch(App.fail) }));
  },

  settings(s) {
    const o = s.options;
    const set = (key) => (value) => App.api('/api/todo/options', { json: { [key]: value } }).then(() => { o[key] = value; }, App.fail);
    const num = (key) => (v) => set(key)(Number(v));
    const client = h('input', { type: 'text', value: s.clientId, placeholder: '00000000-0000-0000-0000-000000000000', style: 'flex:1;min-width:260px' });
    const codeBox = h('div');
    // The same sections, in the same order, as To Do's settings on the Kindle.
    // 1 to 60, as the Kindle's spinner.
    const pushDays = h('input', { type: 'number', min: 1, max: 60, step: 1, value: o.push_days || 7, style: 'width:90px' });
    pushDays.addEventListener('change', () => {
      const n = Math.max(1, Math.min(60, Math.round(Number(pushDays.value)) || 7));
      pushDays.value = n;
      num('push_days')(n);
    });
    const real = s.lists.filter((l) => !l.flagged);
    const listPick = (current, none, onPick) => App.select([...(none ? [['', 'None']] : []), ...real.map((l) => [l.id, l.name])], current || '', onPick);
    const listSet = (op) => (id) => App.api('/api/todo/list', { json: { op, id, on: op === 'pin' ? !!id : true } }).then(() => App.route(), App.fail);
    const pinned = (real.find((l) => l.pinned) || {}).id;
    const dflt = (real.find((l) => l.default) || {}).id;
    return h('div', {},
      h('div', { class: 'card' }, h('h2', {}, 'Display'),
        App.setting('Week starts on', App.select([['sunday', 'Sunday'], ['monday', 'Monday']], o.week_start, set('week_start'))),
        App.setting('Split view (landscape)', App.toggle(o.two_panes !== false, set('two_panes')), 'The lists at the left, the open one at the right.'),
        App.setting('Full refresh', App.select([['6', 'Every 6 changes'], ['3', 'Every 3 changes'], ['1', 'Every change'], ['0', 'Never']], String(o.deghost == null ? 6 : o.deghost), num('deghost')))),
      h('div', { class: 'card' }, h('h2', {}, 'Home'),
        this.homeTiles(s),
        this.listOrder(s),
        App.setting('Show hidden lists', App.toggle(o.show_hidden, set('show_hidden'))),
        App.setting('Pinned list', listPick(pinned, true, listSet('pin'))),
        App.setting('Default list', listPick(dflt, false, listSet('default')))),
      h('div', { class: 'card' }, h('h2', {}, 'Tasks'),
        App.setting('Starred on top', App.toggle(o.starred_first, set('starred_first'))),
        App.setting('Group by due date', App.toggle(o.group_by_due, set('group_by_due'))),
        App.setting('Keep rows in place', App.toggle(o.stable_lists !== false, set('stable_lists')),
          'After you tick, star or reschedule a task, it stays where it is until you leave the page or refresh it.'),
        App.setting('Tap action', App.select([['task', 'Open task'], ['menu', 'Quick actions']], o.tap_opens, set('tap_opens'))),
        App.setting('Postpone by (days)', pushDays),
        App.setting('Reminder alerts', App.toggle(o.reminders !== false, set('reminders')), 'While KOReader is open.'),
        App.setting('Lists on this Kindle', App.toggle(o.local_lists !== false, set('local_lists')), 'Lists kept only on the Kindle, never synced. Off hides them (they’re kept).')),
      h('div', { class: 'card' }, h('h2', {}, 'Sync'),
        App.setting('Background sync', App.select([['0', 'Off'], ['15', 'Every 15 min'], ['30', 'Every 30 min'], ['60', 'Every hour'], ['120', 'Every 2 hours']], o.sync_interval, num('sync_interval'))),
        App.setting('Sync changes immediately', App.toggle(o.send_now, set('send_now'))),
        App.setting('Send changes', App.select([['2', 'After 2 s'], ['4', 'After 4 s'], ['10', 'After 10 s'], ['30', 'After 30 s'], ['60', 'After 1 min']], String(o.send_delay || 4), num('send_delay')),
          'How long after your last change they go out (with Sync changes immediately, while Wi-Fi is on).'),
        App.setting('Download only', App.toggle(o.download_only, set('download_only')))),
      h('div', { class: 'card' }, h('h2', {}, 'Sleep screen'),
        App.setting('Sleep screen content', App.select([['today_next', 'Today + Up next'], ['today', 'Today'], ['starred', 'Starred'], ['pinned', 'Pinned list']], o.sleep_content || 'today_next', set('sleep_content'))),
        h('p', { class: 'muted small' }, 'Which sleep screen the Kindle shows is chosen once for every app: on the Home tab here, or in the launcher’s settings on the Kindle.')),
      // With the launcher: the shared Microsoft account (one App ID and sign-in for To Do and OneNote).
      s.microsoft ? App.microsoftCard() : null,
      s.microsoft ? h('div', { class: 'card stack' }, h('h2', {}, 'To Do'), App.connectionTest('todo')) : null,
      s.microsoft ? null : h('div', { class: 'card stack' },
        h('h2', {}, 'Account'),
        h('label', { class: 'field' }, h('span', {}, 'App (client) ID from your Microsoft ',
          App.link('Entra app registration', 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade'), ' (',
          App.link('how to make one', 'https://github.com/Mcp20091/kindle-koreader-apps/blob/main/guide/setup.md#microsoft-to-do-and-onenote'), ')'),
          h('div', { class: 'row' }, client, h('button', { class: 'btn', onclick: saveClient }, 'Save'))),
        h('div', { class: 'row' },
          s.signedIn ? h('span', { class: 'pill ok' }, 'Signed in') : h('span', { class: 'pill' }, 'Not signed in'),
          h('button', { class: 'btn primary', onclick: signIn }, s.signedIn ? 'Sign in again' : 'Sign in'),
          s.signedIn ? h('button', { class: 'btn danger', onclick: signOut }, 'Sign out') : null),
        codeBox,
        s.clientId || s.signedIn ? App.connectionTest('todo') : null));

    async function saveClient() {
      await App.api('/api/todo/clientid', { json: { id: client.value } }).then(() => App.toast('Saved'), App.fail);
    }
    async function signIn() {
      await saveClient();
      const st = await App.api('/api/todo/signin', { json: {} }).catch(App.fail);
      if (st) App.showCode(codeBox, st, '/api/todo/signin', 'Signed in to To Do. Syncing…');
    }
    async function signOut() {
      if (!await App.confirm('Sign out', 'Sign out of To Do? Tasks saved on the Kindle and unsent changes will be removed.', 'Sign out', true)) return;
      await App.api('/api/todo/signout', { json: {} }).then(App.route, App.fail);
    }
  },

  csv(s) {
    const where = (l) => (l.onKindle ? ' (on this Kindle)' : (s.signedIn ? ' (To Do)' : ''));
    // Export: the lists ticked.
    const ticks = s.lists.map((l) => ({ l, box: h('input', { type: 'checkbox', checked: true }) }));
    const exportLink = () => '/api/todo/export.csv?lists=' + encodeURIComponent(ticks.filter((x) => x.box.checked).map((x) => x.l.id).join(','));
    // Import: into one list, or the lists named in the file (found or made in To Do or on this Kindle).
    const into = App.select([
      ...(s.signedIn ? [['where:todo', 'The lists named in the file, in To Do']] : []),
      ['where:kindle', 'The lists named in the file, on this Kindle'],
      ...s.lists.filter((l) => !l.flagged).map((l) => ['into:' + l.id, 'Everything into ' + l.name + where(l)]),
    ], s.signedIn ? 'where:todo' : 'where:kindle', () => {});
    const file = h('input', { type: 'file', accept: '.csv,text/csv', style: 'display:none' });
    file.addEventListener('change', async () => {
      const f = file.files[0];
      if (!f) return;
      const [kind, value] = [into.value.slice(0, into.value.indexOf(':')), into.value.slice(into.value.indexOf(':') + 1)];
      const q = kind === 'into' ? '?into=' + encodeURIComponent(value) : '?where=' + value;
      const r = await App.api('/api/todo/import' + q, { method: 'POST', body: await f.text() }).catch(App.fail);
      if (r) { App.toast(r.added + ' task(s) added'); App.route(); }
    });
    const template = 'List,Title,Due,Starred,Notes,Steps\nShopping List,Milk,,,,\nTasks,Call the vet,2026-11-02,yes,Ask about vaccines,Find the card; Call\n';
    return h('div', { class: 'stack' },
      h('div', { class: 'card stack' },
        h('h2', {}, 'Export'),
        h('p', { class: 'muted small' }, 'The lists ticked, as CSV: List, Title, Due, Completed, Starred, Notes and Steps.'),
        h('div', { class: 'stack' }, ticks.map((x) => h('label', { class: 'row small' }, x.box, x.l.name + where(x.l)))),
        h('div', { class: 'row' },
          h('button', { class: 'btn primary', onclick: () => { location.href = exportLink(); } }, 'Export CSV'))),
      h('div', { class: 'card stack' },
        h('h2', {}, 'Import'),
        h('p', { class: 'muted small' }, 'One task per row (columns: List, Title, Due as YYYY-MM-DD, Starred, Notes, Steps separated by “;”). A file exported from lists on this Kindle can go into To Do here, and the other way round.'),
        App.setting('Put the tasks into', into),
        h('div', { class: 'row' },
          h('button', { class: 'btn primary', onclick: () => file.click() }, 'Import CSV'), file,
          h('button', { class: 'btn', onclick: () => App.download(new Blob([template], { type: 'text/csv' }), 'todo-template.csv') }, 'Download template'))));
  },
};
