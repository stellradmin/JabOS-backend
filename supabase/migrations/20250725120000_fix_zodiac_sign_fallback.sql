-- Fix zodiac sign hardcoded fallback in RPC function
-- Remove "Aries" fallback that causes incorrect zodiac signs to be displayed

CREATE OR REPLACE FUNCTION public.get_filtered_potential_matches(
    viewer_id UUID,
    exclude_user_ids UUID[] DEFAULT ARRAY[]::UUID[],
    zodiac_filter TEXT DEFAULT NULL,
    min_age_filter INT DEFAULT NULL,
    max_age_filter INT DEFAULT NULL,
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
    traits TEXT[]
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    viewer_user RECORD;
    viewer_profile RECORD;
BEGIN
    -- Get viewer data
    SELECT 
        u.id,
        u.looking_for,
        u.preferences
    INTO viewer_user 
    FROM public.users u
    WHERE u.id = viewer_id;
    
    -- Get viewer profile
    SELECT 
        p.id,
        p.gender,
        p.age
    INTO viewer_profile 
    FROM public.profiles p
    WHERE p.id = viewer_id;
    
    -- Return empty if viewer not found
    IF viewer_user IS NULL OR viewer_profile IS NULL THEN
        RETURN;
    END IF;
    
    -- Return filtered potential matches
    RETURN QUERY
    SELECT 
        p.id,
        COALESCE(p.display_name, 'User') as display_name,
        p.avatar_url,
        COALESCE(p.gender, 'Other') as gender,
        COALESCE(p.age, 28) as age,
        COALESCE(p.interests, ARRAY[]::TEXT[]) as interests,
        p.zodiac_sign, -- REMOVED COALESCE fallback to 'Aries'
        p.education_level,
        COALESCE(p.traits, ARRAY[]::TEXT[]) as traits
    FROM public.profiles p
    INNER JOIN public.users u ON u.id = p.id
    WHERE 
        -- Exclude specified users
        p.id != viewer_id
        AND (exclude_user_ids IS NULL OR p.id != ALL(exclude_user_ids))
        -- Filter by zodiac if specified (handle NULL values properly)
        AND (
            zodiac_filter IS NULL 
            OR zodiac_filter = 'Any'
            OR p.zodiac_sign = zodiac_filter
        )
        -- Filter by age range
        AND (min_age_filter IS NULL OR p.age >= min_age_filter)
        AND (max_age_filter IS NULL OR p.age <= max_age_filter)
        -- Basic gender preference matching
        AND (
            viewer_user.looking_for IS NULL 
            OR viewer_user.looking_for = '{}'::text[]
            OR (
                (p.gender = 'Male' AND 'Males' = ANY(viewer_user.looking_for))
                OR (p.gender = 'Female' AND 'Females' = ANY(viewer_user.looking_for))
                OR (p.gender = 'Non-binary' AND 'Non-Binary' = ANY(viewer_user.looking_for))
                OR ('Both' = ANY(viewer_user.looking_for))
            )
        )
        -- Bidirectional matching - check if the potential match would be interested in viewer
        AND (
            u.looking_for IS NULL 
            OR u.looking_for = '{}'::text[]
            OR (
                (viewer_profile.gender = 'Male' AND 'Males' = ANY(u.looking_for))
                OR (viewer_profile.gender = 'Female' AND 'Females' = ANY(u.looking_for))
                OR (viewer_profile.gender = 'Non-binary' AND 'Non-Binary' = ANY(u.looking_for))
                OR ('Both' = ANY(u.looking_for))
            )
        )
    ORDER BY p.created_at DESC
    LIMIT limit_count
    OFFSET offset_count;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Log error and return empty result rather than failing
        RAISE WARNING 'Error in get_filtered_potential_matches: %', SQLERRM;
        RETURN;
END;
$$;

-- Add comment explaining the fix
COMMENT ON FUNCTION public.get_filtered_potential_matches(UUID, UUID[], TEXT, INT, INT, INT, INT) IS 
'Fixed zodiac sign fallback: Returns actual zodiac_sign value (including NULL) instead of hardcoded "Aries" fallback. This prevents incorrect zodiac signs from being displayed on match cards.';