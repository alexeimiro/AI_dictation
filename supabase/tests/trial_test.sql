-- pgTAP tests for one free trial per iPhone: no trial at sign-up, claim-trial's decision through
-- decide_trial (granted, device_used or unchecked; the first one stands), and who may decide.
-- Run with `supabase test db`.
begin;
select plan(16);

-- Ivy's iPhone is new to Murmur, Jon's had a trial, Kim's check couldn't reach Apple, and Liv was
-- given an invite month before her check.
insert into auth.users (id, email, aud, role, created_at, is_anonymous)
values
  ('cccccccc-0000-0000-0000-000000000001', 'ivy@example.com', 'authenticated', 'authenticated', now(), false),
  ('cccccccc-0000-0000-0000-000000000002', 'jon@example.com', 'authenticated', 'authenticated', now(), false),
  ('cccccccc-0000-0000-0000-000000000003', null, 'authenticated', 'authenticated', now(), true),
  ('cccccccc-0000-0000-0000-000000000004', 'liv@example.com', 'authenticated', 'authenticated', now(), false);

select results_eq(
  $$ select plan, on_trial, remaining from public.quota_status('cccccccc-0000-0000-0000-000000000001') $$,
  $$ values ('basic', false, 1000) $$,
  'a new account is on Basic until its trial is decided');
select results_eq(
  $$ select trial_check, trial_checked_at, trial_started_at from public.entitlements
     where user_id = 'cccccccc-0000-0000-0000-000000000001' $$,
  $$ values (null::text, null::timestamptz, null::timestamptz) $$,
  'nothing is decided at sign-up');

-- Ivy: her iPhone's first trial.
select results_eq(
  $$ select * from public.decide_trial('cccccccc-0000-0000-0000-000000000001', 'granted') $$,
  $$ values ('granted', now() + interval '14 days') $$,
  'the first account on an iPhone gets 14 days');
select results_eq(
  $$ select trial_check, trial_checked_at, trial_started_at, trial_ends_at from public.entitlements
     where user_id = 'cccccccc-0000-0000-0000-000000000001' $$,
  $$ values ('granted', now(), now(), now() + interval '14 days') $$,
  'the grant records when it was decided and when the trial started');
select results_eq(
  $$ select plan, on_trial, remaining from public.quota_status('cccccccc-0000-0000-0000-000000000001') $$,
  $$ values ('pro', true, null::int) $$,
  'the trial is Pro without a weekly limit');
select results_eq(
  $$ select * from public.decide_trial('cccccccc-0000-0000-0000-000000000001', 'device_used') $$,
  $$ values ('granted', now() + interval '14 days') $$,
  'the first decision stands');

-- Jon: his iPhone had its trial.
select results_eq(
  $$ select * from public.decide_trial('cccccccc-0000-0000-0000-000000000002', 'device_used') $$,
  $$ values ('device_used', null::timestamptz) $$,
  'a later account on the same iPhone gets no trial');
select results_eq(
  $$ select plan, on_trial, remaining from public.quota_status('cccccccc-0000-0000-0000-000000000002') $$,
  $$ values ('basic', false, 1000) $$,
  'and stays on Basic');
select results_eq(
  $$ select * from public.decide_trial('cccccccc-0000-0000-0000-000000000002', 'granted') $$,
  $$ values ('device_used', null::timestamptz) $$,
  'asking again doesn''t turn it into a trial');

-- Kim, a guest: Apple couldn't answer, so the trial is granted unchecked.
select results_eq(
  $$ select * from public.decide_trial('cccccccc-0000-0000-0000-000000000003', 'unchecked') $$,
  $$ values ('unchecked', now() + interval '14 days') $$,
  'an unchecked trial is still 14 days');

-- Liv: a longer free stretch already running isn't cut short by the grant.
update public.entitlements
set trial_started_at = now() - interval '2 days', trial_ends_at = now() + interval '28 days'
where user_id = 'cccccccc-0000-0000-0000-000000000004';
select public.decide_trial('cccccccc-0000-0000-0000-000000000004', 'granted');
select results_eq(
  $$ select trial_started_at, trial_ends_at from public.entitlements where user_id = 'cccccccc-0000-0000-0000-000000000004' $$,
  $$ values (now() - interval '2 days', now() + interval '28 days') $$,
  'a grant never shortens a free stretch that is running');

select throws_ok($$ select public.decide_trial('cccccccc-0000-0000-0000-000000000004', 'legacy') $$, '22023', null,
                 'legacy is only for accounts from before the check');
select throws_ok($$ select public.decide_trial('cccccccc-0000-0000-0000-000000000004', null) $$, '22023', null,
                 'a decision needs an outcome');

-- Only the server decides.
set local role authenticated;
set local request.jwt.claims = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select throws_ok($$ select public.decide_trial('cccccccc-0000-0000-0000-000000000002', 'granted') $$, '42501', null,
                 'users cannot decide their own trial');
select throws_ok($$ update public.entitlements set trial_check = null $$, '42501', null,
                 'users cannot reset their decision');
reset role;
set local role anon;
select throws_ok($$ select public.decide_trial('cccccccc-0000-0000-0000-000000000002', 'granted') $$, '42501', null,
                 'the anon key cannot decide trials');
reset role;

select * from finish();
rollback;
