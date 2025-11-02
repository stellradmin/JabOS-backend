-- =====================================================
-- FIX REMAINING AUTH RLS INITPLAN PERFORMANCE ISSUES
-- =====================================================
-- This migration wraps remaining auth.uid(), auth.role(), and auth.jwt() calls
-- in SELECT subqueries to prevent per-row re-evaluation in RLS policies.
-- Date: 2025-10-29
-- =====================================================

BEGIN;

-- =====================================================
-- 1. ISSUE_REPORTS TABLE
-- =====================================================

-- Drop existing policies
DROP POLICY IF EXISTS "Users can view their own issue reports" ON issue_reports;
DROP POLICY IF EXISTS "Users can insert their own issue reports" ON issue_reports;

-- Recreate with wrapped auth.uid()
CREATE POLICY "Users can view their own issue reports" ON issue_reports
    FOR SELECT USING ((SELECT auth.uid()) = user_id);

CREATE POLICY "Users can insert their own issue reports" ON issue_reports
    FOR INSERT WITH CHECK ((SELECT auth.uid()) = user_id);

-- =====================================================
-- 2. PHOTO_VERIFICATION_LOGS TABLE
-- =====================================================

-- Drop existing policies
DROP POLICY IF EXISTS "Users can view their own verification logs" ON photo_verification_logs;
DROP POLICY IF EXISTS "Users can insert their own verification logs" ON photo_verification_logs;

-- Recreate with wrapped auth.uid()
CREATE POLICY "Users can view their own verification logs"
ON photo_verification_logs FOR SELECT
USING ((SELECT auth.uid()) = user_id);

CREATE POLICY "Users can insert their own verification logs"
ON photo_verification_logs FOR INSERT
WITH CHECK ((SELECT auth.uid()) = user_id);

-- =====================================================
-- 3. PHOTO_MANUAL_REVIEW_QUEUE TABLE
-- =====================================================

-- Drop existing policies
DROP POLICY IF EXISTS "Service role can manage manual review queue" ON photo_manual_review_queue;

-- Recreate with wrapped auth.role()
CREATE POLICY "Service role can manage manual review queue"
ON photo_manual_review_queue FOR ALL
USING ((SELECT auth.role()) = 'service_role');

-- =====================================================
-- 4. PHOTO_VERIFICATION_SETTINGS TABLE
-- =====================================================

-- Drop existing policies
DROP POLICY IF EXISTS "Service role can manage verification settings" ON photo_verification_settings;

-- Recreate with wrapped auth.role()
CREATE POLICY "Service role can manage verification settings"
ON photo_verification_settings FOR ALL
USING ((SELECT auth.role()) = 'service_role');

-- =====================================================
-- 5. INVITE_USAGE_LOG TABLE
-- =====================================================

-- Drop existing policies
DROP POLICY IF EXISTS "Users can view their own invite usage" ON invite_usage_log;
DROP POLICY IF EXISTS "Service role can manage invite usage logs" ON invite_usage_log;

-- Recreate with wrapped auth functions
CREATE POLICY "Users can view their own invite usage" ON invite_usage_log
    FOR SELECT USING ((SELECT auth.uid()) = user_id);

CREATE POLICY "Service role can manage invite usage logs" ON invite_usage_log
    FOR ALL USING ((SELECT auth.role()) = 'service_role');

-- =====================================================
-- 6. USER_NOTIFICATIONS TABLE
-- =====================================================

-- Drop existing policies
DROP POLICY IF EXISTS "Users can view their own notifications" ON user_notifications;
DROP POLICY IF EXISTS "Users can update read status of their notifications" ON user_notifications;
DROP POLICY IF EXISTS "Service role can insert notifications" ON user_notifications;
DROP POLICY IF EXISTS "Service role can update notification status" ON user_notifications;

-- Recreate with wrapped auth functions
CREATE POLICY "Users can view their own notifications"
    ON user_notifications FOR SELECT
    USING ((SELECT auth.uid()) = user_id);

CREATE POLICY "Users can update read status of their notifications"
    ON user_notifications FOR UPDATE
    USING ((SELECT auth.uid()) = user_id)
    WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Service role can insert notifications"
    ON user_notifications FOR INSERT
    WITH CHECK (
        (SELECT auth.jwt()) ->> 'role' = 'service_role' OR
        (SELECT auth.uid()) = user_id
    );

CREATE POLICY "Service role can update notification status"
    ON user_notifications FOR UPDATE
    USING ((SELECT auth.jwt()) ->> 'role' = 'service_role');

-- =====================================================
-- 7. NOTIFICATION_READ_STATUS TABLE
-- =====================================================

-- Drop existing policies
DROP POLICY IF EXISTS "Users can view their own read status" ON notification_read_status;
DROP POLICY IF EXISTS "Users can insert their own read status" ON notification_read_status;
DROP POLICY IF EXISTS "Service role can manage read status" ON notification_read_status;

-- Recreate with wrapped auth functions
CREATE POLICY "Users can view their own read status"
    ON notification_read_status FOR SELECT
    USING ((SELECT auth.uid()) = user_id);

CREATE POLICY "Users can insert their own read status"
    ON notification_read_status FOR INSERT
    WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Service role can manage read status"
    ON notification_read_status FOR ALL
    USING ((SELECT auth.jwt()) ->> 'role' = 'service_role');

-- =====================================================
-- 8. NATAL_CHARTS TABLE
-- =====================================================

-- Drop existing policies
DROP POLICY IF EXISTS "Users can manage their natal chart" ON natal_charts;
DROP POLICY IF EXISTS "Service role full access to natal charts" ON natal_charts;

-- Recreate with wrapped auth functions
CREATE POLICY "Users can manage their natal chart" ON natal_charts
    FOR ALL USING ((SELECT auth.uid()) = user_id);

CREATE POLICY "Service role full access to natal charts" ON natal_charts
    FOR ALL USING ((SELECT auth.role()) = 'service_role');

-- =====================================================
-- 9. REVENUECAT_WEBHOOK_EVENTS TABLE
-- =====================================================

-- Drop existing policies
DROP POLICY IF EXISTS "Service role can manage webhook events" ON revenuecat_webhook_events;

-- Recreate with wrapped auth.role()
CREATE POLICY "Service role can manage webhook events" ON revenuecat_webhook_events
    FOR ALL USING ((SELECT auth.role()) = 'service_role');

-- =====================================================
-- 10. REVENUECAT_SUBSCRIPTIONS TABLE
-- =====================================================

-- Drop existing policies
DROP POLICY IF EXISTS "Users can view their own subscriptions" ON revenuecat_subscriptions;
DROP POLICY IF EXISTS "Service role can manage subscriptions" ON revenuecat_subscriptions;

-- Recreate with wrapped auth functions
CREATE POLICY "Users can view their own subscriptions" ON revenuecat_subscriptions
    FOR SELECT USING ((SELECT auth.uid()) = (SELECT auth_user_id FROM users WHERE id = user_id));

CREATE POLICY "Service role can manage subscriptions" ON revenuecat_subscriptions
    FOR ALL USING ((SELECT auth.role()) = 'service_role');

-- =====================================================
-- 11. REVENUECAT_ENTITLEMENTS TABLE
-- =====================================================

-- Drop existing policies
DROP POLICY IF EXISTS "Users can view their own entitlements" ON revenuecat_entitlements;
DROP POLICY IF EXISTS "Service role can manage entitlements" ON revenuecat_entitlements;

-- Recreate with wrapped auth functions
CREATE POLICY "Users can view their own entitlements" ON revenuecat_entitlements
    FOR SELECT USING ((SELECT auth.uid()) = (SELECT auth_user_id FROM users WHERE id = user_id));

CREATE POLICY "Service role can manage entitlements" ON revenuecat_entitlements
    FOR ALL USING ((SELECT auth.role()) = 'service_role');

-- =====================================================
-- VALIDATION & CONFIRMATION
-- =====================================================

DO $$
DECLARE
    policy_count INTEGER;
BEGIN
    -- Count updated policies
    SELECT COUNT(*) INTO policy_count
    FROM pg_policies
    WHERE schemaname = 'public'
    AND tablename IN (
        'issue_reports',
        'photo_verification_logs',
        'photo_manual_review_queue',
        'photo_verification_settings',
        'invite_usage_log',
        'user_notifications',
        'notification_read_status',
        'natal_charts',
        'revenuecat_webhook_events',
        'revenuecat_subscriptions',
        'revenuecat_entitlements'
    );

    RAISE NOTICE '✅ Auth RLS Initplan Fix Migration Complete';
    RAISE NOTICE '  - Fixed auth function wrapping in % policies across 11 tables', policy_count;
    RAISE NOTICE '  - All auth.uid(), auth.role(), and auth.jwt() calls now wrapped in SELECT subqueries';
    RAISE NOTICE '  - Performance should improve significantly for queries on these tables';
END $$;

COMMIT;
