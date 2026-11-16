-- One weekly allowance per iPhone, whichever account is signed in. The free 1,000 words were per
-- account only, so signing out and signing in with a second email (or with Google instead of Apple)
-- gave another 1,000 on the same iPhone.
--
-- The app keeps a random id in the iPhone's Keychain, where it outlives a reinstall, and sends it
-- with every call (header x-murmur-device, and `p_device` to my_quota). Each free word is counted
-- for the account, as before, and for the iPhone it was dictated on; on the free plan the week is
-- used up when either count says so.
--
-- - Only words used on the free plan count for the iPhone, so a Pro subscriber's dictations don't
--   use up the week of someone on Basic who shares the iPad.
-- - The id is the app's word: a client that isn't the app can leave it out or make one up. This is
--   for the everyday case (a second account on one iPhone), not for scripts.
-- - Builds that send no id, and the functions deployed before this, pass nothing: every new
--   parameter defaults to null, which is the per-account rule as it was.
--
-- A parameter can't be added with `create or replace`, and an old version left beside the new one
-- would make every call ambiguous, so each function is dropped and made again here, in one
-- transaction, with its grants.

create table public.device_usage (
  -- SHA-256 of the id (`device_key`), not the id the iPhone keeps.
  device text primary key,
  -- The week `words` belong to; a later week starts over.
  week_start timestamptz not null,
  words integer not null default 0 check (words >= 0),
  updated_at timestamptz not null default now()
);
create index device_usage_week_start on public.device_usage (week_start);
alter table public.device_usage enable row level security;
revoke all on public.device_usage from anon, authenticated;

-- The key a device's words are kept under. Null for anything but an id as the app makes it (a
-- UUID): nothing is then counted per device, and the per-account rule applies alone.
create or replace function public.device_key(p_device text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when lower(btrim(p_device)) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then encode(sha256(convert_to('device:' || lower(btrim(p_device)), 'UTF8')), 'hex')
  end
$$;

-- ---------------------------------------------------------------------------
-- Quota
-- ---------------------------------------------------------------------------

drop function public.quota_status(uuid);

-- As in 20261117000000, and on the free plan the week's words are the larger of the account's and
-- the iPhone's (`p_device`; null: the account's alone).
create function public.quota_status(p_user uuid, p_device text default null)
returns table (
  plan text,
  on_trial boolean,
  trial_ends_at timestamptz,
  words_this_week integer,
  weekly_limit integer,
  remaining integer
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  e public.entitlements%rowtype;
  used integer;
  on_device integer;
  effective text;
  this_week timestamptz := public.week_start(now());
  free_words integer := 1000;
begin
  select * into e from public.entitlements where user_id = p_user;
  if found and e.restored_at is null then
    perform public.restore_account(p_user);
    select * into e from public.entitlements where user_id = p_user;
  end if;
  effective := case
    when e.plan = 'pro' and (e.expires_at is null or e.expires_at > now()) then 'pro'
    when e.trial_ends_at is not null and e.trial_ends_at > now() then 'pro'
    else 'basic'
  end;
  select coalesce(sum(u.words), 0)::integer into used
  from public.usage_events u
  where u.user_id = p_user and u.created_at >= this_week;
  if e.carried_week = this_week then
    used := used + e.carried_words;
  end if;
  if effective <> 'pro' then
    if exists (select 1 from auth.users a where a.id = p_user and a.is_anonymous) then
      free_words := 0;
    end if;
    select d.words into on_device
    from public.device_usage d
    where d.device = public.device_key(p_device) and d.week_start = this_week;
    used := greatest(used, coalesce(on_device, 0));
  end if;

  return query select
    effective,
    effective = 'pro' and coalesce(e.plan, 'basic') <> 'pro',
    e.trial_ends_at,
    used,
    case when effective = 'pro' then null else free_words end,
    case when effective = 'pro' then null else greatest(0, free_words - used) end;
end;
$$;

drop function public.my_quota();

-- What the app shows, for the iPhone it is shown on (`p_device`; builds before the id send none).
-- Two statements, as in 20261117000000.
create function public.my_quota(p_device text default null)
returns table (
  plan text,
  on_trial boolean,
  trial_ends_at timestamptz,
  words_this_week integer,
  weekly_limit integer,
  remaining integer,
  trial_started_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  me uuid := (select auth.uid());
  q record;
begin
  select * into q from public.quota_status(me, p_device);
  return query select q.plan, q.on_trial, q.trial_ends_at, q.words_this_week, q.weekly_limit, q.remaining,
    (select e.trial_started_at from public.entitlements e where e.user_id = me);
end;
$$;

-- ---------------------------------------------------------------------------
-- Usage
-- ---------------------------------------------------------------------------

drop function public.record_usage(uuid, uuid, integer);

-- Still one row per dictation, which keeps the greatest count it was sent. What a call adds to
-- that row is also added to the iPhone's week, while the account is on the free plan.
create function public.record_usage(p_user uuid, p_dictation uuid, p_words integer, p_device text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  counted integer := greatest(coalesce(p_words, 0), 0);
  device_hash text := public.device_key(p_device);
  had integer;
  added integer;
  this_week timestamptz := public.week_start(now());
begin
  if device_hash is not null then
    -- One call at a time per dictation (a speculative translation, the final one, a retry): each
    -- must see what the one before it counted, or the iPhone would be given the same words twice.
    perform pg_advisory_xact_lock(hashtextextended(p_user::text || ':' || p_dictation::text, 0));
    select u.words into had from public.usage_events u where u.user_id = p_user and u.dictation_id = p_dictation;
  end if;

  insert into public.usage_events as u (user_id, dictation_id, words)
  values (p_user, p_dictation, counted)
  on conflict (user_id, dictation_id) do update set words = excluded.words
  where excluded.words > u.words;

  added := counted - coalesce(had, 0);
  if device_hash is null or added <= 0 then
    return;
  end if;
  if exists (
    select 1 from public.entitlements e
    where e.user_id = p_user
      and ((e.plan = 'pro' and (e.expires_at is null or e.expires_at > now()))
           or (e.trial_ends_at is not null and e.trial_ends_at > now()))
  ) then
    return;
  end if;
  insert into public.device_usage as d (device, week_start, words)
  values (device_hash, this_week, added)
  on conflict (device) do update
    set words = case when d.week_start = this_week then d.words + added else added end,
        week_start = this_week,
        updated_at = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- Preflights: as they were, with the iPhone passed on to the quota
-- ---------------------------------------------------------------------------

drop function public.cleanup_preflight(uuid, integer);

create function public.cleanup_preflight(p_user uuid, p_per_minute integer default 40, p_device text default null)
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

  select * into q from public.quota_status(p_user, p_device);

  if window_count > p_per_minute then
    return query select false, 'rate_limited', q.plan, q.remaining;
  elsif q.remaining is not null and q.remaining <= 0 then
    return query select false, 'limit_reached', q.plan, q.remaining;
  else
    return query select true, null::text, q.plan, q.remaining;
  end if;
end;
$$;

drop function public.dictation_preflight(uuid, text, uuid, integer, integer);

create function public.dictation_preflight(
  p_user uuid,
  p_scope text,
  p_dictation uuid default null,
  p_per_minute integer default 40,
  p_max_calls integer default 6,
  p_device text default null
)
returns table (allowed boolean, reason text, plan text, remaining integer, attempt integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  -- How long after a dictation's first allowed call its later calls skip the bucket.
  attempt_window constant interval := interval '10 minutes';
  calls_so_far integer := 0;
  q record;
begin
  -- The scope prefixes the bucket key, so `transcribe` shares the transcribe function's buckets.
  if p_scope is null or p_scope !~ '^[a-z-]{1,32}$' then
    raise exception 'invalid preflight scope: %', p_scope using errcode = '22023';
  end if;

  if p_dictation is not null then
    if random() < 0.02 then
      delete from public.dictation_attempts where window_start < now() - attempt_window;
    end if;

    -- The upsert locks the row, so concurrent calls of one dictation are counted one at a time.
    -- A row whose 10 minutes are up counts as cleaned up: this call is the dictation's first again.
    insert into public.dictation_attempts as a (user_id, scope, dictation_id)
    values (p_user, p_scope, p_dictation)
    on conflict (user_id, scope, dictation_id) do update
      set calls = case when a.window_start >= now() - attempt_window then a.calls else 0 end
    returning a.calls into calls_so_far;
  end if;

  select * into q from public.quota_status(p_user, p_device);

  if p_dictation is not null and calls_so_far >= p_max_calls then
    return query select false, 'too_many_attempts', q.plan, q.remaining, null::integer;
    return;
  end if;

  -- Only a dictation's first allowed call uses the bucket (the same windows as consume_bucket).
  if calls_so_far = 0 then
    if not public.consume_bucket(p_scope || ':' || p_user, p_per_minute, 60) then
      return query select false, 'rate_limited', q.plan, q.remaining, null::integer;
      return;
    end if;
  end if;

  if q.remaining is not null and q.remaining <= 0 then
    return query select false, 'limit_reached', q.plan, q.remaining, null::integer;
    return;
  end if;

  -- The 10 minutes start at the first allowed call, not at a refused one before it.
  if p_dictation is not null then
    update public.dictation_attempts
    set calls = calls_so_far + 1,
        window_start = case when calls_so_far = 0 then now() else window_start end
    where user_id = p_user and scope = p_scope and dictation_id = p_dictation;
  end if;

  return query select true, null::text, q.plan, q.remaining,
    case when p_dictation is not null then calls_so_far + 1 end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Who may call what, and the clean-up
-- ---------------------------------------------------------------------------

-- Dropping a function drops its grants, and a new one is open to everyone until revoked.
revoke execute on function public.device_key(text) from public, anon, authenticated;
revoke execute on function public.quota_status(uuid, text) from public, anon, authenticated;
revoke execute on function public.record_usage(uuid, uuid, integer, text) from public, anon, authenticated;
revoke execute on function public.cleanup_preflight(uuid, integer, text) from public, anon, authenticated;
revoke execute on function public.dictation_preflight(uuid, text, uuid, integer, integer, text)
  from public, anon, authenticated;
revoke execute on function public.my_quota(text) from public, anon;
grant execute on function public.quota_status(uuid, text) to service_role;
grant execute on function public.record_usage(uuid, uuid, integer, text) to service_role;
grant execute on function public.cleanup_preflight(uuid, integer, text) to service_role;
grant execute on function public.dictation_preflight(uuid, text, uuid, integer, integer, text) to service_role;
grant execute on function public.my_quota(text) to authenticated;

-- A device nobody has dictated on for five weeks is forgotten.
do $schedule$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'device allowance: no pg_cron here, so old device rows are not cleaned up';
    return;
  end if;
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.schedule('device-usage-purge', '27 3 * * *',
    $job$ delete from public.device_usage where week_start < now() - interval '35 days' $job$);
end;
$schedule$;

notify pgrst, 'reload schema';
