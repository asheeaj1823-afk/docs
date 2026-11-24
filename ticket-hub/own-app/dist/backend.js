/* Ziar Imaar Hub — own-hosted backend.
   Gives the hub the same runtime it has on claude.ai (window.claude.use('db' | 'user' | 'assets' | 'downloads')),
   but backed by your own Supabase project: email + password sign-in, row-level security in the database,
   live updates over Supabase Realtime. The hub's own code is unchanged. */
(function(){
'use strict';
const CFG = window.HUB_CONFIG || {};
const sb = window.supabase.createClient(CFG.url, CFG.key, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
window.hubSupabase = sb;

const TABLE = { visits: 'tickets', parts: 'parts', stock: 'stock' };     // collections with their own table
const PROFILE_COLS = ['roles', 'requests'];                               // derived from public.profiles
const BUCKET = 'evidence';
const clone = o => (o == null ? o : JSON.parse(JSON.stringify(o)));

let session = null, profile = null;
const cache = {};      // col -> Map(id -> data)
const loading = {};    // col -> Promise
const subs = {};       // col -> Set(callbacks)
let profiles = new Map();

function err(code, message){ const e = new Error(message || code); e.code = code; return e; }
function wrap(e){
  if (!e) return err('failed');
  if (e.code && /^(PGRST301|42501)$/.test(e.code)) return err('permission_denied', e.message);
  if (e.status === 401 || e.status === 403) return err('permission_denied', e.message);
  if (e instanceof TypeError || /fetch|network/i.test(e.message || '')) return err('network', e.message);
  return err(e.code === '23514' ? 'invalid' : 'failed', e.message);
}
async function q(promise){ let r; try { r = await promise; } catch (e) { throw wrap(e); } if (r.error) throw wrap(r.error); return r.data; }

/* ---------- profiles → roles / requests ---------- */
const appRole = r => (r === 'finance' ? 'admin' : r);
function profileDocs(col){
  const m = new Map();
  profiles.forEach(p => {
    if (col === 'roles' && p.active) m.set(p.id, { role: appRole(p.role), name: p.full_name || '', email: p.email || '', phone: p.phone || '', at: p.updated_at });
    if (col === 'requests' && !p.active && !p.dismissed) m.set(p.id, { at: p.created_at, name: p.full_name || '', email: p.email || '' });
  });
  return m;
}
async function loadProfiles(){
  const rows = await q(sb.from('profiles').select('*'));
  profiles = new Map(rows.map(p => [p.id, p]));
  PROFILE_COLS.forEach(c => { cache[c] = profileDocs(c); });
}

/* ---------- loading and live updates ---------- */
async function fetchAll(col){
  const out = new Map(), step = 1000;
  for (let from = 0; ; from += step){
    let rq = TABLE[col] ? sb.from(TABLE[col]).select('id,data') : sb.from('hub_docs').select('id,data').eq('col', col);
    const rows = await q(rq.order('id').range(from, from + step - 1));
    rows.forEach(r => out.set(r.id, r.data));
    if (rows.length < step) break;
  }
  return out;
}
function load(col){
  if (!loading[col]) loading[col] = (PROFILE_COLS.includes(col) ? loadProfiles() : fetchAll(col).then(m => { cache[col] = m; }))
    .catch(e => { delete loading[col]; throw e; });
  return loading[col];
}
function snap(col){
  const m = cache[col] || new Map(), docs = [];
  m.forEach((data, id) => docs.push({ id, exists: true, data: () => clone(data) }));
  return { docs, size: docs.length, empty: !docs.length };
}
const pending = {};
function notify(col){
  clearTimeout(pending[col]);
  pending[col] = setTimeout(() => { (subs[col] || []).forEach(cb => { try { cb(snap(col)); } catch (e) { console.error(e); } }); }, 60);
}
function onChange(table, payload){
  const row = payload.new && Object.keys(payload.new).length ? payload.new : null, old = payload.old || {};
  if (table === 'profiles'){
    if (payload.eventType === 'DELETE') profiles.delete(old.id); else if (row) profiles.set(row.id, row);
    PROFILE_COLS.forEach(c => { cache[c] = profileDocs(c); notify(c); });
    if (row && session && row.id === session.user.id && (row.active !== (profile && profile.active) || row.role !== (profile && profile.role))) location.reload();
    return;
  }
  const col = table === 'hub_docs' ? (row ? row.col : old.col) : Object.keys(TABLE).find(k => TABLE[k] === table);
  if (!col || !cache[col]) return;
  if (payload.eventType === 'DELETE') cache[col].delete(old.id);
  else if (row) cache[col].set(row.id, row.data);
  notify(col);
}
let channel = null;
function live(){
  if (channel) return;
  channel = sb.channel('hub-live');
  ['tickets', 'parts', 'stock', 'hub_docs', 'profiles'].forEach(t =>
    channel.on('postgres_changes', { event: '*', schema: 'public', table: t }, p => onChange(t, p)));
  channel.subscribe(status => {
    // after a dropped connection, reload everything once so nothing is missed
    if (status === 'SUBSCRIBED' && live.wasDown){ live.wasDown = false; Object.keys(subs).forEach(c => { delete loading[c]; load(c).then(() => notify(c)).catch(() => {}); }); }
    if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') live.wasDown = true;
  });
  window.addEventListener('online', () => { Object.keys(subs).forEach(c => { delete loading[c]; load(c).then(() => notify(c)).catch(() => {}); }); });
}

/* ---------- writes ---------- */
async function writeDoc(col, id, data){
  const prev = cache[col] && cache[col].has(id) ? cache[col].get(id) : undefined;
  if (cache[col] && !PROFILE_COLS.includes(col)){ if (data === null) cache[col].delete(id); else cache[col].set(id, clone(data)); notify(col); }
  try {
    if (col === 'roles'){
      if (data === null) await q(sb.from('profiles').update({ active: false, dismissed: true }).eq('id', id));
      else {
        const role = ['admin', 'office', 'finance', 'technician', 'viewer'].includes(data.role) ? data.role : 'viewer';
        const p = profiles.get(id), keep = p && p.role === 'finance' && role === 'admin' ? 'finance' : role;
        await q(sb.from('profiles').update({ role: keep, active: true, dismissed: false, phone: data.phone || '' }).eq('id', id));
      }
      await loadProfiles(); PROFILE_COLS.forEach(notify); return;
    }
    if (col === 'requests'){
      if (data === null && id !== session.user.id) await q(sb.from('profiles').update({ dismissed: true }).eq('id', id));
      await loadProfiles(); PROFILE_COLS.forEach(notify); return;     // a request is simply a signed-up login without access
    }
    const t = TABLE[col] || 'hub_docs';
    if (data === null) await q(TABLE[col] ? sb.from(t).delete().eq('id', id) : sb.from(t).delete().eq('col', col).eq('id', id));
    else await q(sb.from(t).upsert(TABLE[col] ? { id, data } : { col, id, data }));
  } catch (e){
    if (cache[col] && e.code !== 'network'){ if (prev === undefined) cache[col].delete(id); else cache[col].set(id, prev); notify(col); }
    throw e;
  }
}
async function readDoc(col, id){
  if (cache[col]) return cache[col].has(id) ? clone(cache[col].get(id)) : null;
  if (PROFILE_COLS.includes(col)){ await load(col); return cache[col].has(id) ? clone(cache[col].get(id)) : null; }
  const rq = TABLE[col] ? sb.from(TABLE[col]).select('data').eq('id', id) : sb.from('hub_docs').select('data').eq('col', col).eq('id', id);
  const rows = await q(rq.limit(1));
  return rows.length ? rows[0].data : null;
}

const db = {
  collection(col){
    return {
      onSnapshot(cb, onErr){
        (subs[col] = subs[col] || new Set()).add(cb);
        load(col).then(() => cb(snap(col))).catch(e => { if (onErr) onErr(e); });
        return () => subs[col].delete(cb);
      },
      async get(){ await load(col); return snap(col); },
      doc(id){ return db.doc(col + '/' + id); }
    };
  },
  doc(path){
    const i = path.indexOf('/'), col = path.slice(0, i), id = path.slice(i + 1);
    return {
      id,
      async get(){ const d = await readDoc(col, id); return { id, exists: d != null, data: () => clone(d) }; },
      set: data => writeDoc(col, id, clone(data)),
      async update(patch){ const cur = (await readDoc(col, id)) || {}; return writeDoc(col, id, Object.assign(cur, clone(patch))); },
      delete: () => writeDoc(col, id, null)
    };
  }
};

/* ---------- people ---------- */
const user = {
  async me(){ const a = !!(profile && profile.active && ['admin', 'finance'].includes(profile.role)); return { id: session.user.id, name: (profile && profile.full_name) || session.user.email, email: session.user.email, isOwner: a, canEdit: a }; },
  async id(){ return session.user.id; },
  async isOwner(){ return (await user.me()).isOwner; },
  async canEdit(){ return (await user.me()).canEdit; },
  async profiles(ids){ if (!profiles.size) await loadProfiles().catch(() => {}); const o = {}; (ids || []).forEach(id => { const p = profiles.get(id); if (p) o[id] = { id, name: p.full_name || p.email || '' }; }); return o; },
  async search(text){
    if (!profiles.size) await loadProfiles().catch(() => {});
    const t = String(text || '').toLowerCase();
    return [...profiles.values()].filter(p => ((p.full_name || '') + ' ' + (p.email || '')).toLowerCase().includes(t)).slice(0, 20).map(p => ({ id: p.id, name: p.full_name || p.email }));
  }
};

/* ---------- photos and files ---------- */
const assets = {
  async upload(file){
    const safe = String(file.name || 'file').replace(/[^\w.\-]+/g, '_').slice(-80);
    const path = session.user.id + '/' + Date.now() + '-' + safe;
    await q(sb.storage.from(BUCKET).upload(path, file, { contentType: file.type || 'application/octet-stream', upsert: false }));
    const s = await q(sb.storage.from(BUCKET).createSignedUrl(path, 60 * 60 * 24 * 365 * 5));
    return { id: path, url: s.signedUrl, contentType: file.type || '' };
  }
};
const downloads = {
  async save({ filename, data, mimeType }){
    const blob = data instanceof Blob ? data : new Blob([data], { type: mimeType || 'application/octet-stream' });
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = filename || 'download';
    document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 4000);
    return { saved: true };
  }
};

window.claude = { use: n => ({ db, user, assets, downloads }[n] || null) };

/* ---------- sign-in screen ---------- */
const $ = s => document.querySelector(s);
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
function gate(mode, msg){
  let g = $('#hub-gate');
  if (!g){ g = document.createElement('div'); g.id = 'hub-gate'; document.body.appendChild(g); }
  const title = { in: 'Sign in', up: 'Create your login', forgot: 'Reset your password', reset: 'Choose a new password' }[mode];
  g.innerHTML = `<form class="hg-card" autocomplete="on" novalidate>
    <div class="hg-brand"><span class="hg-mark">ZI</span><div><b>Ziar Imaar</b><small>Ticket &amp; Finance Hub</small></div></div>
    <h1>${title}</h1>
    ${msg ? `<div class="hg-msg ${msg.ok ? 'ok' : ''}">${esc(msg.text)}</div>` : ''}
    ${mode === 'up' ? '<label>Full name<input name="name" autocomplete="name" required></label>' : ''}
    ${mode !== 'reset' ? '<label>Email<input name="email" type="email" autocomplete="username" required></label>' : ''}
    ${mode === 'in' || mode === 'up' || mode === 'reset' ? `<label>${mode === 'reset' ? 'New password' : 'Password'}<input name="password" type="password" autocomplete="${mode === 'in' ? 'current-password' : 'new-password'}" minlength="8" required></label>` : ''}
    <button class="hg-btn" type="submit">${{ in: 'Sign in', up: 'Create login', forgot: 'Send reset link', reset: 'Save password' }[mode]}</button>
    <div class="hg-links">
      ${mode === 'in' ? '<a href="#" data-m="forgot">Forgot password?</a><a href="#" data-m="up">New staff? Create a login</a>' : ''}
      ${mode === 'up' || mode === 'forgot' ? '<a href="#" data-m="in">Back to sign in</a>' : ''}
    </div>
    ${mode === 'up' ? '<p class="hg-note">After you create your login, an administrator gives you a role. Until then you will see a waiting screen.</p>' : ''}
  </form>`;
  g.querySelectorAll('[data-m]').forEach(a => a.onclick = e => { e.preventDefault(); gate(a.dataset.m); });
  const f = g.querySelector('form'); const first = f.querySelector('input'); if (first) first.focus();
  f.onsubmit = async e => {
    e.preventDefault(); const b = f.querySelector('button'); b.disabled = true; b.textContent = 'Please wait…';
    const v = n => (f.elements[n] ? f.elements[n].value.trim() : '');
    try {
      if (mode === 'in'){ const r = await sb.auth.signInWithPassword({ email: v('email'), password: f.elements.password.value }); if (r.error) throw r.error; }
      else if (mode === 'up'){
        if (f.elements.password.value.length < 8) throw new Error('Use at least 8 characters for the password.');
        const r = await sb.auth.signUp({ email: v('email'), password: f.elements.password.value, options: { data: { full_name: v('name') }, emailRedirectTo: location.origin + location.pathname } });
        if (r.error) throw r.error;
        if (!r.data.session) return gate('in', { ok: true, text: 'Check your email and click the link to confirm, then sign in.' });
      }
      else if (mode === 'forgot'){ const r = await sb.auth.resetPasswordForEmail(v('email'), { redirectTo: location.origin + location.pathname }); if (r.error) throw r.error; return gate('in', { ok: true, text: 'If that email has a login, a reset link is on its way.' }); }
      else if (mode === 'reset'){ const r = await sb.auth.updateUser({ password: f.elements.password.value }); if (r.error) throw r.error; recovering = false; return start(); }
    } catch (x){
      const m = /invalid login/i.test(x.message || '') ? 'Wrong email or password.' : /not confirmed/i.test(x.message || '') ? 'Please confirm your email first. Check your inbox.' : (x.message || 'Something went wrong. Try again.');
      gate(mode, { text: m });
    }
  };
}
let started = false, recovering = /type=recovery/.test(location.hash);
async function start(){
  if (started) return;
  const { data } = await sb.auth.getSession(); session = data.session;
  if (!session) return gate('in');
  if (recovering) return gate('reset');
  try { profile = (await q(sb.from('profiles').select('*').eq('id', session.user.id).limit(1)))[0] || null; }
  catch (e){ return gate('in', { text: 'Could not reach the hub database. Check your connection and try again.' }); }
  started = true;
  const g = $('#hub-gate'); if (g) g.remove();
  live();
  badge();
  const src = document.getElementById('hub-app'), s = document.createElement('script');
  s.textContent = src.textContent; document.body.appendChild(s);
}
function badge(){
  const b = document.createElement('div'); b.id = 'hub-me';
  b.innerHTML = `<span>${esc(session.user.email)}</span><button type="button">Sign out</button>`;
  b.querySelector('button').onclick = async () => { await sb.auth.signOut(); location.replace(location.pathname); };
  document.body.appendChild(b);
}
sb.auth.onAuthStateChange((ev, s) => {
  if (ev === 'PASSWORD_RECOVERY'){ recovering = true; session = s; gate('reset'); return; }
  if (ev === 'SIGNED_IN' && !started && !recovering){ start(); return; }
  if (ev === 'SIGNED_OUT' && started) location.replace(location.pathname);
  if (s) session = s;
});
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
