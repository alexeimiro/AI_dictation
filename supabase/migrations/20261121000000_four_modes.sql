-- Four modes: Word-to-Word ('verbatim', the default), Rewrite, Email and Funny. Builds from before
-- them (1.0.4 and earlier) still write the five styles of November 12, 2026 ('grammar',
-- 'professional', 'chat', 'concise') and older ones the styles removed in early November
-- ('formal', 'casual', 'veryCasual', 'excited'), and other devices on the account may still hold
-- them, so every one of those stays valid. The app reads each old value as its closest mode.
alter table public.profiles drop constraint if exists profiles_default_style_check;
alter table public.profiles add constraint profiles_default_style_check
  check (default_style in ('verbatim', 'rewrite', 'email', 'funny',
                           'grammar', 'professional', 'chat', 'concise',
                           'formal', 'casual', 'veryCasual', 'excited'));
