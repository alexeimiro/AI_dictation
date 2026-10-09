-- Helpers for the sign-in flow (auth-lookup, signup-status functions). Service role only.

-- Fixed-window counters keyed by an opaque string (e.g. a hashed client IP).
create table public.request_buckets (
  key text not null,
  window_start timestamptz not null,
  count integer not null default 0,
  primary key (key, window_start)
);
alter table public.request_buckets enable row level security;
revoke all on public.request_buckets from anon, authenticated;

create or replace function public.consume_bucket(p_key text, p_limit integer, p_window_seconds integer default 60)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  window_start_at timestamptz := to_timestamp(
    floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  current_count integer;
begin
  insert into public.request_buckets as b (key, window_start, count)
  values (p_key, window_start_at, 1)
  on conflict (key, window_start) do update set count = b.count + 1
  returning b.count into current_count;

  if random() < 0.02 then
    delete from public.request_buckets where window_start < now() - interval '1 hour';
  end if;
  return current_count <= p_limit;
end;
$$;

-- Does an account exist for this email, and how does it sign in? Drives the
-- "Continue with your email" branch (password sign-in vs. create account).
create or replace function public.auth_lookup(p_email text)
returns table (account_exists boolean, confirmed boolean, providers text[])
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  found_user auth.users%rowtype;
begin
  select * into found_user
  from auth.users u
  where lower(u.email) = lower(btrim(p_email)) and u.deleted_at is null
  limit 1;

  if not found then
    return query select false, false, '{}'::text[];
    return;
  end if;

  return query select
    true,
    found_user.email_confirmed_at is not null,
    coalesce(array(select distinct i.provider from auth.identities i where i.user_id = found_user.id), '{}');
end;
$$;

revoke execute on function public.consume_bucket(text, integer, integer) from public, anon, authenticated;
revoke execute on function public.auth_lookup(text) from public, anon, authenticated;
grant execute on function public.consume_bucket(text, integer, integer) to service_role;
grant execute on function public.auth_lookup(text) to service_role;
