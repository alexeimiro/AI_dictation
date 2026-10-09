-- pgTAP tests for RLS, quota and sign-up helpers. Run with `supabase test db`.
begin;
select plan(24);

-- Two users (the auth trigger creates their profile, trial entitlement and referral code).
insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at, aud, role)
values
  ('11111111-1111-1111-1111-111111111111', 'alice@example.com', '{"full_name":"Alice"}', now(), 'authenticated', 'authenticated'),
  ('22222222-2222-2222-2222-222222222222', 'bob@example.com', '{}', null, 'authenticated', 'authenticated');

select is((select full_name from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
          'Alice', 'profile created from sign-up metadata');
select ok((select trial_ends_at between now() + interval '13 days 23 hours' and now() + interval '14 days 1 hour'
           from public.entitlements where user_id = '11111111-1111-1111-1111-111111111111'),
          'new users get a 14-day trial');
select is((select count(*)::int from public.referrals), 2, 'each user gets a referral code');

-- Quota: trial users are Pro (no limit).
select is((select plan from public.quota_status('11111111-1111-1111-1111-111111111111')), 'pro', 'trial counts as pro');
select is((select remaining from public.quota_status('11111111-1111-1111-1111-111111111111')), null::int,
          'pro has no weekly limit');

-- After the trial: Basic with 1,000 words a week.
update public.entitlements set trial_ends_at = now() - interval '1 day'
where user_id = '11111111-1111-1111-1111-111111111111';
select public.record_usage('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 300);
select public.record_usage('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 300);
select is((select words_this_week from public.quota_status('11111111-1111-1111-1111-111111111111')), 300,
          'record_usage is idempotent per dictation');
select is((select remaining from public.quota_status('11111111-1111-1111-1111-111111111111')), 700,
          'basic users have 1,000 words a week');
select public.record_usage('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000002', 800);
select is((select reason from public.cleanup_preflight('11111111-1111-1111-1111-111111111111')), 'limit_reached',
          'preflight blocks when the weekly limit is used up');

-- Usage from last week doesn't count.
update public.usage_events set created_at = public.week_start(now()) - interval '1 hour'
where user_id = '11111111-1111-1111-1111-111111111111';
select is((select remaining from public.quota_status('11111111-1111-1111-1111-111111111111')), 1000,
          'the weekly counter resets');

-- Rate limit: 40 cleanup calls per minute.
-- A loop, because a set-returning function in a query may be evaluated only once.
do $$
begin
  for i in 1..39 loop
    perform public.cleanup_preflight('22222222-2222-2222-2222-222222222222');
  end loop;
end;
$$;
select is((select count from public.rate_limits where user_id = '22222222-2222-2222-2222-222222222222'), 39,
          'each preflight counts against the per-minute limit');
select ok((select allowed from public.cleanup_preflight('22222222-2222-2222-2222-222222222222')),
          'the 40th call is allowed');
select is((select reason from public.cleanup_preflight('22222222-2222-2222-2222-222222222222')), 'rate_limited',
          'the 41st call in a minute is rate limited');

-- Weeks start on Sunday 00:00 Pacific.
select is(extract(dow from public.week_start('2026-10-08 12:00:00+00') at time zone 'America/Los_Angeles')::int, 0,
          'week starts on Sunday');
select is((public.week_start('2026-10-08 12:00:00+00') at time zone 'America/Los_Angeles')::time, '00:00'::time,
          'week starts at midnight Pacific');

-- Sign-in helpers.
select is((select account_exists from public.auth_lookup('ALICE@example.com ')), true, 'auth_lookup finds accounts');
select is((select account_exists from public.auth_lookup('nobody@example.com')), false, 'auth_lookup misses');
select ok((select public.consume_bucket('t:1', 2) and public.consume_bucket('t:1', 2)
           and not public.consume_bucket('t:1', 2)), 'request buckets cap requests');

-- Data owned by each user.
insert into public.notes (id, user_id, title) values
  ('aaaaaaaa-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', 'Alice note'),
  ('bbbbbbbb-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222', 'Bob note');

-- As Alice.
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select is((select count(*)::int from public.notes), 1, 'users only see their own notes');
select is((select count(*)::int from public.entitlements), 1, 'users only see their own entitlement');
select throws_ok($$ update public.entitlements set plan = 'pro' $$, '42501', null,
                 'users cannot change their plan');
select throws_ok($$ insert into public.usage_events (user_id, dictation_id, words)
                    values ('11111111-1111-1111-1111-111111111111', gen_random_uuid(), 0) $$,
                 '42501', null, 'users cannot write usage');
select throws_ok($$ select * from public.quota_status('22222222-2222-2222-2222-222222222222') $$,
                 '42501', null, 'users cannot query other users'' quota');
select throws_ok($$ insert into public.notes (id, user_id, title)
                    values (gen_random_uuid(), '22222222-2222-2222-2222-222222222222', 'sneaky') $$,
                 '42501', null, 'users cannot write rows for someone else');
select is((select remaining from public.my_quota()), 1000, 'my_quota reports the caller''s own quota');

reset role;
select * from finish();
rollback;
