-- =====================================================
-- APPLY CRITICAL RLS AND DATA FIXES (CORRECTED)
-- =====================================================
-- This migration addresses verified security gaps:
-- 1. Enable RLS on 3 tables: notification_read_status, user_notifications, user_settings
-- 2. Populate empty dashboard_thresholds table
-- 3. Add missing RLS policies for analytics tables
-- =====================================================

-- =====================================================
-- 1. ENABLE RLS ON TABLES THAT ARE CURRENTLY DISABLED
-- =====================================================

-- Verified as disabled via pg_tables query
ALTER TABLE public.notification_read_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- 2. ADD MISSING RLS POLICIES FOR ANALYTICS TABLES
-- =====================================================

-- Recreate analytics_events policies
DROP POLICY IF EXISTS "analytics_events_admin_read" ON public.analytics_events;
DROP POLICY IF EXISTS "analytics_events_authenticated_insert" ON public.analytics_events;

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

-- =====================================================
-- 4. POPULATE DASHBOARD_THRESHOLDS TABLE (VERIFIED EMPTY)
-- =====================================================

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
-- 5. VALIDATION
-- =====================================================

DO $$
DECLARE
    disabled_count INTEGER;
    threshold_count INTEGER;
BEGIN
    -- Check RLS status on the 3 tables we fixed
    SELECT COUNT(*) INTO disabled_count
    FROM pg_tables
    WHERE schemaname = 'public'
    AND tablename IN ('notification_read_status', 'user_notifications', 'user_settings')
    AND rowsecurity = false;

    -- Check thresholds
    SELECT COUNT(*) INTO threshold_count
    FROM public.dashboard_thresholds;

    IF disabled_count > 0 THEN
        RAISE WARNING 'L % tables still have RLS disabled!', disabled_count;
    ELSE
        RAISE NOTICE ' All critical tables now have RLS enabled';
    END IF;

    IF threshold_count = 0 THEN
        RAISE WARNING 'L Dashboard thresholds table is still empty!';
    ELSE
        RAISE NOTICE ' Dashboard thresholds populated with % records', threshold_count;
    END IF;
END $$;

