-- Five styles: Word for word (the default), Improve my grammar, Professional, Casual and Concise.
-- Casual is stored as 'chat': 'casual' is one of the styles removed in November 2026, which
-- builds from before then may still write from onboarding and which old profiles still hold, so
-- it stays valid here and keeps its old meaning.
alter table public.profiles drop constraint if exists profiles_default_style_check;
alter table public.profiles add constraint profiles_default_style_check
  check (default_style in ('verbatim', 'grammar', 'professional', 'chat', 'concise',
                           'formal', 'casual', 'veryCasual', 'excited'));
