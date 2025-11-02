-- Production Query Optimization for Stellr
-- Additional indexes and query optimizations for high-performance matching and messaging

-- Note: This migration is commented out due to schema mismatches
-- Uncomment and adjust when schema is finalized

/*

-- Geospatial index for location-based matching
CREATE INDEX IF NOT EXISTS idx_profiles_location_gist 
ON profiles USING GIST (location) 
WHERE location IS NOT NULL AND onboarding_completed = true;

-- Index for zodiac sign filtering (very common in dating apps)
CREATE INDEX IF NOT EXISTS idx_profiles_zodiac_active 
ON profiles (zodiac_sign, created_at) 
WHERE zodiac_sign IS NOT NULL AND onboarding_completed = true;

-- Composite index for age range filtering
CREATE INDEX IF NOT EXISTS idx_profiles_age_range_optimized 
ON profiles (age, gender, onboarding_completed, created_at) 
WHERE onboarding_completed = true AND age BETWEEN 18 AND 100;

-- Index for interests matching (array operations)
CREATE INDEX IF NOT EXISTS idx_profiles_interests_gin 
ON profiles USING GIN (interests) 
WHERE interests IS NOT NULL AND array_length(interests, 1) > 0;

-- ======================
-- SWIPE & MATCH OPTIMIZATION
-- ======================

-- Optimized index for swipe exclusions (critical for match finding)
CREATE INDEX IF NOT EXISTS idx_swipes_exclusion_optimized 
ON swipes (swiper_id, swiped_id, created_at DESC);

-- Index for mutual swipe detection (match creation)
CREATE INDEX IF NOT EXISTS idx_swipes_mutual_detection 
ON swipes (swiped_id, swiper_id, swipe_type) 
WHERE swipe_type = 'like';

-- Index for recent swipe analysis
CREATE INDEX IF NOT EXISTS idx_swipes_recent_activity 
ON swipes (swiper_id, created_at DESC) 
WHERE created_at >= NOW() - INTERVAL '30 days';

-- Optimized matches lookup
CREATE INDEX IF NOT EXISTS idx_matches_user_lookup 
ON matches (user1_id, user2_id, created_at DESC) 
WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_matches_reverse_lookup 
ON matches (user2_id, user1_id, created_at DESC) 
WHERE deleted_at IS NULL;

-- ======================
-- MESSAGING PERFORMANCE
-- ======================

-- Critical index for conversation message loading
CREATE INDEX IF NOT EXISTS idx_messages_conversation_pagination 
ON messages (conversation_id, created_at DESC, id) 
WHERE deleted_at IS NULL;

-- Index for unread message counts
CREATE INDEX IF NOT EXISTS idx_messages_unread_status 
ON messages (conversation_id, read_at, created_at) 
WHERE read_at IS NULL;

-- Optimized conversation listing
CREATE INDEX IF NOT EXISTS idx_conversations_user_activity 
ON conversations (user1_id, last_message_at DESC) 
WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_conversations_user2_activity 
ON conversations (user2_id, last_message_at DESC) 
WHERE deleted_at IS NULL;

-- Media message optimization
CREATE INDEX IF NOT EXISTS idx_messages_media_type 
ON messages (conversation_id, media_type, created_at DESC) 
WHERE media_type IS NOT NULL;

-- ======================
-- SUBSCRIPTION & ANALYTICS
-- ======================

-- Subscription status queries
CREATE INDEX IF NOT EXISTS idx_users_subscription_active 
ON users (subscription_status, subscription_current_period_end) 
WHERE subscription_status IN ('active', 'trialing');

-- Premium feature access
CREATE INDEX IF NOT EXISTS idx_users_premium_features 
ON users (subscription_status, has_active_ticket, created_at) 
WHERE subscription_status = 'active' OR has_active_ticket = true;

-- Analytics queries
CREATE INDEX IF NOT EXISTS idx_users_signup_cohort 
ON users (DATE(created_at), subscription_status);

-- ======================
-- COMPATIBILITY OPTIMIZATION
-- ======================

-- Compatibility calculation cache
CREATE INDEX IF NOT EXISTS idx_matches_compatibility_cache 
ON matches (user1_id, user2_id, overall_score, updated_at) 
WHERE overall_score IS NOT NULL;

-- High compatibility matches
CREATE INDEX IF NOT EXISTS idx_matches_high_compatibility 
ON matches (overall_score DESC, created_at DESC) 
WHERE overall_score >= 80;

-- ======================
-- PERFORMANCE FUNCTIONS
-- ======================

-- Optimized potential matches function
CREATE OR REPLACE FUNCTION get_potential_matches_optimized(
    p_user_id UUID,
    p_gender_preference TEXT DEFAULT NULL,
    p_min_age INTEGER DEFAULT NULL,
    p_max_age INTEGER DEFAULT NULL,
    p_max_distance_km INTEGER DEFAULT NULL,
    p_zodiac_sign TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 20,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    display_name TEXT,
    avatar_url TEXT,
    age INTEGER,
    gender TEXT,
    zodiac_sign TEXT,
    interests TEXT[],
    distance_km NUMERIC,
    compatibility_score INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    user_location GEOMETRY;
BEGIN
    -- Get user's location for distance calculation
    SELECT location INTO user_location 
    FROM profiles 
    WHERE profiles.id = p_user_id;
    
    RETURN QUERY
    WITH excluded_users AS (
        -- Get all users this person has already swiped on
        SELECT swiped_id as user_id FROM swipes WHERE swiper_id = p_user_id
        UNION
        -- Get all users already matched with
        SELECT user1_id as user_id FROM matches WHERE user2_id = p_user_id
        UNION
        SELECT user2_id as user_id FROM matches WHERE user1_id = p_user_id
        UNION
        -- Exclude self
        SELECT p_user_id as user_id
    ),
    potential_matches AS (
        SELECT 
            p.id,
            p.display_name,
            p.avatar_url,
            p.age,
            p.gender,
            p.zodiac_sign,
            p.interests,
            CASE 
                WHEN user_location IS NOT NULL AND p.location IS NOT NULL 
                THEN ROUND(ST_Distance(user_location, p.location)::NUMERIC / 1000, 1)
                ELSE NULL 
            END as distance_km,
            COALESCE(m.overall_score, 50) as compatibility_score
        FROM profiles p
        LEFT JOIN matches m ON (
            (m.user1_id = p_user_id AND m.user2_id = p.id) OR 
            (m.user2_id = p_user_id AND m.user1_id = p.id)
        )
        WHERE p.onboarding_completed = true
        AND p.deleted_at IS NULL
        AND p.id NOT IN (SELECT user_id FROM excluded_users)
        AND (p_gender_preference IS NULL OR p.gender = p_gender_preference)
        AND (p_min_age IS NULL OR p.age >= p_min_age)
        AND (p_max_age IS NULL OR p.age <= p_max_age)
        AND (p_zodiac_sign IS NULL OR p.zodiac_sign = p_zodiac_sign)
        AND (
            p_max_distance_km IS NULL 
            OR user_location IS NULL 
            OR p.location IS NULL
            OR ST_Distance(user_location, p.location) <= p_max_distance_km * 1000
        )
        ORDER BY 
            compatibility_score DESC,
            p.created_at DESC
        LIMIT p_limit OFFSET p_offset
    )
    SELECT * FROM potential_matches;
END;
$$;

-- Optimized conversation list function
CREATE OR REPLACE FUNCTION get_user_conversations_optimized(p_user_id UUID)
RETURNS TABLE (
    conversation_id UUID,
    other_user_id UUID,
    other_user_name TEXT,
    other_user_avatar TEXT,
    last_message TEXT,
    last_message_at TIMESTAMPTZ,
    unread_count BIGINT,
    is_online BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    WITH conversation_data AS (
        SELECT 
            c.id as conversation_id,
            CASE 
                WHEN c.user1_id = p_user_id THEN c.user2_id 
                ELSE c.user1_id 
            END as other_user_id,
            c.last_message_at,
            c.last_message_text as last_message
        FROM conversations c
        WHERE (c.user1_id = p_user_id OR c.user2_id = p_user_id)
        AND c.deleted_at IS NULL
    ),
    unread_counts AS (
        SELECT 
            m.conversation_id,
            COUNT(*) as unread_count
        FROM messages m
        INNER JOIN conversation_data cd ON cd.conversation_id = m.conversation_id
        WHERE m.sender_id != p_user_id 
        AND m.read_at IS NULL
        AND m.deleted_at IS NULL
        GROUP BY m.conversation_id
    )
    SELECT 
        cd.conversation_id,
        cd.other_user_id,
        p.display_name as other_user_name,
        p.avatar_url as other_user_avatar,
        cd.last_message,
        cd.last_message_at,
        COALESCE(uc.unread_count, 0) as unread_count,
        (p.last_seen_at > NOW() - INTERVAL '5 minutes') as is_online
    FROM conversation_data cd
    LEFT JOIN profiles p ON p.id = cd.other_user_id
    LEFT JOIN unread_counts uc ON uc.conversation_id = cd.conversation_id
    ORDER BY cd.last_message_at DESC;
END;
$$;

-- ======================
-- QUERY ANALYSIS FUNCTIONS
-- ======================

-- Function to analyze slow queries
CREATE OR REPLACE FUNCTION analyze_query_performance()
RETURNS TABLE (
    query_type TEXT,
    avg_duration_ms NUMERIC,
    call_count BIGINT,
    max_duration_ms NUMERIC,
    recommendations TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        'potential_matches' as query_type,
        AVG(response_time_ms) as avg_duration_ms,
        COUNT(*) as call_count,
        MAX(response_time_ms) as max_duration_ms,
        CASE 
            WHEN AVG(response_time_ms) > 1000 THEN 'Consider adding more specific indexes for common filter combinations'
            WHEN AVG(response_time_ms) > 500 THEN 'Performance is acceptable but could be optimized'
            ELSE 'Performance is good'
        END as recommendations
    FROM api_performance_logs
    WHERE endpoint_name LIKE '%potential-matches%'
    AND created_at >= NOW() - INTERVAL '24 hours'
    
    UNION ALL
    
    SELECT 
        'messaging' as query_type,
        AVG(response_time_ms) as avg_duration_ms,
        COUNT(*) as call_count,
        MAX(response_time_ms) as max_duration_ms,
        CASE 
            WHEN AVG(response_time_ms) > 500 THEN 'Consider message pagination optimization'
            WHEN AVG(response_time_ms) > 200 THEN 'Performance is acceptable'
            ELSE 'Performance is excellent'
        END as recommendations
    FROM api_performance_logs
    WHERE endpoint_name LIKE '%message%'
    AND created_at >= NOW() - INTERVAL '24 hours';
END;
$$;

-- ======================
-- MAINTENANCE FUNCTIONS
-- ======================

-- Function to maintain database performance
CREATE OR REPLACE FUNCTION maintain_database_performance()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    result TEXT := '';
BEGIN
    -- Update table statistics
    ANALYZE profiles;
    ANALYZE users;
    ANALYZE messages;
    ANALYZE conversations;
    ANALYZE matches;
    ANALYZE swipes;
    
    result := result || 'Statistics updated. ';
    
    -- Clean up old data
    DELETE FROM api_performance_logs WHERE created_at < NOW() - INTERVAL '7 days';
    DELETE FROM system_metrics WHERE recorded_at < NOW() - INTERVAL '30 days';
    
    result := result || 'Old monitoring data cleaned. ';
    
    -- Report on index usage
    WITH unused_indexes AS (
        SELECT 
            schemaname,
            tablename,
            indexname,
            idx_tup_read,
            idx_tup_fetch
        FROM pg_stat_user_indexes 
        WHERE idx_tup_read = 0 AND idx_tup_fetch = 0
        AND schemaname = 'public'
    )
    SELECT COUNT(*) INTO result
    FROM unused_indexes;
    
    IF result::INTEGER > 0 THEN
        result := 'Warning: ' || result || ' unused indexes found. Consider removing them.';
    ELSE
        result := result || 'All indexes are being used effectively.';
    END IF;
    
    RETURN result;
END;
$$;

-- ======================
-- GRANTS
-- ======================

GRANT EXECUTE ON FUNCTION get_potential_matches_optimized TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_user_conversations_optimized TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION analyze_query_performance TO service_role;
GRANT EXECUTE ON FUNCTION maintain_database_performance TO service_role;

-- ======================
-- COMMENTS
-- ======================

COMMENT ON FUNCTION get_potential_matches_optimized IS 'Optimized function for finding potential matches with comprehensive filtering and sorting';
COMMENT ON FUNCTION get_user_conversations_optimized IS 'Optimized function for loading user conversations with unread counts and online status';
COMMENT ON FUNCTION analyze_query_performance IS 'Analyzes API performance and provides optimization recommendations';
COMMENT ON FUNCTION maintain_database_performance IS 'Performs routine database maintenance for optimal performance';*/
