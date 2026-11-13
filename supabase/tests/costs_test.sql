-- pgTAP tests for what dictations cost: record_cost writes one row per billable call, counts only;
-- only the service role writes or reads them; a deleted account's rows stay, without the account;
-- and none of it touches the words counted toward the free plan's week.
-- Run with `supabase test db`.
begin;
select plan(21);

-- Mia subscribes; Noa is a guest.
insert into auth.users (id, email, aud, role, created_at, is_anonymous)
values
  ('dddddddd-1111-0000-0000-000000000001', 'mia@example.com', 'authenticated', 'authenticated', now(), false),
  ('dddddddd-1111-0000-0000-000000000002', null, 'authenticated', 'authenticated', now(), true);

-- A rewritten dictation: its transcription and the model's answer, in one round trip.
select lives_ok($$ select public.record_cost(
    'dddddddd-1111-0000-0000-000000000001', 'eeeeeeee-1111-0000-0000-000000000001',
    '[{"kind":"speech","path":"upload","host":"supabase","plan":"pro","provider":"openai","model":"gpt-transcribe","audioMs":7800},
      {"kind":"text","path":"upload","host":"supabase","plan":"pro","provider":"openai","model":"gpt-6.1-terra",
       "inputTokens":1950,"cachedTokens":1900,"cacheWriteTokens":0,"outputTokens":12}]'::jsonb) $$,
  'a dictation''s calls are recorded together');
select results_eq(
  $$ select kind, path, host, plan, provider, model, backup,
            audio_ms, input_tokens, cached_tokens, cache_write_tokens, output_tokens
     from public.dictation_costs where dictation_id = 'eeeeeeee-1111-0000-0000-000000000001' order by id $$,
  $$ values ('speech', 'upload', 'supabase', 'pro', 'openai', 'gpt-transcribe', false,
             7800, null::int, null::int, null::int, null::int),
            ('text', 'upload', 'supabase', 'pro', 'openai', 'gpt-6.1-terra', false,
             null::int, 1950, 1900, 0, 12) $$,
  'one row per call, with what its bill is counted in');
select is((select count(*)::int from public.dictation_costs
           where user_id = 'dddddddd-1111-0000-0000-000000000001' and created_at = now()),
          2, 'each row is the caller''s, dated now');

-- A second transcription of the same dictation (the backup, or a retry) was paid for again.
select public.record_cost(
  'dddddddd-1111-0000-0000-000000000001', 'eeeeeeee-1111-0000-0000-000000000001',
  '[{"kind":"speech","path":"upload","host":"edge-fi","provider":"openai","model":"gpt-transcribe","backup":true,"audioMs":7800}]'::jsonb);
select results_eq(
  $$ select kind, host, backup, sum(audio_ms)::int from public.dictation_costs
     where dictation_id = 'eeeeeeee-1111-0000-0000-000000000001' and kind = 'speech'
     group by kind, host, backup order by host $$,
  $$ values ('speech', 'edge-fi', true, 7800), ('speech', 'supabase', false, 7800) $$,
  'a retry adds a row: both calls were spent');

-- A live session that named no plan, whose audio length wasn't known, under no dictation of its own.
select public.record_cost(
  'dddddddd-1111-0000-0000-000000000002', null,
  '[{"kind":"speech","path":"live","host":"edge-fi","provider":"own","model":"qwen3-asr-1.7b"}]'::jsonb);
select results_eq(
  $$ select dictation_id, path, plan, backup, audio_ms from public.dictation_costs
     where user_id = 'dddddddd-1111-0000-0000-000000000002' $$,
  $$ values (null::uuid, 'live', null::text, false, null::int) $$,
  'what a call doesn''t say stays empty: no dictation, no plan, no guessed length');

select lives_ok($$ select public.record_cost('dddddddd-1111-0000-0000-000000000001', null, '[]'::jsonb) $$,
  'nothing to record is fine');
select is((select count(*)::int from public.dictation_costs), 4, 'and adds no row');

-- Only what the bill can be made of.
select throws_ok($$ select public.record_cost('dddddddd-1111-0000-0000-000000000001', null,
    '[{"kind":"image","path":"upload","host":"supabase","provider":"openai","model":"x"}]'::jsonb) $$,
  '23514', null, 'a call is a transcription or a text');
select throws_ok($$ select public.record_cost('dddddddd-1111-0000-0000-000000000001', null,
    '[{"kind":"speech","path":"email","host":"supabase","provider":"openai","model":"x"}]'::jsonb) $$,
  '23514', null, 'on the upload or the live path');
select throws_ok($$ select public.record_cost('dddddddd-1111-0000-0000-000000000001', null,
    '[{"kind":"speech","path":"upload","host":"supabase","provider":"openai","model":"x","audioMs":-1}]'::jsonb) $$,
  '23514', null, 'with no negative length');
select throws_ok($$ select public.record_cost('dddddddd-1111-0000-0000-000000000001', null,
    '[{"kind":"speech","path":"upload","host":"supabase","model":"x"}]'::jsonb) $$,
  '23502', null, 'and a provider to price it by');
select is((select count(*)::int from public.dictation_costs), 4, 'a refused call records nothing');

-- The words counted toward the week are another matter.
select is((select count(*)::int from public.usage_events
           where user_id in ('dddddddd-1111-0000-0000-000000000001', 'dddddddd-1111-0000-0000-000000000002')),
          0, 'recording a cost counts no words');

-- Who may write and read them.
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-1111-0000-0000-000000000001","role":"authenticated"}';
select throws_ok($$ select public.record_cost('dddddddd-1111-0000-0000-000000000001', null, '[]'::jsonb) $$,
  '42501', null, 'users cannot record costs');
select throws_ok($$ select * from public.dictation_costs $$, '42501', null, 'users cannot read costs, even their own');
reset role;
set local role anon;
select throws_ok($$ select public.record_cost('dddddddd-1111-0000-0000-000000000001', null, '[]'::jsonb) $$,
  '42501', null, 'the anon key cannot record costs');
select throws_ok($$ select * from public.dictation_costs $$, '42501', null, 'or read them');
reset role;
set local role service_role;
select lives_ok($$ select public.record_cost('dddddddd-1111-0000-0000-000000000002', 'eeeeeeee-1111-0000-0000-000000000002',
    '[{"kind":"speech","path":"upload","host":"supabase","plan":"basic","provider":"openai","model":"gpt-transcribe","audioMs":5300}]'::jsonb) $$,
  'the service role records them');
select is((select count(*)::int from public.dictation_costs), 5, 'and reads them');
reset role;

-- A deleted account leaves its costs behind, without its id.
delete from auth.users where id = 'dddddddd-1111-0000-0000-000000000002';
select results_eq(
  $$ select user_id, coalesce(sum(audio_ms), 0)::int from public.dictation_costs
     where model in ('qwen3-asr-1.7b') or dictation_id = 'eeeeeeee-1111-0000-0000-000000000002'
     group by user_id $$,
  $$ values (null::uuid, 5300) $$,
  'the money was still spent');
select is((select count(*)::int from public.dictation_costs where user_id = 'dddddddd-1111-0000-0000-000000000001'),
          3, 'and nobody else''s rows change');

select * from finish();
rollback;
