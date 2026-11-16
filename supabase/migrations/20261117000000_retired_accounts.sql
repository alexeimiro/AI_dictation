-- Deleting an account and signing up again no longer resets the free plan. Until now every row went
-- with the account, so a new account for the same person started the week at 0 of 1,000 words.
--
-- For 30 days after a deletion we keep a fingerprint of the sign-in (never the email address or
-- Apple or Google id itself) with what a new account would otherwise get afresh: the words used
-- that week, the trial decision and its dates, and the invite it had entered. A new account that
-- matches a fingerprint carries on from there: nothing gained, nothing lost. After 30 days the
-- record is deleted; Apple's per-iPhone mark still stops a second trial on the same iPhone.
--
-- - retire_account: delete-account calls it just before it deletes the user.
-- - restore_account: runs once per account, at its first quota check, trial decision or invite.
-- - quota_status adds the carried words, and gives a guest (an anonymous sign-in) no free words:
--   the app records only for a signed-in account, and anyone can make guests with the app's key.
--
-- Signatures stay as they were, so the functions already deployed and the builds already out keep
-- working while this is applied.

-- ---------------------------------------------------------------------------
-- What an account carries from the one it replaces
-- ---------------------------------------------------------------------------

alter table public.entitlements
  -- When the account was checked against the deleted ones. Accounts from before this change have
  -- nothing to restore, so they count as checked now; a new one is null until its first check.
  add column restored_at timestamptz default now(),
  -- The words a deleted account of the same person had used in `carried_week`.
  add column carried_words integer not null default 0 check (carried_words >= 0),
  add column carried_week timestamptz,
  -- When the person's first account was made, where an earlier one was deleted. Null: this one's.
  add column first_seen_at timestamptz;
alter table public.entitlements alter column restored_at drop default;

-- One row per deleted account that had a sign-in to recognise, for 30 days.
create table public.retired_accounts (
  id uuid primary key default gen_random_uuid(),
  retired_at timestamptz not null default now(),
  expires_at timestamptz not null,
  -- When the first of the accounts it restored was first given its state.
  restored_at timestamptz,
  first_seen_at timestamptz not null,
  -- The week it was deleted in and the words used in it (its own and those it carried).
  week_start timestamptz not null,
  words integer not null default 0 check (words >= 0),
  trial_check text check (trial_check in ('granted', 'device_used', 'unchecked', 'legacy')),
  trial_checked_at timestamptz,
  trial_started_at timestamptz,
  trial_ends_at timestamptz,
  -- Its own invite code, so the links it shared work again when it returns.
  own_code text,
  -- The invite it had entered: whose (an account, or a deleted one's record), when, and whether
  -- its first dictation was counted for the code's owner.
  invite_code text,
  invite_referrer uuid references auth.users (id) on delete set null,
  invite_referrer_retired uuid references public.retired_accounts (id) on delete set null,
  invite_redeemed_at timestamptz,
  invite_first_dictation_at timestamptz,
  invite_referrer_rewarded boolean not null default false
);
create index retired_accounts_expires_at on public.retired_accounts (expires_at);
create index retired_accounts_invite_referrer_retired on public.retired_accounts (invite_referrer_retired)
  where invite_referrer_retired is not null;

-- The fingerprints of a deleted account's sign-ins. A fingerprint points at the newest record.
create table public.retired_account_keys (
  key_hash text primary key,
  retired_id uuid not null references public.retired_accounts (id) on delete cascade
);
create index retired_account_keys_retired on public.retired_account_keys (retired_id);

-- A code owner who deletes their account leaves the friends' records in place (referrer_id goes
-- null). This says whose they were, so a returning owner gets the friends, and the 12-month cap, back.
alter table public.referral_redemptions
  add column referrer_retired uuid references public.retired_accounts (id) on delete set null;
create index referral_redemptions_referrer_retired on public.referral_redemptions (referrer_retired)
  where referrer_retired is not null;

alter table public.retired_accounts enable row level security;
alter table public.retired_account_keys enable row level security;
revoke all on public.retired_accounts, public.retired_account_keys from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Fingerprints
-- ---------------------------------------------------------------------------

-- The secret mixed into every fingerprint, so the table alone can't be tested against a list of
-- email addresses. Vault holds it; where there is no Vault (a bare Postgres for tests) a fixed value
-- stands in. If the secret is ever replaced, the records made with the old one stop matching.
do $secret$
begin
  if exists (select 1 from pg_available_extensions where name = 'supabase_vault') then
    create extension if not exists supabase_vault with schema vault;
    if not exists (select 1 from vault.secrets where name = 'retired_accounts_secret') then
      -- Two random UUIDs: 244 random bits, without needing pgcrypto.
      perform vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
        'retired_accounts_secret', 'Mixed into the fingerprints of deleted accounts (public.account_keys).');
    end if;
    execute $function$
      create or replace function public.account_secret()
      returns text
      language sql
      stable
      security definer
      set search_path = ''
      as $body$
        select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'retired_accounts_secret' limit 1
      $body$
    $function$;
  else
    raise notice 'retired accounts: no Vault here, so fingerprints use a fixed value (tests only)';
    execute $function$
      create or replace function public.account_secret()
      returns text
      language sql
      stable
      set search_path = ''
      as $body$ select 'tests-only-not-a-secret'::text $body$
    $function$;
  end if;
end;
$secret$;

-- One mailbox, one address: lower case, without a "+tag", and without Gmail's dots.
create or replace function public.normal_email(p_email text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when a.domain in ('gmail.com', 'googlemail.com')
      then replace(split_part(a.name, '+', 1), '.', '') || '@gmail.com'
    else split_part(a.name, '+', 1) || '@' || a.domain
  end
  from (select split_part(e, '@', 1) as name, split_part(e, '@', 2) as domain
        from (select lower(btrim(p_email)) as e) trimmed) a
$$;

-- The fingerprint of one sign-in ("apple:<id>", "google:<id>" or "email:<address>") under `p_secret`.
create or replace function public.account_key_hash(p_key text, p_secret text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(p_secret || '|' || p_key, 'UTF8')), 'hex')
$$;

-- The fingerprints of an account's sign-ins: its Apple and Google ids, and each confirmed email
-- address. A guest has none. It reads the secret before anything else and raises without it, so a
-- server that can't make fingerprints says so on every call, whoever the account is.
create or replace function public.account_keys(p_user uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  secret text := public.account_secret();
  keys text[];
begin
  if coalesce(secret, '') = '' then
    raise exception 'retired accounts: the fingerprint secret is missing';
  end if;
  select coalesce(array_agg(public.account_key_hash(k.key, secret)), '{}') into keys
  from (
    select 'email:' || public.normal_email(u.email) as key
    from auth.users u
    where u.id = p_user and u.email like '%_@_%' and u.email_confirmed_at is not null
    union
    select 'email:' || public.normal_email(i.identity_data ->> 'email')
    from auth.identities i
    where i.user_id = p_user and i.provider in ('apple', 'google') and (i.identity_data ->> 'email') like '%_@_%'
    union
    select i.provider || ':' || i.provider_id
    from auth.identities i
    where i.user_id = p_user and i.provider in ('apple', 'google') and coalesce(i.provider_id, '') <> ''
  ) k;
  return keys;
end;
$$;

-- ---------------------------------------------------------------------------
-- Coming back, and leaving
-- ---------------------------------------------------------------------------

-- Gives a new account what a deleted account of the same person had. Once per account: whoever
-- sets `restored_at` does the work, and a call at the same moment waits and finds it set. It never
-- raises: a failure is a warning and the account is tried again at its next check, so a dictation,
-- a trial decision or an invite can't fail because of this.
create or replace function public.restore_account(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  keys text[];
  t public.retired_accounts%rowtype;
  this_week timestamptz := public.week_start(now());
begin
  if not exists (select 1 from public.entitlements where user_id = p_user and restored_at is null) then
    return;
  end if;
  begin
    update public.entitlements set restored_at = now() where user_id = p_user and restored_at is null;
    if not found then
      return;
    end if;
    keys := public.account_keys(p_user);
    if cardinality(keys) = 0 then
      return;
    end if;
    select r.* into t
    from public.retired_accounts r
    where r.expires_at > now()
      and exists (select 1 from public.retired_account_keys k where k.retired_id = r.id and k.key_hash = any (keys))
    order by r.retired_at desc
    limit 1;
    if not found then
      return;
    end if;

    -- The words only within the week they were used in. The trial decision stands, so claim-trial
    -- can't decide a second one; its dates come back where they reach further than the account's.
    update public.entitlements e
    set carried_words = case when t.week_start = this_week then t.words else 0 end,
        carried_week = case when t.week_start = this_week then this_week end,
        first_seen_at = least(coalesce(e.first_seen_at, t.first_seen_at), t.first_seen_at),
        trial_check = coalesce(e.trial_check, t.trial_check),
        trial_checked_at = case when e.trial_check is null then t.trial_checked_at else e.trial_checked_at end,
        trial_started_at = case
          when t.trial_ends_at is not null and (e.trial_ends_at is null or t.trial_ends_at > e.trial_ends_at)
            then t.trial_started_at
          else e.trial_started_at
        end,
        trial_ends_at = case
          when t.trial_ends_at is not null and (e.trial_ends_at is null or t.trial_ends_at > e.trial_ends_at)
            then t.trial_ends_at
          else e.trial_ends_at
        end
    where e.user_id = p_user;

    -- The invite it had entered, as it was: a first dictation that was counted isn't counted again.
    -- Only the first account to return is the code owner's friend again; a second account of the
    -- same person (another address of the same mailbox) just can't enter a code a second time.
    if t.invite_code is not null then
      insert into public.referral_redemptions
        (user_id, code, referrer_id, referrer_retired, redeemed_at, first_dictation_at, referrer_rewarded)
      values (
        p_user, t.invite_code,
        case when t.restored_at is null then t.invite_referrer end,
        case when t.restored_at is null then t.invite_referrer_retired end,
        coalesce(t.invite_redeemed_at, now()),
        case when t.restored_at is null then t.invite_first_dictation_at else coalesce(t.invite_first_dictation_at, now()) end,
        t.restored_at is null and t.invite_referrer_rewarded)
      on conflict (user_id) do nothing;
    end if;

    if t.restored_at is null then
      -- The friends who joined with its code are its friends again, towards the 12 months too:
      -- those with an account, and those who deleted theirs and may return.
      update public.referral_redemptions set referrer_id = p_user, referrer_retired = null
      where referrer_retired = t.id;
      update public.retired_accounts set invite_referrer = p_user, invite_referrer_retired = null
      where invite_referrer_retired = t.id;
      -- The links it shared work again, unless the code was given out since.
      if t.own_code is not null then
        update public.referrals set code = t.own_code
        where user_id = p_user and not exists (select 1 from public.referrals taken where taken.code = t.own_code);
      end if;
      update public.retired_accounts set restored_at = now() where id = t.id;
    end if;
  exception when others then
    raise warning 'restore_account(%) failed: % (%)', p_user, sqlerrm, sqlstate;
  end;
end;
$$;

-- Remembers an account that is about to be deleted. Returns 'kept', or 'none' for an account with
-- no sign-in to recognise (a guest). Service role only: delete-account calls it, and deletes the
-- account whether or not this worked.
create or replace function public.retire_account(p_user uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  keys text[];
  e public.entitlements%rowtype;
  account_made timestamptz;
  this_week timestamptz := public.week_start(now());
  used integer;
  invite public.referral_redemptions%rowtype;
  record_id uuid;
begin
  delete from public.retired_accounts where expires_at < now();
  -- An account deleted before its first check still carries what the one before it left.
  perform public.restore_account(p_user);
  keys := public.account_keys(p_user);
  if cardinality(keys) = 0 then
    return 'none';
  end if;
  select * into e from public.entitlements where user_id = p_user;
  if not found then
    return 'none';
  end if;
  select created_at into account_made from auth.users where id = p_user;
  select coalesce(sum(u.words), 0)::integer into used
  from public.usage_events u
  where u.user_id = p_user and u.created_at >= this_week;
  if e.carried_week = this_week then
    used := used + e.carried_words;
  end if;
  select * into invite from public.referral_redemptions where user_id = p_user;

  insert into public.retired_accounts (
    expires_at, first_seen_at, week_start, words,
    trial_check, trial_checked_at, trial_started_at, trial_ends_at, own_code,
    invite_code, invite_referrer, invite_referrer_retired, invite_redeemed_at, invite_first_dictation_at,
    invite_referrer_rewarded)
  values (
    now() + interval '30 days', coalesce(e.first_seen_at, account_made, now()), this_week, used,
    e.trial_check, e.trial_checked_at, e.trial_started_at, e.trial_ends_at,
    (select r.code from public.referrals r where r.user_id = p_user),
    invite.code, invite.referrer_id, invite.referrer_retired, invite.redeemed_at, invite.first_dictation_at,
    coalesce(invite.referrer_rewarded, false))
  returning id into record_id;

  insert into public.retired_account_keys (key_hash, retired_id)
  select k, record_id from unnest(keys) as k
  on conflict (key_hash) do update set retired_id = excluded.retired_id;

  -- Its friends' records, of those with an account and of those who deleted theirs, stay its own.
  update public.referral_redemptions set referrer_retired = record_id where referrer_id = p_user;
  update public.retired_accounts set invite_referrer_retired = record_id where invite_referrer = p_user;
  return 'kept';
end;
$$;

-- Erases what is kept of a deleted account with this email address, when its owner asks before the
-- 30 days are up. Returns how many records went.
create or replace function public.forget_retired(p_email text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  gone integer;
begin
  with removed as (
    delete from public.retired_accounts r
    using public.retired_account_keys k
    where k.retired_id = r.id
      and k.key_hash = public.account_key_hash('email:' || public.normal_email(p_email), public.account_secret())
    returning r.id
  )
  select count(*)::integer into gone from removed;
  return gone;
end;
$$;

-- ---------------------------------------------------------------------------
-- Quota: carried words, and no free words for a guest
-- ---------------------------------------------------------------------------

-- As before, with three differences: a new account is checked against the deleted ones first (so
-- it is volatile now), the words it carries count towards this week, and a guest has no free words.
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
volatile
security definer
set search_path = public
as $$
declare
  e public.entitlements%rowtype;
  used integer;
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
  if effective <> 'pro' and exists (select 1 from auth.users a where a.id = p_user and a.is_anonymous) then
    free_words := 0;
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

-- What the app shows. Two statements on purpose: the first may restore a returning account, and
-- one statement would still read the trial's start from before that.
create or replace function public.my_quota()
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
  select * into q from public.quota_status(me);
  return query select q.plan, q.on_trial, q.trial_ends_at, q.words_this_week, q.weekly_limit, q.remaining,
    (select e.trial_started_at from public.entitlements e where e.user_id = me);
end;
$$;

-- ---------------------------------------------------------------------------
-- The trial and invites of a returning account
-- ---------------------------------------------------------------------------

-- As before, after the account is checked against the deleted ones: a decision that came back with
-- it is the first decision, so it stands.
create or replace function public.decide_trial(p_user uuid, p_outcome text)
returns table (outcome text, ends_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_outcome is null or p_outcome not in ('granted', 'device_used', 'unchecked') then
    raise exception 'decide_trial: unknown outcome %', p_outcome using errcode = '22023';
  end if;
  perform public.restore_account(p_user);
  update public.entitlements e
  set trial_check = p_outcome,
      trial_checked_at = now(),
      trial_started_at = case
        when p_outcome = 'device_used' then e.trial_started_at
        when e.trial_ends_at > now() then coalesce(e.trial_started_at, now())
        else now()
      end,
      trial_ends_at = case
        when p_outcome = 'device_used' then e.trial_ends_at
        else greatest(coalesce(e.trial_ends_at, now()), now() + interval '14 days')
      end,
      updated_at = now()
  where e.user_id = p_user and e.trial_check is null;
  return query select e.trial_check, e.trial_ends_at from public.entitlements e where e.user_id = p_user;
end;
$$;

-- As before, after the account is checked against the deleted ones (an invite that came back with
-- it is already_redeemed), and the 14 days run from the person's first account, not from this one.
create or replace function public.redeem_referral(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := (select auth.uid());
  normalized text := lower(btrim(coalesce(p_code, '')));
  account record;
  code_owner uuid;
  checked text;
  first_seen timestamptz;
begin
  select id, created_at, is_anonymous into account from auth.users where id = caller;
  if not found or account.is_anonymous then
    return 'sign_in_required';
  end if;
  perform public.restore_account(caller);
  select coalesce(e.first_seen_at, account.created_at) into first_seen
  from public.entitlements e where e.user_id = caller;
  select user_id into code_owner from public.referrals where code = normalized;
  if code_owner is null then
    return 'invalid';
  elsif code_owner = caller then
    return 'own_code';
  elsif exists (select 1 from public.referral_redemptions where user_id = caller) then
    return 'already_redeemed';
  elsif coalesce(first_seen, account.created_at) < now() - interval '14 days' then
    return 'too_late';
  end if;

  select trial_check into checked from public.entitlements where user_id = caller;
  if checked is null then
    return 'device_check_required';
  elsif checked = 'device_used' then
    return 'device_used';
  end if;

  insert into public.referral_redemptions (user_id, code, referrer_id)
  values (caller, normalized, code_owner)
  on conflict (user_id) do nothing;
  if not found then
    return 'already_redeemed';
  end if;

  -- A month of Pro from now, in place of what's left of the trial.
  update public.entitlements
  set trial_started_at = case when trial_ends_at > now() then coalesce(trial_started_at, now()) else now() end,
      trial_ends_at = greatest(coalesce(trial_ends_at, now()), now() + interval '30 days')
  where user_id = caller;

  -- A friend who dictated before entering the code has already done their part.
  if exists (select 1 from public.usage_events where user_id = caller and words > 0) then
    perform public.reward_referrer(caller);
  end if;
  return 'ok';
end;
$$;

-- As before, after the account is checked against the deleted ones (its code and its friends come
-- back with it), and with the 14 days counted as redeem_referral counts them. Two statements, as
-- in my_quota.
create or replace function public.my_referrals()
returns table (
  code text,
  friends_joined integer,
  months_earned integer,
  redeemed boolean,
  can_redeem boolean
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  caller uuid := (select auth.uid());
begin
  perform public.restore_account(caller);
  return query select
    (select r.code from public.referrals r where r.user_id = me.id),
    (select count(*)::integer from public.referral_redemptions x where x.referrer_id = me.id),
    (select count(*)::integer from public.referral_redemptions x where x.referrer_id = me.id and x.referrer_rewarded),
    exists (select 1 from public.referral_redemptions x where x.user_id = me.id),
    not exists (select 1 from public.referral_redemptions x where x.user_id = me.id)
      and not me.is_anonymous
      and coalesce((select e.first_seen_at from public.entitlements e where e.user_id = me.id), me.created_at)
          >= now() - interval '14 days'
  from auth.users me
  where me.id = caller;
end;
$$;

-- ---------------------------------------------------------------------------
-- Who may call what, and the daily clean-up
-- ---------------------------------------------------------------------------

-- New functions are open to everyone until revoked. The existing ones above keep their grants.
revoke execute on function public.account_secret() from public, anon, authenticated, service_role;
revoke execute on function public.account_key_hash(text, text) from public, anon, authenticated, service_role;
revoke execute on function public.account_keys(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.normal_email(text) from public, anon, authenticated;
revoke execute on function public.restore_account(uuid) from public, anon, authenticated;
revoke execute on function public.retire_account(uuid) from public, anon, authenticated;
revoke execute on function public.forget_retired(text) from public, anon, authenticated;
grant execute on function public.restore_account(uuid) to service_role;
grant execute on function public.retire_account(uuid) to service_role;
grant execute on function public.forget_retired(text) to service_role;

-- Records past their 30 days go every night (and whenever an account is deleted). Where pg_cron is
-- missing (a bare Postgres for tests) only the second happens.
do $schedule$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'retired accounts: no pg_cron here, so expired records go only when an account is deleted';
    return;
  end if;
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.schedule('retired-accounts-purge', '17 3 * * *',
    $job$ delete from public.retired_accounts where expires_at < now() $job$);
end;
$schedule$;

-- quota_status, my_quota and my_referrals write now: PostgREST must stop calling them in read-only
-- transactions.
notify pgrst, 'reload schema';
