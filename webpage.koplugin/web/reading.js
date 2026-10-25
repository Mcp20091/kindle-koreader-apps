// Reading: today's reading time, days in a row, the last 30 days and each book, from KOReader's reading statistics.
App.pages.reading = {
  async render(main) {
    const r = await App.api('/api/reading');
    main.append(h('h1', {}, 'Reading'));
    if (!r.available) {
      main.append(h('div', { class: 'empty' }, 'No reading statistics yet. They come from KOReader’s Reading statistics plugin (Tools > Reading statistics), once you’ve read with it on.'));
      return;
    }
    const time = (s) => {
      const m = Math.round((s || 0) / 60);
      if (m < 60) return m + ' min';
      return Math.floor(m / 60) + ' h' + (m % 60 ? ' ' + (m % 60) + ' min' : '');
    };
    const days = App.arr(r.days);
    const week = days.slice(-7).reduce((n, d) => n + d.seconds, 0);
    const stat = (label, value, sub) => h('div', { class: 'card' }, h('h3', { style: 'margin-top:0' }, label),
      h('div', { style: 'font-size:28px;font-weight:700' }, value), sub ? h('div', { class: 'muted small' }, sub) : null);
    main.append(h('p', { class: 'sub' }, 'From KOReader’s reading statistics on the Kindle.'),
      h('div', { class: 'grid' },
        stat('Today', time(r.today)),
        stat('Days in a row', String(r.streak || 0), r.streak ? 'Keep it going' : 'Read today to start one'),
        stat('Last 7 days', time(week), time(week / 7) + ' a day'),
        stat('All time', time(r.total))));

    main.append(syncCard());

    // The last 30 days, a bar each (hover for the day and time; click for its reading).
    const max = Math.max(60, ...days.map((d) => d.seconds));
    const dayBox = h('div', { class: 'stack' });
    const bars = h('div', { class: 'bars' }, days.map((d) => {
      const date = new Date(d.day + 'T12:00:00');
      const label = date.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' }) + ': ' + time(d.seconds);
      return h('div', { class: 'bar tappable', title: label, onclick: () => showDay(d.day) },
        h('div', { class: 'fill', style: 'height:' + Math.round(d.seconds / max * 100) + '%' }),
        h('div', { class: 'day' }, date.getDate() === 1 || d === days[0] || d === days[days.length - 1] ? date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) : ''));
    }));
    main.append(h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'The last 30 days'), bars,
      h('p', { class: 'muted small' }, 'Click a day to see its reading. Edit a session to fix its day or times (a book left open by mistake, say), or delete it.'), dayBox));
    const lastRead = [...days].reverse().find((d) => d.seconds > 0);
    if (lastRead) showDay(lastRead.day);

    // A day's reading in sessions, each with Delete (for time that wasn't really reading).
    async function showDay(day) {
      const r = await App.api('/api/reading/day?day=' + day).catch(App.fail);
      if (!r) return;
      const date = new Date(day + 'T12:00:00').toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
      const sessions = App.arr(r.sessions);
      const clock = (t) => new Date(t * 1000).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
      dayBox.replaceChildren(h('h3', {}, date),
        sessions.length ? h('div', { class: 'list-rows' }, sessions.map((x) => h('div', {},
          h('div', { class: 'grow' }, h('div', {}, x.title), h('div', { class: 'muted small' },
            clock(x.from) + '–' + clock(x.to) + ' · ' + time(x.seconds) + ' · ' + x.pages + (x.pages === 1 ? ' page' : ' pages'))),
          h('button', { class: 'btn small', onclick: () => editSession(x, day) }, 'Edit'),
          h('button', { class: 'btn small danger', onclick: async () => {
            if (!await App.confirm('Delete this reading', 'Take ' + time(x.seconds) + ' of “' + x.title + '” on ' + date + ' (' + clock(x.from) + '–' + clock(x.to) + ') out of the reading statistics? This can’t be undone.', 'Delete', true)) return;
            await App.api('/api/reading/forget', { json: { book: x.book, from: x.from, to: x.to } }).then(() => { App.toast('Deleted'); App.route(); }, App.fail);
          } }, 'Delete')))) : h('p', { class: 'muted small' }, 'No reading that day.'));
    }

    // A session's day, start and end: moved as a whole; shorter cuts time off the end,
    // longer stretches each page's time.
    async function editSession(x, day) {
      const pad = (n) => String(n).padStart(2, '0');
      const hm = (t) => { const d = new Date(t * 1000); return pad(d.getHours()) + ':' + pad(d.getMinutes()); };
      const dayIn = h('input', { type: 'date', value: day });
      const startIn = h('input', { type: 'time', value: hm(x.from) });
      const endIn = h('input', { type: 'time', value: hm(x.to) });
      const length = h('div', { class: 'muted small' });
      const was = [dayIn.value, startIn.value, endIn.value];
      const times = () => {
        // A field left as it was keeps its exact time (the boxes only show minutes).
        const same = dayIn.value === was[0];
        const s = same && startIn.value === was[1] ? x.from : new Date(dayIn.value + 'T' + startIn.value + ':00').getTime() / 1000;
        let e = same && endIn.value === was[2] ? x.to : new Date(dayIn.value + 'T' + endIn.value + ':00').getTime() / 1000;
        if (e <= s) e += 86400;   // past midnight
        return [s, e];
      };
      const show = () => {
        const [s, e] = times();
        length.textContent = isNaN(s) || isNaN(e) ? '' : 'Length: ' + time(e - s) + ' (was ' + time(x.to - x.from) + ')' +
          (e - s < x.to - x.from ? '. Time past the new end is taken out.' : e - s > x.to - x.from ? '. Each page’s time is stretched to fit.' : '');
      };
      [dayIn, startIn, endIn].forEach((el) => el.addEventListener('input', show));
      show();
      const body = h('div', { class: 'stack' },
        h('p', { class: 'muted small' }, '“' + x.title + '”, ' + x.pages + (x.pages === 1 ? ' page' : ' pages') + '.'),
        App.setting('Day', dayIn), App.setting('Start', startIn), App.setting('End', endIn), length);
      const ok = await App.modal('Edit this reading', body, [{ text: 'Cancel', result: false }, { text: 'Save', primary: true, result: true }]);
      if (!ok) return;
      const [s, e] = times();
      if (isNaN(s) || isNaN(e)) return App.toast('Pick a day, a start and an end', true);
      await App.api('/api/reading/edit', { json: { book: x.book, from: x.from, to: x.to, start: s, finish: e } })
        .then(() => { App.toast('Saved'); App.route(); }, App.fail);
    }

    // KOReader's progress sync, for the book open on the Kindle.
    function syncCard() {
      const box = h('div', { class: 'card stack', style: 'margin-top:16px' }, h('h2', {}, 'Progress sync'));
      App.api('/api/kosync').then((k) => {
        if (!k.book) { box.append(h('p', { class: 'muted small' }, 'Open a book on the Kindle to push or pull its progress (KOReader’s Progress sync).')); return; }
        if (!k.available) { box.append(h('p', { class: 'muted small' }, 'KOReader’s Progress sync plugin isn’t on.')); return; }
        const act = (action, done) => App.api('/api/kosync', { json: { action } }).then(() => App.toast(done), App.fail);
        box.append(h('p', { class: 'muted small' }, 'For “' + k.book + '”, open on the Kindle.' + (k.signedIn ? '' : ' Progress sync isn’t signed in yet: set it up on the Kindle (Tools > Progress sync), or on the KOReader tab here.')),
          h('div', { class: 'row' },
            h('button', { class: 'btn primary', onclick: () => act('push', 'Pushing progress…') }, 'Push progress from this device'),
            h('button', { class: 'btn', onclick: () => act('pull', 'Pulling progress…') }, 'Pull progress from other devices')),
          App.setting('Auto sync', App.toggle(k.auto === true, () => act('auto', 'Changed')), 'Pushes and pulls by itself as you open and close books.'));
      }).catch(() => box.append(h('p', { class: 'muted small' }, 'Not available.')));
      return box;
    }

    const books = App.arr(r.books);
    main.append(h('div', { class: 'card', style: 'margin-top:16px' }, h('h2', {}, 'Books'),
      books.length ? h('table', { class: 'list' },
        h('thead', {}, h('tr', {}, h('th', {}, 'Book'), h('th', {}, 'Time'), h('th', {}, 'Pages read'), h('th', {}, 'Last read'), h('th', {}))),
        h('tbody', {}, books.map((b) => h('tr', {},
          h('td', {}, h('div', {}, b.title || 'Untitled'), b.authors ? h('div', { class: 'muted small' }, b.authors) : null),
          h('td', {}, time(b.seconds)),
          h('td', { class: 'muted small' }, b.read + (b.pages ? ' of ' + b.pages : '')),
          h('td', { class: 'muted small' }, App.when(b.last)),
          h('td', { style: 'text-align:right' }, b.id ? h('button', { class: 'btn small danger', onclick: async () => {
            if (!await App.confirm('Reset statistics', 'Take all of “' + (b.title || 'this book') + '” out of the reading statistics (' + time(b.seconds) + ')? This can’t be undone.', 'Reset', true)) return;
            await App.api('/api/reading/forget', { json: { book: b.id } }).then(() => { App.toast('Reset'); App.route(); }, App.fail);
          } }, 'Reset') : null)))))
        : h('div', { class: 'empty' }, 'No books yet.')));
  },
};
