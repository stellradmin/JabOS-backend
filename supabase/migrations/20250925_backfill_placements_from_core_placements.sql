-- Backfill users.natal_chart_data->placements from existing corePlacements/CorePlacements
begin;

create or replace function public.build_placements_from_chart(p_chart jsonb)
returns jsonb
language sql
immutable
as $$
  with chart as (select p_chart j)
  , cores as (
    select coalesce(j->'corePlacements', j->'CorePlacements') cp from chart
  )
  , pairs as (
    select 'Sun' as k union all select 'Moon' union all select 'Ascendant'
    union all select 'Mercury' union all select 'Venus' union all select 'Mars'
    union all select 'Jupiter' union all select 'Saturn' union all select 'Uranus'
    union all select 'Neptune' union all select 'Pluto'
  )
  , built as (
    select jsonb_object_agg(k, jsonb_build_object(
             'sign', coalesce(cp->k->>'Sign', cp->k->>'sign'),
             'degree', coalesce((cp->k->>'Degree')::numeric, (cp->k->>'degree')::numeric, 0),
             'absolute_degree', coalesce((cp->k->>'AbsoluteDegree')::numeric, (cp->k->>'absoluteDegree')::numeric, null)
           )) as placements
    from pairs, cores
    where cp is not null
  )
  select placements from built;
$$;

update public.users u
set natal_chart_data = jsonb_set(u.natal_chart_data, '{placements}', public.build_placements_from_chart(u.natal_chart_data), true),
    updated_at = now()
where u.natal_chart_data is not null
  and (u.natal_chart_data ? 'placements') = false
  and public.build_placements_from_chart(u.natal_chart_data) is not null;

commit;

