#!/usr/bin/env python3
"""Build the own-hosted hub (own-app/dist) from ticket-hub/index.html.

The hub's code is reused unchanged; this only
  * loads supabase.js + backend.js before it (they provide window.claude on top of Supabase),
  * holds the hub script back until someone has signed in,
  * swaps wording that talks about Claude accounts.
Run:  python3 own-app/build.py   (from ticket-hub/)
"""
import os, shutil, sys
here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, '..', 'index.html'), encoding='utf-8').read()
cfg = open(os.path.join(here, 'config.js'), encoding='utf-8').read()

def rep(s, a, b, n=1):
    c = s.count(a)
    if c != n: sys.exit(f'build: expected {n}x {a[:70]!r}, found {c}')
    return s.replace(a, b)

APP = '<script>\n'
i = src.index('<script defer src="https://cdnjs.cloudflare.com/ajax/libs/xlsx/')
j = src.index(APP, i)
head = """<link rel="manifest" href="manifest.webmanifest">
<meta name="theme-color" content="#0a1f4d">
<link rel="icon" href="icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="icon.svg">
<link rel="stylesheet" href="gate.css">
<script>""" + cfg.strip() + """</script>
<script src="supabase.js"></script>
<script src="backend.js"></script>
"""
out = src[:j] + head + '<script type="text/hub-app" id="hub-app">\n' + src[j + len(APP):]
out = ('<!doctype html>\n<html lang="en"><head>\n<meta charset="utf-8">\n'
       '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
       '<meta name="robots" content="noindex,nofollow">\n') + rep(out, '<meta name="claude:viewport-fit-sides" content="cover">\n', '')

out = rep(out, "Signed in to Claude</div>", "Signed in</div>")
out = rep(out, "${me.name?'Signing in as <b>'+esc(me.name)+'</b> (your Claude account). ':''}Each person signs in with their own Claude account and their own PIN. Not you? Sign in to Claude with your own account, then open this link again. New staff: ask the owner to share the hub with your Claude account and give you a role.",
          "${me.name?'Signing in as <b>'+esc(me.name)+'</b>. ':''}Each person signs in with their own email login and their own PIN. Not you? Use Sign out and sign in with your own login. New staff: create a login on the sign-in page, then an administrator gives you a role.")
out = rep(out, "esc(me.name||'your Claude account')", "esc(me.name||'your login')")
out = rep(out, "Sign in to your Claude account to request access.", "Sign in with your email login to request access.")
out = rep(out, "sent to your phone by Claude. Manage it in claude.ai → Scheduled tasks.", "Reminders now show inside the hub on the 1st and 16th.")

dist = os.path.join(here, 'dist')
os.makedirs(dist, exist_ok=True)
open(os.path.join(dist, 'index.html'), 'w', encoding='utf-8').write(out)
for f in ['backend.js', 'supabase.js', 'gate.css', 'manifest.webmanifest', 'icon.svg', '_headers', 'vercel.json']:
    p = os.path.join(here, f)
    if os.path.exists(p): shutil.copy(p, os.path.join(dist, f))
print('built', os.path.join(dist, 'index.html'), len(out), 'bytes')
