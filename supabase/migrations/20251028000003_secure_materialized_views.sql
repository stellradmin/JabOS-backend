-- ===============================================================
-- SECURE MATERIALIZED VIEWS IN API
-- Version: 1.0
-- Date: 2025-10-28
-- Purpose: Add RLS policies to materialized views exposed via PostgREST API
-- Reference: https://supabase.com/docs/guides/database/database-linter?lint=0016_materialized_view_in_api
-- ===============================================================

-- =====================================
-- SECURITY NOTE
-- =====================================
-- Materialized views accessible via the Data APIs can expose sensitive data
-- or enable expensive queries. We need to:
-- 1. Enable RLS on materialized views
-- 2. Add appropriate access policies
-- 3. Consider if these views should be accessible via API at all
-- =====================================

-- =====================================
-- SECTION 1: ENABLE RLS ON MATERIALIZED VIEWS
-- =====================================

-- 1. user_match_stats
ALTER MATERIALIZED VIEW IF EXISTS public.user_match_stats
    SET (security_invoker = true);

DO $$
BEGIN
    -- Enable RLS if the materialized view exists
    IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'public'
          AND c.relname = 'user_match_stats'
          AND c.relkind = 'm'
    ) THEN
        ALTER MATERIALIZED VIEW public.user_match_stats ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'Enabled RLS on user_match_stats';
    END IF;
END $$;

-- Create policy for user_match_stats - users can only see their own stats
DO $$
BEGIN
    DROP POLICY IF EXISTS "Users can view their own match stats" ON public.user_match_stats;

    CREATE POLICY "Users can view their own match stats"
        ON public.user_match_stats
        FOR SELECT
        TO authenticated
        USING (user_id = auth.uid());

    RAISE NOTICE 'Created RLS policy for user_match_stats';
EXCEPTION
    WHEN undefined_table THEN
        RAISE NOTICE 'user_match_stats does not exist, skipping policy creation';
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to create policy for user_match_stats: %', SQLERRM;
END $$;

-- 2. user_engagement_stats
ALTER MATERIALIZED VIEW IF EXISTS public.user_engagement_stats
    SET (security_invoker = true);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'public'
          AND c.relname = 'user_engagement_stats'
          AND c.relkind = 'm'
    ) THEN
        ALTER MATERIALIZED VIEW public.user_engagement_stats ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'Enabled RLS on user_engagement_stats';
    END IF;
END $$;

-- Create policy for user_engagement_stats
DO $$
BEGIN
    DROP POLICY IF EXISTS "Users can view their own engagement stats" ON public.user_engagement_stats;

    CREATE POLICY "Users can view their own engagement stats"
        ON public.user_engagement_stats
        FOR SELECT
        TO authenticated
        USING (user_id = auth.uid());

    RAISE NOTICE 'Created RLS policy for user_engagement_stats';
EXCEPTION
    WHEN undefined_table THEN
        RAISE NOTICE 'user_engagement_stats does not exist, skipping policy creation';
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to create policy for user_engagement_stats: %', SQLERRM;
END $$;

-- 3. user_matching_summary
ALTER MATERIALIZED VIEW IF EXISTS public.user_matching_summary
    SET (security_invoker = true);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'public'
          AND c.relname = 'user_matching_summary'
          AND c.relkind = 'm'
    ) THEN
        ALTER MATERIALIZED VIEW public.user_matching_summary ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'Enabled RLS on user_matching_summary';
    END IF;
END $$;

-- Create policy for user_matching_summary
DO $$
BEGIN
    DROP POLICY IF EXISTS "Users can view their own matching summary" ON public.user_matching_summary;

    CREATE POLICY "Users can view their own matching summary"
        ON public.user_matching_summary
        FOR SELECT
        TO authenticated
        USING (user_id = auth.uid());

    RAISE NOTICE 'Created RLS policy for user_matching_summary';
EXCEPTION
    WHEN undefined_table THEN
        RAISE NOTICE 'user_matching_summary does not exist, skipping policy creation';
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to create policy for user_matching_summary: %', SQLERRM;
END $$;

-- 4. user_compatibility_cache
ALTER MATERIALIZED VIEW IF EXISTS public.user_compatibility_cache
    SET (security_invoker = true);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'public'
          AND c.relname = 'user_compatibility_cache'
          AND c.relkind = 'm'
    ) THEN
        ALTER MATERIALIZED VIEW public.user_compatibility_cache ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'Enabled RLS on user_compatibility_cache';
    END IF;
END $$;

-- Create policy for user_compatibility_cache - users can see compatibility with users they're matched with
DO $$
BEGIN
    DROP POLICY IF EXISTS "Users can view compatibility with their matches" ON public.user_compatibility_cache;

    CREATE POLICY "Users can view compatibility with their matches"
        ON public.user_compatibility_cache
        FOR SELECT
        TO authenticated
        USING (
            user1_id = auth.uid() OR user2_id = auth.uid()
        );

    RAISE NOTICE 'Created RLS policy for user_compatibility_cache';
EXCEPTION
    WHEN undefined_table THEN
        RAISE NOTICE 'user_compatibility_cache does not exist, skipping policy creation';
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to create policy for user_compatibility_cache: %', SQLERRM;
END $$;

-- 5. conversation_summary_cache
ALTER MATERIALIZED VIEW IF EXISTS public.conversation_summary_cache
    SET (security_invoker = true);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'public'
          AND c.relname = 'conversation_summary_cache'
          AND c.relkind = 'm'
    ) THEN
        ALTER MATERIALIZED VIEW public.conversation_summary_cache ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'Enabled RLS on conversation_summary_cache';
    END IF;
END $$;

-- Create policy for conversation_summary_cache - users can see their own conversations
DO $$
BEGIN
    DROP POLICY IF EXISTS "Users can view their own conversation summaries" ON public.conversation_summary_cache;

    CREATE POLICY "Users can view their own conversation summaries"
        ON public.conversation_summary_cache
        FOR SELECT
        TO authenticated
        USING (
            user1_id = auth.uid() OR user2_id = auth.uid()
        );

    RAISE NOTICE 'Created RLS policy for conversation_summary_cache';
EXCEPTION
    WHEN undefined_table THEN
        RAISE NOTICE 'conversation_summary_cache does not exist, skipping policy creation';
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to create policy for conversation_summary_cache: %', SQLERRM;
END $$;

-- =====================================
-- SECTION 2: GRANT APPROPRIATE PERMISSIONS
-- =====================================

-- Grant SELECT to authenticated users (RLS will control actual access)
DO $$
BEGIN
    GRANT SELECT ON public.user_match_stats TO authenticated;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    GRANT SELECT ON public.user_engagement_stats TO authenticated;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    GRANT SELECT ON public.user_matching_summary TO authenticated;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    GRANT SELECT ON public.user_compatibility_cache TO authenticated;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    GRANT SELECT ON public.conversation_summary_cache TO authenticated;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

-- Grant ALL to service_role (bypasses RLS)
DO $$
BEGIN
    GRANT ALL ON public.user_match_stats TO service_role;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    GRANT ALL ON public.user_engagement_stats TO service_role;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    GRANT ALL ON public.user_matching_summary TO service_role;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    GRANT ALL ON public.user_compatibility_cache TO service_role;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    GRANT ALL ON public.conversation_summary_cache TO service_role;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

-- =====================================
-- SECTION 3: ADD REFRESH FUNCTIONS
-- =====================================

-- Create a secure function to refresh materialized views
-- This can be called by a cron job or triggered by events
CREATE OR REPLACE FUNCTION public.refresh_materialized_views()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    -- Refresh all materialized views concurrently where possible
    REFRESH MATERIALIZED VIEW CONCURRENTLY IF EXISTS public.user_match_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY IF EXISTS public.user_engagement_stats;
    REFRESH MATERIALIZED VIEW CONCURRENTLY IF EXISTS public.user_matching_summary;
    REFRESH MATERIALIZED VIEW CONCURRENTLY IF EXISTS public.user_compatibility_cache;
    REFRESH MATERIALIZED VIEW CONCURRENTLY IF EXISTS public.conversation_summary_cache;

    -- Log the refresh
    INSERT INTO public.materialized_view_performance (view_name, refreshed_at)
    VALUES
        ('user_match_stats', NOW()),
        ('user_engagement_stats', NOW()),
        ('user_matching_summary', NOW()),
        ('user_compatibility_cache', NOW()),
        ('conversation_summary_cache', NOW())
    ON CONFLICT (view_name) DO UPDATE
        SET refreshed_at = EXCLUDED.refreshed_at,
            refresh_count = public.materialized_view_performance.refresh_count + 1;

EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Error refreshing materialized views: %', SQLERRM;
END;
$$;

COMMENT ON FUNCTION public.refresh_materialized_views() IS
    'Refreshes all materialized views and logs the refresh time. Should be called by a cron job.';

-- Grant execute to service_role only
REVOKE ALL ON FUNCTION public.refresh_materialized_views() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_materialized_views() TO service_role;

-- =====================================
-- SECTION 4: DOCUMENTATION
-- =====================================

DO $$
BEGIN
    COMMENT ON MATERIALIZED VIEW public.user_match_stats IS
        'Materialized view caching user match statistics. RLS enabled - users can only see their own stats. Refresh via refresh_materialized_views().';
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    COMMENT ON MATERIALIZED VIEW public.user_engagement_stats IS
        'Materialized view caching user engagement metrics. RLS enabled - users can only see their own stats. Refresh via refresh_materialized_views().';
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    COMMENT ON MATERIALIZED VIEW public.user_matching_summary IS
        'Materialized view caching user matching summaries. RLS enabled - users can only see their own summary. Refresh via refresh_materialized_views().';
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    COMMENT ON MATERIALIZED VIEW public.user_compatibility_cache IS
        'Materialized view caching compatibility scores. RLS enabled - users can only see compatibility with their matches. Refresh via refresh_materialized_views().';
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    COMMENT ON MATERIALIZED VIEW public.conversation_summary_cache IS
        'Materialized view caching conversation summaries. RLS enabled - users can only see their own conversations. Refresh via refresh_materialized_views().';
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

-- =====================================
-- NOTES
-- =====================================
-- After running this migration:
--
-- 1. Set up a cron job to refresh materialized views:
--    SELECT cron.schedule('refresh-materialized-views', '*/15 * * * *',
--        'SELECT public.refresh_materialized_views()');
--
-- 2. Monitor materialized view performance:
--    SELECT * FROM public.materialized_view_performance
--    ORDER BY refreshed_at DESC;
--
-- 3. Consider if all materialized views need to be accessible via API:
--    - If not, revoke SELECT from authenticated role
--    - If yes, ensure RLS policies are correctly configured
-- =====================================
