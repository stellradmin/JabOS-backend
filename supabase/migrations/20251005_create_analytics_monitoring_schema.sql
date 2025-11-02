-- Stellr analytics & monitoring schema
-- Creates event ingestion tables, aggregated metrics, operational logs,
-- supporting materialized views, and RPC used by the admin dashboard.

-- Ensure required extensions are enabled
create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;

-- Dashboard admin accounts and role management
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'dashboard_admin_role' AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.dashboard_admin_role AS ENUM ('super_admin', 'operator', 'analyst', 'read_only');
  END IF;
END $$;

create table if not exists public.dashboard_admins (
    id uuid primary key default gen_random_uuid(),
    auth_user_id uuid unique references auth.users(id) on delete cascade,
    email text not null unique,
    full_name text,
    role public.dashboard_admin_role not null default 'analyst',
    permissions jsonb not null default '[]'::jsonb,
    active boolean not null default true,
    last_seen_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

comment on table public.dashboard_admins is 'Authorized administrators for the Stellr operations dashboard.';
comment on column public.dashboard_admins.permissions is 'Optional fine-grained permissions beyond the primary role.';

create index if not exists dashboard_admins_active_idx on public.dashboard_admins (active) where active = true;
create index if not exists dashboard_admins_role_idx on public.dashboard_admins (role);

create or replace function public.is_active_dashboard_admin(p_user uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from public.dashboard_admins da
    where da.auth_user_id = p_user
      and da.active = true
  );
$$;

grant execute on function public.is_active_dashboard_admin(uuid) to authenticated;

alter table public.dashboard_admins enable row level security;

create policy dashboard_admins_self_access on public.dashboard_admins
    for select
    using (auth.uid() = auth_user_id);

create policy dashboard_admins_self_update on public.dashboard_admins
    for update
    using (auth.uid() = auth_user_id)
    with check (auth.uid() = auth_user_id);

grant select on table public.dashboard_admins to authenticated;
grant update on table public.dashboard_admins to authenticated;
-- 1. Raw analytics events captured from the mobile app and services
create table if not exists public.analytics_events (
    id uuid primary key default gen_random_uuid(),
    user_id uuid references auth.users(id) on delete set null,
    event_name text not null,
    event_properties jsonb default '{}'::jsonb,
    device_info jsonb default '{}'::jsonb,
    context jsonb default '{}'::jsonb,
    created_at timestamptz not null default now()
);

comment on table public.analytics_events is 'Raw user interaction events replicated from PostHog and in-app logging.';
comment on column public.analytics_events.context is 'Optional context payload (screen name, journey, etc.)';

create index if not exists analytics_events_user_created_idx on public.analytics_events (user_id, created_at desc);
create index if not exists analytics_events_name_created_idx on public.analytics_events (event_name, created_at desc);
create index if not exists analytics_events_created_idx on public.analytics_events (created_at desc);

-- 2. Daily aggregated metrics maintained by edge functions
create table if not exists public.daily_metrics (
    id uuid primary key default gen_random_uuid(),
    metric_date date not null,
    metric_type text not null,
    value numeric not null,
    metadata jsonb default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

comment on table public.daily_metrics is 'Daily rollups for KPI trend lines (match rate, active users, etc.).';
comment on column public.daily_metrics.metadata is 'Structured payload with supporting values for the metric row.';

alter table public.daily_metrics add constraint daily_metrics_unique_day_type unique (metric_date, metric_type);
create index if not exists daily_metrics_type_date_idx on public.daily_metrics (metric_type, metric_date desc);

-- 3. Error logs linked with Sentry incidents
create table if not exists public.error_logs (
    id uuid primary key default gen_random_uuid(),
    user_id uuid references auth.users(id) on delete set null,
    error_message text,
    error_stack text,
    sentry_event_id text,
    app_version text,
    os_version text,
    severity text not null default 'error',
    context jsonb default '{}'::jsonb,
    created_at timestamptz not null default now()
);

comment on table public.error_logs is 'Critical runtime errors captured alongside Sentry event identifiers.';
comment on column public.error_logs.context is 'Additional metadata (screen, feature flags, device info).';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'error_logs_severity_check' AND conrelid = 'public.error_logs'::regclass
  ) THEN
    ALTER TABLE public.error_logs ADD CONSTRAINT error_logs_severity_check
      CHECK (severity IN ('critical', 'error', 'warning'));
  END IF;
END $$;

create index if not exists error_logs_severity_created_idx on public.error_logs (severity, created_at desc);
create index if not exists error_logs_created_idx on public.error_logs (created_at desc);

-- 4. Match quality metrics persisted daily
create table if not exists public.match_metrics (
    id uuid primary key default gen_random_uuid(),
    metric_date date not null,
    total_matches integer not null default 0,
    avg_time_to_match interval,
    match_quality_score numeric,
    metadata jsonb default '{}'::jsonb,
    created_at timestamptz not null default now()
);

comment on table public.match_metrics is 'Daily match performance rollups generated by background jobs.';

alter table public.match_metrics add constraint match_metrics_unique_day unique (metric_date);

-- 5. Real-time operational metrics feed (latest value per metric name)
create table if not exists public.operational_metrics (
    id uuid primary key default gen_random_uuid(),
    metric_name text not null,
    value numeric not null,
    unit text,
    metadata jsonb default '{}'::jsonb,
    recorded_at timestamptz not null default now()
);

comment on table public.operational_metrics is 'Append-only operational metrics powering realtime dashboard widgets.';
create index if not exists operational_metrics_name_recorded_idx on public.operational_metrics (metric_name, recorded_at desc);

-- 6. Materialized view summarizing user engagement per day
-- Drop/recreate to guarantee latest definition when running migrations multiple times in different environments.
drop materialized view if exists public.user_engagement_stats;
create materialized view public.user_engagement_stats as
select
    date_trunc('day', ae.created_at) as day,
    count(distinct ae.user_id) as daily_active_users,
    count(*) filter (where ae.event_name = 'profile_view') as profile_views,
    count(*) filter (where ae.event_name = 'swipe_right') as likes_sent,
    count(*) filter (where ae.event_name = 'message_sent') as messages_sent
from public.analytics_events ae
where ae.created_at >= now() - interval '30 days'
group by 1
order by 1;

comment on materialized view public.user_engagement_stats is '30-day rolling engagement metrics for dashboard visualisations.';
create unique index if not exists user_engagement_stats_day_idx on public.user_engagement_stats (day);

GRANT SELECT ON public.user_engagement_stats TO authenticated;

-- 7. RPC function consumed by the dashboard UI for rollup metrics
create or replace function public.get_dashboard_metrics(days_back integer default 7)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
    result jsonb;
begin
    result := jsonb_build_object(
        'active_users', (
            select count(distinct ae.user_id)
            from public.analytics_events ae
            where ae.created_at >= now() - make_interval(days => coalesce(days_back, 7))
        ),
        'total_matches', (
            select count(*)
            from public.matches m
            where m.created_at >= now() - make_interval(days => coalesce(days_back, 7))
        ),
        'avg_match_rate', (
            select avg(dm.value)
            from public.daily_metrics dm
            where dm.metric_type = 'match_rate'
              and dm.metric_date >= current_date - coalesce(days_back, 7)
        ),
        'critical_errors', (
            select count(*)
            from public.error_logs el
            where el.severity = 'critical'
              and el.created_at >= now() - make_interval(days => coalesce(days_back, 7))
        )
    );

    return result;
end;
$$;

comment on function public.get_dashboard_metrics(integer) is 'Aggregated KPI payload for the Stellr admin dashboard (active users, matches, errors).';

grant execute on function public.get_dashboard_metrics(integer) to authenticated, service_role;

-- 8. Helper views/functions for edge function calculations
create or replace function public.calculate_avg_time_to_match()
returns interval
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
    avg_interval interval;
begin
    with participant_deltas as (
        select
            m.id,
            m.matched_at,
            m.user1_id,
            m.user2_id,
            au1.created_at as user1_created_at,
            au2.created_at as user2_created_at
        from public.matches m
        join auth.users au1 on au1.id = m.user1_id
        join auth.users au2 on au2.id = m.user2_id
        where m.matched_at >= now() - interval '30 days'
    ),
    delta_values as (
        select matched_at - user1_created_at as delta from participant_deltas
        union all
        select matched_at - user2_created_at as delta from participant_deltas
    )
    select avg(delta)
    into avg_interval
    from delta_values
    where delta is not null;

    return coalesce(avg_interval, interval '0 seconds');
end;
$$;

comment on function public.calculate_avg_time_to_match() is 'Average duration between user creation and first match in the last 30 days.';

grant execute on function public.calculate_avg_time_to_match() to service_role;

create or replace function public.calculate_match_quality_score()
returns numeric
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
    score numeric;
begin
    -- Ratio of matches with at least one conversation message within 24 hours
    with recent_matches as (
        select m.id, m.conversation_id, m.matched_at
        from public.matches m
        where m.matched_at >= now() - interval '30 days'
    ),
    responsive_matches as (
        select distinct rm.id
        from recent_matches rm
        join public.messages msg on msg.conversation_id = rm.conversation_id
        where rm.conversation_id is not null
          and msg.created_at <= rm.matched_at + interval '24 hours'
    ),
    totals as (
        select
            count(*)::numeric as total_matches,
            count(responsive_matches.id)::numeric as responsive_matches
        from recent_matches
        left join responsive_matches on responsive_matches.id = recent_matches.id
    )
    select case when total_matches = 0 then 0 else responsive_matches / total_matches end
    into score
    from totals;

    return coalesce(score, 0);
end;
$$;

comment on function public.calculate_match_quality_score() is 'Calculates match quality proxy (responsive convos within 24h / total matches).';

grant execute on function public.calculate_match_quality_score() to service_role;

-- Enable row level security to enforce explicit policy creation in follow-up migrations
alter table public.analytics_events enable row level security;
alter table public.daily_metrics enable row level security;
alter table public.error_logs enable row level security;
alter table public.match_metrics enable row level security;
alter table public.operational_metrics enable row level security;

-- Default policies (placeholder - follow-up migration should scope access properly)
create policy analytics_events_admin_read on public.analytics_events
    for select
    using (
      auth.uid() is not null
      and public.is_active_dashboard_admin(auth.uid())
    );
create policy analytics_events_authenticated_insert on public.analytics_events
    for insert
    to authenticated
    with check (auth.uid() = user_id or user_id is null);


grant select on table public.analytics_events to authenticated;
grant insert on table public.analytics_events to authenticated;

grant select on table public.daily_metrics to authenticated;

grant select on table public.error_logs to authenticated;
grant insert on table public.error_logs to authenticated;

grant select on table public.match_metrics to authenticated;

grant select on table public.operational_metrics to authenticated;

create policy daily_metrics_admin_read on public.daily_metrics
    for select
    using (
      auth.uid() is not null
      and public.is_active_dashboard_admin(auth.uid())
    );

create policy error_logs_admin_read on public.error_logs
    for select
    using (
      auth.uid() is not null
      and public.is_active_dashboard_admin(auth.uid())
    );

-- Ensure error_logs has user_id column before creating policy
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'error_logs' AND column_name = 'user_id'
  ) THEN
    ALTER TABLE public.error_logs ADD COLUMN user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
END $$;

create policy error_logs_authenticated_insert on public.error_logs
    for insert
    to authenticated
    with check (auth.uid() = user_id or user_id is null);


create policy match_metrics_admin_read on public.match_metrics
    for select
    using (
      auth.uid() is not null
      and public.is_active_dashboard_admin(auth.uid())
    );

create policy operational_metrics_admin_read on public.operational_metrics
    for select
    using (
      auth.uid() is not null
      and public.is_active_dashboard_admin(auth.uid())
    );

-- Insert helpful metadata table for alert thresholds (optional starter)
create table if not exists public.dashboard_thresholds (
    metric_name text primary key,
    warning_threshold numeric,
    critical_threshold numeric,
    metadata jsonb default '{}'::jsonb,
    updated_at timestamptz not null default now()
);

comment on table public.dashboard_thresholds is 'Stores alert thresholds referenced by Supabase edge functions.';

alter table public.dashboard_thresholds enable row level security;
create policy dashboard_thresholds_admin_read on public.dashboard_thresholds
    for select
    using (
      auth.uid() is not null
      and public.is_active_dashboard_admin(auth.uid())
    );

insert into public.dashboard_thresholds (metric_name, warning_threshold, critical_threshold, metadata, updated_at) values
  ('active_users', 800, 1200, jsonb_build_object('window_minutes', 5, 'direction', 'above'), now()),
  ('matches_created', 150, 250, jsonb_build_object('window_minutes', 5, 'direction', 'above'), now()),
  ('critical_errors', 5, 10, jsonb_build_object('window_minutes', 5, 'direction', 'above'), now()),
  ('match_rate_today', 0.08, 0.05, jsonb_build_object('goal', 'ratio', 'direction', 'below'), now())
on conflict (metric_name) do nothing;

grant select on table public.dashboard_thresholds to authenticated;

create policy dashboard_thresholds_service_role_read on public.dashboard_thresholds
    for select
    to service_role
    using (true);
