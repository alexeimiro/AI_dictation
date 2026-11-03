-- Onboarding answers that need more than the boolean/jsonb columns of 20261009000000_init.sql.

-- The data choice ("Your data is safe") is consent, so keep which wording was agreed to and when,
-- separately from the analytics answers in `survey`.
alter table public.profiles
  add column data_sharing_policy_version integer check (data_sharing_policy_version > 0),
  add column data_sharing_decided_at timestamptz;

-- "Email me a link for later" on the desktop screen.
alter table public.profiles
  add column desktop_link_email text check (desktop_link_email is null or char_length(desktop_link_email) <= 320),
  add column desktop_link_requested_at timestamptz;
