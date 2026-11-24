# Ticket hub database

Supabase project `ziar-imaar-ops` (ref `fvjgsambbanisyvvxghx`, region ap-south-1 Mumbai).
Migrations in `migrations/` are applied in filename order and are already live on that project.

## What's in it
| Piece | Purpose |
|---|---|
| `profiles` + `app_role` | One row per login. Roles: admin, office, finance, technician, viewer. |
| Sign-up rule | The first login becomes the active admin. Everyone after starts as an inactive viewer until an admin approves them. Only admins can change role or access, and the last admin can't demote themselves. |
| `tickets` | The app's visits. Key fields are columns for filtering and later joins; the full visit document is in `data`. |
| `parts`, `stock` | The app's Parts Needed log and monthly stock counts. |
| `audit_log` | Append-only. Triggers record every insert, update and delete on all tables, with who, their role, before/after and the changed columns. Not even the database owner can edit or delete rows. Readable by admin and finance. |
| `evidence` bucket | Private storage for photos, PDFs and signatures (25 MB per file). |
| Realtime | `tickets`, `parts` and `stock` publish live changes, replacing the current store's onSnapshot. |

## Permissions
| | admin | office | finance | technician | viewer (active) |
|---|---|---|---|---|---|
| Read tickets, parts, stock | ✓ | ✓ | ✓ | ✓ | ✓ |
| Create tickets | ✓ | ✓ | | | |
| Edit tickets | any | any | | only open (new/recheck), and only move to review | |
| Delete tickets | ✓ | | | | |
| Log parts | ✓ | ✓ | ✓ | ✓ | |
| Edit stock counts | ✓ | ✓ | ✓ | | |
| Read audit log | ✓ | | ✓ | | |
| Manage users | ✓ | | | | |

These rules were tested role by role in a rolled-back transaction (2026-11-24).

## v3 hub on Supabase (migration `20261124000200`)
`ticket-hub/index.html` is the v3 hub. Opened as a Claude artifact it uses the artifact store as before. Opened anywhere else (for example Netlify), it signs in with Supabase and reads and writes this database.

| App collection | Stored in | Who can read / write |
|---|---|---|
| visits | `tickets` | all staff read · admin & office write · technicians only their assigned, open tickets, and only to submit for review |
| parts, stock | own tables | as in Phase 1 |
| assets, inventory | `documents` | all staff read · admin & office write |
| invoices, bills, bankAccounts, bankTx, journals, statements, partnerTx, finSettings | `documents` | admin (and finance) only |
| audit (the app's action log) | `documents` | each person writes their own · admins read all · nobody deletes |
| roles, requests | derived from `profiles` | approving a request or setting a role updates the login |
| pins | not stored | replaced by Supabase sign-in |

**Sign-in:** email and password, then an authenticator-app code (Supabase MFA). The database grants no role to a session that skipped the code, so this can't be bypassed from the browser. To reset someone's authenticator, remove their MFA factor in the Supabase dashboard (Authentication → Users); they set up a new one at their next sign-in.

**Moving data from the artifact:** sign in as admin, open Backup & recovery, and restore the backup file. Restoring only adds records that are missing.
