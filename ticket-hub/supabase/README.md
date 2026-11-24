# Ticket hub database (Phase 1: Foundation)

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
