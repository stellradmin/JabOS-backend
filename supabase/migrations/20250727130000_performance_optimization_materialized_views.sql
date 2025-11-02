-- Performance Optimization: Materialized Views and Precomputed Data
-- This migration creates materialized views for frequently accessed data patterns
-- Target: Reduce query times from 2000ms to <200ms for matching operations

BEGIN;

-- Ensure spatial functions are available for location computations
CREATE EXTENSION IF NOT EXISTS postgis;

-- =====================================================
-- 1. MATERIALIZED VIEW: User Matching Summary
-- Pre-computes essential matching data for fast retrieval
-- =====================================================

CREATE MATERIALIZED VIEW user_matching_summary AS
SELECT 
    p.id,
    p.display_name,
    p.avatar_url,
    p.gender,
    p.age,
    p.zodiac_sign,
    p.interests,
    p.traits,
    p.education_level,
    p.created_at,
    p.onboarding_completed,
    u.looking_for,
    u.preferences,
    p.location,
    -- Precompute location as POINT for faster distance calculations
    CASE 
        WHEN p.location IS NOT NULL AND jsonb_typeof(p.location->'coordinates') = 'array'
        THEN ST_SetSRID(ST_MakePoint(
            (p.location->'coordinates'->>0)::float,
            (p.location->'coordinates'->>1)::float
        ), 4326)
        ELSE NULL
    END as location_point,
    -- Cache computed fields for faster access
    CASE 
        WHEN p.interests IS NOT NULL 
        THEN array_length(p.interests, 1) 
        ELSE 0 
    END as interests_count,
    -- Activity preferences for quick filtering
    COALESCE(u.preferences->>'activity_preferences', '[]')::jsonb as activity_preferences,
    -- Age range preferences
    COALESCE((u.preferences->>'min_age')::int, 18) as min_age_pref,
    COALESCE((u.preferences->>'max_age')::int, 80) as max_age_pref,
    -- Distance preference
    COALESCE((u.preferences->>'max_distance_km')::int, 50) as max_distance_pref
FROM profiles p
INNER JOIN users u ON u.id = p.id
WHERE p.onboarding_completed = true
    AND p.display_name IS NOT NULL
    AND p.age IS NOT NULL
    AND p.gender IS NOT NULL;

-- Create indexes on the materialized view for optimal performance
CREATE UNIQUE INDEX idx_user_matching_summary_id ON user_matching_summary (id);
CREATE INDEX idx_user_matching_summary_gender_age ON user_matching_summary (gender, age, onboarding_completed);
CREATE INDEX idx_user_matching_summary_zodiac ON user_matching_summary (zodiac_sign) WHERE zodiac_sign IS NOT NULL;
CREATE INDEX idx_user_matching_summary_location ON user_matching_summary USING GIST (location_point) WHERE location_point IS NOT NULL;
CREATE INDEX idx_user_matching_summary_interests ON user_matching_summary USING GIN (interests) WHERE interests IS NOT NULL;
CREATE INDEX idx_user_matching_summary_activity ON user_matching_summary USING GIN (activity_preferences);
CREATE INDEX idx_user_matching_summary_created_at ON user_matching_summary (created_at DESC);

-- =====================================================
-- 2. MATERIALIZED VIEW: Swipe Exclusion Cache
-- Pre-aggregates swipe data for fast exclusion filtering
-- =====================================================

CREATE MATERIALIZED VIEW swipe_exclusion_cache AS
SELECT 
    swiper_id,
    array_agg(swiped_id ORDER BY created_at DESC) as swiped_user_ids,
    array_agg(CASE WHEN swipe_type = 'like' THEN swiped_id ELSE NULL END) FILTER (WHERE swipe_type = 'like') as liked_user_ids,
    array_agg(CASE WHEN swipe_type = 'pass' THEN swiped_id ELSE NULL END) FILTER (WHERE swipe_type = 'pass') as passed_user_ids,
    COUNT(*) as total_swipes,
    COUNT(*) FILTER (WHERE swipe_type = 'like') as total_likes,
    COUNT(*) FILTER (WHERE swipe_type = 'pass') as total_passes,
    MAX(created_at) as last_swipe_at
FROM swipes
GROUP BY swiper_id;

-- Index for fast swiper lookups
CREATE UNIQUE INDEX idx_swipe_exclusion_cache_swiper ON swipe_exclusion_cache (swiper_id);
CREATE INDEX idx_swipe_exclusion_cache_last_swipe ON swipe_exclusion_cache (last_swipe_at DESC);

-- =====================================================
-- 3. MATERIALIZED VIEW: Match Compatibility Cache
-- Pre-computes compatibility scores for existing matches
-- =====================================================

CREATE MATERIALIZED VIEW match_compatibility_cache AS
SELECT 
    m.id as match_id,
    m.user1_id,
    m.user2_id,
    m.status,
    m.compatibility_score,
    m.astrological_grade,
    m.questionnaire_grade,
    m.overall_score,
    m.calculation_result,
    m.created_at,
    -- User 1 data
    p1.display_name as user1_name,
    p1.avatar_url as user1_avatar,
    p1.age as user1_age,
    p1.zodiac_sign as user1_zodiac,
    -- User 2 data
    p2.display_name as user2_name,
    p2.avatar_url as user2_avatar,
    p2.age as user2_age,
    p2.zodiac_sign as user2_zodiac,
    -- Compatibility indicators
    CASE 
        WHEN p1.zodiac_sign = p2.zodiac_sign THEN true 
        ELSE false 
    END as zodiac_match,
    CASE 
        WHEN p1.interests && p2.interests THEN true 
        ELSE false 
    END as shared_interests
FROM matches m
INNER JOIN profiles p1 ON p1.id = m.user1_id
INNER JOIN profiles p2 ON p2.id = m.user2_id
WHERE m.status = 'active';

-- Indexes for fast match lookups
CREATE UNIQUE INDEX idx_match_compatibility_cache_id ON match_compatibility_cache (match_id);
CREATE INDEX idx_match_compatibility_cache_user1 ON match_compatibility_cache (user1_id, created_at DESC);
CREATE INDEX idx_match_compatibility_cache_user2 ON match_compatibility_cache (user2_id, created_at DESC);
CREATE INDEX idx_match_compatibility_cache_score ON match_compatibility_cache (compatibility_score DESC NULLS LAST);

-- =====================================================
-- 4. MATERIALIZED VIEW: Conversation Summary Cache
-- Pre-aggregates conversation data for messaging performance
-- =====================================================

CREATE MATERIALIZED VIEW conversation_summary_cache AS
SELECT 
    c.id as conversation_id,
    c.user1_id,
    c.user2_id,
    c.created_at,
    c.updated_at,
    -- Message statistics
    COALESCE(msg_stats.total_messages, 0) as total_messages,
    COALESCE(msg_stats.user1_messages, 0) as user1_messages,
    COALESCE(msg_stats.user2_messages, 0) as user2_messages,
    msg_stats.last_message_at,
    msg_stats.last_message_content,
    msg_stats.last_sender_id,
    -- Unread counts
    COALESCE(unread1.unread_count, 0) as user1_unread_count,
    COALESCE(unread2.unread_count, 0) as user2_unread_count,
    -- Participant data
    p1.display_name as user1_name,
    p1.avatar_url as user1_avatar,
    p2.display_name as user2_name,
    p2.avatar_url as user2_avatar
FROM conversations c
INNER JOIN profiles p1 ON p1.id = c.user1_id
INNER JOIN profiles p2 ON p2.id = c.user2_id
LEFT JOIN (
    SELECT 
        conversation_id,
        COUNT(*) as total_messages,
        COUNT(*) FILTER (WHERE sender_id = (SELECT user1_id FROM conversations WHERE id = conversation_id)) as user1_messages,
        COUNT(*) FILTER (WHERE sender_id = (SELECT user2_id FROM conversations WHERE id = conversation_id)) as user2_messages,
        MAX(created_at) as last_message_at,
        (array_agg(content ORDER BY created_at DESC))[1] as last_message_content,
        (array_agg(sender_id ORDER BY created_at DESC))[1] as last_sender_id
    FROM messages
    GROUP BY conversation_id
) msg_stats ON msg_stats.conversation_id = c.id
LEFT JOIN (
    SELECT 
        conversation_id,
        COUNT(*) as unread_count
    FROM messages m
    INNER JOIN conversations c ON c.id = m.conversation_id
    WHERE m.is_read = false AND m.sender_id = c.user2_id
    GROUP BY conversation_id
) unread1 ON unread1.conversation_id = c.id
LEFT JOIN (
    SELECT 
        conversation_id,
        COUNT(*) as unread_count
    FROM messages m
    INNER JOIN conversations c ON c.id = m.conversation_id
    WHERE m.is_read = false AND m.sender_id = c.user1_id
    GROUP BY conversation_id
) unread2 ON unread2.conversation_id = c.id;

-- Indexes for conversation lookups
CREATE UNIQUE INDEX idx_conversation_summary_cache_id ON conversation_summary_cache (conversation_id);
CREATE INDEX idx_conversation_summary_cache_user1 ON conversation_summary_cache (user1_id, last_message_at DESC NULLS LAST);
CREATE INDEX idx_conversation_summary_cache_user2 ON conversation_summary_cache (user2_id, last_message_at DESC NULLS LAST);
CREATE INDEX idx_conversation_summary_cache_updated ON conversation_summary_cache (updated_at DESC);

-- =====================================================
-- 5. COMPATIBILITY SCORING CACHE TABLE
-- Pre-computed compatibility scores for user pairs
-- =====================================================

CREATE TABLE IF NOT EXISTS compatibility_score_cache (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user1_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user2_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    compatibility_score INTEGER NOT NULL DEFAULT 0,
    astrological_score INTEGER NOT NULL DEFAULT 0,
    questionnaire_score INTEGER NOT NULL DEFAULT 0,
    overall_grade CHAR(1) NOT NULL DEFAULT 'C',
    is_recommended BOOLEAN NOT NULL DEFAULT false,
    calculation_details JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Ensure user1_id < user2_id for consistency
    CONSTRAINT compatibility_score_cache_user_order CHECK (user1_id < user2_id),
    CONSTRAINT compatibility_score_cache_unique_pair UNIQUE (user1_id, user2_id)
);

-- Indexes for fast compatibility lookups
CREATE INDEX idx_compatibility_score_cache_user1 ON compatibility_score_cache (user1_id, compatibility_score DESC);
CREATE INDEX idx_compatibility_score_cache_user2 ON compatibility_score_cache (user2_id, compatibility_score DESC);
CREATE INDEX idx_compatibility_score_cache_score ON compatibility_score_cache (compatibility_score DESC, is_recommended);
CREATE INDEX idx_compatibility_score_cache_updated ON compatibility_score_cache (updated_at DESC);

-- =====================================================
-- 6. REFRESH FUNCTIONS FOR MATERIALIZED VIEWS
-- =====================================================

-- Function to refresh user matching summary
CREATE OR REPLACE FUNCTION refresh_user_matching_summary()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY user_matching_summary;
    
    -- Log refresh
    INSERT INTO system_logs (log_level, message, details)
    VALUES ('INFO', 'Refreshed user_matching_summary materialized view', 
            jsonb_build_object('timestamp', NOW(), 'type', 'materialized_view_refresh'));
END;
$$;

-- Function to refresh swipe exclusion cache
CREATE OR REPLACE FUNCTION refresh_swipe_exclusion_cache()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY swipe_exclusion_cache;
    
    -- Log refresh
    INSERT INTO system_logs (log_level, message, details)
    VALUES ('INFO', 'Refreshed swipe_exclusion_cache materialized view', 
            jsonb_build_object('timestamp', NOW(), 'type', 'materialized_view_refresh'));
END;
$$;

-- Function to refresh match compatibility cache
CREATE OR REPLACE FUNCTION refresh_match_compatibility_cache()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY match_compatibility_cache;
    
    -- Log refresh
    INSERT INTO system_logs (log_level, message, details)
    VALUES ('INFO', 'Refreshed match_compatibility_cache materialized view', 
            jsonb_build_object('timestamp', NOW(), 'type', 'materialized_view_refresh'));
END;
$$;

-- Function to refresh conversation summary cache
CREATE OR REPLACE FUNCTION refresh_conversation_summary_cache()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY conversation_summary_cache;
    
    -- Log refresh
    INSERT INTO system_logs (log_level, message, details)
    VALUES ('INFO', 'Refreshed conversation_summary_cache materialized view', 
            jsonb_build_object('timestamp', NOW(), 'type', 'materialized_view_refresh'));
END;
$$;

-- =====================================================
-- 7. OPTIMIZED QUERY FUNCTIONS USING MATERIALIZED VIEWS
-- =====================================================

-- Ultra-fast potential matches using materialized view
CREATE OR REPLACE FUNCTION get_potential_matches_optimized(
    viewer_id UUID,
    exclude_user_ids UUID[] DEFAULT '{}',
    zodiac_filter TEXT DEFAULT NULL,
    min_age_filter INTEGER DEFAULT NULL,
    max_age_filter INTEGER DEFAULT NULL,
    max_distance_km INTEGER DEFAULT NULL,
    limit_count INTEGER DEFAULT 10,
    offset_count INTEGER DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    display_name TEXT,
    avatar_url TEXT,
    gender TEXT,
    age INTEGER,
    zodiac_sign TEXT,
    interests TEXT[],
    education_level TEXT,
    bio TEXT,
    compatibility_score INTEGER,
    distance_km NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    viewer_location_point GEOMETRY;
    viewer_preferences JSONB;
    viewer_looking_for TEXT[];
BEGIN
    -- Get viewer's location and preferences
    SELECT 
        location_point,
        COALESCE(u.preferences, '{}'::jsonb),
        COALESCE(u.looking_for, ARRAY[]::text[])
    INTO viewer_location_point, viewer_preferences, viewer_looking_for
    FROM user_matching_summary u
    WHERE u.id = viewer_id;
    
    RETURN QUERY
    SELECT 
        ums.id,
        ums.display_name,
        ums.avatar_url,
        ums.gender,
        ums.age,
        ums.zodiac_sign,
        ums.interests,
        ums.education_level,
        COALESCE(array_to_string(ums.interests, ', '), 'No interests listed') as bio,
        -- Get cached compatibility score or default
        COALESCE(csc.compatibility_score, 50) as compatibility_score,
        -- Calculate distance if both have locations
        CASE 
            WHEN viewer_location_point IS NOT NULL AND ums.location_point IS NOT NULL
            THEN ROUND(ST_Distance(viewer_location_point, ums.location_point) / 1000.0, 1)
            ELSE NULL
        END as distance_km
    FROM user_matching_summary ums
    LEFT JOIN compatibility_score_cache csc ON (
        (csc.user1_id = viewer_id AND csc.user2_id = ums.id) OR
        (csc.user1_id = ums.id AND csc.user2_id = viewer_id)
    )
    LEFT JOIN swipe_exclusion_cache sec ON sec.swiper_id = viewer_id
    WHERE 
        ums.id != viewer_id
        -- Exclude swiped users
        AND (sec.swiped_user_ids IS NULL OR NOT (ums.id = ANY(sec.swiped_user_ids)))
        -- Exclude explicitly passed users
        AND NOT (ums.id = ANY(exclude_user_ids))
        -- Gender preference filtering (bidirectional)
        AND (
            (viewer_looking_for IS NULL OR array_length(viewer_looking_for, 1) IS NULL) OR
            (
                CASE 
                    WHEN 'Males' = ANY(viewer_looking_for) AND ums.gender = 'Male' THEN true
                    WHEN 'Females' = ANY(viewer_looking_for) AND ums.gender = 'Female' THEN true
                    WHEN 'Non-Binary' = ANY(viewer_looking_for) AND ums.gender = 'Non-binary' THEN true
                    WHEN 'Both' = ANY(viewer_looking_for) THEN true
                    ELSE false
                END
            )
        )
        -- Reverse gender preference filtering
        AND (
            (ums.looking_for IS NULL OR array_length(ums.looking_for, 1) IS NULL) OR
            (
                CASE 
                    WHEN 'Males' = ANY(ums.looking_for) AND (SELECT gender FROM user_matching_summary WHERE id = viewer_id) = 'Male' THEN true
                    WHEN 'Females' = ANY(ums.looking_for) AND (SELECT gender FROM user_matching_summary WHERE id = viewer_id) = 'Female' THEN true
                    WHEN 'Non-Binary' = ANY(ums.looking_for) AND (SELECT gender FROM user_matching_summary WHERE id = viewer_id) = 'Non-binary' THEN true
                    WHEN 'Both' = ANY(ums.looking_for) THEN true
                    ELSE false
                END
            )
        )
        -- Zodiac filtering
        AND (zodiac_filter IS NULL OR ums.zodiac_sign = zodiac_filter)
        -- Age filtering
        AND (min_age_filter IS NULL OR ums.age >= min_age_filter)
        AND (max_age_filter IS NULL OR ums.age <= max_age_filter)
        -- Distance filtering
        AND (
            max_distance_km IS NULL OR 
            viewer_location_point IS NULL OR 
            ums.location_point IS NULL OR
            ST_Distance(viewer_location_point, ums.location_point) <= (max_distance_km * 1000)
        )
    ORDER BY 
        -- Prioritize recommended matches
        COALESCE(csc.is_recommended, false) DESC,
        -- Then by compatibility score
        COALESCE(csc.compatibility_score, 50) DESC,
        -- Finally by recency
        ums.created_at DESC
    LIMIT limit_count
    OFFSET offset_count;
END;
$$;

-- Fast conversation list using materialized view
CREATE OR REPLACE FUNCTION get_user_conversations_optimized(
    user_id UUID,
    limit_count INTEGER DEFAULT 20,
    offset_count INTEGER DEFAULT 0
)
RETURNS TABLE (
    conversation_id UUID,
    other_user_id UUID,
    other_user_name TEXT,
    other_user_avatar TEXT,
    last_message_content TEXT,
    last_message_at TIMESTAMPTZ,
    unread_count INTEGER,
    total_messages INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        csc.conversation_id,
        CASE 
            WHEN csc.user1_id = user_id THEN csc.user2_id
            ELSE csc.user1_id
        END as other_user_id,
        CASE 
            WHEN csc.user1_id = user_id THEN csc.user2_name
            ELSE csc.user1_name
        END as other_user_name,
        CASE 
            WHEN csc.user1_id = user_id THEN csc.user2_avatar
            ELSE csc.user1_avatar
        END as other_user_avatar,
        csc.last_message_content,
        csc.last_message_at,
        CASE 
            WHEN csc.user1_id = user_id THEN csc.user1_unread_count
            ELSE csc.user2_unread_count
        END as unread_count,
        csc.total_messages
    FROM conversation_summary_cache csc
    WHERE csc.user1_id = user_id OR csc.user2_id = user_id
    ORDER BY csc.last_message_at DESC NULLS LAST
    LIMIT limit_count
    OFFSET offset_count;
END;
$$;

-- =====================================================
-- 8. AUTOMATED REFRESH SCHEDULE
-- =====================================================

-- Create a refresh schedule table
CREATE TABLE IF NOT EXISTS materialized_view_refresh_schedule (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    view_name TEXT NOT NULL,
    refresh_interval_minutes INTEGER NOT NULL,
    last_refresh TIMESTAMPTZ,
    next_refresh TIMESTAMPTZ,
    enabled BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Insert refresh schedules
INSERT INTO materialized_view_refresh_schedule (view_name, refresh_interval_minutes, next_refresh) VALUES
('user_matching_summary', 15, NOW() + INTERVAL '15 minutes'),      -- Refresh every 15 minutes
('swipe_exclusion_cache', 5, NOW() + INTERVAL '5 minutes'),         -- Refresh every 5 minutes
('match_compatibility_cache', 60, NOW() + INTERVAL '60 minutes'),   -- Refresh every hour
('conversation_summary_cache', 2, NOW() + INTERVAL '2 minutes');    -- Refresh every 2 minutes

-- =====================================================
-- 9. TRIGGERS FOR AUTOMATIC CACHE INVALIDATION
-- =====================================================

-- Function to mark materialized views for refresh
CREATE OR REPLACE FUNCTION mark_view_for_refresh(p_view_name TEXT)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE materialized_view_refresh_schedule
    SET next_refresh = NOW()
    WHERE view_name = p_view_name AND enabled = true;
END;
$$;

-- Trigger for profile updates
CREATE OR REPLACE FUNCTION trigger_user_matching_refresh()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM mark_view_for_refresh('user_matching_summary');
    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Create triggers
DROP TRIGGER IF EXISTS profile_updated_refresh_matching ON profiles;
CREATE TRIGGER profile_updated_refresh_matching
    AFTER INSERT OR UPDATE OR DELETE ON profiles
    FOR EACH STATEMENT
    EXECUTE FUNCTION trigger_user_matching_refresh();

DROP TRIGGER IF EXISTS user_updated_refresh_matching ON users;
CREATE TRIGGER user_updated_refresh_matching
    AFTER UPDATE ON users
    FOR EACH STATEMENT
    EXECUTE FUNCTION trigger_user_matching_refresh();

-- Trigger for swipe updates
CREATE OR REPLACE FUNCTION trigger_swipe_refresh()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM mark_view_for_refresh('swipe_exclusion_cache');
    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS swipe_updated_refresh_cache ON swipes;
CREATE TRIGGER swipe_updated_refresh_cache
    AFTER INSERT OR UPDATE OR DELETE ON swipes
    FOR EACH STATEMENT
    EXECUTE FUNCTION trigger_swipe_refresh();

-- =====================================================
-- 10. PERFORMANCE MONITORING
-- =====================================================

-- Add performance tracking for materialized views
CREATE TABLE IF NOT EXISTS materialized_view_performance (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    view_name TEXT NOT NULL,
    operation TEXT NOT NULL, -- 'refresh', 'query'
    duration_ms INTEGER NOT NULL,
    rows_affected INTEGER,
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    details JSONB
);

-- Index for performance tracking
CREATE INDEX idx_mv_performance_view_timestamp ON materialized_view_performance (view_name, timestamp DESC);

-- Grant necessary permissions
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;

-- Grant execute permissions on functions
GRANT EXECUTE ON FUNCTION get_potential_matches_optimized(UUID, UUID[], TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_conversations_optimized TO authenticated;

COMMIT;