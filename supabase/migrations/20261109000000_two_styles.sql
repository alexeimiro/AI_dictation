-- Two styles: Word for word (the default) and Improve my grammar. Builds from before November
-- 2026 may still write the removed styles from onboarding, so they stay valid here; the functions
-- read them as Improve my grammar.
alter table public.profiles drop constraint if exists profiles_default_style_check;
alter table public.profiles add constraint profiles_default_style_check
  check (default_style in ('verbatim', 'grammar', 'formal', 'casual', 'veryCasual', 'excited'));
alter table public.profiles alter column default_style set default 'verbatim';
