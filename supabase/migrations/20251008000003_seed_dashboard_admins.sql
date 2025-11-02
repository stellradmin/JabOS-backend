-- Seed initial dashboard administrators
-- Run this migration AFTER 20251005_create_analytics_monitoring_schema.sql

-- ============================================================================
-- IMPORTANT: Update auth_user_id values before running this migration!
-- ============================================================================
-- To get auth user IDs, run this query in Supabase SQL Editor:
--
-- SELECT id, email, created_at
-- FROM auth.users
-- WHERE email IN ('ops@stellr.app', 'admin@stellr.app')
-- ORDER BY created_at DESC;
-- ============================================================================

-- Insert dashboard administrators
-- Replace <auth_user_uuid_1>, <auth_user_uuid_2> with actual UUID values from auth.users table

insert into public.dashboard_admins (
  auth_user_id,
  email,
  full_name,
  role,
  permissions,
  active,
  metadata
)
values
  -- Super Admin - Full system access
  (
    null, -- TODO: Replace with actual auth.users.id for ops@stellr.app
    'ops@stellr.app',
    'Operations Lead',
    'super_admin',
    jsonb_build_array(
      'view_all_metrics',
      'manage_thresholds',
      'manage_alerts',
      'view_error_logs',
      'manage_admins'
    ),
    true,
    jsonb_build_object(
      'department', 'operations',
      'timezone', 'UTC',
      'notification_channels', jsonb_build_array('email', 'slack')
    )
  ),

  -- Operator - Operations monitoring and alerting
  (
    null, -- TODO: Replace with actual auth.users.id for monitor@stellr.app
    'monitor@stellr.app',
    'System Monitor',
    'operator',
    jsonb_build_array(
      'view_all_metrics',
      'manage_alerts',
      'view_error_logs'
    ),
    true,
    jsonb_build_object(
      'department', 'engineering',
      'timezone', 'UTC',
      'notification_channels', jsonb_build_array('slack')
    )
  ),

  -- Analyst - Read-only analytics access
  (
    null, -- TODO: Replace with actual auth.users.id for analytics@stellr.app
    'analytics@stellr.app',
    'Data Analyst',
    'analyst',
    jsonb_build_array(
      'view_all_metrics',
      'export_data'
    ),
    true,
    jsonb_build_object(
      'department', 'analytics',
      'timezone', 'America/Los_Angeles',
      'notification_channels', jsonb_build_array('email')
    )
  )
on conflict (email)
do update set
  full_name = excluded.full_name,
  role = excluded.role,
  permissions = excluded.permissions,
  metadata = excluded.metadata,
  updated_at = now();

-- ============================================================================
-- MANUAL SEEDING TEMPLATE (If you prefer to run manually)
-- ============================================================================
-- Run this in Supabase SQL Editor after getting the auth_user_id:
--
-- INSERT INTO public.dashboard_admins (auth_user_id, email, full_name, role)
-- VALUES ('<auth_user_uuid>', 'your-email@stellr.app', 'Your Full Name', 'super_admin')
-- ON CONFLICT (email) DO NOTHING;
-- ============================================================================

-- ============================================================================
-- VERIFY SEEDING
-- ============================================================================
-- Check all dashboard admins:
--
-- SELECT
--   da.email,
--   da.full_name,
--   da.role,
--   da.active,
--   da.permissions,
--   da.created_at,
--   au.email as auth_email,
--   au.confirmed_at as auth_confirmed
-- FROM public.dashboard_admins da
-- LEFT JOIN auth.users au ON au.id = da.auth_user_id
-- ORDER BY da.created_at DESC;
-- ============================================================================

-- Grant necessary permissions to authenticated users to view their own admin record
grant select on table public.dashboard_admins to authenticated;

-- Create helper function to check if current user is a dashboard admin
create or replace function public.current_user_dashboard_role()
returns text
language sql
stable
security definer
as $$
  select role::text
  from public.dashboard_admins
  where auth_user_id = auth.uid()
    and active = true
  limit 1;
$$;

comment on function public.current_user_dashboard_role() is 'Returns the dashboard role of the currently authenticated user, or null if not a dashboard admin';

grant execute on function public.current_user_dashboard_role() to authenticated;
