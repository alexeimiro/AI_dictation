-- One free trial per iPhone. A new account no longer gets its 14 days of Pro at sign-up: the
-- claim-trial function decides them once, after asking Apple's DeviceCheck whether this iPhone has
-- had a Murmur trial before (bit 0 of the two bits Apple keeps per device for this developer team).
-- An invite code's free month is that iPhone's trial too, so one iPhone can't collect months.

alter table public.entitlements
  add column trial_check text
    check (trial_check in ('granted', 'device_used', 'unchecked', 'legacy')),
  add column trial_checked_at timestamptz;

comment on column public.entitlements.trial_check is
  'How the free trial was decided: granted (the iPhone''s first), device_used (the iPhone had one), '
  'unchecked (granted without Apple''s answer), legacy (granted at sign-up, before this check). '
  'Null until claim-trial decides.';

-- Accounts from before this change keep the trial they got at sign-up.
update public.entitlements set trial_check = 'legacy', trial_checked_at = now();

-- A free stretch starts when one is granted, not when the row is made.
alter table public.entitlements alter column trial_started_at drop default;

-- New users get a profile, an entitlement on Basic and a referral code. The trial is claim-trial's.
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

  insert into public.entitlements (user_id, plan, source, trial_ends_at, trial_started_at)
  values (new.id, 'basic', 'trial', null, null)
  on conflict (user_id) do nothing;

  insert into public.referrals (code, user_id)
  values (lower(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)), new.id)
  on conflict do nothing;

  return new;
end;
$$;

-- claim-trial's decision, once per account: the first answer stands, so two claims at once can't
-- both grant. A grant is 14 days from now and never shortens a free stretch already running.
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

-- Entering a friend's code, as before, with one more rule: the month is this iPhone's free trial,
-- so it isn't given on an iPhone that already had one (device_used), nor before claim-trial has
-- asked Apple (device_check_required; the app claims first and can try again).
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

revoke execute on function public.decide_trial(uuid, text) from public, anon, authenticated;
grant execute on function public.decide_trial(uuid, text) to service_role;
revoke execute on function public.redeem_referral(text) from public, anon;
grant execute on function public.redeem_referral(text) to authenticated;
