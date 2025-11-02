-- Sync profiles.age from users.birth_date and keep it up to date

-- Helper: compute age from a text date like 'July 28, 1994'
create or replace function public.compute_age_from_text_date(p_birth_date text)
returns int
language plpgsql
as $$
declare
  d date;
  years int;
begin
  if p_birth_date is null or length(trim(p_birth_date)) = 0 then
    return null;
  end if;
  begin
    d := p_birth_date::date; -- relies on standard month name parsing
  exception when others then
    return null;
  end;
  if d is null then
    return null;
  end if;
  years := date_part('year', age(current_date, d));
  if years < 0 or years > 150 then
    return null;
  end if;
  return years;
end;
$$;

-- One-time backfill/correction
DO $$
BEGIN
    UPDATE public.profiles p
    SET age = public.compute_age_from_text_date(u.birth_date)
    FROM public.users u
    WHERE p.id = u.id
      AND u.birth_date IS NOT NULL
      AND public.compute_age_from_text_date(u.birth_date) IS NOT NULL
      AND (p.age IS NULL OR p.age <> public.compute_age_from_text_date(u.birth_date));
END $$;

-- Keep in sync on future changes
create or replace function public.sync_profile_age_from_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  new_age int;
begin
  if TG_OP = 'INSERT' or TG_OP = 'UPDATE' then
    if NEW.birth_date is not null then
      new_age := public.compute_age_from_text_date(NEW.birth_date);
      if new_age is not null then
        update public.profiles p
        set age = new_age,
            updated_at = now()
        where p.id = NEW.id or p.id = NEW.auth_user_id;
      end if;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_sync_profile_age_from_user on public.users;
create trigger trg_sync_profile_age_from_user
after insert or update of birth_date on public.users
for each row execute function public.sync_profile_age_from_user();
