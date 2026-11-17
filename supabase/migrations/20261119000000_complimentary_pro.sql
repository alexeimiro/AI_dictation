-- Pro that never runs out, for the people behind Murmur: the owner, mironenkoantony@gmail.com, to
-- begin with. An account is listed by its email address, so it keeps Pro through everything that
-- rewrites a plan: a trial running out, an App Store or Paddle subscription that ends or is
-- refunded, and deleting the account and signing in again.
--
-- It works on the account's `entitlements` row: before any insert or update of a listed account's
-- row, the plan is set to pro with no end date. Everything that already asks "is this account Pro"
-- reads that row (quota_status and so my_quota and the preflights, record_usage's count for the
-- iPhone, the lifecycle emails, the app's offer screen), so each one answers yes with no change of
-- its own, and a later migration that remakes one of them keeps the rule. A purchase still records
-- its transaction on the row; only the plan and its end date stay put.
--
-- Only a signed-in account (not a guest) whose address is confirmed counts. An email-code account
-- is made before its code is entered; the update right after sign-in (restore_account, at the first
-- quota check, and the trial decision) then gives it Pro.
--
-- To add someone: insert into public.complimentary_pro (email, reason) values ('…', '…'), then
-- touch their row (update public.entitlements set updated_at = now() where user_id = …).
-- To take it away: delete the email, then set the row's plan back to 'basic' and source to 'trial'.

create table public.complimentary_pro (
  -- Lower case, no spaces around it: compared with lower(auth.users.email).
  email text primary key check (email = lower(btrim(email)) and email like '%_@_%'),
  reason text not null,
  created_at timestamptz not null default now()
);
alter table public.complimentary_pro enable row level security;
-- No policies: only the server (and the functions below) see the list.
revoke all on public.complimentary_pro from anon, authenticated;

insert into public.complimentary_pro (email, reason) values ('mironenkoantony@gmail.com', 'owner');

-- Whether an account has Pro for free: a signed-in account whose confirmed address is listed.
create function public.has_complimentary_pro(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from auth.users u
    join public.complimentary_pro c on c.email = lower(btrim(u.email))
    where u.id = p_user
      and not coalesce(u.is_anonymous, false)
      and u.email_confirmed_at is not null
  )
$$;

create function public.keep_complimentary_pro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.has_complimentary_pro(new.user_id) then
    new.plan := 'pro';
    new.expires_at := null;
    -- 'trial' would read as "no paid plan" to the app's offer screen; a purchase's source stays.
    if new.source = 'trial' then
      new.source := 'grant';
    end if;
  end if;
  return new;
end;
$$;

create trigger entitlements_complimentary_pro
  before insert or update on public.entitlements
  for each row execute function public.keep_complimentary_pro();

revoke execute on function public.has_complimentary_pro(uuid) from public, anon, authenticated;
revoke execute on function public.keep_complimentary_pro() from public, anon, authenticated;
grant execute on function public.has_complimentary_pro(uuid) to service_role;

-- The listed accounts that exist now get Pro at once (the trigger does the work). Every account has
-- a row from the sign-up trigger; one that somehow hasn't gets it here.
insert into public.entitlements (user_id)
select u.id
from auth.users u
join public.complimentary_pro c on c.email = lower(btrim(u.email))
where not coalesce(u.is_anonymous, false) and u.email_confirmed_at is not null
on conflict (user_id) do update set updated_at = now();
