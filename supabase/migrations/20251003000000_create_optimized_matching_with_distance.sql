-- Create optimized potential matches function with distance filtering
-- This function adds geographic distance filtering to the existing matching logic
-- Called by get-potential-matches-optimized edge function

-- Drop existing function if it exists (required when changing return type)
DROP FUNCTION IF EXISTS public.get_potential_matches_optimized(UUID, UUID[], TEXT, INT, INT, INT, INT, INT);

CREATE OR REPLACE FUNCTION public.get_potential_matches_optimized(
    viewer_id UUID,
    exclude_user_ids UUID[] DEFAULT ARRAY[]::UUID[],
    zodiac_filter TEXT DEFAULT NULL,
    min_age_filter INT DEFAULT NULL,
    max_age_filter INT DEFAULT NULL,
    max_distance_km INT DEFAULT NULL,
    limit_count INT DEFAULT 10,
    offset_count INT DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    display_name TEXT,
    avatar_url TEXT,
    gender TEXT,
    age INT,
    interests TEXT[],
    zodiac_sign TEXT,
    education_level TEXT,
    traits TEXT[],
    bio TEXT,
    compatibility_score NUMERIC,
    distance_km NUMERIC,
    is_match_recommended BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    viewer_user RECORD;
    viewer_profile RECORD;
    viewer_lat NUMERIC;
    viewer_lng NUMERIC;
BEGIN
    -- Get viewer data for bidirectional filtering
    SELECT * INTO viewer_user FROM public.users WHERE id = viewer_id;
    SELECT * INTO viewer_profile FROM public.profiles WHERE id = viewer_id;

    -- If viewer data not found, return empty
    IF viewer_user IS NULL OR viewer_profile IS NULL THEN
        RETURN;
    END IF;

    -- Get viewer coordinates for distance calculation
    viewer_lat := viewer_profile.lat;
    viewer_lng := viewer_profile.lng;

    -- Return filtered potential matches with distance calculation
    RETURN QUERY
    SELECT
        p.id,
        p.display_name,
        p.avatar_url,
        p.gender,
        p.age,
        p.interests,
        p.zodiac_sign,
        p.education_level,
        p.traits,
        p.bio,
        -- Get compatibility score from cache if available, otherwise NULL
        COALESCE(
            (SELECT compatibility_score
             FROM public.user_compatibility_cache
             WHERE user1_id = viewer_id AND user2_id = p.id
             LIMIT 1),
            85.0  -- Default score if not calculated yet
        ) as compatibility_score,
        -- Calculate distance using Haversine formula (returns km)
        CASE
            WHEN viewer_lat IS NOT NULL
                AND viewer_lng IS NOT NULL
                AND p.lat IS NOT NULL
                AND p.lng IS NOT NULL
            THEN
                6371 * acos(
                    cos(radians(viewer_lat)) *
                    cos(radians(p.lat)) *
                    cos(radians(p.lng) - radians(viewer_lng)) +
                    sin(radians(viewer_lat)) *
                    sin(radians(p.lat))
                )
            ELSE NULL
        END as distance_km,
        -- Match recommendation based on compatibility score
        COALESCE(
            (SELECT compatibility_score
             FROM public.user_compatibility_cache
             WHERE user1_id = viewer_id AND user2_id = p.id
             LIMIT 1) >= 80.0,
            true  -- Default to recommended if not calculated
        ) as is_match_recommended
    FROM public.profiles p
    JOIN public.users u ON p.id = u.id
    WHERE
        -- Exclude self and already processed users
        p.id != viewer_id
        AND (
            array_length(exclude_user_ids, 1) IS NULL
            OR p.id != ALL(exclude_user_ids)
        )

        -- Age filter (if specified)
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

        -- Zodiac filter (if specified)
        AND (
            zodiac_filter IS NULL
            OR zodiac_filter = 'Any'
            OR p.zodiac_sign = zodiac_filter
        )

        -- Distance filter (if specified) - only filter if both users have coordinates
        AND (
            max_distance_km IS NULL
            OR viewer_lat IS NULL
            OR viewer_lng IS NULL
            OR p.lat IS NULL
            OR p.lng IS NULL
            OR (
                6371 * acos(
                    cos(radians(viewer_lat)) *
                    cos(radians(p.lat)) *
                    cos(radians(p.lng) - radians(viewer_lng)) +
                    sin(radians(viewer_lat)) *
                    sin(radians(p.lat))
                ) <= max_distance_km
            )
        )

        -- Bidirectional gender preference check using looking_for
        AND (
            -- Check if viewer is looking for target's gender
            viewer_user.looking_for IS NULL
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
        )
        AND (
            -- Check if target is looking for viewer's gender
            u.looking_for IS NULL
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
        )

        -- Basic compatibility filters using existing function
        AND (
            SELECT (check_user_eligibility_filters(viewer_id, p.id)->>'is_eligible')::BOOLEAN
        ) = true

    -- Order by compatibility score (highest first), then distance (closest first)
    ORDER BY
        COALESCE(
            (SELECT compatibility_score
             FROM public.user_compatibility_cache
             WHERE user1_id = viewer_id AND user2_id = p.id
             LIMIT 1),
            85.0
        ) DESC,
        CASE
            WHEN viewer_lat IS NOT NULL AND viewer_lng IS NOT NULL AND p.lat IS NOT NULL AND p.lng IS NOT NULL
            THEN 6371 * acos(
                cos(radians(viewer_lat)) *
                cos(radians(p.lat)) *
                cos(radians(p.lng) - radians(viewer_lng)) +
                sin(radians(viewer_lat)) *
                sin(radians(p.lat))
            )
            ELSE 999999  -- Put users without coordinates at the end
        END ASC,
        p.created_at DESC
    LIMIT limit_count
    OFFSET offset_count;

EXCEPTION
    WHEN OTHERS THEN
        -- Log error and return empty result rather than failing
        RAISE WARNING 'Error in get_potential_matches_optimized: %', SQLERRM;
        RETURN;
END;
$$;

-- Create index on lat/lng for faster distance calculations (only if columns exist)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = 'lat'
  ) AND EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = 'lng'
  ) THEN
    CREATE INDEX IF NOT EXISTS idx_profiles_lat_lng ON public.profiles(lat, lng) WHERE lat IS NOT NULL AND lng IS NOT NULL;
  END IF;
END $$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.get_potential_matches_optimized(UUID, UUID[], TEXT, INT, INT, INT, INT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_potential_matches_optimized(UUID, UUID[], TEXT, INT, INT, INT, INT, INT) TO service_role;

-- Add comment
COMMENT ON FUNCTION public.get_potential_matches_optimized(UUID, UUID[], TEXT, INT, INT, INT, INT, INT) IS
'Optimized batch filtering function for potential matches with distance filtering. Applies bidirectional gender preferences, age filters, zodiac filters, distance filtering, and compatibility checks. Returns matches with compatibility scores and calculated distances. Used by get-potential-matches-optimized edge function.';
