-- Keep profiles.natal_chart_data in sync with users.natal_chart_data (sanitized planets subset)
begin;

-- Helper: extract planets array from various natal_chart_data shapes
create or replace function public.extract_planets_from_natal_chart(p_chart jsonb)
returns jsonb
language sql
immutable
as $$
  with chart as (
    select p_chart as j
  )
  -- Prefer explicit planets array if present
  , direct as (
    select case
      when (j ? 'chartData') and jsonb_typeof(j->'chartData'->'planets') = 'array' then j->'chartData'->'planets'
      else null
    end as planets
    from chart
  )
  -- Build from corePlacements map if needed
  , from_core as (
    select case
      when (select planets from direct) is not null then null
      when (j ? 'corePlacements') then (
        select jsonb_agg(
                 jsonb_build_object(
                   'name', key,
                   'sign', value->>'Sign',
                   'degree', coalesce((value->>'Degree')::numeric, 0)
                 )
               )
        from jsonb_each(j->'corePlacements')
      )
      when (j ? 'CorePlacements') then (
        select jsonb_agg(
                 jsonb_build_object(
                   'name', key,
                   'sign', value->>'Sign',
                   'degree', coalesce((value->>'Degree')::numeric, 0)
                 )
               )
        from jsonb_each(j->'CorePlacements')
      )
      else null
    end as planets
    from chart
  )
  select coalesce((select planets from direct), (select planets from from_core));
$$;

-- One-time backfill from users to profiles
update public.profiles p
set natal_chart_data = jsonb_build_object('chartData', jsonb_build_object('planets', planets)),
    updated_at = now()
from (
  select coalesce(u.id, u.auth_user_id) as uid,
         public.extract_planets_from_natal_chart(u.natal_chart_data) as planets
  from public.users u
  where u.natal_chart_data is not null
) s
where p.id = s.uid
  and s.planets is not null
  and (p.natal_chart_data is null or p.natal_chart_data = '{}'::jsonb);

-- Trigger to keep profiles in sync on changes to users.natal_chart_data
create or replace function public.sync_profile_natal_chart_from_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  planets jsonb;
begin
  if TG_OP = 'INSERT' or TG_OP = 'UPDATE' then
    if NEW.natal_chart_data is not null then
      planets := public.extract_planets_from_natal_chart(NEW.natal_chart_data);
      if planets is not null then
        update public.profiles p
        set natal_chart_data = jsonb_build_object('chartData', jsonb_build_object('planets', planets)),
            updated_at = now()
        where p.id = NEW.id or p.id = NEW.auth_user_id;
      end if;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_sync_profile_natal_chart_from_user on public.users;
create trigger trg_sync_profile_natal_chart_from_user
after insert or update of natal_chart_data on public.users
for each row execute function public.sync_profile_natal_chart_from_user();

commit;

