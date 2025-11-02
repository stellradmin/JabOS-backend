-- PERFORMANCE OPTIMIZATIONS FOR MATCHING SYSTEM
-- Comprehensive index strategy and query optimizations

-- =====================================
-- SECTION 1: DROP REDUNDANT INDEXES
-- =====================================

-- Drop any redundant indexes that might exist
DROP INDEX IF EXISTS idx_matches_user_id;
DROP INDEX IF EXISTS idx_swipes_user_id;
DROP INDEX IF EXISTS idx_match_requests_user_id;

-- =====================================
-- SECTION 2: OPTIMIZED INDEXES
-- =====================================

-- Composite indexes for common query patterns

-- Match requests: Common queries by status and users (if table exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        CREATE INDEX IF NOT EXISTS idx_match_requests_requester_status 
            ON public.match_requests(requester_id, status, created_at DESC)
            WHERE status IN ('pending', 'active');

        CREATE INDEX IF NOT EXISTS idx_match_requests_matched_user_status 
            ON public.match_requests(matched_user_id, status, created_at DESC)
            WHERE status IN ('pending', 'active');
    END IF;
END $$;

-- Matches: Optimize for user lookups
CREATE INDEX IF NOT EXISTS idx_matches_user_lookup 
    ON public.matches(user1_id, user2_id, status)
    WHERE status = 'active';

-- Swipes: Optimize for duplicate checking and match detection
CREATE INDEX IF NOT EXISTS idx_swipes_mutual_check 
    ON public.swipes(swiper_id, swiped_id, swipe_type)
    WHERE swipe_type = 'like';

CREATE INDEX IF NOT EXISTS idx_swipes_reverse_lookup 
    ON public.swipes(swiped_id, swiper_id, swipe_type)
    WHERE swipe_type = 'like';

-- Profiles: Optimize for matching queries
CREATE INDEX IF NOT EXISTS idx_profiles_onboarding_complete 
    ON public.profiles(onboarding_completed, created_at DESC)
    WHERE onboarding_completed = true;

CREATE INDEX IF NOT EXISTS idx_profiles_zodiac_onboarding 
    ON public.profiles(zodiac_sign, onboarding_completed)
    WHERE onboarding_completed = true;

CREATE INDEX IF NOT EXISTS idx_profiles_age_onboarding 
    ON public.profiles(age, onboarding_completed)
    WHERE onboarding_completed = true AND age IS NOT NULL;

-- Users: Optimize for preference queries
CREATE INDEX IF NOT EXISTS idx_users_looking_for 
    ON public.users USING GIN(looking_for)
    WHERE looking_for IS NOT NULL AND looking_for != '{}';

-- Location-based queries (commented out - location column not in users table)
-- CREATE INDEX IF NOT EXISTS idx_users_location_gist 
--     ON public.users USING GIST(location)
--     WHERE location IS NOT NULL;

-- =====================================
-- SECTION 3: MATERIALIZED VIEWS
-- =====================================

-- Create materialized view for user match statistics (without match_requests for now)
CREATE MATERIALIZED VIEW IF NOT EXISTS public.user_match_stats AS
SELECT 
    u.id as user_id,
    COUNT(DISTINCT s.swiped_id) FILTER (WHERE s.swipe_type = 'like') as likes_sent,
    COUNT(DISTINCT s.swiped_id) FILTER (WHERE s.swipe_type = 'pass') as passes_sent,
    COUNT(DISTINCT s2.swiper_id) FILTER (WHERE s2.swipe_type = 'like') as likes_received,
    COUNT(DISTINCT m.id) FILTER (WHERE m.status = 'active') as active_matches,
    0 as pending_requests_sent, -- Placeholder until match_requests table is created
    0 as pending_requests_received, -- Placeholder until match_requests table is created
    MAX(GREATEST(s.created_at, s2.created_at, m.created_at)) as last_activity
FROM public.users u
LEFT JOIN public.swipes s ON s.swiper_id = u.id
LEFT JOIN public.swipes s2 ON s2.swiped_id = u.id
LEFT JOIN public.matches m ON (m.user1_id = u.id OR m.user2_id = u.id)
GROUP BY u.id;

-- Create indexes on materialized view
CREATE UNIQUE INDEX idx_user_match_stats_user_id ON public.user_match_stats(user_id);
CREATE INDEX idx_user_match_stats_last_activity ON public.user_match_stats(last_activity DESC NULLS LAST);

-- =====================================
-- SECTION 4: OPTIMIZED FUNCTIONS
-- =====================================

-- Optimized function to get match status between two users
CREATE OR REPLACE FUNCTION public.get_match_status_fast(
    p_user1_id UUID,
    p_user2_id UUID
)
RETURNS TABLE (
    is_matched BOOLEAN,
    match_id UUID,
    has_swiped BOOLEAN,
    swipe_type TEXT,
    has_pending_request BOOLEAN,
    request_id UUID
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_user1 UUID := LEAST(p_user1_id, p_user2_id);
    v_user2 UUID := GREATEST(p_user1_id, p_user2_id);
BEGIN
    RETURN QUERY
    WITH match_check AS (
        SELECT m.id, true as is_matched
        FROM public.matches m
        WHERE m.user1_id = v_user1 AND m.user2_id = v_user2 AND m.status = 'active'
        LIMIT 1
    ),
    swipe_check AS (
        SELECT s.swipe_type, true as has_swiped
        FROM public.swipes s
        WHERE s.swiper_id = p_user1_id AND s.swiped_id = p_user2_id
        LIMIT 1
    ),
    request_check AS (
        -- Placeholder query since match_requests table doesn't exist yet
        SELECT NULL::UUID as id, false as has_request
        WHERE false
    )
    SELECT 
        COALESCE(mc.is_matched, false),
        mc.id,
        COALESCE(sc.has_swiped, false),
        sc.swipe_type,
        COALESCE(rc.has_request, false),
        rc.id
    FROM (SELECT 1) dummy
    LEFT JOIN match_check mc ON true
    LEFT JOIN swipe_check sc ON true
    LEFT JOIN request_check rc ON true;
END;
$$;

-- =====================================
-- SECTION 5: QUERY OPTIMIZATION SETTINGS
-- =====================================

-- Function to set optimal query planner settings for matching queries
CREATE OR REPLACE FUNCTION public.optimize_matching_session()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Increase work memory for sorting and joins
    SET LOCAL work_mem = '32MB';
    
    -- Optimize for read-heavy workload
    SET LOCAL random_page_cost = 1.1;
    
    -- Enable parallel queries
    SET LOCAL max_parallel_workers_per_gather = 4;
    
    -- Optimize join planning
    SET LOCAL join_collapse_limit = 12;
END;
$$;

-- =====================================
-- SECTION 6: REFRESH FUNCTIONS
-- =====================================

-- Function to refresh materialized views
CREATE OR REPLACE FUNCTION public.refresh_match_stats()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.user_match_stats;
END;
$$;

-- =====================================
-- SECTION 7: VACUUM AND ANALYZE
-- =====================================

-- Note: VACUUM cannot be run within a migration transaction
-- Run these commands manually after migration:
-- VACUUM ANALYZE public.profiles;
-- VACUUM ANALYZE public.users;
-- VACUUM ANALYZE public.matches;
-- VACUUM ANALYZE public.swipes;

-- =====================================
-- SECTION 8: PERMISSIONS
-- =====================================

GRANT SELECT ON public.user_match_stats TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_match_status_fast TO authenticated;
GRANT EXECUTE ON FUNCTION public.optimize_matching_session TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_match_stats TO service_role;

-- =====================================
-- SECTION 9: SCHEDULED JOBS
-- =====================================

-- Note: These would typically be set up using pg_cron or external schedulers
-- Example commands for reference:

-- Schedule stats refresh every hour
-- SELECT cron.schedule('refresh-match-stats', '0 * * * *', 'SELECT public.refresh_match_stats();');

-- Schedule audit log cleanup weekly
-- SELECT cron.schedule('cleanup-audit-logs', '0 3 * * 0', 'SELECT public.cleanup_old_audit_logs();');

-- =====================================
-- SECTION 10: COMMENTS
-- =====================================

COMMENT ON MATERIALIZED VIEW public.user_match_stats IS 'Cached statistics for user matching activity';
COMMENT ON FUNCTION public.get_match_status_fast IS 'Optimized function to check match status between users';
COMMENT ON FUNCTION public.optimize_matching_session IS 'Set optimal query planner settings for matching queries';
COMMENT ON FUNCTION public.refresh_match_stats IS 'Refresh user match statistics materialized view';