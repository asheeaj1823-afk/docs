# Ziar Imaar Hub — your own website

The same hub, on your own address, with **email + password logins**. Nobody needs a Claude account.

- **Data:** your Supabase project `ziar-imaar-ops`.
- **Security:** enforced inside the database (row-level security):
  - finance is admin-only;
  - technicians can only update their visits and send them for review;
  - every change to tickets, finance and settings is written to an audit log that cannot be edited.
- **Live updates:** changes appear on every phone and computer within a second (Supabase Realtime).

## What is in this folder

| File | What it is |
|---|---|
| `dist/` | **The website.** Upload this folder; nothing else is needed. |
| `build.py` | Rebuilds `dist/` from `../index.html` after the hub is changed. |
| `backend.js` | Sign-in screen and the link between the hub and Supabase. |
| `config.js` | Your Supabase address and public key (safe to publish; the database rules protect the data). |

## Put it online (5 minutes, free)

**Netlify (simplest)**
1. Go to app.netlify.com/drop and sign up or sign in.
2. Drag the `dist` folder onto the page. You get an address such as `https://ziar-hub.netlify.app`.
3. Optional: *Site settings → Change site name*, or *Domain management → Add a domain* to use your own domain, e.g. `hub.ziarimaar.ae`.

**Vercel (alternative)**
1. Sign in at vercel.com.
2. Choose *Add New → Project*, import this GitHub repository, set the root directory to `ticket-hub/own-app/dist`, then deploy.

## Supabase settings (once, in the Supabase dashboard)

1. **Authentication → URL Configuration → Site URL:** your new address, e.g. `https://ziar-hub.netlify.app`. Add the same address under *Redirect URLs*. Without this, confirmation and password-reset emails point to the wrong place.
2. **Authentication → Providers → Email:** keep *Confirm email* on.
3. **Authentication → Attack Protection:** turn on *Leaked password protection*.
4. **Make yourself the admin:**
   1. Open your new site, choose **Create a login**, then confirm your email.
   2. Ask Claude to make your login the admin, or run this in *SQL Editor*, with your email:
      ```sql
      update public.profiles set role = 'admin', active = true where email = 'YOUR-EMAIL';
      ```
   3. Remove the two test logins (`zi-test-admin@example.com` and `zi-test-tech@example.com`) under *Authentication → Users*. Do this once your own admin login works.

## Move your data from the claude.ai hub

The 223 tickets are already in Supabase. To bring over everything else (invoices, statements, rate card, settings, inventory, and the latest ticket changes):

1. In the **claude.ai hub**, go to *Administration → Backup & Recovery → Download full backup*.
2. In the **new site**, sign in as admin and go to *Administration → Backup & Recovery → Restore*. Choose that file.
3. Tick **"Also replace the records that differ"**, then choose *Restore* and *Confirm*.
4. Check the totals in Finance against the old hub.

## Adding staff

1. Staff open the site and choose **New staff? Create a login**, then confirm their email.
2. They appear under *Administration → Users & Roles* as a request.
3. Give them a role: Office, Technician or Viewer. They are in at once.

## What works differently from the claude.ai version

| Feature | Own website |
|---|---|
| Tickets, review, parts, assets, reports, finance, invoices, PDFs, statements, backup | Same |
| Logins | Email + password, plus the hub's own PIN (no device approval needed: the email login already protects each account) |
| Photos | Stored privately in Supabase Storage (bucket `evidence`) |
| "Draft note with Claude" button | Hidden (needs an Anthropic API key) |
| Airtable / Xero live connection | Not connected. Use *Import tickets from a file* (CSV/Excel) and *Send invoices to Xero* (CSV export) |
| Phone reminders on the 1st and 16th | A billing-day banner on the Dashboard for 5 days after each cycle closes; not pushed to the phone |
