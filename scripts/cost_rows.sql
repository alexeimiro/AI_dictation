-- The rows scripts/cost_report.ts reads: what each transcription and model call was billed by.
-- Counts only, never text or audio, and each account as a pseudonym.
-- Run it in the Supabase dashboard's SQL editor (or any read-only connection), and save the one
-- cell it returns as scripts/out/cost_rows.json (that folder is git-ignored). Then:
--   deno run --allow-read scripts/cost_report.ts scripts/out/cost_rows.json
-- Change the interval for another period.
select coalesce(json_agg(r order by r.created_at), '[]'::json) as cost_rows
from (
  select
    created_at,
    md5(user_id::text) as "user",
    dictation_id,
    kind,
    path,
    host,
    plan,
    provider,
    model,
    backup,
    audio_ms,
    input_tokens,
    cached_tokens,
    cache_write_tokens,
    output_tokens
  from public.dictation_costs
  where created_at >= now() - interval '30 days'
) r;
