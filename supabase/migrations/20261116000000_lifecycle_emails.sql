-- Lifecycle emails: the welcome, the tips of a new account's first two weeks and the reminder the
-- day before its Pro trial ends, sent by the lifecycle-emails Edge Function through Resend
-- (_shared/lifecycle.ts holds the schedule, _shared/lifecycle_emails.ts the emails).
--
-- - email_settings: each account's unsubscribe choice, and the random token its email links carry
--   (unsubscribe, the 1–10 question), so a link works without signing in.
-- - email_sends: one row per account and email, claimed before the email goes out, so no email is
--   sent twice, even by two runs at once. Emails that no longer fit are recorded as skipped.
-- - email_scores: the answer to "How likely are you to recommend Murmur to a friend?".
-- - lifecycle_candidates: the accounts the function looks at on each run, with what it needs.
-- - Every 15 minutes pg_cron calls the function with a secret that only Vault holds. The function
--   sends nothing until its LIFECYCLE_EMAILS secret says so.
--
-- All of it is service role only.

create table public.email_settings (
  user_id uuid primary key references auth.users (id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  subscribed boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.email_sends (
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind ~ '^[a-z_]{1,32}$'),
  status text not null default 'sending' check (status in ('sending', 'sent', 'skipped', 'failed')),
  -- Resend's email ID, or why it was skipped or failed.
  detail text check (char_length(detail) <= 300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, kind)
);
create index email_sends_status_updated on public.email_sends (status, updated_at);

create table public.email_scores (
  user_id uuid primary key references auth.users (id) on delete cascade,
  score smallint not null check (score between 1 and 10),
  comment text check (char_length(comment) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger email_settings_updated_at before update on public.email_settings
  for each row execute function public.set_updated_at();
create trigger email_sends_updated_at before update on public.email_sends
  for each row execute function public.set_updated_at();
create trigger email_scores_updated_at before update on public.email_scores
  for each row execute function public.set_updated_at();

alter table public.email_settings enable row level security;
alter table public.email_sends enable row level security;
alter table public.email_scores enable row level security;
revoke all on public.email_settings, public.email_sends, public.email_scores from anon, authenticated;

-- The account's email-link token, made on first use.
create or replace function public.email_token(p_user uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  result uuid;
begin
  insert into public.email_settings (user_id) values (p_user) on conflict (user_id) do nothing;
  select token into result from public.email_settings where user_id = p_user;
  return result;
end;
$$;

-- Accounts made since p_since (and in the last 60 days) that have an email address, haven't
-- unsubscribed and still have emails to come (fewer than p_kinds sent or skipped), newest first.
-- Days and streaks count UTC days with at least one dictation. `sent` lists every email handled
-- (sent, skipped, failed or being sent); `last_sent_at` is when the last one actually went out.
create or replace function public.lifecycle_candidates(p_since timestamptz, p_kinds integer, p_limit integer default 500)
returns table (
  user_id uuid,
  email text,
  full_name text,
  created_at timestamptz,
  paid boolean,
  trial_check text,
  trial_ends_at timestamptz,
  token uuid,
  dictations integer,
  words integer,
  days_used integer,
  longest_streak integer,
  sent text[],
  last_sent_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with people as (
    select u.id, u.email, u.created_at
    from auth.users u
    left join public.email_settings s on s.user_id = u.id
    where u.created_at >= greatest(p_since, now() - interval '60 days')
      and not coalesce(u.is_anonymous, false)
      and coalesce(u.email, '') <> ''
      and coalesce(s.subscribed, true)
      and (select count(*) from public.email_sends es where es.user_id = u.id) < p_kinds
    order by u.created_at desc
    limit p_limit
  ),
  days as (
    select ue.user_id, (ue.created_at at time zone 'UTC')::date as day, count(*) as n, sum(ue.words) as words
    from public.usage_events ue
    join people p on p.id = ue.user_id
    group by 1, 2
  ),
  runs as (
    select d.user_id, count(*) as length
    from (select user_id, day - (row_number() over (partition by user_id order by day))::integer as run from days) d
    group by d.user_id, d.run
  ),
  totals as (
    select d.user_id, sum(d.n)::integer as dictations, sum(d.words)::integer as words, count(*)::integer as days_used,
      (select max(r.length)::integer from runs r where r.user_id = d.user_id) as longest_streak
    from days d
    group by d.user_id
  )
  select
    p.id,
    p.email,
    pr.full_name,
    p.created_at,
    coalesce(e.plan = 'pro' and (e.expires_at is null or e.expires_at > now()), false),
    e.trial_check,
    e.trial_ends_at,
    s.token,
    coalesce(t.dictations, 0),
    coalesce(t.words, 0),
    coalesce(t.days_used, 0),
    coalesce(t.longest_streak, 0),
    array(select es.kind from public.email_sends es where es.user_id = p.id order by es.kind),
    (select max(es.updated_at) from public.email_sends es where es.user_id = p.id and es.status = 'sent')
  from people p
  left join public.entitlements e on e.user_id = p.id
  left join public.profiles pr on pr.id = p.id
  left join public.email_settings s on s.user_id = p.id
  left join totals t on t.user_id = p.id
  order by p.created_at desc
$$;

revoke execute on function public.email_token(uuid) from public, anon, authenticated;
revoke execute on function public.lifecycle_candidates(timestamptz, integer, integer) from public, anon, authenticated;
grant execute on function public.email_token(uuid) to service_role;
grant execute on function public.lifecycle_candidates(timestamptz, integer, integer) to service_role;

-- The schedule. Vault makes the secret the cron call carries; lifecycle_cron_ok lets the function
-- check it, so the secret never leaves the database. Where pg_cron, pg_net or Vault is missing (a
-- bare Postgres for tests), there is no schedule and lifecycle_cron_ok doesn't exist, so the
-- function refuses cron calls. The URL is the hosted project's: a local stack's calls get refused
-- there, since its Vault secret differs.
do $schedule$
begin
  if (select count(*) from pg_available_extensions where name in ('pg_cron', 'pg_net', 'supabase_vault')) < 3 then
    raise notice 'lifecycle emails: pg_cron, pg_net or Vault is missing, so nothing is scheduled';
    return;
  end if;
  create extension if not exists pg_cron with schema pg_catalog;
  create extension if not exists pg_net with schema extensions;
  create extension if not exists supabase_vault with schema vault;

  if not exists (select 1 from vault.secrets where name = 'lifecycle_cron_secret') then
    -- Two random UUIDs: 244 random bits, without needing pgcrypto.
    perform vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'lifecycle_cron_secret',
      'Sent by the lifecycle-emails cron job; checked by public.lifecycle_cron_ok.');
  end if;

  execute $function$
    create or replace function public.lifecycle_cron_ok(p_secret text)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
    as $body$
      select coalesce(
        (select s.decrypted_secret = p_secret from vault.decrypted_secrets s
         where s.name = 'lifecycle_cron_secret' limit 1),
        false)
    $body$
  $function$;
  revoke execute on function public.lifecycle_cron_ok(text) from public, anon, authenticated;
  grant execute on function public.lifecycle_cron_ok(text) to service_role;

  perform cron.schedule('lifecycle-emails', '*/15 * * * *', $job$
    select net.http_post(
      url := 'https://aljjzxfzqbbmyfmardaj.supabase.co/functions/v1/lifecycle-emails',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-murmur-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'lifecycle_cron_secret')),
      body := '{"action":"run"}'::jsonb,
      timeout_milliseconds := 60000)
  $job$);
end;
$schedule$;
