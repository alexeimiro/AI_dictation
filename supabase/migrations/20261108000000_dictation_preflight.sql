-- One round trip before each `dictate` call: per-dictation attempts, a per-minute bucket for the
-- scope and the weekly quota. Service role only. `transcribe` and `cleanup` keep their RPCs, and
-- `record_usage` keeps its signature, so old builds' calls and replies are unchanged; only a
-- Regenerate that comes back with more words now raises its dictation's count.

-- ---------------------------------------------------------------------------
-- Tables and indexes
-- ---------------------------------------------------------------------------

-- Allowed calls per dictation and scope. Callers pass a dictation only for calls meant to share
-- one: `dictate`'s text calls (speculative translations, the final one, retries), not its audio
-- calls. Only a dictation's first call takes from the scope's bucket, for 10 minutes from its first
-- allowed call (a dictation is at most 5); then its next call starts over. So a dictation can't
-- keep its skipped calls longer, though those of every dictation opened in the 10 minutes can be
-- sent at once.
create table public.dictation_attempts (
  user_id uuid not null references auth.users (id) on delete cascade,
  scope text not null,
  dictation_id uuid not null,
  calls integer not null default 0 check (calls >= 0),
  -- The first allowed call of the current 10 minutes (the insert, until a call is allowed).
  window_start timestamptz not null default now(),
  primary key (user_id, scope, dictation_id)
);
create index dictation_attempts_window_start on public.dictation_attempts (window_start);
alter table public.dictation_attempts enable row level security;
revoke all on public.dictation_attempts from anon, authenticated;

-- The inline cleanups delete windows by age; these turn them into range scans.
create index request_buckets_window_start on public.request_buckets (window_start);
create index rate_limits_window_start on public.rate_limits (window_start);

-- ---------------------------------------------------------------------------
-- Preflight and usage (service role only)
-- ---------------------------------------------------------------------------

-- Checks, in order: the dictation's attempt cap, the bucket, the quota. `reason` is null when
-- allowed, else too_many_attempts, rate_limited or limit_reached; `plan` and `remaining` are as in
-- cleanup_preflight. `attempt` numbers an allowed call within its dictation and scope from 1 (from
-- 1 again once its 10 minutes are up), and is null when the call is refused or has no dictation
-- (then nothing is counted and every call is bucketed).
create or replace function public.dictation_preflight(
  p_user uuid,
  p_scope text,
  p_dictation uuid default null,
  p_per_minute integer default 40,
  p_max_calls integer default 6
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

  select * into q from public.quota_status(p_user);

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

-- Still one row per dictation, so retries can't double-count. A later call that counted more
-- words (the final translation after a speculative one) raises it; fewer words never lower it.
-- Same signature, so the grants from init.sql stay.
create or replace function public.record_usage(p_user uuid, p_dictation uuid, p_words integer)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.usage_events as u (user_id, dictation_id, words)
  values (p_user, p_dictation, greatest(p_words, 0))
  on conflict (user_id, dictation_id) do update set words = excluded.words
  where excluded.words > u.words;
$$;

revoke execute on function public.dictation_preflight(uuid, text, uuid, integer, integer)
  from public, anon, authenticated;
grant execute on function public.dictation_preflight(uuid, text, uuid, integer, integer) to service_role;
