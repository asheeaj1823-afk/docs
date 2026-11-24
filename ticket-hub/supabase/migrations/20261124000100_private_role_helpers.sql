-- Move the role helpers out of the API-exposed public schema (Supabase advisor 0028/0029).
-- Policies reference functions by OID, so they keep working after the move.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

alter function public.my_role() set schema private;
alter function public.has_role(variadic public.app_role[]) set schema private;
alter function public.is_staff() set schema private;

revoke execute on function private.my_role(), private.has_role(variadic public.app_role[]), private.is_staff() from public, anon;
grant execute on function private.my_role(), private.has_role(variadic public.app_role[]), private.is_staff() to authenticated;

create or replace function private.has_role(variadic roles public.app_role[])
returns boolean language sql stable security definer set search_path = ''
as $$ select coalesce(private.my_role() = any (roles), false) $$;
create or replace function private.is_staff()
returns boolean language sql stable security definer set search_path = ''
as $$ select private.my_role() is not null $$;

create or replace function public.guard_profile_privileges()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if (new.role is distinct from old.role or new.active is distinct from old.active)
     and not private.has_role('admin') then
    raise exception 'Only an admin can change a user''s role or access' using errcode = '42501';
  end if;
  if new.id = auth.uid() and old.role = 'admin' and (new.role <> 'admin' or not new.active)
     and not exists (select 1 from public.profiles where role = 'admin' and active and id <> new.id) then
    raise exception 'You are the last active admin; make someone else admin first' using errcode = '42501';
  end if;
  return new;
end;
$$;

create or replace function public.guard_ticket_transition()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if private.has_role('admin', 'office') then
    return new;
  end if;
  if private.has_role('technician') then
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
revoke execute on function public.guard_profile_privileges(), public.guard_ticket_transition() from public, anon, authenticated;
