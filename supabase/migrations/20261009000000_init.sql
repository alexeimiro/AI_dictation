-- Murmur initial schema.
--
-- User-owned data (profile, dictionary, snippets, notes, feedback, issue reports) is protected by
-- RLS `user_id = auth.uid()`. Billing and usage (`entitlements`, `usage_events`, `rate_limits`)
-- can only be written by the service role (Edge Functions); users may read their own rows.
-- Transcript history stays on the device and is not stored here.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Weekly word limits reset on Sunday 00:00 America/Los_Angeles.
create or replace function public.week_start(ts timestamptz default now())
returns timestamptz
language sql
stable
as $$
  select (date_trunc('week', (ts at time zone 'America/Los_Angeles') + interval '1 day')
          - interval '1 day') at time zone 'America/Los_Angeles'
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text check (char_length(full_name) <= 120),
  survey jsonb not null default '{}'::jsonb,
  languages text[] not null default '{}',
  default_style text not null default 'casual'
    check (default_style in ('formal', 'casual', 'veryCasual', 'excited')),
  data_sharing boolean not null default false,
  referred_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.entitlements (
  user_id uuid primary key references auth.users (id) on delete cascade,
  plan text not null default 'basic' check (plan in ('basic', 'pro')),
  source text not null default 'trial' check (source in ('trial', 'app_store', 'grant')),
  trial_ends_at timestamptz,
  expires_at timestamptz,
  original_transaction_id text,
  updated_at timestamptz not null default now()
);

create table public.usage_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  dictation_id uuid not null,
  words integer not null check (words >= 0),
  created_at timestamptz not null default now(),
  unique (user_id, dictation_id)
);
create index usage_events_user_created on public.usage_events (user_id, created_at);

create table public.rate_limits (
  user_id uuid not null references auth.users (id) on delete cascade,
  window_start timestamptz not null,
  count integer not null default 0,
  primary key (user_id, window_start)
);

-- Synced tables: ids are generated on the device, `updated_at` (set by trigger) is the sync
-- cursor, and deletes are soft so other devices learn about them.
create table public.dictionary_entries (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  term text not null check (char_length(term) between 1 and 59),
  misspelling text check (misspelling is null or char_length(misspelling) between 1 and 59),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index dictionary_entries_sync on public.dictionary_entries (user_id, updated_at);

create table public.snippets (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  trigger text not null check (char_length(trigger) between 1 and 59),
  trigger_norm text generated always as (lower(btrim(trigger))) stored,
  expansion text not null check (char_length(expansion) between 1 and 4000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create unique index snippets_user_trigger on public.snippets (user_id, trigger_norm)
  where deleted_at is null;
create index snippets_sync on public.snippets (user_id, updated_at);

create table public.notes (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text not null default '' check (char_length(title) <= 200),
  body text not null default '' check (char_length(body) <= 200000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index notes_sync on public.notes (user_id, updated_at);

create table public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  dictation_id uuid,
  rating smallint not null check (rating in (-1, 1)),
  comment text check (char_length(comment) <= 2000),
  -- Only sent when the user opted in to share dictations.
  raw_text text check (char_length(raw_text) <= 20000),
  cleaned_text text check (char_length(cleaned_text) <= 20000),
  created_at timestamptz not null default now()
);

create table public.issue_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  message text not null check (char_length(message) between 1 and 5000),
  diagnostics jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.referrals (
  code text primary key,
  user_id uuid not null unique references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();
create trigger entitlements_updated_at before update on public.entitlements
  for each row execute function public.set_updated_at();
create trigger dictionary_entries_updated_at before update on public.dictionary_entries
  for each row execute function public.set_updated_at();
create trigger snippets_updated_at before update on public.snippets
  for each row execute function public.set_updated_at();
create trigger notes_updated_at before update on public.notes
  for each row execute function public.set_updated_at();

-- New users get a profile, a 14-day Pro trial (no card) and a referral code.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data ->> 'full_name')
  on conflict (id) do nothing;

  insert into public.entitlements (user_id, plan, source, trial_ends_at)
  values (new.id, 'basic', 'trial', now() + interval '14 days')
  on conflict (user_id) do nothing;

  insert into public.referrals (code, user_id)
  values (lower(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)), new.id)
  on conflict do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.entitlements enable row level security;
alter table public.usage_events enable row level security;
alter table public.rate_limits enable row level security;
alter table public.dictionary_entries enable row level security;
alter table public.snippets enable row level security;
alter table public.notes enable row level security;
alter table public.feedback enable row level security;
alter table public.issue_reports enable row level security;
alter table public.referrals enable row level security;

create policy "Users manage their profile" on public.profiles
  for all to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "Users read their entitlement" on public.entitlements
  for select to authenticated using (user_id = (select auth.uid()));

create policy "Users read their usage" on public.usage_events
  for select to authenticated using (user_id = (select auth.uid()));

create policy "Users manage their dictionary" on public.dictionary_entries
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "Users manage their snippets" on public.snippets
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "Users manage their notes" on public.notes
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "Users send and read their feedback" on public.feedback
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Users insert feedback" on public.feedback
  for insert to authenticated with check (user_id = (select auth.uid()));

create policy "Users read their issue reports" on public.issue_reports
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Users insert issue reports" on public.issue_reports
  for insert to authenticated with check (user_id = (select auth.uid()));

create policy "Users read their referral code" on public.referrals
  for select to authenticated using (user_id = (select auth.uid()));

-- Belt and braces: billing tables are never writable from the client.
revoke insert, update, delete on public.entitlements from anon, authenticated;
revoke insert, update, delete on public.usage_events from anon, authenticated;
revoke all on public.rate_limits from anon, authenticated;
revoke insert, update, delete on public.referrals from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Quota (service role only)
-- ---------------------------------------------------------------------------

create or replace function public.quota_status(p_user uuid)
returns table (
  plan text,
  on_trial boolean,
  trial_ends_at timestamptz,
  words_this_week integer,
  weekly_limit integer,
  remaining integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  e public.entitlements%rowtype;
  used integer;
  effective text;
begin
  select * into e from public.entitlements where user_id = p_user;
  effective := case
    when e.plan = 'pro' and (e.expires_at is null or e.expires_at > now()) then 'pro'
    when e.trial_ends_at is not null and e.trial_ends_at > now() then 'pro'
    else 'basic'
  end;
  select coalesce(sum(u.words), 0)::integer into used
  from public.usage_events u
  where u.user_id = p_user and u.created_at >= public.week_start(now());

  return query select
    effective,
    effective = 'pro' and coalesce(e.plan, 'basic') <> 'pro',
    e.trial_ends_at,
    used,
    case when effective = 'pro' then null else 1000 end,
    case when effective = 'pro' then null else greatest(0, 1000 - used) end;
end;
$$;

-- One round trip before each cleanup: rate limit + quota.
create or replace function public.cleanup_preflight(p_user uuid, p_per_minute integer default 40)
returns table (allowed boolean, reason text, plan text, remaining integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  window_count integer;
  q record;
begin
  insert into public.rate_limits as r (user_id, window_start, count)
  values (p_user, date_trunc('minute', now()), 1)
  on conflict (user_id, window_start) do update set count = r.count + 1
  returning r.count into window_count;

  if random() < 0.02 then
    delete from public.rate_limits where window_start < now() - interval '10 minutes';
  end if;

  select * into q from public.quota_status(p_user);

  if window_count > p_per_minute then
    return query select false, 'rate_limited', q.plan, q.remaining;
  elsif q.remaining is not null and q.remaining <= 0 then
    return query select false, 'limit_reached', q.plan, q.remaining;
  else
    return query select true, null::text, q.plan, q.remaining;
  end if;
end;
$$;

-- Idempotent per dictation, so retries can't double-count.
create or replace function public.record_usage(p_user uuid, p_dictation uuid, p_words integer)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.usage_events (user_id, dictation_id, words)
  values (p_user, p_dictation, greatest(p_words, 0))
  on conflict (user_id, dictation_id) do nothing;
$$;

-- What the app shows ("N words left this week", trial countdown).
create or replace function public.my_quota()
returns table (
  plan text,
  on_trial boolean,
  trial_ends_at timestamptz,
  words_this_week integer,
  weekly_limit integer,
  remaining integer
)
language sql
stable
security definer
set search_path = public
as $$
  select * from public.quota_status((select auth.uid()));
$$;

revoke execute on function public.quota_status(uuid) from public, anon, authenticated;
revoke execute on function public.cleanup_preflight(uuid, integer) from public, anon, authenticated;
revoke execute on function public.record_usage(uuid, uuid, integer) from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.my_quota() from public, anon;
grant execute on function public.quota_status(uuid) to service_role;
grant execute on function public.cleanup_preflight(uuid, integer) to service_role;
grant execute on function public.record_usage(uuid, uuid, integer) to service_role;
grant execute on function public.my_quota() to authenticated;
