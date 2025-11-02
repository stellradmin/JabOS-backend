-- =====================================================
-- CRITICAL RLS SECURITY FIXES
-- =====================================================
-- This migration addresses all identified security vulnerabilities:
-- 1. Ensures RLS is enabled on all critical tables
-- 2. Adds missing RLS policies where needed
-- 3. Revokes overly permissive grants on materialized views
-- 4. Adds search_path to functions for SQL injection prevention
--
-- Date: 2025-10-08
-- Version: 1.0.0
-- =====================================================

-- =====================================================
-- 1. VERIFY AND FIX RLS ON CRITICAL TABLES
-- =====================================================

-- Ensure RLS is enabled on all critical tables
DO $$
DECLARE
    v_table_name TEXT;
    table_count INTEGER := 0;
BEGIN
    -- List of critical tables that MUST have RLS
    FOR v_table_name IN
        SELECT unnest(ARRAY[
            'user_settings',
            'user_notifications',
            'notification_read_status',
            'analytics_events',
            'daily_metrics',
            'error_logs',
            'match_metrics',
            'operational_metrics',
            'dashboard_thresholds',
            'threshold_history',
            'user_settings_changelog',
            'dashboard_admins',
            'compatibility_score_cache',
            'materialized_view_refresh_schedule'
        ])
    LOOP
        -- Check if table exists and enable RLS
        IF EXISTS (
            SELECT 1 FROM information_schema.tables t
            WHERE t.table_schema = 'public'
            AND t.table_name = v_table_name
        ) THEN
            EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', v_table_name);
            table_count := table_count + 1;
            RAISE NOTICE '✅ RLS enabled on: %', v_table_name;
        END IF;
    END LOOP;

    RAISE NOTICE '📊 Total tables with RLS enabled: %', table_count;
END $$;

-- =====================================================
-- 2. ADD MISSING RLS POLICIES FOR ANALYTICS TABLES
-- =====================================================

-- Ensure all analytics tables have proper read policies
-- These were created but might have been disabled

-- Drop existing policies if they exist to recreate them
DROP POLICY IF EXISTS "analytics_events_admin_read" ON public.analytics_events;
DROP POLICY IF EXISTS "analytics_events_authenticated_insert" ON public.analytics_events;
DROP POLICY IF EXISTS "daily_metrics_admin_read" ON public.daily_metrics;
DROP POLICY IF EXISTS "error_logs_admin_read" ON public.error_logs;
DROP POLICY IF EXISTS "error_logs_authenticated_insert" ON public.error_logs;
DROP POLICY IF EXISTS "match_metrics_admin_read" ON public.match_metrics;
DROP POLICY IF EXISTS "operational_metrics_admin_read" ON public.operational_metrics;

-- Recreate policies with proper security

-- Analytics Events
CREATE POLICY "analytics_events_admin_read" ON public.analytics_events
    FOR SELECT
    USING (
        auth.uid() IS NOT NULL
        AND public.is_active_dashboard_admin(auth.uid())
    );

CREATE POLICY "analytics_events_authenticated_insert" ON public.analytics_events
    FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = user_id OR user_id IS NULL);

-- Daily Metrics
-- Drop existing policies if they exist to avoid conflicts
DROP POLICY IF EXISTS "daily_metrics_admin_read" ON public.daily_metrics;
DROP POLICY IF EXISTS "daily_metrics_service_write" ON public.daily_metrics;
DROP POLICY IF EXISTS "error_logs_admin_read" ON public.error_logs;
DROP POLICY IF EXISTS "error_logs_authenticated_insert" ON public.error_logs;
DROP POLICY IF EXISTS "match_metrics_admin_read" ON public.match_metrics;
DROP POLICY IF EXISTS "match_metrics_service_write" ON public.match_metrics;
DROP POLICY IF EXISTS "operational_metrics_admin_read" ON public.operational_metrics;
DROP POLICY IF EXISTS "operational_metrics_service_write" ON public.operational_metrics;
DROP POLICY IF EXISTS "dashboard_thresholds_admin_manage" ON public.dashboard_thresholds;
DROP POLICY IF EXISTS "threshold_history_admin_read" ON public.threshold_history;

CREATE POLICY "daily_metrics_admin_read" ON public.daily_metrics
    FOR SELECT
    USING (
        auth.uid() IS NOT NULL
        AND public.is_active_dashboard_admin(auth.uid())
    );

CREATE POLICY "daily_metrics_service_write" ON public.daily_metrics
    FOR ALL
    TO service_role
    USING (true);

-- Error Logs
CREATE POLICY "error_logs_admin_read" ON public.error_logs
    FOR SELECT
    USING (
        auth.uid() IS NOT NULL
        AND public.is_active_dashboard_admin(auth.uid())
    );

CREATE POLICY "error_logs_authenticated_insert" ON public.error_logs
    FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = user_id OR user_id IS NULL);

-- Match Metrics
CREATE POLICY "match_metrics_admin_read" ON public.match_metrics
    FOR SELECT
    USING (
        auth.uid() IS NOT NULL
        AND public.is_active_dashboard_admin(auth.uid())
    );

CREATE POLICY "match_metrics_service_write" ON public.match_metrics
    FOR ALL
    TO service_role
    USING (true);

-- Operational Metrics
CREATE POLICY "operational_metrics_admin_read" ON public.operational_metrics
    FOR SELECT
    USING (
        auth.uid() IS NOT NULL
        AND public.is_active_dashboard_admin(auth.uid())
    );

CREATE POLICY "operational_metrics_service_write" ON public.operational_metrics
    FOR ALL
    TO service_role
    USING (true);

-- =====================================================
-- 3. SECURE MATERIALIZED VIEW ACCESS
-- =====================================================

-- Revoke direct SELECT on materialized views from anon
-- Access should only be via SECURITY DEFINER functions

DO $$
DECLARE
    mv_name TEXT;
BEGIN
    FOR mv_name IN
        SELECT unnest(array_agg(matviewname))
        FROM pg_matviews
        WHERE schemaname = 'public'
    LOOP
        -- Revoke from anon
        EXECUTE format('REVOKE SELECT ON %I FROM anon', mv_name);
        -- Grant only to authenticated
        EXECUTE format('GRANT SELECT ON %I TO authenticated', mv_name);
        RAISE NOTICE '🔒 Secured materialized view: %', mv_name;
    END LOOP;
END $$;

-- =====================================================
-- 4. ADD MISSING RLS POLICY FOR COMPATIBILITY CACHE
-- =====================================================

-- This table was created but may be missing RLS policies
ALTER TABLE public.compatibility_score_cache ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "compatibility_cache_user_read" ON public.compatibility_score_cache;
CREATE POLICY "compatibility_cache_user_read" ON public.compatibility_score_cache
    FOR SELECT
    USING (
        auth.uid() IS NOT NULL AND
        (auth.uid() = user1_id OR auth.uid() = user2_id)
    );

DROP POLICY IF EXISTS "compatibility_cache_service_manage" ON public.compatibility_score_cache;
CREATE POLICY "compatibility_cache_service_manage" ON public.compatibility_score_cache
    FOR ALL
    TO service_role
    USING (true);

GRANT SELECT ON public.compatibility_score_cache TO authenticated;

-- =====================================================
-- 5. ADD SEARCH_PATH TO HIGH-RISK FUNCTIONS
-- =====================================================
-- Prevents SQL injection by explicitly setting search path

-- Get all functions missing search_path
DO $$
DECLARE
    func_record RECORD;
    fixed_count INTEGER := 0;
BEGIN
    FOR func_record IN
        SELECT
            p.proname as function_name,
            n.nspname as schema_name,
            pg_get_function_identity_arguments(p.oid) as args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
        AND p.prosecdef = true  -- SECURITY DEFINER functions
        AND NOT EXISTS (
            SELECT 1
            FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) AS config_item
            WHERE split_part(config_item, '=', 1) = 'search_path'
        )
        AND p.proname NOT LIKE 'pg_%'
        AND p.proname NOT LIKE 'uuid_%'
        LIMIT 100  -- Process in batches
    LOOP
        -- Add search_path to function
        BEGIN
            EXECUTE format(
                'ALTER FUNCTION public.%I(%s) SET search_path = public, auth, extensions',
                func_record.function_name,
                func_record.args
            );
            fixed_count := fixed_count + 1;

            IF fixed_count <= 10 THEN
                RAISE NOTICE '🔧 Fixed search_path for: %(%)',
                    func_record.function_name,
                    func_record.args;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING 'Failed to fix function %: %',
                    func_record.function_name,
                    SQLERRM;
        END;
    END LOOP;

    RAISE NOTICE '📊 Total functions fixed: %', fixed_count;

    IF fixed_count = 100 THEN
        RAISE NOTICE 'ℹ️  More functions may need fixing. Run this migration again or create a follow-up.';
    END IF;
END $$;

-- =====================================================
-- 6. VERIFY DASHBOARD THRESHOLD DATA
-- =====================================================

-- Ensure dashboard_thresholds table has required data
INSERT INTO public.dashboard_thresholds (metric_name, warning_threshold, critical_threshold, metadata, updated_at)
VALUES
    ('active_users', 800, 1200, jsonb_build_object('window_minutes', 5, 'direction', 'above', 'unit', 'users'), NOW()),
    ('matches_created', 150, 250, jsonb_build_object('window_minutes', 5, 'direction', 'above', 'unit', 'matches'), NOW()),
    ('critical_errors', 5, 10, jsonb_build_object('window_minutes', 5, 'direction', 'above', 'unit', 'errors'), NOW()),
    ('match_rate_today', 0.08, 0.05, jsonb_build_object('goal', 'ratio', 'direction', 'below', 'unit', 'ratio'), NOW())
ON CONFLICT (metric_name) DO UPDATE SET
    warning_threshold = EXCLUDED.warning_threshold,
    critical_threshold = EXCLUDED.critical_threshold,
    metadata = EXCLUDED.metadata,
    updated_at = EXCLUDED.updated_at;

-- =====================================================
-- 7. SECURITY VALIDATION REPORT
-- =====================================================

-- Generate security validation report
DO $$
DECLARE
    total_tables INTEGER;
    tables_with_rls INTEGER;
    tables_without_rls INTEGER;
    rls_coverage NUMERIC;
    policy_count INTEGER;
    table_record RECORD;
BEGIN
    -- Count total public tables
    SELECT COUNT(*) INTO total_tables
    FROM information_schema.tables
    WHERE table_schema = 'public'
    AND table_type = 'BASE TABLE';

    -- Count tables with RLS enabled
    SELECT COUNT(*) INTO tables_with_rls
    FROM pg_tables
    WHERE schemaname = 'public'
    AND rowsecurity = true;

    tables_without_rls := total_tables - tables_with_rls;

    IF total_tables > 0 THEN
        rls_coverage := (tables_with_rls::NUMERIC / total_tables::NUMERIC) * 100;
    ELSE
        rls_coverage := 0;
    END IF;

    -- Count total RLS policies
    SELECT COUNT(*) INTO policy_count
    FROM pg_policies
    WHERE schemaname = 'public';

    RAISE NOTICE '
==============================================
SECURITY VALIDATION REPORT
==============================================
📊 Total Tables: %
✅ Tables with RLS: % (%.1f%%)
❌ Tables without RLS: %
🔐 Total RLS Policies: %
==============================================
    ', total_tables, tables_with_rls, rls_coverage, tables_without_rls, policy_count;

    -- List tables without RLS if any
    IF tables_without_rls > 0 THEN
        RAISE NOTICE '⚠️  Tables without RLS:';
        FOR table_record IN
            SELECT tablename
            FROM pg_tables
            WHERE schemaname = 'public'
            AND rowsecurity = false
            ORDER BY tablename
        LOOP
            RAISE NOTICE '  - %', table_record.tablename;
        END LOOP;
    END IF;
END $$;

-- =====================================================
-- 8. GRANT CLEANUP
-- =====================================================

-- Remove any overly permissive grants
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon;

-- Grant minimal necessary permissions
GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Specific grants for authenticated users are handled by RLS policies

-- =====================================================
-- 9. COMMENTS AND DOCUMENTATION
-- =====================================================

COMMENT ON TABLE public.user_settings IS 'User preferences and settings - SECURED with RLS (users can only access own settings)';
COMMENT ON TABLE public.analytics_events IS 'Analytics events - SECURED with RLS (admin read only)';
COMMENT ON TABLE public.daily_metrics IS 'Daily metrics - SECURED with RLS (admin read, service write)';
COMMENT ON TABLE public.error_logs IS 'Error logs - SECURED with RLS (admin read, user insert own errors)';
COMMENT ON TABLE public.compatibility_score_cache IS 'Compatibility scores - SECURED with RLS (users can only see scores involving them)';

COMMIT;

-- =====================================================
-- VERIFICATION QUERIES
-- =====================================================
-- Run these manually to verify the migration:
--
-- 1. Check RLS status:
-- SELECT tablename, rowsecurity
-- FROM pg_tables
-- WHERE schemaname = 'public'
-- ORDER BY tablename;
--
-- 2. Check policies:
-- SELECT tablename, policyname, cmd, qual
-- FROM pg_policies
-- WHERE schemaname = 'public'
-- ORDER BY tablename, policyname;
--
-- 3. Check function search_paths:
-- SELECT
--     p.proname,
--     pg_get_function_identity_arguments(p.oid) as args,
--     (SELECT unnest FROM pg_proc_config(p.oid) WHERE split_part(unnest, '=', 1) = 'search_path') as search_path
-- FROM pg_proc p
-- JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public'
-- AND p.prosecdef = true
-- ORDER BY p.proname;
--
-- 4. Verify threshold data:
-- SELECT * FROM public.dashboard_thresholds ORDER BY metric_name;
-- =====================================================
