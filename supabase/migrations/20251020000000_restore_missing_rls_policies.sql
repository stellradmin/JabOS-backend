-- =====================================================
-- RESTORE MISSING RLS POLICIES
-- =====================================================
-- This migration restores RLS policies that were created in earlier migrations
-- but are missing from the current database state.
-- Affected tables: user_settings, compatibility_scores, daily_metrics, error_logs, operational_metrics
-- Date: 2025-10-20
-- =====================================================

-- =====================================================
-- 1. USER_SETTINGS TABLE POLICIES
-- =====================================================

DROP POLICY IF EXISTS "Users can access own settings" ON public.user_settings;
DROP POLICY IF EXISTS "Service role full access" ON public.user_settings;

CREATE POLICY "Users can access own settings" ON public.user_settings
    FOR ALL
    USING (auth.uid() = user_id);

CREATE POLICY "Service role full access" ON public.user_settings
    FOR ALL
    TO service_role
    USING (true);

-- =====================================================
-- 2. COMPATIBILITY_SCORES TABLE POLICIES
-- =====================================================

DROP POLICY IF EXISTS "Users can view their own compatibility scores" ON public.compatibility_scores;
DROP POLICY IF EXISTS "Service role has full access to compatibility scores" ON public.compatibility_scores;
DROP POLICY IF EXISTS "Authenticated users can insert compatibility scores" ON public.compatibility_scores;
DROP POLICY IF EXISTS "Authenticated users can update compatibility scores" ON public.compatibility_scores;

CREATE POLICY "Users can view their own compatibility scores"
    ON public.compatibility_scores
    FOR SELECT
    USING (auth.uid() = user_id OR auth.uid() = potential_match_id);

CREATE POLICY "Service role has full access to compatibility scores"
    ON public.compatibility_scores
    FOR ALL
    TO service_role
    USING (true);

CREATE POLICY "Authenticated users can insert compatibility scores"
    ON public.compatibility_scores
    FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Authenticated users can update compatibility scores"
    ON public.compatibility_scores
    FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- =====================================================
-- 3. DAILY_METRICS TABLE POLICIES
-- =====================================================

DROP POLICY IF EXISTS "daily_metrics_admin_read" ON public.daily_metrics;
DROP POLICY IF EXISTS "daily_metrics_service_write" ON public.daily_metrics;

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

-- =====================================================
-- 4. ERROR_LOGS TABLE POLICIES
-- =====================================================

DROP POLICY IF EXISTS "error_logs_admin_read" ON public.error_logs;
DROP POLICY IF EXISTS "error_logs_authenticated_insert" ON public.error_logs;

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

-- =====================================================
-- 5. OPERATIONAL_METRICS TABLE POLICIES
-- =====================================================

DROP POLICY IF EXISTS "operational_metrics_admin_read" ON public.operational_metrics;
DROP POLICY IF EXISTS "operational_metrics_service_write" ON public.operational_metrics;

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
-- 6. VALIDATION REPORT
-- =====================================================

DO $$
DECLARE
    policy_count INTEGER;
    table_name TEXT;
    policy_record RECORD;
BEGIN
    RAISE NOTICE '
=====================================================
RLS POLICY RESTORATION REPORT
=====================================================';

    FOR table_name IN
        SELECT unnest(ARRAY['user_settings', 'compatibility_scores', 'daily_metrics', 'error_logs', 'operational_metrics'])
    LOOP
        SELECT COUNT(*) INTO policy_count
        FROM pg_policies
        WHERE schemaname = 'public'
        AND tablename = table_name;

        RAISE NOTICE '📊 Table: % - % policies', table_name, policy_count;

        IF policy_count = 0 THEN
            RAISE WARNING '⚠️  No policies found for table: %', table_name;
        ELSE
            FOR policy_record IN
                SELECT policyname
                FROM pg_policies
                WHERE schemaname = 'public'
                AND tablename = table_name
                ORDER BY policyname
            LOOP
                RAISE NOTICE '   ✅ %', policy_record.policyname;
            END LOOP;
        END IF;
    END LOOP;

    RAISE NOTICE '=====================================================';
END $$;

-- =====================================================
-- 7. COMMENTS
-- =====================================================

COMMENT ON POLICY "Users can access own settings" ON public.user_settings IS
'Users can view and modify their own settings. Service role has unrestricted access.';

COMMENT ON POLICY "Users can view their own compatibility scores" ON public.compatibility_scores IS
'Users can view compatibility scores where they are either the user or the potential match.';

COMMENT ON POLICY "daily_metrics_admin_read" ON public.daily_metrics IS
'Only active dashboard admins can read daily metrics. Service role can manage all data.';

COMMENT ON POLICY "error_logs_admin_read" ON public.error_logs IS
'Only active dashboard admins can read error logs. Authenticated users can insert their own errors.';

COMMENT ON POLICY "operational_metrics_admin_read" ON public.operational_metrics IS
'Only active dashboard admins can read operational metrics. Service role can manage all data.';
