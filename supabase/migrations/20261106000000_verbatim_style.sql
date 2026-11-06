-- "Word for word" style: keeps the speaker's exact words and translates literally.
alter table public.profiles drop constraint if exists profiles_default_style_check;
alter table public.profiles add constraint profiles_default_style_check
  check (default_style in ('formal', 'casual', 'veryCasual', 'excited', 'verbatim'));
