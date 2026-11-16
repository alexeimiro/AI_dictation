-- pgTAP tests for deleted accounts: an account that is deleted and made again within 30 days
-- carries on where it left off (words this week, trial, invite), a different person starts fresh,
-- a guest has no free words, and nobody but the server can touch any of it.
-- Run with `supabase test db`.
begin;
select plan(50);

-- What delete-account does: remember the account, then delete it.
create function pg_temp.delete_account(p_user uuid) returns text language plpgsql as $$
declare
  kept text;
begin
  kept := public.retire_account(p_user);
  delete from auth.users where id = p_user;
  return kept;
end;
$$;

-- A signed-in account whose email address is confirmed, made `p_age` ago.
create function pg_temp.sign_up(p_user uuid, p_email text, p_age interval default '0') returns void language sql as $$
  insert into auth.users (id, email, aud, role, created_at, is_anonymous, email_confirmed_at)
  values (p_user, p_email, 'authenticated', 'authenticated', now() - p_age, false, now() - p_age);
$$;

-- The record kept for an email address.
create function pg_temp.record_of(p_email text) returns uuid language sql as $$
  select retired_id from public.retired_account_keys
  where key_hash = public.account_key_hash('email:' || public.normal_email(p_email), public.account_secret());
$$;

select is(public.normal_email(' N.O.A+Work@GoogleMail.com '), 'noa@gmail.com',
          'a Gmail address is one mailbox however it is dotted or tagged');
select is(public.normal_email('First.Last+x@example.com'), 'first.last@example.com',
          'elsewhere only the tag goes');

-- ---------------------------------------------------------------------------
-- Words
-- ---------------------------------------------------------------------------

-- Mia signs in with Apple behind a relay address, uses 400 words and deletes her account.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000001', 'mia.relay@privaterelay.appleid.com');
insert into auth.identities (user_id, provider, provider_id, identity_data)
values ('dddddddd-0000-0000-0000-000000000001', 'apple', '000111.mia',
        '{"sub":"000111.mia","email":"mia.relay@privaterelay.appleid.com"}');
select public.record_usage('dddddddd-0000-0000-0000-000000000001', gen_random_uuid(), 400);
select is(pg_temp.delete_account('dddddddd-0000-0000-0000-000000000001'), 'kept',
          'an account with a sign-in is remembered when it is deleted');
select ok((select bool_and(key_hash ~ '^[0-9a-f]{64}$') and count(*) = 2 from public.retired_account_keys),
          'as fingerprints only: one for the Apple id, one for the address');
select is((select count(*)::int from public.usage_events where user_id = 'dddddddd-0000-0000-0000-000000000001'), 0,
          'its own rows are gone');

-- She returns with the same Apple ID, this time sharing her real address.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000002', 'mia@icloud.com');
insert into auth.identities (user_id, provider, provider_id, identity_data)
values ('dddddddd-0000-0000-0000-000000000002', 'apple', '000111.mia', '{"sub":"000111.mia","email":"mia@icloud.com"}');
select results_eq(
  $$ select plan, words_this_week, remaining from public.quota_status('dddddddd-0000-0000-0000-000000000002') $$,
  $$ values ('basic', 400, 600) $$,
  'the same Apple ID carries on with the words it had used');
select public.record_usage('dddddddd-0000-0000-0000-000000000002', gen_random_uuid(), 100);
select is((select remaining from public.quota_status('dddddddd-0000-0000-0000-000000000002')), 500,
          'and its new words count on top');

-- Ned is somebody else.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000003', 'ned@example.com');
select is((select remaining from public.quota_status('dddddddd-0000-0000-0000-000000000003')), 1000,
          'a different person starts with a full week');

-- Noa uses the whole week on a tagged Gmail address and comes back on another spelling of it.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000004', 'n.o.a+work@gmail.com');
select public.record_usage('dddddddd-0000-0000-0000-000000000004', gen_random_uuid(), 1000);
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000004');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000005', 'noa@googlemail.com');
select is((select remaining from public.quota_status('dddddddd-0000-0000-0000-000000000005')), 0,
          'another spelling of the same mailbox has no words left either');
-- Deleting again keeps what was carried.
select public.record_usage('dddddddd-0000-0000-0000-000000000005', gen_random_uuid(), 50);
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000005');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000006', 'no.a@gmail.com');
select is((select words_this_week from public.quota_status('dddddddd-0000-0000-0000-000000000006')), 1050,
          'delete, return, delete, return: the words add up');
-- An address nobody confirmed proves nothing.
insert into auth.users (id, email, aud, role, created_at, is_anonymous)
values ('dddddddd-0000-0000-0000-000000000007', 'noa+2@gmail.com', 'authenticated', 'authenticated', now(), false);
select is((select remaining from public.quota_status('dddddddd-0000-0000-0000-000000000007')), 1000,
          'an unconfirmed address matches nothing');

-- Yul's second account is deleted before anything checked it: the chain still holds.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000033', 'yul@example.com');
select public.record_usage('dddddddd-0000-0000-0000-000000000033', gen_random_uuid(), 600);
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000033');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000034', 'yul@example.com');
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000034');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000035', 'yul@example.com');
select is((select words_this_week from public.quota_status('dddddddd-0000-0000-0000-000000000035')), 600,
          'an account deleted before its first check passes on what it would have carried');

-- Ora comes back the week after: last week's words are last week's.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000008', 'ora@example.com');
select public.record_usage('dddddddd-0000-0000-0000-000000000008', gen_random_uuid(), 700);
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000008');
update public.retired_accounts set week_start = week_start - interval '7 days' where id = pg_temp.record_of('ora@example.com');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000009', 'ora@example.com');
select results_eq(
  $$ select words_this_week, remaining from public.quota_status('dddddddd-0000-0000-0000-000000000009') $$,
  $$ values (0, 1000) $$,
  'words are carried only within the week they were used in');

-- Pat comes back after the 30 days.
select pg_temp.sign_up('dddddddd-0000-0000-0000-00000000000a', 'pat@example.com');
select public.record_usage('dddddddd-0000-0000-0000-00000000000a', gen_random_uuid(), 300);
select pg_temp.delete_account('dddddddd-0000-0000-0000-00000000000a');
select ok((select expires_at = retired_at + interval '30 days' from public.retired_accounts
           where id = pg_temp.record_of('pat@example.com')), 'a record is kept for 30 days');
update public.retired_accounts set expires_at = now() - interval '1 second' where id = pg_temp.record_of('pat@example.com');
select pg_temp.sign_up('dddddddd-0000-0000-0000-00000000000b', 'pat@example.com');
select is((select remaining from public.quota_status('dddddddd-0000-0000-0000-00000000000b')), 1000,
          'after that the account is new');
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000003');
select is((select count(*)::int from public.retired_accounts where expires_at < now()), 0,
          'and the next deletion sweeps expired records away');

-- Xan asks for the record to be erased before the 30 days are up.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000031', 'xan@example.com');
select public.record_usage('dddddddd-0000-0000-0000-000000000031', gen_random_uuid(), 500);
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000031');
select is(public.forget_retired(' Xan@Example.com '), 1, 'a record can be erased on request');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000032', 'xan@example.com');
select is((select remaining from public.quota_status('dddddddd-0000-0000-0000-000000000032')), 1000,
          'and then nothing is carried');

-- ---------------------------------------------------------------------------
-- Guests
-- ---------------------------------------------------------------------------

insert into auth.users (id, aud, role, created_at, is_anonymous)
values
  ('dddddddd-0000-0000-0000-00000000000c', 'authenticated', 'authenticated', now(), true),
  ('dddddddd-0000-0000-0000-00000000000d', 'authenticated', 'authenticated', now(), true);
select results_eq(
  $$ select plan, weekly_limit, remaining from public.quota_status('dddddddd-0000-0000-0000-00000000000c') $$,
  $$ values ('basic', 0, 0) $$,
  'a guest has no free words');
update public.entitlements set plan = 'pro', source = 'app_store', expires_at = now() + interval '1 month'
where user_id = 'dddddddd-0000-0000-0000-00000000000d';
select results_eq(
  $$ select plan, remaining from public.quota_status('dddddddd-0000-0000-0000-00000000000d') $$,
  $$ values ('pro', null::int) $$,
  'a guest who bought Pro has Pro');
select is(pg_temp.delete_account('dddddddd-0000-0000-0000-00000000000c'), 'none',
          'a guest has no sign-in to remember');

-- ---------------------------------------------------------------------------
-- The trial
-- ---------------------------------------------------------------------------

-- Tom deletes his account on day 4 of his trial and comes back.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000010', 'tom@example.com');
select public.decide_trial('dddddddd-0000-0000-0000-000000000010', 'granted');
update public.entitlements set trial_started_at = now() - interval '4 days', trial_ends_at = now() + interval '10 days'
where user_id = 'dddddddd-0000-0000-0000-000000000010';
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000010');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000011', 'tom@example.com');
-- The app's first call for the new account.
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000011","role":"authenticated"}';
select results_eq(
  $$ select plan, on_trial, trial_ends_at, trial_started_at from public.my_quota() $$,
  $$ values ('pro', true, now() + interval '10 days', now() - interval '4 days') $$,
  'the trial comes back as it was, in the app''s very first answer');
reset role;
select results_eq(
  $$ select * from public.decide_trial('dddddddd-0000-0000-0000-000000000011', 'granted') $$,
  $$ values ('granted', now() + interval '10 days') $$,
  'and claim-trial can''t start a second one');

-- Uma's iPhone had had its trial; Vic's trial had ended.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000012', 'uma@example.com');
select public.decide_trial('dddddddd-0000-0000-0000-000000000012', 'device_used');
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000012');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000013', 'uma@example.com');
select results_eq(
  $$ select * from public.decide_trial('dddddddd-0000-0000-0000-000000000013', 'granted') $$,
  $$ values ('device_used', null::timestamptz) $$,
  'no trial stays no trial, even on an iPhone that hasn''t had one');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000014', 'vic@example.com');
select public.decide_trial('dddddddd-0000-0000-0000-000000000014', 'granted');
update public.entitlements set trial_started_at = now() - interval '16 days', trial_ends_at = now() - interval '2 days'
where user_id = 'dddddddd-0000-0000-0000-000000000014';
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000014');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000015', 'vic@example.com');
select results_eq(
  $$ select * from public.decide_trial('dddddddd-0000-0000-0000-000000000015', 'granted') $$,
  $$ values ('granted', now() - interval '2 days') $$,
  'a trial that had ended stays ended');
select is((select plan from public.quota_status('dddddddd-0000-0000-0000-000000000015')), 'basic',
          'so the account is on Basic');

-- ---------------------------------------------------------------------------
-- Invites
-- ---------------------------------------------------------------------------

-- Ann shares her code; Fred enters it and dictates, which earns Ann her month.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000020', 'ann@example.com');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000021', 'fred@example.com');
select public.decide_trial(id, 'granted') from auth.users
where id in ('dddddddd-0000-0000-0000-000000000020', 'dddddddd-0000-0000-0000-000000000021');
select set_config('test.ann', (select code from public.referrals where user_id = 'dddddddd-0000-0000-0000-000000000020'), true);
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000021","role":"authenticated"}';
select is(public.redeem_referral(current_setting('test.ann')), 'ok', 'Fred enters Ann''s code');
reset role;
select public.record_usage('dddddddd-0000-0000-0000-000000000021', gen_random_uuid(), 12);
select set_config('test.ann_ends',
  (select trial_ends_at::text from public.entitlements where user_id = 'dddddddd-0000-0000-0000-000000000020'), true);

-- Fred deletes his account and comes back.
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000021');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000022', 'fred@example.com');
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000022","role":"authenticated"}';
select is(public.redeem_referral(current_setting('test.ann')), 'already_redeemed',
          'a returning friend can''t enter a code a second time');
select ok((select on_trial and trial_ends_at = now() + interval '30 days' from public.my_quota()),
          'and still has the month the code gave');
reset role;
select public.record_usage('dddddddd-0000-0000-0000-000000000022', gen_random_uuid(), 30);
select ok((select trial_ends_at = current_setting('test.ann_ends')::timestamptz
           from public.entitlements where user_id = 'dddddddd-0000-0000-0000-000000000020'),
          'whose first dictation, counted once, isn''t counted again');
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000020","role":"authenticated"}';
select results_eq($$ select friends_joined, months_earned from public.my_referrals() $$, $$ values (1, 1) $$,
                  'Ann sees her friend and her month again');
reset role;

-- Ann deletes her account and comes back: her code, her friend and her month are hers again.
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000020');
select results_eq(
  $$ select referrer_id, referrer_retired is not null from public.referral_redemptions
     where user_id = 'dddddddd-0000-0000-0000-000000000022' $$,
  $$ values (null::uuid, true) $$,
  'a deleted owner''s friend is kept as that owner''s');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000023', 'ann@example.com');
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000023","role":"authenticated"}';
select results_eq(
  $$ select code, friends_joined, months_earned from public.my_referrals() $$,
  $$ values (current_setting('test.ann'), 1, 1) $$,
  'a returning owner has the same code, friend and month, so the 12-month cap holds');
reset role;
select ok((select trial_ends_at = current_setting('test.ann_ends')::timestamptz
           from public.entitlements where user_id = 'dddddddd-0000-0000-0000-000000000023'),
          'and the free months that were still to run');

-- Lea's first account is 20 days old: a new one doesn't reopen the 14 days for a code.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000024', 'lea@example.com', interval '20 days');
select public.decide_trial('dddddddd-0000-0000-0000-000000000024', 'granted');
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000024');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000025', 'lea@example.com');
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000025","role":"authenticated"}';
select is((select can_redeem from public.my_referrals()), false, 'a returning account isn''t offered a code field again');
select is(public.redeem_referral(current_setting('test.ann')), 'too_late',
          'the 14 days run from the person''s first account');
reset role;

-- Gil enters Ann's code, dictates, deletes his account and comes back as two accounts of one mailbox.
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000026', 'gil@gmail.com');
select public.decide_trial('dddddddd-0000-0000-0000-000000000026', 'granted');
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000026","role":"authenticated"}';
select is(public.redeem_referral(current_setting('test.ann')), 'ok', 'Gil enters the code Ann got back');
reset role;
select public.record_usage('dddddddd-0000-0000-0000-000000000026', gen_random_uuid(), 9);
select pg_temp.delete_account('dddddddd-0000-0000-0000-000000000026');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000027', 'gil@gmail.com');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000028', 'g.il+2@gmail.com');
select public.quota_status('dddddddd-0000-0000-0000-000000000027');
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000028","role":"authenticated"}';
select is(public.redeem_referral(current_setting('test.ann')), 'already_redeemed',
          'a second account of the same mailbox can''t enter a code either');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000023","role":"authenticated"}';
select results_eq($$ select friends_joined, months_earned from public.my_referrals() $$, $$ values (2, 2) $$,
                  'and the owner counts that friend once');
reset role;

-- ---------------------------------------------------------------------------
-- A restore that fails never fails the caller
-- ---------------------------------------------------------------------------

select pg_temp.sign_up('dddddddd-0000-0000-0000-00000000002f', 'wes@example.com');
select public.record_usage('dddddddd-0000-0000-0000-00000000002f', gen_random_uuid(), 200);
select pg_temp.delete_account('dddddddd-0000-0000-0000-00000000002f');
select pg_temp.sign_up('dddddddd-0000-0000-0000-000000000030', 'wes@example.com');
-- The secret goes missing.
select set_config('test.secret', pg_get_functiondef('public.account_secret()'::regprocedure), true);
create or replace function public.account_secret() returns text language sql stable set search_path = ''
as $$ select null::text $$;
select results_eq(
  $$ select plan, words_this_week, remaining from public.quota_status('dddddddd-0000-0000-0000-000000000030') $$,
  $$ values ('basic', 0, 1000) $$,
  'the quota is still answered');
select results_eq(
  $$ select * from public.decide_trial('dddddddd-0000-0000-0000-000000000030', 'device_used') $$,
  $$ values ('device_used', null::timestamptz) $$,
  'and a trial is still decided');
select is((select restored_at from public.entitlements where user_id = 'dddddddd-0000-0000-0000-000000000030'), null,
          'the account stays unchecked');
select throws_ok($$ select public.retire_account('dddddddd-0000-0000-0000-000000000030') $$, 'P0001', null,
                 'while remembering a deletion says that it failed (delete-account deletes anyway)');
select throws_ok($$ select public.retire_account('dddddddd-0000-0000-0000-00000000000d') $$, 'P0001', null,
                 'for a guest too, so a server that can''t make fingerprints is noticed at once');
-- The secret is back.
do $$ begin execute current_setting('test.secret'); end $$;
select is((select words_this_week from public.quota_status('dddddddd-0000-0000-0000-000000000030')), 200,
          'so it is restored at its next check');

-- ---------------------------------------------------------------------------
-- Only the server
-- ---------------------------------------------------------------------------

select ok(
  (select bool_and(not has_function_privilege(r, f, 'execute'))
   from unnest(array['anon', 'authenticated']) r,
        unnest(array['public.retire_account(uuid)', 'public.restore_account(uuid)', 'public.forget_retired(text)',
                     'public.account_keys(uuid)', 'public.account_key_hash(text, text)', 'public.account_secret()',
                     'public.normal_email(text)', 'public.quota_status(uuid, text)']) f),
  'users can''t call any of it');
select ok(
  has_function_privilege('service_role', 'public.retire_account(uuid)', 'execute')
    and has_function_privilege('service_role', 'public.forget_retired(text)', 'execute')
    and not has_function_privilege('service_role', 'public.account_secret()', 'execute')
    and not has_function_privilege('service_role', 'public.account_key_hash(text, text)', 'execute'),
  'the server can remember and forget, and can''t read the secret');
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000002","role":"authenticated"}';
select throws_ok($$ select * from public.retired_accounts $$, '42501', null, 'users cannot read the records');
select throws_ok($$ select * from public.retired_account_keys $$, '42501', null, 'nor the fingerprints');
select throws_ok($$ update public.entitlements set carried_words = 0 $$, '42501', null,
                 'nor wipe the words they carry');
reset role;

select * from finish();
rollback;
