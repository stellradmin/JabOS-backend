-- Remove empty-object defaults for natal_chart_data and guard against storing empty charts
begin;

-- Drop default of '{}' and use NULL as default
alter table public.users
  alter column natal_chart_data drop default;

-- Normalize existing empty charts to NULL
update public.users
set natal_chart_data = NULL
where natal_chart_data = '{}'::jsonb;

-- Sanitizer: coerce empty/invalid charts to NULL before write
create or replace function public.sanitize_user_natal_chart()
returns trigger
language plpgsql
as $$
declare
  planets_count int;
begin
  if tg_op = 'INSERT' or tg_op = 'UPDATE' then
    if NEW.natal_chart_data is not null then
      -- Treat raw empty object as null
      if NEW.natal_chart_data = '{}'::jsonb then
        NEW.natal_chart_data := NULL;
      else
        -- Accept if unified placements present
        if (NEW.natal_chart_data ? 'CorePlacements') or (NEW.natal_chart_data ? 'corePlacements') then
          return NEW;
        end if;
        -- Accept if planets array present and non-empty
        if (NEW.natal_chart_data ? 'chartData') and jsonb_typeof(NEW.natal_chart_data->'chartData'->'planets') = 'array' then
          select jsonb_array_length(NEW.natal_chart_data->'chartData'->'planets') into planets_count;
          if planets_count is not null and planets_count > 0 then
            return NEW;
          end if;
        end if;
        -- Otherwise nullify
        NEW.natal_chart_data := NULL;
      end if;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_sanitize_user_natal_chart on public.users;
create trigger trg_sanitize_user_natal_chart
before insert or update of natal_chart_data on public.users
for each row execute function public.sanitize_user_natal_chart();

commit;

