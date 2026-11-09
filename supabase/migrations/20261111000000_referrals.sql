-- Invites ("Refer a friend"). A friend who enters an invite code within 14 days of signing up gets a
-- month of Pro. The code's owner gets a month when that friend finishes a first dictation, for up
-- to 12 friends. Free months move the trial dates, so quota_status counts them as it counts the
-- trial; my_quota now also says when the current free stretch started, for "N of M days used".

alter table public.entitlements add column trial_started_at timestamptz;
update public.entitlements set trial_started_at = trial_ends_at - interval '14 days'
  where trial_ends_at is not null;
alter table public.entitlements alter column trial_started_at set default now();

-- One row per friend who entered a code: whose code, when they first dictated, and whether that
-- earned the code's owner a month. Written only by the functions below.
create table public.referral_redemptions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  code text not null,
  referrer_id uuid references auth.users (id) on delete set null,
  redeemed_at timestamptz not null default now(),
  first_dictation_at timestamptz,
  referrer_rewarded boolean not null default false
);
create index referral_redemptions_referrer on public.referral_redemptions (referrer_id);
alter table public.referral_redemptions enable row level security;
revoke all on public.referral_redemptions from anon, authenticated;

-- Free Pro for `p_days` more days: added to a free stretch that's still running, else from now.
create or replace function public.extend_free_pro(p_user uuid, p_days integer)
returns void
language sql
security definer
set search_path = public
as $$
  update public.entitlements
  set trial_started_at = case when trial_ends_at > now() then coalesce(trial_started_at, now()) else now() end,
      trial_ends_at = greatest(coalesce(trial_ends_at, now()), now()) + make_interval(days => p_days)
  where user_id = p_user;
$$;

-- The friend's first dictation: the code's owner gets a month, unless 12 friends already earned one.
create or replace function public.reward_referrer(p_friend uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  redemption public.referral_redemptions%rowtype;
begin
  select * into redemption from public.referral_redemptions
  where user_id = p_friend and first_dictation_at is null
  for update;
  if not found then
    return;
  end if;
  update public.referral_redemptions set first_dictation_at = now() where user_id = p_friend;
  if redemption.referrer_id is null then
    return;
  end if;
  -- One reward at a time per owner, so two friends dictating at once can't pass 12 together.
  perform 1 from public.entitlements where user_id = redemption.referrer_id for update;
  if (select count(*) from public.referral_redemptions
      where referrer_id = redemption.referrer_id and referrer_rewarded) >= 12 then
    return;
  end if;
  update public.referral_redemptions set referrer_rewarded = true where user_id = p_friend;
  perform public.extend_free_pro(redemption.referrer_id, 30);
end;
$$;

create or replace function public.usage_rewards_referrer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.reward_referrer(new.user_id);
  return null;
end;
$$;

create trigger usage_events_reward_referrer
  after insert or update of words on public.usage_events
  for each row when (new.words > 0)
  execute function public.usage_rewards_referrer();

-- Entering a friend's code. Returns ok, invalid, own_code, already_redeemed, too_late or
-- sign_in_required (no session, or a guest without an account).
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
begin
  select id, created_at, is_anonymous into account from auth.users where id = caller;
  if not found or account.is_anonymous then
    return 'sign_in_required';
  end if;
  select user_id into code_owner from public.referrals where code = normalized;
  if code_owner is null then
    return 'invalid';
  elsif code_owner = caller then
    return 'own_code';
  elsif exists (select 1 from public.referral_redemptions where user_id = caller) then
    return 'already_redeemed';
  elsif account.created_at < now() - interval '14 days' then
    return 'too_late';
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

-- What "Refer a friend" shows: the caller's code, how many friends joined with it and earned a
-- month, and whether the caller can still enter someone's code.
create or replace function public.my_referrals()
returns table (
  code text,
  friends_joined integer,
  months_earned integer,
  redeemed boolean,
  can_redeem boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    (select r.code from public.referrals r where r.user_id = me.id),
    (select count(*)::integer from public.referral_redemptions x where x.referrer_id = me.id),
    (select count(*)::integer from public.referral_redemptions x where x.referrer_id = me.id and x.referrer_rewarded),
    exists (select 1 from public.referral_redemptions x where x.user_id = me.id),
    not exists (select 1 from public.referral_redemptions x where x.user_id = me.id)
      and not me.is_anonymous and me.created_at >= now() - interval '14 days'
  from auth.users me
  where me.id = (select auth.uid());
$$;

-- my_quota gains trial_started_at; a new result column means dropping it first.
drop function public.my_quota();
create function public.my_quota()
returns table (
  plan text,
  on_trial boolean,
  trial_ends_at timestamptz,
  words_this_week integer,
  weekly_limit integer,
  remaining integer,
  trial_started_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select q.*, e.trial_started_at
  from public.quota_status((select auth.uid())) q
  left join public.entitlements e on e.user_id = (select auth.uid());
$$;

revoke execute on function public.extend_free_pro(uuid, integer) from public, anon, authenticated;
revoke execute on function public.reward_referrer(uuid) from public, anon, authenticated;
revoke execute on function public.usage_rewards_referrer() from public, anon, authenticated;
revoke execute on function public.redeem_referral(text) from public, anon;
revoke execute on function public.my_referrals() from public, anon;
revoke execute on function public.my_quota() from public, anon;
grant execute on function public.redeem_referral(text) to authenticated;
grant execute on function public.my_referrals() to authenticated;
grant execute on function public.my_quota() to authenticated;
