// AI: the AI services every app uses (Notes, Crosswords, SSH): which one does each job, each
// service's key, model or addresses, Try a prompt, Test connection, and Advanced (each feature's
// instructions, how much is sent, a preview). The work is the launcher's appsai.lua (webai.lua has
// the routes); the Kindle's Settings > AI uses the same code.
App.pages.ai = {
  async render(main) {
    main.append(h('h1', {}, 'AI'),
      h('p', { class: 'sub' }, 'The AI services the apps use, as in the Kindle’s Settings > AI. Keys are stored only on the Kindle.'));
    const s = await App.api('/api/ai');
    if (!s.installed) { main.append(h('div', { class: 'empty' }, 'The AI settings need the launcher plugin (apps.koplugin).')); return; }
    const st = App.obj(s.settings);
    const set = (key) => (value) => App.api('/api/ai/settings', { json: { [key]: value } })
      .then(() => { st[key] = value; return true; }, (e) => { App.fail(e); return false; });
    const saveKey = (service, key) => App.api('/api/ai/key', { json: { service, key } }).then(() => { App.toast('Saved'); App.route(); }, App.fail);
    const clearKey = (service) => App.api('/api/ai/key', { json: { service, clear: true } }).then(App.route, App.fail);
    const providers = App.arr(s.providers);
    const names = {};
    for (const p of providers) names[p.id] = p.id === 'server' ? 'Local AI' : p.name;

    // Which AI does each job (the apps' jobs: Notes', SSH's).
    const jobs = App.arr(s.jobs);
    if (jobs.length) {
      main.append(h('div', { class: 'card' }, h('h2', {}, 'Which AI does each job'),
        ...jobs.map((j) => App.setting(j.name, App.select(App.arr(j.services).map((id) => [id, names[id] || id]), j.service, (v) =>
          App.api('/api/ai/settings', { json: { jobs: { [j.key]: v } } }).then(() => App.toast('Saved'), App.fail)))),
        // Each AI service set up tried, from the Kindle.
        s.any && App.connectionTest ? App.connectionTest('ai') : null));
    } else if (s.any && App.connectionTest) {
      main.append(h('div', { class: 'card' }, h('h2', {}, 'Test connection'), App.connectionTest('ai')));
    }

    // Load models: the service's models now (asked by the Kindle with your key), into the box's list.
    const latest = (id, list, input) => h('button', { class: 'btn', onclick: async (e) => {
      const btn = e.currentTarget;
      btn.disabled = true;
      const r = await App.api('/api/ai/models?id=' + encodeURIComponent(id)).catch((err) => ({ error: String(err) }));
      btn.disabled = false;
      const got = App.arr(r.models);
      if (!got.length) return App.toast('Couldn’t load the models' + (r.error ? ': ' + r.error : ''), true);
      list.replaceChildren(...got.map((m) => h('option', { value: m.id, label: m.name || m.id })));
      App.toast(got.length + ' models: pick one in the box');
      input.focus();
    } }, 'Load models');

    // A model box shows its whole list while you're in it: the saved model goes grey (as the
    // hint) and comes back if you leave without picking another. (A browser's list only
    // shows the entries that match what's in the box.)
    const fullList = (input) => {
      input.addEventListener('focus', () => {
        input.dataset.was = input.value;
        if (input.value) { input.placeholder = input.value; input.value = ''; }
      });
      input.addEventListener('blur', () => { if (!input.value.trim()) input.value = input.dataset.was || ''; });
      return input;
    };

    // What's left with Claude, Groq (their last answer) and OpenRouter (asked now).
    const usage = (id) => {
      const out = h('div', { class: 'muted small' });
      const when = (t) => new Date(t * 1000).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
      const usd = (n) => (n == null ? '?' : '$' + Number(n).toFixed(2));
      const show = async () => {
        out.textContent = 'Checking…';
        const r = await App.api('/api/ai/usage?id=' + id).catch((e) => ({ error: String(e) }));
        const lines = [];
        if (r.openrouter) {
          const u = r.openrouter;
          if (u.daily != null) lines.push('Used today: ' + usd(u.daily));
          if (u.monthly != null) lines.push('Used this month: ' + usd(u.monthly));
          if (u.limit != null) lines.push('This key’s limit: ' + usd(u.remaining) + ' left of ' + usd(u.limit) + (u.reset ? ', resets ' + u.reset : ''));
          if (u.credits != null && u.spent != null) lines.push('Credit left: ' + usd(u.credits - u.spent));
          if (u.free) lines.push('Free tier: free models have a daily request limit.');
        } else if (r.limits) {
          const names = { requests: 'Requests', tokens: 'Tokens', input: 'Input tokens', output: 'Output tokens' };
          for (const part of ['requests', 'tokens', 'input', 'output']) {
            const x = r.limits[part];
            if (!x || x.remaining == null) continue;
            let line = names[part] + ': ' + x.remaining + (x.limit != null ? ' of ' + x.limit : '') + ' left';
            if (x.reset) line += x.reset <= r.now ? ', reset since' : ', resets ' + (x.reset - r.now < 3600 ? 'in ' + Math.max(1, Math.round((x.reset - r.now) / 60)) + ' min' : 'at ' + when(x.reset));
            lines.push(line);
          }
          if (lines.length) lines.unshift('As of ' + when(r.limits.at) + ':');
        }
        out.replaceChildren(...(lines.length ? lines : [r.error ? 'Couldn’t check: ' + r.error : 'Shows after the next answer from this service (Try a prompt, or any AI feature).'])
          .map((l) => h('div', {}, l)));
      };
      return App.setting('Usage', h('div', { class: 'row' }, out, h('button', { class: 'btn', onclick: show }, 'Check')));
    };

    // Claude.
    const key = h('input', { type: 'password', placeholder: s.claude.keySet ? 'A key is set (type a new one to replace it)' : 'sk-ant-…', style: 'flex:1;min-width:260px' });
    const models = App.arr(s.claude.models);
    main.append(h('div', { class: 'card stack' },
      h('h2', {}, 'Claude'),
      h('p', { class: 'muted small' }, 'An API key from ', App.link('platform.claude.com', 'https://platform.claude.com'), ' (Max and Team plans include monthly API credits: ',
        App.link('claude.ai > Settings > Billing', 'https://claude.ai/settings/billing'), ').'),
      h('div', { class: 'row' }, key,
        h('button', { class: 'btn primary', onclick: () => { if (key.value.trim()) saveKey('claude', key.value); } }, 'Save'),
        s.claude.keySet ? h('button', { class: 'btn danger', onclick: () => clearKey('claude') }, 'Remove the key') : null),
      (() => {
        // The model: one of these, any other typed, or one loaded from Claude.
        const list = h('datalist', { id: 'models-claude' }, ...models.map(([v, label]) => h('option', { value: v, label })));
        const input = fullList(h('input', { type: 'text', value: s.claude.model || '', list: 'models-claude', style: 'flex:1;min-width:240px' }));
        input.addEventListener('change', () => input.value.trim() && set('claude_model')(input.value.trim()).then((ok) => { if (ok) App.toast('Saved'); }));
        return h('label', { class: 'field' }, h('span', {}, 'Model'), h('div', { class: 'row' }, input, s.claude.keySet ? latest('claude', list, input) : null), list);
      })(),
      s.claude.keySet ? usage('claude') : null,
      s.claude.keySet ? this.tryPrompt('claude', s.sample) : null));

    // Your local AI.
    const text = (k, placeholder) => {
      const input = h('input', { type: 'text', value: st[k] || '', placeholder, style: 'flex:1;min-width:240px' });
      input.addEventListener('change', () => set(k)(input.value.trim()).then((ok) => { if (ok) App.toast('Saved'); }));
      return input;
    };
    const serverKey = h('input', { type: 'password', placeholder: s.serverKeySet ? 'A key is set (type a new one to replace it)' : 'API key', style: 'flex:1;min-width:240px' });
    main.append(h('div', { class: 'card stack' },
      h('h2', {}, 'Local AI'),
      h('p', { class: 'muted small' }, 'Your own AI, speaking the OpenAI-style API. The Internal URL is used when the Kindle can reach it on the home network; the External URL from anywhere else. The model must read pictures.'),
      h('label', { class: 'field' }, h('span', {}, 'Internal URL (your AI on the home network)'), text('server_home', 'http://192.168.1.50:11434')),
      h('label', { class: 'field' }, h('span', {}, 'External URL (reachable from anywhere)'), text('server_pangolin', 'https://ai.example.com/v1')),
      h('label', { class: 'field' }, h('span', {}, 'API key (optional, sent as a Bearer token with the External URL)'),
        h('div', { class: 'row' }, serverKey,
          h('button', { class: 'btn', onclick: () => { if (serverKey.value.trim()) saveKey('server', serverKey.value); } }, 'Save'),
          s.serverKeySet ? h('button', { class: 'btn danger', onclick: () => clearKey('server') }, 'Remove') : null)),
      h('label', { class: 'field' }, h('span', {}, 'Model'), text('server_model', 'gemma4')),
      App.setting('Thinking', App.toggle(st.server_think, set('server_think')), 'Slower, sometimes better.'),
      (st.server_home || st.server_pangolin) ? this.tryPrompt('server', s.sample) : null));

    // Gemini, OpenRouter, Groq and Custom: each its own key and model.
    for (const p of providers.filter((x) => x.id !== 'claude' && x.id !== 'server')) {
      const pkey = h('input', { type: 'password', placeholder: p.keySet ? 'A key is set (type a new one to replace it)' : 'API key', style: 'flex:1;min-width:240px' });
      const listId = 'models-' + p.id;
      const model = fullList(h('input', { type: 'text', value: p.model || '', placeholder: App.arr(p.models)[0] || 'model name', list: listId, style: 'flex:1;min-width:240px' }));
      model.addEventListener('change', () => model.value.trim() && set(p.id + '_model')(model.value.trim()).then((ok) => { if (ok) App.toast('Saved'); }));
      main.append(h('div', { class: 'card stack' },
        h('h2', {}, p.name),
        p.keyFrom ? h('p', { class: 'muted small' }, 'A key from ', App.link(p.keyFrom, 'https://' + p.keyFrom), (p.free ? ' (it has a free tier).' : '.')) : null,
        p.free ? h('p', { class: 'muted small' }, 'On a free tier the service may use what you send to improve its products: keep private pages on Claude or your local AI.') : null,
        p.id === 'custom' ? h('label', { class: 'field' }, h('span', {}, 'Address (OpenAI-compatible)'), text('custom_url', 'https://ai.example.com/v1')) : null,
        h('label', { class: 'field' }, h('span', {}, p.id === 'custom' ? 'API key (optional)' : 'API key'),
          h('div', { class: 'row' }, pkey,
            h('button', { class: 'btn', onclick: () => { if (pkey.value.trim()) saveKey(p.id, pkey.value); } }, 'Save'),
            p.keySet ? h('button', { class: 'btn danger', onclick: () => clearKey(p.id) }, 'Remove') : null)),
        (() => {
          const list = h('datalist', { id: listId }, ...App.arr(p.models).map((m) => h('option', { value: m })));
          return h('label', { class: 'field' }, h('span', {}, 'Model (one that reads pictures)'),
            h('div', { class: 'row' }, model, (p.keySet || p.id === 'openrouter') ? latest(p.id, list, model) : null), list);
        })(),
        (p.keySet && (p.id === 'openrouter' || p.id === 'groq')) ? usage(p.id) : null,
        p.ready ? this.tryPrompt(p.id, s.sample) : null));
    }

    main.append(this.advanced());
  },

  // Try a prompt: the Kindle sends its sample handwriting to this service and
  // shows the reply, how long it took and which model answered.
  tryPrompt(id, sample) {
    const out = h('div', { class: 'stack' });
    const btn = h('button', { class: 'btn', onclick: async () => {
      btn.disabled = true;
      out.replaceChildren(h('div', { class: 'muted small' }, 'Sending the sample handwriting… (a real request: a little cost on paid services)'));
      const r = await App.api('/api/ai/try', { json: { provider: id } }).catch(App.fail);
      if (!r) { btn.disabled = false; out.replaceChildren(); return; }
      const ask = async () => {
        const s = await App.api('/api/ai/try?key=' + encodeURIComponent(r.key)).catch(() => null);
        if (!s || s.status !== 'done') return setTimeout(ask, 1500);
        btn.disabled = false;
        const x = s.result || {};
        out.replaceChildren(x.ok
          ? h('div', { class: 'stack' }, h('div', { class: 'small' }, h('b', {}, x.name + ' answered in ' + x.secs + ' s'), ' · model ' + (x.model || '?')),
              h('pre', { class: 'small', style: 'white-space:pre-wrap;margin:0' }, x.text || '(Nothing read.)'),
              sample ? h('div', { class: 'muted small' }, 'The sample says: “' + sample + '”.') : null)
          : h('div', { class: 'small' }, h('b', {}, (x.name || 'It') + ' did not answer: '), String(x.why || '')));
      };
      ask();
    } }, 'Try a prompt');
    return h('div', { class: 'stack' }, h('div', { class: 'row' }, btn,
      h('span', { class: 'muted small' }, 'Reads a short handwriting sample: shows whether the model reads pictures, how well and how fast.')), out);
  },

  // Advanced: each feature's instructions (yours or the default), how much
  // is sent, and what's sent.
  advanced() {
    const card = h('div', { class: 'card stack' }, h('h2', {}, 'Advanced'),
      h('p', { class: 'muted small' }, 'For each AI feature: how it should do it (your wording; the form of the answer each feature needs is added after it and can’t be changed), how much goes with it, and exactly what leaves the Kindle.'));
    const body = h('div', { class: 'stack' });
    card.append(body);
    const draw = async () => {
      const r = await App.api('/api/ai/advanced').catch(() => null);
      if (!r) return;
      const features = App.arr(r.features);
      if (!features.length) { body.replaceChildren(h('div', { class: 'muted small' }, 'No app with AI features is installed.')); return; }
      body.replaceChildren(...features.map((f) => {
        const area = h('textarea', { rows: 5, style: 'width:100%' });
        area.value = f.words || '';
        const save = (json) => App.api('/api/ai/advanced', { json: Object.assign({ key: f.key }, json) })
          .then(() => { App.toast('Saved'); draw(); }, App.fail);
        const preview = h('div', { class: 'stack' });
        return h('div', { class: 'stack', style: 'border-top:1px solid var(--line);padding-top:10px' },
          h('div', {}, h('b', {}, f.name), f.edited ? h('span', { class: 'muted small' }, ' · edited') : null),
          area,
          h('div', { class: 'row' },
            h('button', { class: 'btn', onclick: () => save({ words: area.value }) }, 'Save'),
            f.edited ? h('button', { class: 'btn', onclick: () => save({ reset: true }) }, 'Reset to default') : null,
            h('button', { class: 'btn', onclick: async () => {
              const p = await App.api('/api/ai/preview?key=' + encodeURIComponent(f.key)).catch(App.fail);
              if (!p) return;
              preview.replaceChildren(
                p.note ? h('div', { class: 'muted small' }, p.note) : null,
                h('div', { class: 'row', style: 'gap:8px;flex-wrap:wrap' }, App.arr(p.images).map((src) => h('img', { src, style: 'max-height:160px;border:1px solid var(--line);border-radius:6px;background:#fff' }))),
                h('pre', { class: 'small', style: 'white-space:pre-wrap;margin:0' }, p.text));
            } }, 'Preview what’s sent')),
          f.amounts ? App.setting('How much is sent', App.select(App.arr(f.amounts), f.amount, (v) => save({ amount: v }))) : null,
          preview);
      }));
    };
    draw();
    return card;
  },
};
