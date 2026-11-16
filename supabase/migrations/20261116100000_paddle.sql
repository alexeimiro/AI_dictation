-- Pro bought on the web through Paddle (Murmur for Mac is a download, so it can't use the App
-- Store). The webhook (`paddle-webhook`) applies each subscription event to the account it was
-- bought for; `quota_status` already treats any unexpired 'pro' row as Pro, whatever its source.

alter table public.entitlements drop constraint if exists entitlements_source_check;
alter table public.entitlements
  add constraint entitlements_source_check check (source in ('trial', 'app_store', 'grant', 'paddle'));
alter table public.entitlements add column if not exists paddle_subscription_id text;
alter table public.entitlements add column if not exists paddle_customer_id text;
create unique index if not exists entitlements_paddle_subscription
  on public.entitlements (paddle_subscription_id) where paddle_subscription_id is not null;

-- One subscription event: `p_active` while Paddle bills it (active, trialing or past due), with
-- `p_ends_at` the end of the paid period. An App Store subscription that is still running is
-- never taken away by a Paddle one ending; a Paddle one starting takes over the row.
create or replace function public.apply_paddle_subscription(
  p_user uuid,
  p_subscription text,
  p_customer text,
  p_active boolean,
  p_ends_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  e public.entitlements%rowtype;
begin
  select * into e from public.entitlements where user_id = p_user for update;
  if not p_active and found and e.source <> 'paddle' then
    -- The account's Pro comes from somewhere else (or it has none): only forget the subscription.
    update public.entitlements
      set paddle_subscription_id = p_subscription, paddle_customer_id = p_customer, updated_at = now()
      where user_id = p_user;
    return;
  end if;
  insert into public.entitlements (user_id, plan, source, expires_at, paddle_subscription_id, paddle_customer_id, updated_at)
  values (p_user, case when p_active then 'pro' else 'basic' end, 'paddle', p_ends_at, p_subscription, p_customer, now())
  on conflict (user_id) do update set
    plan = excluded.plan,
    source = 'paddle',
    expires_at = excluded.expires_at,
    paddle_subscription_id = excluded.paddle_subscription_id,
    paddle_customer_id = excluded.paddle_customer_id,
    updated_at = now();
end;
$$;

revoke all on function public.apply_paddle_subscription(uuid, text, text, boolean, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_paddle_subscription(uuid, text, text, boolean, timestamptz) to service_role;
