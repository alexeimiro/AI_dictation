-- App Store subscriptions (verify-purchase, app-store-notifications): which product and
-- environment granted Pro, when it was refunded or revoked, and one subscription per account.
alter table public.entitlements
  add column product_id text,
  add column environment text,
  add column revoked_at timestamptz;

create unique index entitlements_original_transaction on public.entitlements (original_transaction_id)
  where original_transaction_id is not null;
