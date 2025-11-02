-- Create batch filtering RPC function for get-potential-matches edge function
-- This function replaces the missing parameters expected by the edge function

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
    -- Get viewer data for bidirectional filtering
    SELECT * INTO viewer_user FROM public.users WHERE id = viewer_id;
    SELECT * INTO viewer_profile FROM public.profiles WHERE id = viewer_id;
    
    -- If viewer data not found, return empty
    IF viewer_user IS NULL OR viewer_profile IS NULL THEN
        RETURN;
    END IF;
    
    -- Return filtered potential matches using bidirectional compatibility
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
        p.traits
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

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.get_filtered_potential_matches(UUID, UUID[], TEXT, INT, INT, INT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_filtered_potential_matches(UUID, UUID[], TEXT, INT, INT, INT, INT) TO service_role;

-- Add comment
COMMENT ON FUNCTION public.get_filtered_potential_matches(UUID, UUID[], TEXT, INT, INT, INT, INT) IS 
'Batch filtering function for potential matches. Applies bidirectional gender preferences, age filters, zodiac filters, and compatibility checks. Used by get-potential-matches edge function.';