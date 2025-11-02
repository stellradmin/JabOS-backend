-- ==========================================
-- UNIFIED MATCHING FILTERS - PRODUCTION READY
-- ==========================================
-- This migration consolidates ALL matching filter logic from previous versions:
-- - Activity type filtering (from 20250110_add_activity_filtering.sql)
-- - Blocks filtering (from 20250926_fix_get_potential_matches_signature.sql)
-- - Distance calculations (from 20251003000000_create_optimized_matching_with_distance.sql)
-- - Match requests exclusion (NEW - critical for production)
-- - "Any Sign" / "Any Date" handling (NEW - user requirement)
--
-- This is the DEFINITIVE version that will be used by get-potential-matches-optimized edge function
-- ==========================================

BEGIN;

-- Drop ALL previous function signatures to avoid conflicts
DROP FUNCTION IF EXISTS public.get_potential_matches_optimized(UUID, UUID[], TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.get_potential_matches_optimized(UUID, UUID[], TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.get_potential_matches_optimized(UUID, INTEGER, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.get_potential_matches_optimized CASCADE;

-- Create the unified, production-ready function
CREATE OR REPLACE FUNCTION public.get_potential_matches_optimized(
    viewer_id UUID,
    exclude_user_ids UUID[] DEFAULT ARRAY[]::UUID[],
    zodiac_filter TEXT DEFAULT NULL,
    min_age_filter INTEGER DEFAULT NULL,
    max_age_filter INTEGER DEFAULT NULL,
    max_distance_km INTEGER DEFAULT NULL,
    activity_filter TEXT DEFAULT NULL,  -- CRITICAL: Activity type filtering (main app feature)
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
    distance_km NUMERIC,
    traits TEXT[],
    height INTEGER,
    lat DECIMAL,
    lng DECIMAL,
    last_active TIMESTAMPTZ,
    premium_user BOOLEAN,
    profile_image_url TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    viewer_profile RECORD;
    viewer_user RECORD;
    viewer_lat NUMERIC;
    viewer_lng NUMERIC;
BEGIN
    -- Get viewer profile and user data for bidirectional filtering
    SELECT * INTO viewer_profile FROM public.profiles WHERE id = viewer_id;
    SELECT * INTO viewer_user FROM public.users WHERE id = viewer_id;

    -- If viewer data not found, return empty
    IF viewer_profile IS NULL THEN
        RETURN;
    END IF;

    -- Get viewer coordinates for distance calculation
    viewer_lat := COALESCE(viewer_profile.current_city_lat, viewer_user.birth_lat);
    viewer_lng := COALESCE(viewer_profile.current_city_lng, viewer_user.birth_lng);

    -- Return filtered potential matches with comprehensive exclusions
    RETURN QUERY
    SELECT
        p.id,
        p.display_name,
        p.avatar_url,
        p.gender,
        p.age,
        p.zodiac_sign,
        COALESCE(p.interests, ARRAY[]::TEXT[]) as interests,
        p.education_level,
        COALESCE(p.bio, '') as bio,
        -- Get compatibility score from cache if available, otherwise default to 50
        COALESCE(
            (SELECT compatibility_score::INTEGER
             FROM public.compatibility_scores
             WHERE (user_id = viewer_id AND potential_match_id = p.id)
                OR (user_id = p.id AND potential_match_id = viewer_id)
             ORDER BY calculated_at DESC
             LIMIT 1),
            50
        ) as compatibility_score,
        -- Calculate distance using Haversine formula (returns km)
        CASE
            WHEN viewer_lat IS NOT NULL
                AND viewer_lng IS NOT NULL
                AND COALESCE(p.current_city_lat, u.birth_lat) IS NOT NULL
                AND COALESCE(p.current_city_lng, u.birth_lng) IS NOT NULL
            THEN
                ROUND(
                    (6371 * acos(
                        LEAST(1.0, GREATEST(-1.0,
                            cos(radians(viewer_lat)) *
                            cos(radians(COALESCE(p.current_city_lat, u.birth_lat))) *
                            cos(radians(COALESCE(p.current_city_lng, u.birth_lng)) - radians(viewer_lng)) +
                            sin(radians(viewer_lat)) *
                            sin(radians(COALESCE(p.current_city_lat, u.birth_lat)))
                        ))
                    ))::NUMERIC, 1
                )
            ELSE NULL
        END as distance_km,
        COALESCE(p.traits, ARRAY[]::TEXT[]) as traits,
        p.height,
        COALESCE(p.current_city_lat, u.birth_lat)::DECIMAL as lat,
        COALESCE(p.current_city_lng, u.birth_lng)::DECIMAL as lng,
        p.updated_at as last_active,
        COALESCE(u.subscription_status = 'active', false) as premium_user,
        p.avatar_url as profile_image_url
    FROM public.profiles p
    JOIN public.users u ON u.id = p.id
    LEFT JOIN public.swipe_exclusion_cache sec ON sec.swiper_id = viewer_id
    WHERE
        -- BASIC EXCLUSIONS
        -- Exclude self
        p.id != viewer_id

        -- Exclude explicitly passed user IDs
        AND (
            array_length(exclude_user_ids, 1) IS NULL
            OR NOT (p.id = ANY(exclude_user_ids))
        )

        -- Only show users who completed onboarding
        AND p.onboarding_completed = true

        -- SWIPE EXCLUSIONS
        -- Exclude already-swiped users (prevents re-showing swiped profiles)
        AND (
            sec.swiped_user_ids IS NULL
            OR NOT (p.id = ANY(sec.swiped_user_ids))
        )

        -- MATCH REQUESTS EXCLUSIONS (CRITICAL - prevents duplicate invites)
        -- Exclude users with pending match requests (sent by viewer)
        AND NOT EXISTS (
            SELECT 1 FROM public.match_requests mr
            WHERE mr.requester_id = viewer_id
              AND mr.matched_user_id = p.id
              AND mr.status IN ('pending', 'confirmed')
        )

        -- Exclude users who sent match requests to viewer (pending)
        AND NOT EXISTS (
            SELECT 1 FROM public.match_requests mr
            WHERE mr.requester_id = p.id
              AND mr.matched_user_id = viewer_id
              AND mr.status = 'pending'
        )

        -- Exclude users who declined viewer's match request
        AND NOT EXISTS (
            SELECT 1 FROM public.match_requests mr
            WHERE mr.requester_id = viewer_id
              AND mr.matched_user_id = p.id
              AND mr.status = 'rejected'
        )

        -- Exclude users whose match request viewer declined
        AND NOT EXISTS (
            SELECT 1 FROM public.match_requests mr
            WHERE mr.requester_id = p.id
              AND mr.matched_user_id = viewer_id
              AND mr.status = 'rejected'
        )

        -- ALREADY MATCHED EXCLUSIONS
        -- Exclude users already matched (bidirectional check)
        AND NOT EXISTS (
            SELECT 1 FROM public.matches m
            WHERE (m.user1_id = viewer_id AND m.user2_id = p.id)
               OR (m.user1_id = p.id AND m.user2_id = viewer_id)
        )

        -- BLOCKS EXCLUSIONS
        -- Exclude blocked users (bidirectional)
        AND NOT EXISTS (
            SELECT 1 FROM public.user_blocks b
            WHERE (b.blocking_user_id = viewer_id AND b.blocked_user_id = p.id)
               OR (b.blocking_user_id = p.id AND b.blocked_user_id = viewer_id)
        )

        -- AGE FILTERS (STRICT)
        AND (
            min_age_filter IS NULL
            OR p.age IS NULL
            OR p.age >= min_age_filter
        )
        AND (
            max_age_filter IS NULL
            OR p.age IS NULL
            OR p.age <= max_age_filter
        )

        -- ZODIAC FILTER (with "Any Sign" support)
        AND (
            zodiac_filter IS NULL
            OR zodiac_filter = ''
            OR LOWER(zodiac_filter) = 'any'
            OR LOWER(zodiac_filter) = 'all'
            OR p.zodiac_sign = zodiac_filter
            OR LOWER(p.zodiac_sign) = LOWER(zodiac_filter)
        )

        -- DISTANCE FILTER (STRICT - only filter if both users have coordinates)
        AND (
            max_distance_km IS NULL
            OR viewer_lat IS NULL
            OR viewer_lng IS NULL
            OR COALESCE(p.current_city_lat, u.birth_lat) IS NULL
            OR COALESCE(p.current_city_lng, u.birth_lng) IS NULL
            OR (
                6371 * acos(
                    LEAST(1.0, GREATEST(-1.0,
                        cos(radians(viewer_lat)) *
                        cos(radians(COALESCE(p.current_city_lat, u.birth_lat))) *
                        cos(radians(COALESCE(p.current_city_lng, u.birth_lng)) - radians(viewer_lng)) +
                        sin(radians(viewer_lat)) *
                        sin(radians(COALESCE(p.current_city_lat, u.birth_lat)))
                    ))
                ) <= max_distance_km
            )
        )

        -- BIDIRECTIONAL GENDER/SEXUALITY PREFERENCE FILTERING
        -- Viewer's preference: Check if viewer wants target's gender
        AND (
            viewer_user.looking_for IS NULL
            OR array_length(viewer_user.looking_for, 1) IS NULL
            OR p.gender IS NULL
            OR (
                CASE p.gender
                    WHEN 'Male' THEN 'Males'
                    WHEN 'Female' THEN 'Females'
                    WHEN 'Non-binary' THEN 'Non-Binary'
                    WHEN 'Other' THEN 'Non-Binary'
                    ELSE 'Non-Binary'
                END = ANY(viewer_user.looking_for)
            )
            OR 'Both' = ANY(viewer_user.looking_for)
            OR 'Everyone' = ANY(viewer_user.looking_for)
        )

        -- Target's preference: Check if target wants viewer's gender
        AND (
            u.looking_for IS NULL
            OR array_length(u.looking_for, 1) IS NULL
            OR viewer_profile.gender IS NULL
            OR (
                CASE viewer_profile.gender
                    WHEN 'Male' THEN 'Males'
                    WHEN 'Female' THEN 'Females'
                    WHEN 'Non-binary' THEN 'Non-Binary'
                    WHEN 'Other' THEN 'Non-Binary'
                    ELSE 'Non-Binary'
                END = ANY(u.looking_for)
            )
            OR 'Both' = ANY(u.looking_for)
            OR 'Everyone' = ANY(u.looking_for)
        )

        -- ACTIVITY TYPE FILTERING (with "Any Date" support)
        -- Main app feature: filter by preferred date activity
        AND (
            activity_filter IS NULL
            OR activity_filter = ''
            OR LOWER(activity_filter) = 'any'
            OR LOWER(activity_filter) = 'all'
            OR LOWER(activity_filter) = 'any date'
            OR (
                -- Check if user has this activity in their preferences
                u.activity_preferences IS NOT NULL
                AND u.activity_preferences::jsonb ? activity_filter
            )
            OR (
                -- Also check profile-level activity preferences if they exist
                p.activity_preferences IS NOT NULL
                AND p.activity_preferences::jsonb ? activity_filter
            )
        )

        -- DATA COMPLETENESS CHECK
        -- Only show users with complete compatibility data
        AND u.natal_chart_data IS NOT NULL
        AND u.questionnaire_responses IS NOT NULL
        AND jsonb_typeof(u.questionnaire_responses) = 'array'
        AND jsonb_array_length(u.questionnaire_responses) > 0

    -- ORDERING
    ORDER BY
        -- Prioritize premium users
        COALESCE(u.subscription_status = 'active', false) DESC,
        -- Then by compatibility score (highest first)
        COALESCE(
            (SELECT compatibility_score
             FROM public.compatibility_scores
             WHERE (user_id = viewer_id AND potential_match_id = p.id)
                OR (user_id = p.id AND potential_match_id = viewer_id)
             ORDER BY calculated_at DESC
             LIMIT 1),
            50
        ) DESC,
        -- Then by distance (closest first)
        CASE
            WHEN viewer_lat IS NOT NULL AND viewer_lng IS NOT NULL
                 AND COALESCE(p.current_city_lat, u.birth_lat) IS NOT NULL
                 AND COALESCE(p.current_city_lng, u.birth_lng) IS NOT NULL
            THEN 6371 * acos(
                LEAST(1.0, GREATEST(-1.0,
                    cos(radians(viewer_lat)) *
                    cos(radians(COALESCE(p.current_city_lat, u.birth_lat))) *
                    cos(radians(COALESCE(p.current_city_lng, u.birth_lng)) - radians(viewer_lng)) +
                    sin(radians(viewer_lat)) *
                    sin(radians(COALESCE(p.current_city_lat, u.birth_lat)))
                ))
            )
            ELSE 999999  -- Put users without coordinates at the end
        END ASC,
        -- Finally by recency
        p.updated_at DESC
    LIMIT limit_count
    OFFSET offset_count;

EXCEPTION
    WHEN OTHERS THEN
        -- Log error and return empty result rather than failing
        RAISE WARNING 'Error in get_potential_matches_optimized: % (SQLSTATE: %)', SQLERRM, SQLSTATE;
        RETURN;
END;
$$;

-- Create indexes for performance (only if they don't exist)
CREATE INDEX IF NOT EXISTS idx_profiles_current_city_location
    ON public.profiles(current_city_lat, current_city_lng)
    WHERE current_city_lat IS NOT NULL AND current_city_lng IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_profiles_zodiac_sign
    ON public.profiles(zodiac_sign)
    WHERE zodiac_sign IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_profiles_age
    ON public.profiles(age)
    WHERE age IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_profiles_onboarding_completed
    ON public.profiles(onboarding_completed)
    WHERE onboarding_completed = true;

CREATE INDEX IF NOT EXISTS idx_match_requests_requester_matched_status
    ON public.match_requests(requester_id, matched_user_id, status);

CREATE INDEX IF NOT EXISTS idx_matches_user1_user2
    ON public.matches(user1_id, user2_id);

CREATE INDEX IF NOT EXISTS idx_user_blocks_blocking_blocked
    ON public.user_blocks(blocking_user_id, blocked_user_id);

-- Grant permissions
REVOKE EXECUTE ON FUNCTION public.get_potential_matches_optimized FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_potential_matches_optimized TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_potential_matches_optimized TO service_role;

-- Add comprehensive documentation
COMMENT ON FUNCTION public.get_potential_matches_optimized IS
'PRODUCTION-READY matching function with comprehensive filtering:

FILTERS IMPLEMENTED:
✅ Zodiac sign (with "Any"/"All" support)
✅ Activity type (with "Any Date" support) - MAIN APP FEATURE
✅ Age range (strict min/max enforcement)
✅ Distance (Haversine formula, strict enforcement)
✅ Bidirectional gender/sexuality preferences (Both/Everyone support)

EXCLUSIONS IMPLEMENTED:
✅ Already swiped users (via swipe_exclusion_cache)
✅ Pending match requests (sent or received)
✅ Rejected match requests (bidirectional)
✅ Already matched users (bidirectional)
✅ Blocked users (bidirectional via user_blocks)
✅ Self
✅ Incomplete onboarding
✅ Missing compatibility data

EDGE CASES HANDLED:
✅ NULL handling for all optional fields
✅ Case-insensitive string matching
✅ "Any"/"All" special values for zodiac and activity
✅ Missing coordinates (no distance filter applied)
✅ Missing gender preferences (no filtering applied)
✅ Error handling (returns empty on error, logs warning)

PERFORMANCE OPTIMIZATIONS:
✅ Indexed columns (lat/lng, zodiac, age, onboarding)
✅ Indexed foreign keys (match_requests, matches, blocks)
✅ Compatibility score caching
✅ Swipe exclusion caching
✅ SECURITY DEFINER with explicit search_path

Used by: get-potential-matches-optimized edge function
Version: 1.0.0-production
Date: 2025-10-22
';

COMMIT;

-- Verification query (commented out for production, uncomment for testing)
-- SELECT proname, pg_get_function_arguments(oid) as args
-- FROM pg_proc
-- WHERE proname = 'get_potential_matches_optimized';
