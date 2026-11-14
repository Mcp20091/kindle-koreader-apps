// Spotify (the optional Spotify plugin): what's playing, the remote's buttons, the volume, the devices,
// playlists, recently played songs and a search, and its settings and sign-in. The Kindle talks to Spotify;
// the page reads the Kindle's state again every few seconds while this tab is open (that is what makes the
// Kindle read Spotify: nothing is read once the tab is closed), and a moment after each command.
App.pages.spotify = {
  timer: null,
  asked: false,
  signInUrl: null,

  async render(main) {
    clearTimeout(this.timer);
    const s = await App.api('/api/spotify');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'Spotify Remote isn’t installed on this Kindle. It’s an optional app: copy spotify.koplugin to koreader/plugins.')); return; }
    ['devices', 'playlists', 'recent'].forEach((k) => { s[k + 'Read'] = Array.isArray(s[k]); s[k] = App.arr(s[k]); });
    s.search = App.obj(s.search);
    main.append(
      h('div', {}, h('h1', {}, 'Spotify Remote'), h('p', { class: 'sub' }, 'A remote for ',
        App.link('Spotify', 'https://www.spotify.com'), '. The music plays on a Spotify device, not on the Kindle.')),
      ...[this.again(s), this.playing(s), this.opened(s), this.devices(s), this.start(s), this.more(s), this.settings(s)].filter(Boolean));
    const failed = App.obj(s.failed);
    if (failed.choose) this.chooseDevice(s, failed);
    else if (failed.text) App.toast(failed.text, true);
    const signIn = App.obj(s.signInResult);
    if (signIn.ok) App.toast('Signed in to Spotify');
    else if (signIn.text) App.toast(signIn.text, true);
    // (your playlists and recent songs are read by the Kindle once, when the tab first opens)
    if (s.configured && !this.asked) {
      this.asked = true;
      this.quiet('playlists', {});
      this.quiet('recent', {});
    }
    if (s.configured || s.signingIn) {
      const wait = s.reading || s.search.reading ? 2000 : Math.max(5, Number(s.interval) || 10) * 1000;
      this.timer = setTimeout(() => {
        const typing = document.activeElement && document.activeElement.tagName === 'INPUT';
        if (main.isConnected && location.hash.startsWith('#spotify') && !document.querySelector('.modal') && !typing) this.reload();
        else if (main.isConnected) this.timer = setTimeout(() => this.reload(), 5000);
      }, wait);
    }
  },

  reload() { App.route(); },

  quiet(name, args) { return App.api('/api/spotify/act', { json: { name, args } }).catch(() => {}); },

  async act(name, args, done) {
    try {
      await App.api('/api/spotify/act', { json: { name, args } });
      if (done) App.toast(done);
      setTimeout(() => this.reload(), 1800);
    } catch (e) { App.fail(e); }
  },

  row(name, line, ...right) {
    return h('div', { class: 'spread', style: 'padding:6px 0;border-top:1px solid var(--line);gap:10px' },
      h('div', {}, h('div', {}, name), line ? h('div', { class: 'small muted' }, line) : null),
      h('div', { class: 'row', style: 'gap:10px;white-space:nowrap' }, ...right.filter(Boolean)));
  },

  // Several devices are on and none is playing: which one?
  chooseDevice(s, failed) {
    const page = this;
    const args = App.obj(failed.args);
    const usable = s.devices.filter((d) => d.usable);
    App.modal('Play on', h('p', { class: 'muted' }, 'Nothing is playing yet. Which device?'),
      [{ text: 'Cancel', result: null }, ...usable.map((d) => ({ text: d.name, result: d.id }))])
      .then((id) => { if (id) page.act(failed.name, { ...args, device: id }); });
  },

  playing(s) {
    const page = this;
    // (not set up or not signed in: the Client ID and the sign-in are the first thing on the page)
    if (!s.hasClientId) {
      return h('div', { class: 'card' }, h('h2', { style: 'margin-top:0' }, 'Spotify Remote isn’t set up yet'), ...this.account(s));
    }
    if (!s.signedIn) {
      return h('div', { class: 'card' }, h('h2', { style: 'margin-top:0' }, 'Not signed in to Spotify'), ...this.account(s));
    }
    const p = s.player;
    if (!p && !s.nothing) {
      return h('div', { class: 'card' }, h('p', { class: 'muted' }, s.why || 'Reading Spotify…'),
        h('button', { class: 'btn', onclick: () => page.act('refresh', {}) }, 'Try again'));
    }
    const q = App.obj(p);
    const off = !p;
    const bar = h('input', { type: 'range', min: 0, max: Math.max(1, q.duration || 1), value: q.progress || 0, style: 'width:100%',
      disabled: off || !q.duration ? '' : null });
    bar.addEventListener('change', () => page.act('seek', { ms: Number(bar.value) }));
    const volume = h('input', { type: 'range', min: 0, max: 100, value: q.volume == null ? 0 : q.volume, style: 'flex:1;min-width:120px',
      disabled: off || !q.canVolume ? '' : null });
    volume.addEventListener('change', () => page.act('volume', { percent: Number(volume.value) }));
    const next = { off: 'context', context: 'track', track: 'off' };
    const button = (text, name, args, opts = {}) => h('button', { class: 'btn' + (opts.primary ? ' primary' : ''),
      style: opts.on ? 'border-width:2px;border-color:var(--text);font-weight:600' : null,
      disabled: opts.disabled ? '' : null, onclick: () => page.act(name, args) }, text);
    return h('div', { class: 'card' },
      h('div', { class: 'row', style: 'gap:16px;align-items:flex-start;flex-wrap:nowrap' },
        q.picture ? h('img', { src: q.picture, alt: '', style: 'width:120px;height:120px;border-radius:8px;object-fit:cover' }) : null,
        h('div', { style: 'flex:1;min-width:0' },
          h('h2', { style: 'margin:0' }, off ? 'Nothing playing' : (q.title || 'Nothing playing')),
          q.artist ? h('div', {}, q.artist) : null,
          q.album ? h('div', { class: 'muted small' }, q.album) : null,
          h('div', { style: 'margin-top:10px' }, bar),
          h('div', { class: 'spread small muted' },
            h('span', {}, off ? '' : ((q.playing ? '' : 'Paused · ') + (q.progressText || ''))), h('span', {}, off ? '' : (q.durationText || ''))))),
      h('div', { class: 'row', style: 'gap:8px;margin-top:12px' },
        button('Shuffle', 'shuffle', { on: !q.shuffle }, { on: q.shuffle, disabled: off }),
        button('Previous', 'previous', {}, { disabled: off }),
        button(q.playing ? 'Pause' : 'Play', 'toggle', {}, { primary: true }),
        button('Next', 'next', {}, { disabled: off }),
        button(q.repeatName || 'Repeat off', 'repeat', { mode: next[q.repeat] || 'context' }, { on: q.repeat && q.repeat !== 'off', disabled: off })),
      h('div', { class: 'row', style: 'gap:10px;margin-top:12px' }, h('span', { class: 'small muted' }, 'Volume'), volume,
        h('span', { class: 'small muted' }, q.volume == null || !q.canVolume ? '' : q.volume + '%')),
      // The song's own buttons: Like, Add to playlist (your own playlists), its album and artist.
      off || !q.uri ? null : h('div', { class: 'row', style: 'gap:8px;margin-top:12px' },
        q.canLike ? h('button', { class: 'btn', style: q.liked ? 'border-width:2px;border-color:var(--text);font-weight:600' : null,
          onclick: () => page.act('like', { uri: q.uri, on: !q.liked }, q.liked ? 'Removed from Liked Songs' : 'Added to Liked Songs') }, q.liked ? 'Liked' : 'Like') : null,
        q.canLike ? page.addTo(s, q.uri) : null,
        q.albumUri ? h('button', { class: 'btn', onclick: () => page.act('open', { kind: 'album', uri: q.albumUri, name: q.album }) }, 'Open album') : null,
        q.artistUri ? h('button', { class: 'btn', onclick: () => page.act('open', { kind: 'artist', uri: q.artistUri, name: q.artistName }) }, 'Open artist') : null,
        q.canRemove ? h('button', { class: 'btn', onclick: () => {
          page.act('removefrom', { playlist: q.context, uri: q.uri });
          App.undo(q.title + ' removed', () => page.act('addto', { playlist: q.context, uri: q.uri }));
        } }, 'Remove from this playlist') : null),
      s.signInAgain ? h('p', { class: 'small' }, 'Sign in again for Like, Library and adding to playlists: ',
        h('button', { class: 'btn small', onclick: () => page.signIn() }, 'Sign in')) : null,
      h('p', { class: 'small muted' }, [q.device ? 'Playing on ' + q.device : null, s.read ? 'Read ' + App.ago(s.read) : null, s.why].filter(Boolean).join(' · ')));
  },

  devices(s) {
    if (!s.configured) return null;
    const page = this;
    return h('div', { class: 'card' },
      h('div', { class: 'spread' }, h('h2', { style: 'margin:0' }, 'Devices'),
        h('button', { class: 'btn small', onclick: () => page.act('refresh', {}) }, 'Refresh')),
      s.devicesRead && !s.devices.length ? h('p', { class: 'muted' }, 'No Spotify device is on. Open Spotify on a phone, computer or speaker.') : null,
      ...s.devices.map((d) => this.row(h('span', { class: d.usable ? null : 'muted' }, d.name), d.line,
        d.active ? h('span', { class: 'pill ok' }, 'Active') : null,
        !d.usable ? h('span', { class: 'pill' }, 'Unavailable') : null,
        d.usable && !d.active ? h('button', { class: 'btn small', onclick: () => page.act('transfer', { device: d.id }, (App.obj(s.player).playing ? 'Playing on ' : 'Play starts on ') + d.name) },
          App.obj(s.player).playing ? 'Play here' : 'Use this') : null)),
      // Devices used before that Spotify doesn't list now (it lists one only while it's connected).
      ...(App.arr(s.seen).length ? [h('h3', {}, 'Seen before'),
        h('p', { class: 'small muted' }, 'Not on right now. Try sends the music there anyway.'),
        ...App.arr(s.seen).map((d) => this.row(d.name, d.line,
          h('button', { class: 'btn small', onclick: () => page.act('forget', { device: d.id }, d.name + ' forgotten') }, 'Forget'),
          h('button', { class: 'btn small', onclick: () => page.act('transfer', { device: d.id }, 'Trying ' + d.name + '…') }, 'Try')))] : []));
  },

  // Sign in (again): Spotify's page in a new tab; the box for the address it ends on is under the Client ID.
  async signIn() {
    try {
      const r = await App.api('/api/spotify/act', { json: { name: 'signin', args: {} } });
      window.open(r.url, '_blank', 'noopener');
      setTimeout(() => this.reload(), 500);
    } catch (e) { App.fail(e); }
  },

  // "Add to playlist": one of your own playlists picked from a list.
  addTo(s, uri) {
    const own = App.arr(s.own);
    if (!own.length) return null;
    const pick = h('select', {}, h('option', { value: '' }, 'Add to playlist'), ...own.map((p) => h('option', { value: p.uri }, p.name)));
    pick.addEventListener('change', () => {
      const pl = own.find((p) => p.uri === pick.value);
      if (!pl) return;
      this.act('addto', { playlist: pl.uri, uri });
      App.undo('Added to ' + pl.name, () => this.act('removefrom', { playlist: pl.uri, uri }));
    });
    return pick;
  },

  // An album's songs or an artist's albums, opened from a song, the library or a search.
  opened(s) {
    const o = s.opened;
    if (!o) return null;
    const page = this;
    const items = App.arr(o.items);
    return h('div', { class: 'card' },
      h('div', { class: 'spread' }, h('h2', { style: 'margin:0' }, o.name || (o.kind === 'album' ? 'Album' : 'Artist')),
        h('div', { class: 'row', style: 'gap:8px' },
          h('button', { class: 'btn primary small', onclick: () => page.act('play', { context: o.uri }, 'Playing ' + (o.name || '')) }, 'Play'),
          h('button', { class: 'btn small', onclick: () => page.act('close', {}) }, 'Close'))),
      o.why ? h('p', { class: 'muted' }, o.why) : null,
      !o.items && !o.why ? h('p', { class: 'muted' }, 'Reading…') : null,
      ...items.map((x, i) => (o.kind === 'playlist' ? this.row(x.title, x.artist,
        ...[['Top', 1], ['Up', i], ['Down', i + 2], ['Bottom', items.length]].map(([text, to]) =>
          h('button', { class: 'btn small', disabled: to < 1 || to > items.length || to === i + 1 ? '' : null,
            onclick: () => page.act('move', { playlist: o.uri, from: i + 1, to }) }, text)),
        h('button', { class: 'btn small', onclick: () => this.act('play', { context: o.uri, track: x.uri }, 'Playing ' + x.title) }, 'Play'))
        : o.kind === 'album' ? this.song(x)
        : this.row(x.name, x.sub, h('button', { class: 'btn small', onclick: () => page.act('open', { kind: 'album', uri: x.uri, name: x.name }) }, 'Open'),
          h('button', { class: 'btn small', onclick: () => page.act('play', { context: x.uri }, 'Playing ' + x.name) }, 'Play')))));
  },

  // The queue, and the library (Liked Songs, saved albums, followed artists): each read when asked for.
  more(s) {
    if (!s.configured) return null;
    const page = this;
    const q = s.queue;
    const lib = s.library;
    const load = (kind) => page.act('list', { kind, force: true });
    const context = (kind) => (x) => this.row(x.name, x.sub,
      h('button', { class: 'btn small', onclick: () => page.act('open', { kind, uri: x.uri, name: x.name }) }, 'Open'),
      h('button', { class: 'btn small', onclick: () => page.act('play', { context: x.uri }, 'Playing ' + x.name) }, 'Play'));
    return h('div', { class: 'card' },
      h('div', { class: 'spread' }, h('h2', { style: 'margin:0' }, 'Queue'),
        h('button', { class: 'btn small', onclick: () => load('queue') }, q ? 'Refresh' : 'Show')),
      q && !App.arr(q.next).length ? h('p', { class: 'muted' }, 'Nothing comes next.') : null,
      ...App.arr(q && q.next).slice(0, 20).map((x) => this.row(x.title, x.artist)),
      h('div', { class: 'spread', style: 'margin-top:16px' }, h('h2', { style: 'margin:0' }, 'Library'),
        h('button', { class: 'btn small', onclick: () => { load('library'); page.quiet('list', { kind: 'liked' }); } }, lib ? 'Refresh' : 'Show')),
      ...(lib ? [
        s.liked ? this.row('Liked Songs', null, h('button', { class: 'btn small', onclick: () => page.act('play', { context: s.liked }, 'Playing Liked Songs') }, 'Play')) : null,
        App.arr(lib.albums).length ? h('h3', {}, 'Albums') : null, ...App.arr(lib.albums).map(context('album')),
        App.arr(lib.artists).length ? h('h3', {}, 'Artists') : null, ...App.arr(lib.artists).map(context('artist')),
      ] : []));
  },

  song(x) {
    return this.row(x.title, x.artist,
      h('button', { class: 'btn small', onclick: () => this.act('queue', { uri: x.uri }, 'Added to the queue') }, 'Add to queue'),
      h('button', { class: 'btn small', onclick: () => this.act('play', { context: x.context, track: x.uri }, 'Playing ' + x.title) }, 'Play'));
  },

  start(s) {
    if (!s.configured) return null;
    const page = this;
    const S = s.search;
    const r = App.obj(S.results);
    const box = h('input', { type: 'text', value: S.q || '', placeholder: 'A song, album, playlist or artist' });
    const run = () => page.act('search', { q: box.value.trim() });
    box.addEventListener('keydown', (e) => { if (e.key === 'Enter') run(); });
    const context = (x) => this.row(x.name, x.sub || x.line,
      h('button', { class: 'btn small', onclick: () => page.act('play', { context: x.uri }, 'Playing ' + x.name) }, 'Play'));
    const opens = (kind) => (x) => this.row(x.name, x.sub,
      h('button', { class: 'btn small', onclick: () => page.act('open', { kind, uri: x.uri, name: x.name }) }, 'Open'),
      h('button', { class: 'btn small', onclick: () => page.act('play', { context: x.uri }, 'Playing ' + x.name) }, 'Play'));
    // (your own playlists open too: their songs, to move)
    const mine = (x) => this.row(x.name, x.sub || x.line,
      App.arr(s.own).some((p) => p.uri === x.uri) ? h('button', { class: 'btn small', onclick: () => page.act('open', { kind: 'playlist', uri: x.uri, name: x.name }) }, 'Open') : null,
      h('button', { class: 'btn small', onclick: () => page.act('play', { context: x.uri }, 'Playing ' + x.name) }, 'Play'));
    const part = (title, list, draw) => (App.arr(list).length ? [h('h3', {}, title), ...App.arr(list).map(draw)] : []);
    return h('div', { class: 'card' }, h('h2', {}, 'Play'),
      h('div', { class: 'row', style: 'gap:8px;margin-bottom:10px' }, box,
        h('button', { class: 'btn', onclick: run }, 'Search'),
        s.dj ? h('button', { class: 'btn', onclick: () => page.act('play', { context: s.dj }, 'Starting DJ') }, 'DJ') : null,
        S.q ? h('button', { class: 'btn', onclick: () => page.act('search', { q: '' }) }, 'Clear') : null),
      S.reading ? h('p', { class: 'muted' }, 'Searching…') : null,
      S.why ? h('p', { class: 'muted' }, S.why) : null,
      S.results && !r.count ? h('p', { class: 'muted' }, 'Nothing found for “' + S.q + '”.') : null,
      ...part('Songs', r.tracks, (x) => this.song(x)),
      ...part('Albums', r.albums, opens('album')),
      ...part('Playlists', r.playlists, context),
      ...part('Artists', r.artists, opens('artist')),
      h('h3', {}, 'Your playlists'),
      s.playlistsRead && !s.playlists.length ? h('p', { class: 'muted' }, 'No playlists yet.') : null,
      ...s.playlists.map(mine),
      h('h3', {}, 'Recent'),
      s.recentRead && !s.recent.length ? h('p', { class: 'muted' }, 'Nothing played lately.') : null,
      ...s.recent.slice(0, 15).map((x) => this.song(x)));
  },

  settings(s) {
    const page = this;
    const save = (args, done) => App.api('/api/spotify/act', { json: { name: 'settings', args } })
      .then(() => { App.toast(done || 'Saved'); setTimeout(() => page.reload(), 1200); }).catch(App.fail);
    return h('div', { class: 'card' }, h('h2', {}, 'Settings'),
      App.setting('Album art', App.toggle(!!s.art, (v) => save({ art: v }))),
      App.setting('Read every', App.select([[5, '5 seconds'], [10, '10 seconds'], [15, '15 seconds'], [30, '30 seconds'], [60, '1 minute']],
        s.interval || 10, (v) => save({ interval: Number(v) })), 'While Spotify Remote is open.'),
      App.setting('Full screen: read every', App.select([[0, 'Same as the app'], [5, '5 seconds'], [10, '10 seconds'], [15, '15 seconds'], [30, '30 seconds'], [60, '1 minute']],
        s.playerInterval || 0, (v) => save({ playerInterval: Number(v) }))),
      h('h3', {}, 'Buttons'),
      ...App.arr(s.buttons).map((b) => App.setting(b.name, App.select(App.arr(s.actions).map((a) => [a.id, a.name]), b.action,
        (v) => save({ button: b.key, action: v })))),
      App.setting('Stay on the list after Play', App.toggle(!!s.stay, (v) => save({ stay: v }))),
      h('h3', {}, 'Playback'),
      App.setting('Volume step', App.select([[2, '2%'], [5, '5%'], [10, '10%']], s.volumeStep || 5, (v) => save({ volumeStep: Number(v) }))),
      // (until it's signed in, the account is in the first card)
      ...(s.configured ? [h('h3', {}, 'Account'), ...this.account(s)] : []));
  },

  // The requirements and Spotify's limits (the Kindle's own words: spmodel.needs), open until it's set up.
  needs(s) {
    const n = App.obj(s.needs);
    const list = (items) => h('ul', { style: 'margin:6px 0 10px;padding-left:20px' }, ...App.arr(items).map((x) => h('li', {}, x)));
    return h('details', { open: s.configured ? null : '', style: 'margin:8px 0 12px' },
      h('summary', { style: 'cursor:pointer;font-weight:600' }, 'Requirements'),
      list(n.needs),
      h('div', { class: 'small muted', style: 'font-weight:600' }, 'Limits'),
      h('div', { class: 'small muted' }, list(n.limits)));
  },

  // The box for the address the sign-in ends on.
  finish() {
    const page = this;
    const address = h('input', { type: 'text', value: '', placeholder: 'http://127.0.0.1:8888/callback?code=…', style: 'flex:1;min-width:220px' });
    const go = () => { if (address.value.trim()) page.act('finish', { address: address.value.trim() }, 'Signing in…'); };
    address.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
    return h('div', { style: 'margin-top:12px' },
      h('p', { class: 'small muted' }, 'After you agree, the browser shows an error for an address that starts with http://127.0.0.1:8888. That’s expected. Copy that whole address and paste it here.'),
      h('div', { class: 'row', style: 'gap:8px' }, address, h('button', { class: 'btn primary', onclick: go }, 'Finish')));
  },

  // Signing in again while signed in (for new permissions): the box first on the page, not down in Settings.
  again(s) {
    if (!(s.signingIn && s.signedIn)) return null;
    return h('div', { class: 'card' }, h('h2', { style: 'margin-top:0' }, 'Finish signing in'), this.finish(s));
  },

  // The Client ID, Sign in or Sign out, and the box for the address the sign-in ends on.
  account(s) {
    const page = this;
    const save = (args, done) => App.api('/api/spotify/act', { json: { name: 'settings', args } })
      .then(() => { App.toast(done || 'Saved'); setTimeout(() => page.reload(), 1200); }).catch(App.fail);
    const id = h('input', { type: 'text', value: '', style: 'flex:1;min-width:260px',
      placeholder: s.hasClientId ? 'Saved (' + s.clientIdHint + '): type to change' : 'Your app’s Client ID' });
    id.addEventListener('keydown', (e) => { if (e.key === 'Enter' && id.value.trim()) save({ clientId: id.value.trim() }); });
    const signIn = async () => {
      try {
        const r = await App.api('/api/spotify/act', { json: { name: 'signin', args: {} } });
        window.open(r.url, '_blank', 'noopener');
        setTimeout(() => page.reload(), 500);
      } catch (e) { App.fail(e); }
    };
    const ready = s.hasClientId && !s.signedIn;
    return [
      this.needs(s),
      h('div', { style: 'margin-top:8px' }, 'Client ID'),
      h('div', { class: 'small muted' }, 'From your app in ',
        App.link('Spotify’s developer dashboard', 'https://developer.spotify.com/dashboard'),
        '. Give the app the redirect URI ' + s.redirect + ' and tick Web API.'),
      h('div', { class: 'row', style: 'gap:8px;margin-top:8px' }, id,
        h('button', { class: 'btn' + (ready ? '' : ' primary'), onclick: () => { if (id.value.trim()) save({ clientId: id.value.trim() }); } }, 'Save'),
        ready ? h('button', { class: 'btn' + (s.signingIn ? '' : ' primary'), onclick: signIn }, 'Sign in') : null,
        s.signedIn ? h('button', { class: 'btn', onclick: () => page.act('signout', {}, 'Signed out') }, 'Sign out') : null,
        s.configured ? App.connectionTest('spotify') : null),
      s.signingIn && !s.signedIn ? this.finish(s) : null,
    ];
  },
};
