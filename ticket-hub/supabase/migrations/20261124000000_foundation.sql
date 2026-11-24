-- Phase 1: Foundation
-- Authentication-linked profiles, role-based permissions, the shared operational
-- tables the ticket hub already uses (visits -> tickets, parts, stock), file storage
-- for evidence, and an append-only audit trail on every table.

------------------------------------------------------------------------------
-- Roles and profiles
------------------------------------------------------------------------------
create type public.app_role as enum ('admin', 'office', 'finance', 'technician', 'viewer');

create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text not null default '',
  email       text,
  role        public.app_role not null default 'viewer',
  active      boolean not null default false,   -- new sign-ups wait for an admin to approve them
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table public.profiles is 'One row per login. role and active are set by an admin only.';

-- Role helpers. SECURITY DEFINER so policies can read profiles without recursing into profiles' own RLS.
create or replace function public.my_role()
returns public.app_role
language sql stable security definer set search_path = ''
as $$
  select p.role from public.profiles p where p.id = auth.uid() and p.active
$$;

create or replace function public.has_role(variadic roles public.app_role[])
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(public.my_role() = any (roles), false)
$$;

create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.my_role() is not null
$$;

-- Create a profile for every new login. The very first login becomes the active admin.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  first_user boolean;
begin
  select not exists (select 1 from public.profiles) into first_user;
  insert into public.profiles (id, email, full_name, role, active)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(coalesce(new.email, ''), '@', 1)),
    case when first_user then 'admin'::public.app_role else 'viewer'::public.app_role end,
    first_user
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Only admins may change role or active, including their own.
create or replace function public.guard_profile_privileges()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (new.role is distinct from old.role or new.active is distinct from old.active)
     and not public.has_role('admin') then
    raise exception 'Only an admin can change a user''s role or access' using errcode = '42501';
  end if;
  if new.id = auth.uid() and old.role = 'admin' and (new.role <> 'admin' or not new.active)
     and not exists (select 1 from public.profiles where role = 'admin' and active and id <> new.id) then
    raise exception 'You are the last active admin; make someone else admin first' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger profiles_guard
  before update on public.profiles
  for each row execute function public.guard_profile_privileges();

------------------------------------------------------------------------------
-- Shared housekeeping: updated_at / updated_by
------------------------------------------------------------------------------
create or replace function public.touch_row()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  if tg_table_name <> 'profiles' then
    new.updated_by := auth.uid();
    if tg_op = 'INSERT' then new.created_by := coalesce(new.created_by, auth.uid()); end if;
  end if;
  return new;
end;
$$;

create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_row();

------------------------------------------------------------------------------
-- Operational tables (mirror the ticket hub's current collections)
------------------------------------------------------------------------------
-- tickets = the app's "visits". Key fields are columns for filtering, reporting and
-- later joins to customers, assets and invoices (Phase 2/3); the full visit document
-- stays in `data` so the existing app works unchanged.
create table public.tickets (
  id            text primary key,                       -- visit / ticket number, e.g. '0218'
  ref           text,
  status        text not null default 'new'
                check (status in ('new', 'review', 'completed', 'recheck', 'cancelled')),
  priority      text not null default 'Normal' check (priority in ('Urgent', 'High', 'Normal')),
  type          text,
  site          text,
  region        text,
  product       text,
  model         text,
  scheduled_at  timestamptz,
  assigned_to   uuid references public.profiles (id),
  billing_ref   text,
  data          jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  created_by    uuid references public.profiles (id) default auth.uid(),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references public.profiles (id)
);
create index tickets_status_idx on public.tickets (status);
create index tickets_scheduled_idx on public.tickets (scheduled_at desc);
create index tickets_assigned_idx on public.tickets (assigned_to);

-- Technicians may only work on visits that are open (new / recheck) and may only
-- move them to 'review'. Completing, cancelling and reopening is office work.
create or replace function public.guard_ticket_transition()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if public.has_role('admin', 'office') then
    return new;
  end if;
  if public.has_role('technician') then
    if old.status not in ('new', 'recheck') then
      raise exception 'This visit has been submitted and can no longer be edited' using errcode = '42501';
    end if;
    if new.status not in (old.status, 'review') then
      raise exception 'Technicians can only submit a visit for review' using errcode = '42501';
    end if;
    if new.id <> old.id then
      raise exception 'A visit number cannot be changed' using errcode = '42501';
    end if;
    return new;
  end if;
  raise exception 'Your role cannot change visits' using errcode = '42501';
end;
$$;

create trigger tickets_touch before insert or update on public.tickets
  for each row execute function public.touch_row();
create trigger tickets_guard before update on public.tickets
  for each row execute function public.guard_ticket_transition();

-- parts = the app's "Parts Needed" / parts-used log; stock = monthly stock counts.
create table public.parts (
  id          text primary key,
  data        jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles (id) default auth.uid(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles (id)
);
create table public.stock (
  id          text primary key,
  month       text generated always as (data ->> 'month') stored,
  data        jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles (id) default auth.uid(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles (id)
);
create index stock_month_idx on public.stock (month);

create trigger parts_touch before insert or update on public.parts
  for each row execute function public.touch_row();
create trigger stock_touch before insert or update on public.stock
  for each row execute function public.touch_row();

------------------------------------------------------------------------------
-- Audit trail (append-only)
------------------------------------------------------------------------------
create table public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       uuid default auth.uid(),
  actor_role  public.app_role default public.my_role(),
  table_name  text not null,
  record_id   text not null,
  action      text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_data    jsonb,
  new_data    jsonb,
  changed     text[]                                  -- top-level columns that changed on UPDATE
);
create index audit_log_record_idx on public.audit_log (table_name, record_id, at desc);
create index audit_log_at_idx on public.audit_log (at desc);
comment on table public.audit_log is 'Append-only. Written by triggers; no one can update or delete rows.';

create or replace function public.audit_row()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  o jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  n jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  diff text[];
begin
  if tg_op = 'UPDATE' then
    select array_agg(k order by k) into diff
    from jsonb_object_keys(n) k
    where k not in ('updated_at', 'updated_by') and (o -> k) is distinct from (n -> k);
    if diff is null then return new; end if;               -- nothing meaningful changed
  end if;
  insert into public.audit_log (table_name, record_id, action, old_data, new_data, changed)
  values (tg_table_name, coalesce(n ->> 'id', o ->> 'id'), tg_op, o, n, diff);
  return coalesce(new, old);
end;
$$;

create or replace function public.audit_log_immutable()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  raise exception 'The audit log is append-only' using errcode = '42501';
end;
$$;

create trigger audit_log_no_update before update or delete on public.audit_log
  for each row execute function public.audit_log_immutable();
create trigger audit_log_no_truncate before truncate on public.audit_log
  for each statement execute function public.audit_log_immutable();

create trigger profiles_audit after insert or update or delete on public.profiles
  for each row execute function public.audit_row();
create trigger tickets_audit after insert or update or delete on public.tickets
  for each row execute function public.audit_row();
create trigger parts_audit after insert or update or delete on public.parts
  for each row execute function public.audit_row();
create trigger stock_audit after insert or update or delete on public.stock
  for each row execute function public.audit_row();

------------------------------------------------------------------------------
-- Row-level security
------------------------------------------------------------------------------
alter table public.profiles  enable row level security;
alter table public.tickets   enable row level security;
alter table public.parts     enable row level security;
alter table public.stock     enable row level security;
alter table public.audit_log enable row level security;

-- profiles: everyone signed in sees their own row (so a pending user sees "awaiting approval");
-- active staff see the team; you may edit your own name; admins manage everyone.
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_staff());
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_update_admin on public.profiles for update to authenticated
  using (public.has_role('admin')) with check (public.has_role('admin'));

-- tickets
create policy tickets_select on public.tickets for select to authenticated
  using (public.is_staff());
create policy tickets_insert on public.tickets for insert to authenticated
  with check (public.has_role('admin', 'office'));
create policy tickets_update on public.tickets for update to authenticated
  using (public.has_role('admin', 'office', 'technician'))
  with check (public.has_role('admin', 'office', 'technician'));
create policy tickets_delete on public.tickets for delete to authenticated
  using (public.has_role('admin'));

-- parts and stock: all staff read; office, finance and admin write; technicians log parts.
create policy parts_select on public.parts for select to authenticated using (public.is_staff());
create policy parts_write on public.parts for insert to authenticated
  with check (public.has_role('admin', 'office', 'finance', 'technician'));
create policy parts_update on public.parts for update to authenticated
  using (public.has_role('admin', 'office', 'finance'))
  with check (public.has_role('admin', 'office', 'finance'));
create policy parts_delete on public.parts for delete to authenticated
  using (public.has_role('admin', 'office'));

create policy stock_select on public.stock for select to authenticated using (public.is_staff());
create policy stock_insert on public.stock for insert to authenticated
  with check (public.has_role('admin', 'office', 'finance'));
create policy stock_update on public.stock for update to authenticated
  using (public.has_role('admin', 'office', 'finance'))
  with check (public.has_role('admin', 'office', 'finance'));
create policy stock_delete on public.stock for delete to authenticated
  using (public.has_role('admin', 'office'));

-- audit_log: read-only for admin and finance; no write policies at all (triggers write it).
create policy audit_select on public.audit_log for select to authenticated
  using (public.has_role('admin', 'finance'));

revoke all on public.audit_log from anon;
revoke insert, update, delete, truncate on public.audit_log from authenticated;
revoke all on public.profiles, public.tickets, public.parts, public.stock from anon;
revoke execute on function public.handle_new_user(), public.audit_row(), public.audit_log_immutable(),
  public.guard_profile_privileges(), public.guard_ticket_transition(), public.touch_row()
  from public, anon, authenticated;

------------------------------------------------------------------------------
-- Live updates for the app (replaces the artifact store's onSnapshot)
------------------------------------------------------------------------------
alter publication supabase_realtime add table public.tickets, public.parts, public.stock;

------------------------------------------------------------------------------
-- Evidence storage (photos, PDFs, signatures)
------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('evidence', 'evidence', false, 26214400)
on conflict (id) do nothing;

create policy evidence_read on storage.objects for select to authenticated
  using (bucket_id = 'evidence' and public.is_staff());
create policy evidence_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'evidence' and public.has_role('admin', 'office', 'technician'));
create policy evidence_delete on storage.objects for delete to authenticated
  using (bucket_id = 'evidence' and public.has_role('admin', 'office'));
