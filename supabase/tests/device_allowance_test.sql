-- pgTAP tests for the weekly allowance per iPhone: accounts on one device share one free week, an
-- account on two devices isn't counted twice, Pro words never use up a device, calls that name no
-- device work as they always did, and only the server can touch any of it.
-- Run with `supabase test db`.
begin;
select plan(31);

-- Ava and Ben are on Basic and share Ava's iPhone; Cal has an iPhone and an iPad; Pia is on Pro.
insert into auth.users (id, email, aud, role, created_at, is_anonymous)
values
  ('eeeeeeee-0000-0000-0000-000000000001', 'ava@example.com', 'authenticated', 'authenticated', now(), false),
  ('eeeeeeee-0000-0000-0000-000000000002', 'ben@example.com', 'authenticated', 'authenticated', now(), false),
  ('eeeeeeee-0000-0000-0000-000000000003', 'cal@example.com', 'authenticated', 'authenticated', now(), false),
  ('eeeeeeee-0000-0000-0000-000000000004', 'pia@example.com', 'authenticated', 'authenticated', now(), false),
  ('eeeeeeee-0000-0000-0000-000000000005', 'dee@example.com', 'authenticated', 'authenticated', now(), false),
  ('eeeeeeee-0000-0000-0000-000000000006', null, 'authenticated', 'authenticated', now(), true);
update public.entitlements set plan = 'pro', source = 'app_store', expires_at = now() + interval '1 month'
where user_id = 'eeeeeeee-0000-0000-0000-000000000004';

-- The ids the apps keep: Ava's iPhone, Cal's iPhone and iPad, Pia's iPad.
select set_config('test.phone', '11111111-1111-4111-8111-111111111111', true);
select set_config('test.cal_phone', '22222222-2222-4222-8222-222222222222', true);
select set_config('test.cal_pad', '33333333-3333-4333-8333-333333333333', true);
select set_config('test.pia_pad', '44444444-4444-4444-8444-444444444444', true);

select ok(public.device_key(current_setting('test.phone')) ~ '^[0-9a-f]{64}$', 'a device is kept as a hash of its id');
select is(public.device_key('  ' || upper(current_setting('test.phone')) || ' '), public.device_key(current_setting('test.phone')),
          'however the id is written');
select is(public.device_key('my-iphone'), null, 'anything but an id as the app makes it is no device');

-- ---------------------------------------------------------------------------
-- Two accounts, one iPhone
-- ---------------------------------------------------------------------------

select public.record_usage('eeeeeeee-0000-0000-0000-000000000001', gen_random_uuid(), 600, current_setting('test.phone'));
select results_eq(
  $$ select words_this_week, remaining from public.quota_status('eeeeeeee-0000-0000-0000-000000000001', current_setting('test.phone')) $$,
  $$ values (600, 400) $$,
  'an account''s words count as before on its own iPhone');
select results_eq(
  $$ select words_this_week, remaining from public.quota_status('eeeeeeee-0000-0000-0000-000000000002', current_setting('test.phone')) $$,
  $$ values (600, 400) $$,
  'a second account on that iPhone has only what the iPhone has left');
select is((select remaining from public.quota_status('eeeeeeee-0000-0000-0000-000000000002')), 1000,
          'a call that names no device goes by the account alone, as before');

-- Ben uses the rest: the iPhone's week is over for both.
select public.record_usage('eeeeeeee-0000-0000-0000-000000000002', gen_random_uuid(), 400, current_setting('test.phone'));
select is((select remaining from public.quota_status('eeeeeeee-0000-0000-0000-000000000001', current_setting('test.phone'))), 0,
          'the first account can''t go on from where the second stopped');
select is((select remaining from public.quota_status('eeeeeeee-0000-0000-0000-000000000002', current_setting('test.phone'))), 0,
          'nor the second');
select is((select remaining from public.quota_status('eeeeeeee-0000-0000-0000-000000000001', current_setting('test.cal_pad'))), 400,
          'on another device the first account has its own words left');
select results_eq(
  $$ select allowed, reason from public.dictation_preflight('eeeeeeee-0000-0000-0000-000000000002', 'dictate',
       p_device => current_setting('test.phone')) $$,
  $$ values (false, 'limit_reached') $$,
  'the dictation preflight refuses on a used-up iPhone');
select results_eq(
  $$ select allowed, reason from public.cleanup_preflight('eeeeeeee-0000-0000-0000-000000000002',
       p_device => current_setting('test.phone')) $$,
  $$ values (false, 'limit_reached') $$,
  'and so does the cleanup preflight');
select results_eq(
  $$ select allowed, remaining from public.dictation_preflight('eeeeeeee-0000-0000-0000-000000000002', 'dictate') $$,
  $$ values (true, 600) $$,
  'while a build that sends no id is checked by the account alone');

-- What the app shows is what the server enforces.
set local role authenticated;
set local request.jwt.claims = '{"sub":"eeeeeeee-0000-0000-0000-000000000002","role":"authenticated"}';
select results_eq(
  $$ select words_this_week, remaining from public.my_quota(current_setting('test.phone')) $$,
  $$ values (1000, 0) $$,
  'my_quota answers for the iPhone it is asked from');
select is((select remaining from public.my_quota()), 600, 'and for the account alone when a build sends no id');
reset role;

-- ---------------------------------------------------------------------------
-- One account, two devices
-- ---------------------------------------------------------------------------

select public.record_usage('eeeeeeee-0000-0000-0000-000000000003', gen_random_uuid(), 300, current_setting('test.cal_phone'));
select public.record_usage('eeeeeeee-0000-0000-0000-000000000003', gen_random_uuid(), 200, current_setting('test.cal_pad'));
select results_eq(
  $$ select (select words_this_week from public.quota_status('eeeeeeee-0000-0000-0000-000000000003', current_setting('test.cal_phone'))),
            (select words_this_week from public.quota_status('eeeeeeee-0000-0000-0000-000000000003', current_setting('test.cal_pad'))) $$,
  $$ values (500, 500) $$,
  'an account''s words on two devices are counted once');
select results_eq(
  $$ select (select words from public.device_usage where device = public.device_key(current_setting('test.cal_phone'))),
            (select words from public.device_usage where device = public.device_key(current_setting('test.cal_pad'))) $$,
  $$ values (300, 200) $$,
  'and each device has what was dictated on it');

-- A dictation's calls: a first count, a larger one, the same again, a smaller one.
select set_config('test.dictation', gen_random_uuid()::text, true);
select public.record_usage('eeeeeeee-0000-0000-0000-000000000005', current_setting('test.dictation')::uuid, 5, current_setting('test.pia_pad'));
select public.record_usage('eeeeeeee-0000-0000-0000-000000000005', current_setting('test.dictation')::uuid, 12, current_setting('test.pia_pad'));
select public.record_usage('eeeeeeee-0000-0000-0000-000000000005', current_setting('test.dictation')::uuid, 12, current_setting('test.pia_pad'));
select public.record_usage('eeeeeeee-0000-0000-0000-000000000005', current_setting('test.dictation')::uuid, 8, current_setting('test.pia_pad'));
select results_eq(
  $$ select (select words from public.usage_events where dictation_id = current_setting('test.dictation')::uuid),
            (select words from public.device_usage where device = public.device_key(current_setting('test.pia_pad'))) $$,
  $$ values (12, 12) $$,
  'a dictation counted in several calls adds its words to the device once');

-- ---------------------------------------------------------------------------
-- Pro, guests, another week
-- ---------------------------------------------------------------------------

-- Pia, on Pro, dictates a lot on the iPad Dee (on Basic) also uses.
select public.record_usage('eeeeeeee-0000-0000-0000-000000000004', gen_random_uuid(), 5000, current_setting('test.pia_pad'));
select is((select words from public.device_usage where device = public.device_key(current_setting('test.pia_pad'))), 12,
          'words dictated on Pro don''t count against the device');
select is((select remaining from public.quota_status('eeeeeeee-0000-0000-0000-000000000005', current_setting('test.pia_pad'))), 988,
          'so they don''t use up a Basic account''s week on it');
select results_eq(
  $$ select plan, words_this_week, remaining from public.quota_status('eeeeeeee-0000-0000-0000-000000000004', current_setting('test.phone')) $$,
  $$ values ('pro', 5000, null::int) $$,
  'and Pro has no limit on a used-up iPhone either');

select results_eq(
  $$ select weekly_limit, remaining from public.quota_status('eeeeeeee-0000-0000-0000-000000000006', current_setting('test.cal_pad')) $$,
  $$ values (0, 0) $$,
  'a guest has no free words on any device');

-- Next week the iPhone starts over.
update public.device_usage set week_start = week_start - interval '7 days'
where device = public.device_key(current_setting('test.phone'));
select is((select remaining from public.quota_status('eeeeeeee-0000-0000-0000-000000000002', current_setting('test.phone'))), 600,
          'a device''s words belong to the week they were used in');
select public.record_usage('eeeeeeee-0000-0000-0000-000000000002', gen_random_uuid(), 10, current_setting('test.phone'));
select results_eq(
  $$ select words, week_start = public.week_start(now()) from public.device_usage
     where device = public.device_key(current_setting('test.phone')) $$,
  $$ values (10, true) $$,
  'and its count starts again with the first word of a new week');

-- ---------------------------------------------------------------------------
-- Calls that name no device, or no real one
-- ---------------------------------------------------------------------------

select public.record_usage('eeeeeeee-0000-0000-0000-000000000003', gen_random_uuid(), 40);
select public.record_usage('eeeeeeee-0000-0000-0000-000000000003', gen_random_uuid(), 40, 'my-iphone');
select results_eq(
  $$ select (select words_this_week from public.quota_status('eeeeeeee-0000-0000-0000-000000000003')),
            (select count(*)::int from public.device_usage) $$,
  $$ values (580, 4) $$,
  'usage without a device, or with a made-up one, counts for the account and for no device');
select is((select words_this_week from public.quota_status('eeeeeeee-0000-0000-0000-000000000003', 'my-iphone')), 580,
          'and a made-up device is asked about as if none was named');
select results_eq(
  $$ select allowed, remaining from public.cleanup_preflight('eeeeeeee-0000-0000-0000-000000000003') $$,
  $$ values (true, 420) $$,
  'the cleanup preflight still takes just an account');
select results_eq(
  $$ select allowed, remaining from public.cleanup_preflight('eeeeeeee-0000-0000-0000-000000000003', 10) $$,
  $$ values (true, 420) $$,
  'or an account and a limit');

-- ---------------------------------------------------------------------------
-- Only the server
-- ---------------------------------------------------------------------------

select ok(
  (select bool_and(not has_function_privilege(r, f, 'execute'))
   from unnest(array['anon', 'authenticated']) r,
        unnest(array['public.quota_status(uuid, text)', 'public.record_usage(uuid, uuid, integer, text)',
                     'public.cleanup_preflight(uuid, integer, text)',
                     'public.dictation_preflight(uuid, text, uuid, integer, integer, text)',
                     'public.device_key(text)']) f),
  'users can''t call the quota, the usage or the preflights');
select ok(
  has_function_privilege('authenticated', 'public.my_quota(text)', 'execute')
    and not has_function_privilege('anon', 'public.my_quota(text)', 'execute'),
  'a signed-in user can ask for their own quota, and nobody else can');
select ok(
  (select bool_and(has_function_privilege('service_role', f, 'execute'))
   from unnest(array['public.quota_status(uuid, text)', 'public.record_usage(uuid, uuid, integer, text)',
                     'public.cleanup_preflight(uuid, integer, text)',
                     'public.dictation_preflight(uuid, text, uuid, integer, integer, text)']) f),
  'the server can call all four');
set local role authenticated;
set local request.jwt.claims = '{"sub":"eeeeeeee-0000-0000-0000-000000000001","role":"authenticated"}';
select throws_ok($$ select * from public.device_usage $$, '42501', null, 'users cannot read device counts');
reset role;

select * from finish();
rollback;
