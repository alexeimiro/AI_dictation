-- pgTAP tests for RLS, quota, the dictation preflight and sign-up helpers. Run with `supabase test db`.
begin;
select plan(69);

-- Two users (the auth trigger creates their profile, an entitlement on Basic and a referral code;
-- claim-trial decides the trial, through decide_trial).
insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at, aud, role)
values
  ('11111111-1111-1111-1111-111111111111', 'alice@example.com', '{"full_name":"Alice"}', now(), 'authenticated', 'authenticated'),
  ('22222222-2222-2222-2222-222222222222', 'bob@example.com', '{}', null, 'authenticated', 'authenticated');

select is((select full_name from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
          'Alice', 'profile created from sign-up metadata');
select results_eq(
  $$ select trial_ends_at, trial_started_at, trial_check from public.entitlements
     where user_id = '11111111-1111-1111-1111-111111111111' $$,
  $$ values (null::timestamptz, null::timestamptz, null::text) $$,
  'new users start without a trial until claim-trial decides it');
select public.decide_trial('11111111-1111-1111-1111-111111111111', 'granted');
select ok((select trial_ends_at between now() + interval '13 days 23 hours' and now() + interval '14 days 1 hour'
           from public.entitlements where user_id = '11111111-1111-1111-1111-111111111111'),
          'a granted trial is 14 days');
select is((select count(*)::int from public.referrals
           where user_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')),
          2, 'each user gets a referral code');

-- Styles: Word for word by default; the four the model writes, and the styles older builds still write.
select is((select default_style from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
          'verbatim', 'new profiles default to Word for word');
select lives_ok($$ update public.profiles set default_style = 'grammar'
                   where id = '22222222-2222-2222-2222-222222222222' $$, 'Improve my grammar is a valid style');
select lives_ok($$ update public.profiles set default_style = 'professional'
                   where id = '22222222-2222-2222-2222-222222222222' $$, 'Professional is a valid style');
select lives_ok($$ update public.profiles set default_style = 'chat'
                   where id = '22222222-2222-2222-2222-222222222222' $$, 'Casual is stored as chat');
select lives_ok($$ update public.profiles set default_style = 'concise'
                   where id = '22222222-2222-2222-2222-222222222222' $$, 'Concise is a valid style');
select lives_ok($$ update public.profiles set default_style = 'casual'
                   where id = '22222222-2222-2222-2222-222222222222' $$, 'a style older builds write is still valid');
select throws_ok($$ update public.profiles set default_style = 'shouty'
                    where id = '22222222-2222-2222-2222-222222222222' $$,
                 '23514', null, 'an unknown style is rejected');

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

-- Dictation preflight. Carol is on her trial (no word limit), Dave is on Basic. `now()` is fixed
-- for the transaction, so every call below falls in the same minute.
insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at, aud, role)
values
  ('33333333-3333-3333-3333-333333333333', 'carol@example.com', '{}', now(), 'authenticated', 'authenticated'),
  ('44444444-4444-4444-4444-444444444444', 'dave@example.com', '{}', now(), 'authenticated', 'authenticated');
select public.decide_trial('33333333-3333-3333-3333-333333333333', 'granted');
update public.entitlements set trial_ends_at = now() - interval '1 day'
where user_id = '44444444-4444-4444-4444-444444444444';

select results_eq(
  $$ select allowed, reason, attempt from public.dictation_preflight(
       '33333333-3333-3333-3333-333333333333', 'dictate', 'cccccccc-0000-0000-0000-000000000001') $$,
  $$ values (true, null::text, 1) $$,
  'a dictation''s first call is allowed as attempt 1');
select results_eq(
  $$ select allowed, attempt from public.dictation_preflight('33333333-3333-3333-3333-333333333333', 'dictate') $$,
  $$ values (true, null::int) $$,
  'calls without a dictation id are not numbered');

-- Rate limit: 40 calls per minute per scope. Two so far.
do $$
begin
  for i in 1..37 loop
    perform public.dictation_preflight('33333333-3333-3333-3333-333333333333', 'dictate');
  end loop;
end;
$$;
select ok((select allowed from public.dictation_preflight('33333333-3333-3333-3333-333333333333', 'dictate')),
          'the 40th dictate call is allowed');
select results_eq(
  $$ select reason, attempt from public.dictation_preflight(
       '33333333-3333-3333-3333-333333333333', 'dictate', 'cccccccc-0000-0000-0000-000000000002') $$,
  $$ values ('rate_limited'::text, null::int) $$,
  'the 41st dictate call in a minute is rate limited, and not numbered');

-- Later calls of an allowed dictation skip the full bucket, up to 6 calls in all.
select results_eq(
  $$ select allowed, attempt from public.dictation_preflight(
       '33333333-3333-3333-3333-333333333333', 'dictate', 'cccccccc-0000-0000-0000-000000000001') $$,
  $$ values (true, 2) $$,
  'a dictation''s second call is allowed while the bucket is full');
do $$
begin
  for i in 3..5 loop
    perform public.dictation_preflight('33333333-3333-3333-3333-333333333333', 'dictate',
                                       'cccccccc-0000-0000-0000-000000000001');
  end loop;
end;
$$;
select is((select attempt from public.dictation_preflight(
             '33333333-3333-3333-3333-333333333333', 'dictate', 'cccccccc-0000-0000-0000-000000000001')),
          6, 'calls are numbered per dictation');
select results_eq(
  $$ select reason, attempt from public.dictation_preflight(
       '33333333-3333-3333-3333-333333333333', 'dictate', 'cccccccc-0000-0000-0000-000000000001') $$,
  $$ values ('too_many_attempts'::text, null::int) $$,
  'a dictation''s 7th call is refused, and not numbered');
select is((select count from public.request_buckets where key = 'dictate:33333333-3333-3333-3333-333333333333'),
          41, 'only a dictation''s first call counts against the bucket');

-- The rate-limited first call of dictation 2 wasn't counted: with room in the bucket it is attempt 1.
-- Its row dates from that refusal, here 9 minutes ago; the 10 minutes start at the allowed call.
update public.dictation_attempts set window_start = now() - interval '9 minutes'
where dictation_id = 'cccccccc-0000-0000-0000-000000000002' and scope = 'dictate';
select results_eq(
  $$ select allowed, attempt from public.dictation_preflight(
       '33333333-3333-3333-3333-333333333333', 'dictate', 'cccccccc-0000-0000-0000-000000000002',
       p_per_minute => 100) $$,
  $$ values (true, 1) $$,
  'a rate-limited call is not counted as an attempt');
select is((select window_start from public.dictation_attempts
           where dictation_id = 'cccccccc-0000-0000-0000-000000000002' and scope = 'dictate'),
          now(), 'a dictation''s 10 minutes start at its first allowed call, not at a refused one');

-- Dictation 1's later calls skip the bucket for 10 minutes from its first allowed call. After that
-- its next call starts over, so a dictation can't keep its skipped calls longer.
update public.dictation_attempts set window_start = now() - interval '9 minutes'
where dictation_id = 'cccccccc-0000-0000-0000-000000000001' and scope = 'dictate';
select is((select reason from public.dictation_preflight(
             '33333333-3333-3333-3333-333333333333', 'dictate', 'cccccccc-0000-0000-0000-000000000001',
             p_per_minute => 100)),
          'too_many_attempts', 'a dictation keeps its count for 10 minutes');
update public.dictation_attempts set window_start = now() - interval '11 minutes'
where dictation_id = 'cccccccc-0000-0000-0000-000000000001' and scope = 'dictate';
select results_eq(
  $$ select allowed, attempt from public.dictation_preflight(
       '33333333-3333-3333-3333-333333333333', 'dictate', 'cccccccc-0000-0000-0000-000000000001',
       p_per_minute => 100) $$,
  $$ values (true, 1) $$,
  'a dictation''s calls start over 10 minutes after its first');
select is((select count from public.request_buckets where key = 'dictate:33333333-3333-3333-3333-333333333333'),
          43, 'and its first call counts against the bucket again');
select is((select attempt from public.dictation_preflight(
             '33333333-3333-3333-3333-333333333333', 'dictate', 'cccccccc-0000-0000-0000-000000000001')),
          2, 'the 10 minutes restart at that call');
-- Later calls don't move the start: the 10 minutes don't slide.
update public.dictation_attempts set window_start = now() - interval '5 minutes'
where dictation_id = 'cccccccc-0000-0000-0000-000000000001' and scope = 'dictate';
do $$
begin
  perform public.dictation_preflight('33333333-3333-3333-3333-333333333333', 'dictate',
                                     'cccccccc-0000-0000-0000-000000000001');
end;
$$;
select is((select window_start from public.dictation_attempts
           where dictation_id = 'cccccccc-0000-0000-0000-000000000001' and scope = 'dictate'),
          now() - interval '5 minutes', 'a dictation''s later calls don''t move the start of its 10 minutes');

-- 2% of calls with a dictation delete the attempts whose 10 minutes are up. In PostgreSQL 17 the
-- first random() after this seed is 0.0047, so the next call runs the cleanup.
insert into public.dictation_attempts (user_id, scope, dictation_id, calls, window_start)
values
  ('33333333-3333-3333-3333-333333333333', 'dictate', 'cccccccc-0000-0000-0000-000000000009', 3,
   now() - interval '11 minutes'),
  ('33333333-3333-3333-3333-333333333333', 'dictate', 'cccccccc-0000-0000-0000-000000000010', 3,
   now() - interval '9 minutes');
select setseed(-0.9117);
do $$
begin
  perform public.dictation_preflight('33333333-3333-3333-3333-333333333333', 'dictate',
                                     'cccccccc-0000-0000-0000-000000000003', p_per_minute => 100);
end;
$$;
select results_eq(
  $$ select dictation_id from public.dictation_attempts
     where dictation_id in ('cccccccc-0000-0000-0000-000000000009', 'cccccccc-0000-0000-0000-000000000010') $$,
  $$ values ('cccccccc-0000-0000-0000-000000000010'::uuid) $$,
  'the cleanup deletes attempts whose 10 minutes are up and keeps the rest');

-- Scopes have their own buckets and attempt counts, and `transcribe` uses the transcribe function's keys.
select ok((select allowed from public.dictation_preflight('33333333-3333-3333-3333-333333333333', 'transcribe')),
          'a full dictate bucket doesn''t limit another scope');
select is((select count from public.request_buckets where key = 'transcribe:33333333-3333-3333-3333-333333333333'),
          1, 'the transcribe scope counts in transcribe''s bucket');
select results_eq(
  $$ select allowed, attempt from public.dictation_preflight(
       '33333333-3333-3333-3333-333333333333', 'transcribe', 'cccccccc-0000-0000-0000-000000000001') $$,
  $$ values (true, 1) $$,
  'a dictation''s dictate calls don''t let it skip another scope''s bucket');

-- A lower limit (anonymous callers get 10 a minute).
do $$
begin
  for i in 1..10 loop
    perform public.dictation_preflight('33333333-3333-3333-3333-333333333333', 'live-token', p_per_minute => 10);
  end loop;
end;
$$;
select is((select reason from public.dictation_preflight(
             '33333333-3333-3333-3333-333333333333', 'live-token', p_per_minute => 10)),
          'rate_limited', 'with a limit of 10, the 11th call is rate limited');

select throws_ok($$ select * from public.dictation_preflight('33333333-3333-3333-3333-333333333333', 'dictate:x') $$,
                 '22023', null, 'scopes are short lowercase names');

-- Usage keeps one row per dictation with the larger word count.
select public.record_usage('44444444-4444-4444-4444-444444444444', 'dddddddd-0000-0000-0000-000000000001', 300);
select public.record_usage('44444444-4444-4444-4444-444444444444', 'dddddddd-0000-0000-0000-000000000001', 200);
select public.record_usage('44444444-4444-4444-4444-444444444444', 'dddddddd-0000-0000-0000-000000000002', 300);
select public.record_usage('44444444-4444-4444-4444-444444444444', 'dddddddd-0000-0000-0000-000000000002', 450);
select is((select words from public.usage_events where dictation_id = 'dddddddd-0000-0000-0000-000000000001'),
          300, 'a smaller later count doesn''t lower recorded usage');
select is((select words from public.usage_events where dictation_id = 'dddddddd-0000-0000-0000-000000000002'),
          450, 'a larger later count raises recorded usage');
select is((select count(*)::int from public.usage_events where user_id = '44444444-4444-4444-4444-444444444444'),
          2, 'usage is still recorded once per dictation');

-- Dave has 250 of his 1,000 words left, then none. While he has words, he starts dictation 5 and
-- uses up all six calls of dictation 6.
select results_eq(
  $$ select plan, remaining from public.dictation_preflight('44444444-4444-4444-4444-444444444444', 'dictate') $$,
  $$ select plan, remaining from public.quota_status('44444444-4444-4444-4444-444444444444') $$,
  'the dictation preflight reports the quota like quota_status');
select is((select attempt from public.dictation_preflight(
             '44444444-4444-4444-4444-444444444444', 'dictate', 'dddddddd-0000-0000-0000-000000000005')),
          1, 'a dictation starts while there are words left');
do $$
begin
  for i in 1..6 loop
    perform public.dictation_preflight('44444444-4444-4444-4444-444444444444', 'dictate',
                                       'dddddddd-0000-0000-0000-000000000006');
  end loop;
end;
$$;
select public.record_usage('44444444-4444-4444-4444-444444444444', 'dddddddd-0000-0000-0000-000000000003', 250);
select results_eq(
  $$ select allowed, reason, remaining, attempt from public.dictation_preflight(
       '44444444-4444-4444-4444-444444444444', 'dictate', 'dddddddd-0000-0000-0000-000000000004') $$,
  $$ values (false, 'limit_reached'::text, 0, null::int) $$,
  'the dictation preflight blocks when the weekly limit is used up');
select is((select reason from public.dictation_preflight(
             '44444444-4444-4444-4444-444444444444', 'dictate', 'dddddddd-0000-0000-0000-000000000005')),
          'limit_reached', 'the quota applies to a dictation''s later calls too');
select is((select reason from public.dictation_preflight(
             '44444444-4444-4444-4444-444444444444', 'dictate', 'dddddddd-0000-0000-0000-000000000006')),
          'too_many_attempts', 'the attempt cap is checked before the quota');
-- With a limit of 1, the first call takes the slot and is refused for the quota; the second finds
-- the bucket full.
do $$
begin
  perform public.dictation_preflight('44444444-4444-4444-4444-444444444444', 'live-token', p_per_minute => 1);
end;
$$;
select is((select reason from public.dictation_preflight(
             '44444444-4444-4444-4444-444444444444', 'live-token', p_per_minute => 1)),
          'rate_limited', 'the rate limit is checked before the quota');

-- With words left again, dictation 4's first allowed call is attempt 1: its refusal wasn't counted.
delete from public.usage_events where dictation_id = 'dddddddd-0000-0000-0000-000000000003';
select is((select attempt from public.dictation_preflight(
             '44444444-4444-4444-4444-444444444444', 'dictate', 'dddddddd-0000-0000-0000-000000000004')),
          1, 'a call refused for the quota is not counted as an attempt');

-- The inline cleanups of old windows and attempts are index scans.
select has_index('public', 'request_buckets', 'request_buckets_window_start', array['window_start']::name[],
                 'request buckets are indexed by window');
select has_index('public', 'rate_limits', 'rate_limits_window_start', array['window_start']::name[],
                 'rate limits are indexed by window');
select has_index('public', 'dictation_attempts', 'dictation_attempts_window_start', array['window_start']::name[],
                 'dictation attempts are indexed by window');

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
select throws_ok($$ select * from public.dictation_preflight('11111111-1111-1111-1111-111111111111', 'dictate') $$,
                 '42501', null, 'users cannot run the dictation preflight');
select throws_ok($$ select * from public.dictation_attempts $$, '42501', null, 'users cannot read attempt counts');
select throws_ok($$ insert into public.notes (id, user_id, title)
                    values (gen_random_uuid(), '22222222-2222-2222-2222-222222222222', 'sneaky') $$,
                 '42501', null, 'users cannot write rows for someone else');
select is((select remaining from public.my_quota()), 1000, 'my_quota reports the caller''s own quota');

-- Without a session (the anon key).
reset role;
set local role anon;
select throws_ok($$ select * from public.dictation_preflight('11111111-1111-1111-1111-111111111111', 'dictate') $$,
                 '42501', null, 'the anon key cannot run the dictation preflight');

reset role;
select * from finish();
rollback;
