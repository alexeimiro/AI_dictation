-- What each dictation cost to serve: one row per billable call (a transcription, or a model call
-- that wrote text), with what its bill is counted in: audio milliseconds, or tokens. Counts only,
-- never text or audio. Service role only; `scripts/cost_report.ts` turns the rows into dollars.
-- `usage_events` and `record_usage` are untouched: the limits don't read this table, and a write
-- that fails here never affects a dictation.

create table public.dictation_costs (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  -- Kept without the account once it is deleted: the money was still spent.
  user_id uuid references auth.users (id) on delete set null,
  -- Null when the call named no dictation of its own (an old build's transcription).
  dictation_id uuid,
  kind text not null check (kind in ('speech', 'text')),
  -- 'upload': the recording sent after the user stopped. 'live': streamed while speaking.
  path text not null check (path in ('upload', 'live')),
  -- Which home of the code served it: 'supabase', or the dictation server's name.
  host text not null,
  -- The caller's plan when the call was made, where the check before it said so.
  plan text,
  provider text not null,
  model text not null,
  -- The backup answered because the first choice failed.
  backup boolean not null default false,
  -- Speech: the audio's length. Null when the file didn't say.
  audio_ms integer check (audio_ms >= 0),
  -- Text: every input token, of which `cached_tokens` were read from the cache and
  -- `cache_write_tokens` written to it; and the output.
  input_tokens integer check (input_tokens >= 0),
  cached_tokens integer check (cached_tokens >= 0),
  cache_write_tokens integer check (cache_write_tokens >= 0),
  output_tokens integer check (output_tokens >= 0)
);
create index dictation_costs_created_at on public.dictation_costs (created_at);
create index dictation_costs_user_created_at on public.dictation_costs (user_id, created_at);
alter table public.dictation_costs enable row level security;
revoke all on public.dictation_costs from anon, authenticated;

-- One round trip for all of a request's calls. `p_calls` is a JSON array of
-- { kind, path, host, plan?, provider, model, backup?, audioMs?, inputTokens?, cachedTokens?,
--   cacheWriteTokens?, outputTokens? }.
create or replace function public.record_cost(p_user uuid, p_dictation uuid, p_calls jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.dictation_costs (
    user_id, dictation_id, kind, path, host, plan, provider, model, backup,
    audio_ms, input_tokens, cached_tokens, cache_write_tokens, output_tokens
  )
  select
    p_user, p_dictation, c->>'kind', c->>'path', c->>'host', c->>'plan', c->>'provider', c->>'model',
    coalesce((c->>'backup')::boolean, false),
    (c->>'audioMs')::integer, (c->>'inputTokens')::integer, (c->>'cachedTokens')::integer,
    (c->>'cacheWriteTokens')::integer, (c->>'outputTokens')::integer
  from jsonb_array_elements(p_calls) as c;
$$;

revoke execute on function public.record_cost(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.record_cost(uuid, uuid, jsonb) to service_role;
