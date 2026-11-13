-- pgTAP tests for invites: entering a code, the friend's month, the owner's month on the friend's
-- first dictation, the 12-month cap, and who may call what. Run with `supabase test db`.
begin;
select plan(30);

-- Ann shares her code. Fred and Dan are new; Lea signed up 20 days ago; the guest has no account.
insert into auth.users (id, email, aud, role, created_at, is_anonymous)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'ann@example.com', 'authenticated', 'authenticated', now(), false),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'fred@example.com', 'authenticated', 'authenticated', now(), false),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'lea@example.com', 'authenticated', 'authenticated', now() - interval '20 days', false),
  ('aaaaaaaa-0000-0000-0000-000000000004', null, 'authenticated', 'authenticated', now(), true),
  ('aaaaaaaa-0000-0000-0000-000000000005', 'dan@example.com', 'authenticated', 'authenticated', now(), false);
-- claim-trial gives each of them their iPhone's first trial after sign-up, as the app asks it to.
select public.decide_trial(id, 'granted') from auth.users
where id in ('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
             'aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000005');
select set_config('test.ann', (select code from public.referrals where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'), true);
select set_config('test.ann_ends',
  (select trial_ends_at::text from public.entitlements where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'), true);

select ok((select trial_started_at = now() from public.entitlements where user_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
          'a granted trial records when it started');

-- Fred enters Ann's code.
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000002","role":"authenticated"}';
select is((select can_redeem from public.my_referrals()), true, 'a new account can enter a code');
select is(public.redeem_referral('nope1234'), 'invalid', 'an unknown code is refused');
select is(public.redeem_referral(upper(' ' || current_setting('test.ann') || ' ')), 'ok',
          'a code works however it''s typed');
select is(public.redeem_referral(current_setting('test.ann')), 'already_redeemed', 'an account enters one code');
select results_eq($$ select redeemed, can_redeem from public.my_referrals() $$, $$ values (true, false) $$,
                  'after entering a code there''s none left to enter');
select ok((select trial_ends_at = now() + interval '30 days' from public.my_quota()), 'the friend gets a month of Pro');
select ok((select on_trial and trial_started_at < now() + interval '1 second' from public.my_quota()),
          'my_quota says when the free month started');
select throws_ok($$ select * from public.referral_redemptions $$, '42501', null, 'users cannot read redemptions');
select throws_ok($$ select public.reward_referrer('aaaaaaaa-0000-0000-0000-000000000002') $$, '42501', null,
                 'users cannot hand out rewards');
select throws_ok($$ select public.extend_free_pro('aaaaaaaa-0000-0000-0000-000000000002', 365) $$, '42501', null,
                 'users cannot give themselves Pro');
reset role;

-- Ann can't use her own code; Lea is too late; the guest needs an account.
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}';
select is(public.redeem_referral(current_setting('test.ann')), 'own_code', 'nobody enters their own code');
select results_eq($$ select friends_joined, months_earned from public.my_referrals() $$, $$ values (1, 0) $$,
                  'the owner sees a friend joined, with no month until they dictate');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000003","role":"authenticated"}';
select is(public.redeem_referral(current_setting('test.ann')), 'too_late', 'codes are for accounts under 14 days old');
select is((select can_redeem from public.my_referrals()), false, 'an older account isn''t offered a code field');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000004","role":"authenticated"}';
select is(public.redeem_referral(current_setting('test.ann')), 'sign_in_required', 'guests need an account first');
reset role;
set local role anon;
select throws_ok($$ select public.redeem_referral('x') $$, '42501', null, 'the anon key cannot enter codes');
reset role;

-- The month is the iPhone's free trial: none on an iPhone that already had one (Gus), and none
-- before claim-trial has asked Apple (Hal).
insert into auth.users (id, email, aud, role, created_at, is_anonymous)
values
  ('aaaaaaaa-0000-0000-0000-000000000006', 'gus@example.com', 'authenticated', 'authenticated', now(), false),
  ('aaaaaaaa-0000-0000-0000-000000000007', 'hal@example.com', 'authenticated', 'authenticated', now(), false);
select public.decide_trial('aaaaaaaa-0000-0000-0000-000000000006', 'device_used');
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000006","role":"authenticated"}';
select is(public.redeem_referral(current_setting('test.ann')), 'device_used',
          'no month on an iPhone that already had its trial');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000007","role":"authenticated"}';
select is(public.redeem_referral(current_setting('test.ann')), 'device_check_required',
          'no month before the iPhone is checked');
reset role;
select results_eq(
  $$ select (select count(*)::int from public.referral_redemptions
             where user_id in ('aaaaaaaa-0000-0000-0000-000000000006', 'aaaaaaaa-0000-0000-0000-000000000007')),
            (select count(*)::int from public.entitlements
             where user_id in ('aaaaaaaa-0000-0000-0000-000000000006', 'aaaaaaaa-0000-0000-0000-000000000007')
               and trial_ends_at is not null) $$,
  $$ values (0, 0) $$,
  'neither is recorded as a friend or given Pro');

-- Fred's first dictation earns Ann a month; later ones don't.
select public.record_usage('aaaaaaaa-0000-0000-0000-000000000002', gen_random_uuid(), 0);
select is((select first_dictation_at from public.referral_redemptions where user_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
          null, 'a dictation without words doesn''t count');
select public.record_usage('aaaaaaaa-0000-0000-0000-000000000002', gen_random_uuid(), 12);
select ok((select trial_ends_at = current_setting('test.ann_ends')::timestamptz + interval '30 days'
           from public.entitlements where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
          'the owner gets a month, added to the trial, when the friend first dictates');
select public.record_usage('aaaaaaaa-0000-0000-0000-000000000002', gen_random_uuid(), 40);
select ok((select trial_ends_at = current_setting('test.ann_ends')::timestamptz + interval '30 days'
           from public.entitlements where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
          'only the friend''s first dictation counts');

-- Dan dictated before entering the code: Ann's month comes as soon as he enters it.
select public.record_usage('aaaaaaaa-0000-0000-0000-000000000005', gen_random_uuid(), 5);
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000005","role":"authenticated"}';
select is(public.redeem_referral(current_setting('test.ann')), 'ok', 'a friend can enter the code after dictating');
reset role;
select ok((select trial_ends_at = current_setting('test.ann_ends')::timestamptz + interval '60 days'
           from public.entitlements where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
          'a friend who dictated first earns the owner a month at once');

-- Twelve months at most: ten more friends earned one, and a thirteenth friend's dictation adds none.
insert into auth.users (id, aud, role, created_at, is_anonymous)
select ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'authenticated', 'authenticated', now(), false
from generate_series(1, 11) n;
insert into public.referral_redemptions (user_id, code, referrer_id, first_dictation_at, referrer_rewarded)
select ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, current_setting('test.ann'),
       'aaaaaaaa-0000-0000-0000-000000000001', now(), true
from generate_series(1, 10) n;
insert into public.referral_redemptions (user_id, code, referrer_id)
values ('bbbbbbbb-0000-0000-0000-000000000011', current_setting('test.ann'), 'aaaaaaaa-0000-0000-0000-000000000001');
select public.record_usage('bbbbbbbb-0000-0000-0000-000000000011', gen_random_uuid(), 7);
select ok((select trial_ends_at = current_setting('test.ann_ends')::timestamptz + interval '60 days'
           from public.entitlements where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
          'invites earn 12 months at most');
select isnt((select first_dictation_at from public.referral_redemptions where user_id = 'bbbbbbbb-0000-0000-0000-000000000011'),
            null, 'the thirteenth friend''s dictation is still recorded');
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}';
select results_eq($$ select friends_joined, months_earned from public.my_referrals() $$, $$ values (13, 12) $$,
                  'the owner sees 13 friends and 12 months');
reset role;

-- A month earned after the trial ended starts a new free stretch from now.
update public.entitlements set trial_ends_at = now() - interval '1 day', trial_started_at = now() - interval '21 days'
where user_id = 'aaaaaaaa-0000-0000-0000-000000000003';
select public.extend_free_pro('aaaaaaaa-0000-0000-0000-000000000003', 30);
select results_eq(
  $$ select trial_started_at, trial_ends_at from public.entitlements where user_id = 'aaaaaaaa-0000-0000-0000-000000000003' $$,
  $$ values (now(), now() + interval '30 days') $$,
  'a month after the trial ended runs from now');

-- Deleting the owner's account keeps the friend's month and their record.
delete from auth.users where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select is((select referrer_id from public.referral_redemptions where user_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
          null, 'a deleted owner leaves the friend''s redemption in place');

select * from finish();
rollback;
