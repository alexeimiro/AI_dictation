-- pgTAP tests for the lifecycle emails' tables and functions: who lifecycle_candidates returns and
-- what it counts, email_token, and that only the service role can use any of it.
-- Run with `supabase test db`.
begin;
select plan(14);

-- Ann is two days old on a trial and dictated on four days, three of them in a row; Gus pays; Ben
-- is a guest, Cal has no email, Dee is 70 days old, Eve unsubscribed and Fay has had every email.
insert into auth.users (id, email, aud, role, created_at, is_anonymous)
values
  ('dddddddd-0000-0000-0000-000000000001', 'ann@example.com', 'authenticated', 'authenticated', now() - interval '2 days', false),
  ('dddddddd-0000-0000-0000-000000000002', null, 'authenticated', 'authenticated', now() - interval '2 days', true),
  ('dddddddd-0000-0000-0000-000000000003', '', 'authenticated', 'authenticated', now() - interval '2 days', false),
  ('dddddddd-0000-0000-0000-000000000004', 'dee@example.com', 'authenticated', 'authenticated', now() - interval '70 days', false),
  ('dddddddd-0000-0000-0000-000000000005', 'eve@example.com', 'authenticated', 'authenticated', now() - interval '3 days', false),
  ('dddddddd-0000-0000-0000-000000000006', 'fay@example.com', 'authenticated', 'authenticated', now() - interval '20 days', false),
  ('dddddddd-0000-0000-0000-000000000007', 'gus@example.com', 'authenticated', 'authenticated', now() - interval '5 days', false);

update public.profiles set full_name = 'Ann Lee' where id = 'dddddddd-0000-0000-0000-000000000001';
update public.entitlements set trial_check = 'granted', trial_ends_at = now() + interval '12 days'
  where user_id = 'dddddddd-0000-0000-0000-000000000001';
update public.entitlements set plan = 'pro', source = 'app_store', expires_at = now() + interval '20 days'
  where user_id = 'dddddddd-0000-0000-0000-000000000007';

insert into public.usage_events (user_id, dictation_id, words, created_at)
values
  ('dddddddd-0000-0000-0000-000000000001', gen_random_uuid(), 10, date_trunc('day', now()) - interval '5 days' + interval '1 hour'),
  ('dddddddd-0000-0000-0000-000000000001', gen_random_uuid(), 20, date_trunc('day', now()) - interval '4 days' + interval '1 hour'),
  ('dddddddd-0000-0000-0000-000000000001', gen_random_uuid(), 30, date_trunc('day', now()) - interval '4 days' + interval '2 hours'),
  ('dddddddd-0000-0000-0000-000000000001', gen_random_uuid(), 40, date_trunc('day', now()) - interval '3 days' + interval '1 hour'),
  ('dddddddd-0000-0000-0000-000000000001', gen_random_uuid(), 50, date_trunc('day', now()) - interval '1 day' + interval '1 hour');

insert into public.email_settings (user_id, subscribed) values ('dddddddd-0000-0000-0000-000000000005', false);
insert into public.email_sends (user_id, kind, status)
select 'dddddddd-0000-0000-0000-000000000006', kind, 'sent'
from unnest(array['welcome', 'setup', 'founder', 'personalize', 'week_one', 'beyond', 'score', 'trial_ending']) kind;
insert into public.email_sends (user_id, kind, status, detail)
values
  ('dddddddd-0000-0000-0000-000000000001', 'welcome', 'sent', 'em_1'),
  ('dddddddd-0000-0000-0000-000000000001', 'setup', 'skipped', 'dictated');

select results_eq(
  $$ select user_id from public.lifecycle_candidates(now() - interval '90 days', 8) $$,
  $$ values ('dddddddd-0000-0000-0000-000000000001'::uuid), ('dddddddd-0000-0000-0000-000000000007'::uuid) $$,
  'only signed-in accounts with an email, under 60 days old, subscribed and with emails to come');

select results_eq(
  $$ select email, full_name, paid, trial_check, dictations, words, days_used, longest_streak, sent
     from public.lifecycle_candidates(now() - interval '90 days', 8)
     where user_id = 'dddddddd-0000-0000-0000-000000000001' $$,
  $$ values ('ann@example.com', 'Ann Lee', false, 'granted', 5, 150, 4, 3, array['setup', 'welcome']) $$,
  'Ann: her dictations, words, days, longest streak and the emails handled');

select ok(
  (select last_sent_at is not null from public.lifecycle_candidates(now() - interval '90 days', 8)
   where user_id = 'dddddddd-0000-0000-0000-000000000001'),
  'last_sent_at comes from the sent email');

select results_eq(
  $$ select paid, dictations, longest_streak, sent, last_sent_at from public.lifecycle_candidates(now() - interval '90 days', 8)
     where user_id = 'dddddddd-0000-0000-0000-000000000007' $$,
  $$ values (true, 0, 0, '{}'::text[], null::timestamptz) $$,
  'Gus pays, has no dictations and no emails yet');

select results_eq(
  $$ select user_id from public.lifecycle_candidates(now() - interval '3 days', 8) $$,
  $$ values ('dddddddd-0000-0000-0000-000000000001'::uuid) $$,
  'p_since leaves out older accounts');

select is(
  (select count(*)::integer from public.lifecycle_candidates(now() - interval '90 days', 8, 1)), 1,
  'p_limit caps the rows');

select is(
  (select user_id from public.lifecycle_candidates(now() - interval '90 days', 8, 1)),
  'dddddddd-0000-0000-0000-000000000001'::uuid,
  'newest accounts first');

-- email_token makes a token once and keeps it.
select ok(
  public.email_token('dddddddd-0000-0000-0000-000000000007') is not null,
  'email_token makes a token');
select is(
  public.email_token('dddddddd-0000-0000-0000-000000000007'),
  (select token from public.email_settings where user_id = 'dddddddd-0000-0000-0000-000000000007'),
  'and gives the same one again');
select is(
  (select token from public.lifecycle_candidates(now() - interval '90 days', 8)
   where user_id = 'dddddddd-0000-0000-0000-000000000007'),
  public.email_token('dddddddd-0000-0000-0000-000000000007'),
  'lifecycle_candidates returns it');

-- Service role only.
select ok(
  not has_function_privilege('authenticated', 'public.lifecycle_candidates(timestamptz, integer, integer)', 'execute')
  and not has_function_privilege('anon', 'public.email_token(uuid)', 'execute'),
  'anon and signed-in users cannot call the functions');
select ok(
  not has_table_privilege('authenticated', 'public.email_settings', 'select')
  and not has_table_privilege('anon', 'public.email_sends', 'insert')
  and not has_table_privilege('authenticated', 'public.email_scores', 'select'),
  'nor read or write the tables');

-- Deleting an account deletes its email rows.
insert into public.email_scores (user_id, score) values ('dddddddd-0000-0000-0000-000000000001', 9);
delete from auth.users where id = 'dddddddd-0000-0000-0000-000000000001';
select is(
  (select count(*)::integer from public.email_sends where user_id = 'dddddddd-0000-0000-0000-000000000001')
  + (select count(*)::integer from public.email_scores where user_id = 'dddddddd-0000-0000-0000-000000000001'),
  0,
  'a deleted account leaves no email rows');

select throws_ok(
  $$ insert into public.email_scores (user_id, score) values ('dddddddd-0000-0000-0000-000000000007', 11) $$,
  '23514', null,
  'a score is 1 to 10');

select * from finish();
rollback;
