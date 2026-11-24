-- Ticket hub v3 on Supabase.
-- * Every staff permission now needs a session verified with an authenticator code (MFA, aal2),
--   replacing the app's in-page PIN + authenticator check, so it is enforced by the database.
-- * Technicians may only change tickets assigned to them (matches the app's canEditTicket).
-- * A general `documents` table holds the app's other collections (assets, inventory, finance
--   records, per-person action log) with permissions per collection, until Phases 2-3 give
--   them their own typed tables.
-- * Technician phone numbers live on profiles.

------------------------------------------------------------------------------
-- MFA: no role unless this session passed the authenticator step
------------------------------------------------------------------------------
create or replace function private.my_role()
returns public.app_role
language sql stable security definer set search_path = ''
as $$
  select p.role from public.profiles p
  where p.id = auth.uid() and p.active and coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
$$;

alter table public.profiles add column if not exists phone text not null default '';

------------------------------------------------------------------------------
-- Tickets: technicians only on their own assigned tickets, and cannot reassign
------------------------------------------------------------------------------
create index if not exists tickets_assigned_idx on public.tickets (assigned_to);

drop policy if exists tickets_update on public.tickets;
create policy tickets_update on public.tickets for update to authenticated
  using (private.has_role('admin', 'office')
         or (private.has_role('technician') and assigned_to = auth.uid()))
  with check (private.has_role('admin', 'office')
         or (private.has_role('technician') and assigned_to = auth.uid()));

create or replace function public.guard_ticket_transition()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if private.has_role('admin', 'office') then
    return new;
  end if;
  if private.has_role('technician') then
    if new.id <> old.id then
      raise exception 'A visit number cannot be changed' using errcode = '42501';
    end if;
    if new.assigned_to is distinct from old.assigned_to then
      raise exception 'Only the office can reassign a visit' using errcode = '42501';
    end if;
    if old.status not in ('new', 'recheck') then
      raise exception 'This visit has been submitted and can no longer be edited' using errcode = '42501';
    end if;
    if new.status not in (old.status, 'review') then
      raise exception 'Technicians can only submit a visit for review' using errcode = '42501';
    end if;
    return new;
  end if;
  raise exception 'Your role cannot change visits' using errcode = '42501';
end;
$$;
revoke execute on function public.guard_ticket_transition() from public, anon, authenticated;

------------------------------------------------------------------------------
-- Documents: the app's remaining collections
------------------------------------------------------------------------------
create table public.documents (
  collection  text not null check (collection ~ '^[A-Za-z][A-Za-z0-9_]{0,40}$'),
  id          text not null,
  data        jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles (id) default auth.uid(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles (id),
  primary key (collection, id)
);
comment on table public.documents is 'App collections not yet modelled as their own tables. Access is decided per collection by private.doc_access.';

-- Who may read ('r') or write ('w') a collection. Unknown collections: admins only.
create or replace function private.doc_access(col text, doc_id text, op text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select case
    when col in ('bankAccounts', 'bankTx', 'invoices', 'partnerTx', 'finSettings',
                 'statements', 'journals', 'bills')
      then private.has_role('admin', 'finance')
    when col in ('assets', 'inventory')
      then case when op = 'r' then private.is_staff() else private.has_role('admin', 'office') end
    when col = 'audit'                 -- each person's own action log; admins read everyone's
      then case when op = 'r' then private.has_role('admin') or (private.is_staff() and doc_id = auth.uid()::text)
                else private.is_staff() and doc_id = auth.uid()::text end
    else private.has_role('admin')
  end
$$;
revoke execute on function private.doc_access(text, text, text) from public, anon;
grant execute on function private.doc_access(text, text, text) to authenticated;

alter table public.documents enable row level security;
create policy documents_select on public.documents for select to authenticated
  using (private.doc_access(collection, id, 'r'));
create policy documents_insert on public.documents for insert to authenticated
  with check (private.doc_access(collection, id, 'w'));
create policy documents_update on public.documents for update to authenticated
  using (private.doc_access(collection, id, 'w')) with check (private.doc_access(collection, id, 'w'));
create policy documents_delete on public.documents for delete to authenticated
  using (private.doc_access(collection, id, 'w') and collection <> 'audit');
revoke all on public.documents from anon;

create trigger documents_touch before insert or update on public.documents
  for each row execute function public.touch_row();

-- record ids in the audit trail include the collection for documents
create or replace function public.audit_row()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  o jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  n jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  r jsonb := coalesce(n, o);
  diff text[];
begin
  if tg_op = 'UPDATE' then
    select array_agg(k order by k) into diff
    from jsonb_object_keys(n) k
    where k not in ('updated_at', 'updated_by') and (o -> k) is distinct from (n -> k);
    if diff is null then return new; end if;
  end if;
  insert into public.audit_log (table_name, record_id, action, old_data, new_data, changed)
  values (tg_table_name,
          case when r ? 'collection' then (r ->> 'collection') || '/' || (r ->> 'id') else r ->> 'id' end,
          tg_op, o, n, diff);
  return coalesce(new, old);
end;
$$;
revoke execute on function public.audit_row() from public, anon, authenticated;

create trigger documents_audit after insert or update or delete on public.documents
  for each row execute function public.audit_row();

------------------------------------------------------------------------------
-- Live updates
------------------------------------------------------------------------------
alter publication supabase_realtime add table public.documents, public.profiles;
