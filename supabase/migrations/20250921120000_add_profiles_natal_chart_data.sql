-- Add sanitized natal chart storage to profiles for match display
-- Rationale: Keep full chart in public.users (strict RLS), expose minimal, non-sensitive
-- placement data via profiles for discovery/matching UI.

-- Add column on profiles to hold sanitized chart subset (planets only)
alter table public.profiles
  add column if not exists natal_chart_data jsonb;

comment on column public.profiles.natal_chart_data is
  'Sanitized natal chart subset for display (e.g., planets with sign/degree). No birth data.';

-- Optional: lightweight GIN index for existence checks
create index if not exists idx_profiles_natal_chart_present
  on public.profiles ((natal_chart_data is not null))
  where natal_chart_data is not null;

