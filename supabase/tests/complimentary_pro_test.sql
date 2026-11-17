-- pgTAP tests for free Pro (complimentary_pro): a listed address keeps Pro through a trial that
-- runs out, a subscription that ends, a Paddle cancellation and deleting the account; nobody else
-- is affected; and only the server can see or use the list.
-- Run with `supabase test db`.
begin;
select plan(26);

-- A signed-in account whose email address is confirmed (or not yet, for an email-code sign-up).
create function pg_temp.sign_up(p_user uuid, p_email text, p_confirmed boolean default true) returns void
language sql as $$
  insert into auth.users (id, email, aud, role, created_at, is_anonymous, email_confirmed_at)
  values (p_user, p_email, 'authenticated', 'authenticated', now(), false, case when p_confirmed then now() end);
$$;

create function pg_temp.row_of(p_user uuid) returns table (plan text, source text, expires_at timestamptz)
language sql as $$
  select e.plan, e.source, e.expires_at from public.entitlements e where e.user_id = p_user;
$$;

select ok(exists (select 1 from public.complimentary_pro where email = 'mironenkoantony@gmail.com' and reason = 'owner'),
          'the owner is on the list');

insert into public.complimentary_pro (email, reason) values ('boss@example.com', 'test');
select throws_ok($$ insert into public.complimentary_pro (email, reason) values ('Boss2@Example.com', 'test') $$,
                 '23514', null, 'addresses are kept in lower case');

-- ---------------------------------------------------------------------------
-- A listed account
-- ---------------------------------------------------------------------------

select pg_temp.sign_up('cccccccc-0000-0000-0000-000000000001', 'boss@example.com');
select results_eq($$ select * from pg_temp.row_of('cccccccc-0000-0000-0000-000000000001') $$,
                  $$ values ('pro', 'grant', null::timestamptz) $$,
                  'a listed address is Pro from sign-up, with no end date');
select results_eq(
  $$ select plan, on_trial, weekly_limit, remaining from public.quota_status('cccccccc-0000-0000-0000-000000000001') $$,
  $$ values ('pro', false, null::integer, null::integer) $$,
  'the quota says Pro with no limit, and not a trial');

-- The trial decision and a trial that runs out change nothing.
select public.decide_trial('cccccccc-0000-0000-0000-000000000001', 'granted');
update public.entitlements set trial_ends_at = now() - interval '1 day'
where user_id = 'cccccccc-0000-0000-0000-000000000001';
select is((select plan from public.quota_status('cccccccc-0000-0000-0000-000000000001')), 'pro',
          'still Pro after the trial has run out');

-- An App Store subscription: its transaction is recorded, the end date isn't.
update public.entitlements
set plan = 'pro', source = 'app_store', expires_at = now() + interval '30 days', original_transaction_id = 'tx-boss'
where user_id = 'cccccccc-0000-0000-0000-000000000001';
select results_eq(
  $$ select plan, source, expires_at, original_transaction_id from public.entitlements
     where user_id = 'cccccccc-0000-0000-0000-000000000001' $$,
  $$ values ('pro', 'app_store', null::timestamptz, 'tx-boss') $$,
  'a purchase records its transaction but no end date');

-- The subscription expires…
update public.entitlements set expires_at = now() - interval '1 day'
where user_id = 'cccccccc-0000-0000-0000-000000000001';
select is((select plan from public.quota_status('cccccccc-0000-0000-0000-000000000001')), 'pro',
          'still Pro when the subscription has expired');

-- …or is taken off the account (what releaseSubscription writes after a refund or a transfer).
update public.entitlements
set plan = 'basic', source = 'trial', expires_at = null, original_transaction_id = null
where user_id = 'cccccccc-0000-0000-0000-000000000001';
select results_eq($$ select * from pg_temp.row_of('cccccccc-0000-0000-0000-000000000001') $$,
                  $$ values ('pro', 'grant', null::timestamptz) $$,
                  'still Pro when the subscription is taken off');

-- A Paddle subscription that starts and then ends.
select public.apply_paddle_subscription('cccccccc-0000-0000-0000-000000000001', 'sub_boss', 'ctm_boss', true,
                                        now() + interval '30 days');
select public.apply_paddle_subscription('cccccccc-0000-0000-0000-000000000001', 'sub_boss', 'ctm_boss', false,
                                        now() - interval '1 day');
select is((select plan from public.quota_status('cccccccc-0000-0000-0000-000000000001')), 'pro',
          'still Pro when a Paddle subscription ends');

-- On the free plan an iPhone's week is counted; for a listed account it isn't.
select public.record_usage('cccccccc-0000-0000-0000-000000000001', gen_random_uuid(), 5000, 'b0550000-0000-4000-8000-000000000001');
select is((select count(*)::int from public.device_usage where device = public.device_key('b0550000-0000-4000-8000-000000000001')), 0,
          'a listed account''s words are not counted against its iPhone');
select is((select remaining from public.quota_status('cccccccc-0000-0000-0000-000000000001', 'b0550000-0000-4000-8000-000000000001')), null,
          'and 5,000 words in a week leave it unlimited');

-- Deleted and made again, with the address typed in another case.
delete from auth.users where id = 'cccccccc-0000-0000-0000-000000000001';
select pg_temp.sign_up('cccccccc-0000-0000-0000-000000000002', 'Boss@Example.com');
select results_eq($$ select * from pg_temp.row_of('cccccccc-0000-0000-0000-000000000002') $$,
                  $$ values ('pro', 'grant', null::timestamptz) $$,
                  'an account made again with the same address (in any case) is Pro');

-- What the app reads.
set local role authenticated;
set local request.jwt.claims = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select results_eq($$ select plan, on_trial, weekly_limit from public.my_quota() $$,
                  $$ values ('pro', false, null::integer) $$,
                  'my_quota shows Pro to the app');
select results_eq($$ select plan, source, expires_at from public.entitlements $$,
                  $$ values ('pro', 'grant', null::timestamptz) $$,
                  'and the offer screen reads a plan with no end date');
reset role;

-- ---------------------------------------------------------------------------
-- Everyone else
-- ---------------------------------------------------------------------------

-- An email-code sign-up exists before its code is entered.
insert into public.complimentary_pro (email, reason) values ('later@example.com', 'test');
select pg_temp.sign_up('cccccccc-0000-0000-0000-000000000003', 'later@example.com', false);
select is((select plan from pg_temp.row_of('cccccccc-0000-0000-0000-000000000003')), 'basic',
          'an address nobody has confirmed yet gets nothing');
update auth.users set email_confirmed_at = now() where id = 'cccccccc-0000-0000-0000-000000000003';
select is((select plan from public.quota_status('cccccccc-0000-0000-0000-000000000003')), 'pro',
          'once confirmed, the first quota check after sign-in gives it Pro');

-- A guest carrying a listed address gets nothing.
insert into auth.users (id, email, aud, role, created_at, is_anonymous, email_confirmed_at)
values ('cccccccc-0000-0000-0000-000000000004', 'boss@example.com', 'authenticated', 'authenticated', now(), true, now());
select is((select plan from pg_temp.row_of('cccccccc-0000-0000-0000-000000000004')), 'basic',
          'a guest never gets free Pro');

-- Someone who isn't listed is untouched.
select pg_temp.sign_up('cccccccc-0000-0000-0000-000000000005', 'someone@example.com');
select results_eq($$ select * from pg_temp.row_of('cccccccc-0000-0000-0000-000000000005') $$,
                  $$ values ('basic', 'trial', null::timestamptz) $$,
                  'an address that is not listed starts on Basic as before');
update public.entitlements set plan = 'pro', source = 'app_store', expires_at = now() - interval '1 day'
where user_id = 'cccccccc-0000-0000-0000-000000000005';
select is((select plan from public.quota_status('cccccccc-0000-0000-0000-000000000005')), 'basic',
          'and its expired subscription still ends');
select public.record_usage('cccccccc-0000-0000-0000-000000000005', gen_random_uuid(), 300, 'b0550000-0000-4000-8000-000000000002');
select is((select words from public.device_usage where device = public.device_key('b0550000-0000-4000-8000-000000000002')), 300,
          'and its free words still count for its iPhone');

-- Taking it away: the address comes off the list and the row goes back to Basic.
delete from public.complimentary_pro where email = 'boss@example.com';
update public.entitlements set plan = 'basic', source = 'trial' where user_id = 'cccccccc-0000-0000-0000-000000000002';
select is((select plan from public.quota_status('cccccccc-0000-0000-0000-000000000002')), 'basic',
          'an address taken off the list can be set back to Basic');

-- ---------------------------------------------------------------------------
-- Who can see the list
-- ---------------------------------------------------------------------------

select ok(not has_function_privilege('authenticated', 'public.has_complimentary_pro(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.has_complimentary_pro(uuid)', 'execute'),
          'apps cannot ask who has free Pro');
select ok(has_function_privilege('service_role', 'public.has_complimentary_pro(uuid)', 'execute'),
          'the server can');
set local role authenticated;
set local request.jwt.claims = '{"sub":"cccccccc-0000-0000-0000-000000000005","role":"authenticated"}';
select throws_ok($$ select * from public.complimentary_pro $$, '42501', null, 'users cannot read the list');
select throws_ok($$ insert into public.complimentary_pro (email, reason) values ('me@example.com', 'x') $$,
                 '42501', null, 'or add themselves to it');
reset role;
set local role anon;
select throws_ok($$ select * from public.complimentary_pro $$, '42501', null, 'nor can anyone signed out');
reset role;

select * from finish();
rollback;
