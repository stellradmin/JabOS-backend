-- EMERGENCY RPC FUNCTIONS FOR MATCHING SYSTEM
-- Critical functions needed by Edge Functions

-- =====================================
-- SECTION 1: GET FILTERED POTENTIAL MATCHES
-- =====================================

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
        COALESCE(p.zodiac_sign, 'Aries') as zodiac_sign,
        p.education_level,
        COALESCE(p.traits, ARRAY[]::TEXT[]) as traits
    FROM public.profiles p
    INNER JOIN public.users u ON u.id = p.id
    WHERE 
        -- Exclude specified users
        p.id != viewer_id
        AND (exclude_user_ids IS NULL OR p.id != ALL(exclude_user_ids))
        -- Filter by zodiac if specified
        AND (zodiac_filter IS NULL OR p.zodiac_sign = zodiac_filter)
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
        -- Only show completed profiles
        AND p.onboarding_completed = true
    ORDER BY 
        -- Order by creation date (location-based sorting removed since location column doesn't exist)
        p.created_at DESC
    LIMIT limit_count
    OFFSET offset_count;
END;
$$;

-- =====================================
-- SECTION 2: CALCULATE COMPATIBILITY
-- =====================================

CREATE OR REPLACE FUNCTION public.calculate_compatibility_score(
    user1_id UUID,
    user2_id UUID
)
RETURNS TABLE (
    overall_score INTEGER,
    astro_score INTEGER,
    questionnaire_score INTEGER,
    astro_details JSONB,
    questionnaire_details JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    user1_data RECORD;
    user2_data RECORD;
    v_astro_score INTEGER := 75; -- Default score
    v_quest_score INTEGER := 75; -- Default score
    v_overall_score INTEGER;
BEGIN
    -- Get user data
    SELECT 
        p.zodiac_sign,
        p.questionnaire_answers
    INTO user1_data
    FROM public.profiles p
    WHERE p.id = user1_id;
    
    SELECT 
        p.zodiac_sign,
        p.questionnaire_answers
    INTO user2_data
    FROM public.profiles p
    WHERE p.id = user2_id;
    
    -- Simple zodiac compatibility (can be enhanced)
    IF user1_data.zodiac_sign IS NOT NULL AND user2_data.zodiac_sign IS NOT NULL THEN
        -- Basic compatibility matrix (simplified)
        CASE 
            WHEN user1_data.zodiac_sign = user2_data.zodiac_sign THEN
                v_astro_score := 80;
            WHEN (user1_data.zodiac_sign IN ('Aries', 'Leo', 'Sagittarius') AND 
                  user2_data.zodiac_sign IN ('Aries', 'Leo', 'Sagittarius')) THEN
                v_astro_score := 90; -- Fire signs
            WHEN (user1_data.zodiac_sign IN ('Taurus', 'Virgo', 'Capricorn') AND 
                  user2_data.zodiac_sign IN ('Taurus', 'Virgo', 'Capricorn')) THEN
                v_astro_score := 90; -- Earth signs
            WHEN (user1_data.zodiac_sign IN ('Gemini', 'Libra', 'Aquarius') AND 
                  user2_data.zodiac_sign IN ('Gemini', 'Libra', 'Aquarius')) THEN
                v_astro_score := 90; -- Air signs
            WHEN (user1_data.zodiac_sign IN ('Cancer', 'Scorpio', 'Pisces') AND 
                  user2_data.zodiac_sign IN ('Cancer', 'Scorpio', 'Pisces')) THEN
                v_astro_score := 90; -- Water signs
            ELSE
                v_astro_score := 70;
        END CASE;
    END IF;
    
    -- Simple questionnaire compatibility (can be enhanced)
    IF user1_data.questionnaire_answers IS NOT NULL AND 
       user2_data.questionnaire_answers IS NOT NULL THEN
        -- Count matching answers
        SELECT 
            LEAST(100, 50 + (COUNT(*) * 10)) INTO v_quest_score
        FROM (
            SELECT key
            FROM jsonb_each_text(user1_data.questionnaire_answers) e1
            JOIN jsonb_each_text(user2_data.questionnaire_answers) e2 
                ON e1.key = e2.key AND e1.value = e2.value
        ) matches;
    END IF;
    
    -- Calculate overall score
    v_overall_score := (v_astro_score + v_quest_score) / 2;
    
    RETURN QUERY
    SELECT 
        v_overall_score,
        v_astro_score,
        v_quest_score,
        jsonb_build_object(
            'sign1', user1_data.zodiac_sign,
            'sign2', user2_data.zodiac_sign,
            'score', v_astro_score
        ),
        jsonb_build_object(
            'matching_answers', COALESCE(
                (SELECT COUNT(*) 
                 FROM jsonb_each_text(user1_data.questionnaire_answers) e1
                 JOIN jsonb_each_text(user2_data.questionnaire_answers) e2 
                    ON e1.key = e2.key AND e1.value = e2.value), 0
            ),
            'score', v_quest_score
        );
END;
$$;

-- =====================================
-- SECTION 3: CHECK MATCH ELIGIBILITY
-- =====================================

-- Drop existing function if it has a different signature
DROP FUNCTION IF EXISTS public.check_match_eligibility(UUID, UUID);

CREATE OR REPLACE FUNCTION public.check_match_eligibility(
    p_viewer_id UUID,
    p_target_id UUID
)
RETURNS TABLE (
    is_eligible BOOLEAN,
    reason TEXT,
    compatibility_score INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_existing_swipe RECORD;
    v_existing_match RECORD;
    v_compatibility INTEGER;
BEGIN
    -- Check if already swiped
    SELECT * INTO v_existing_swipe
    FROM public.swipes
    WHERE swiper_id = p_viewer_id AND swiped_id = p_target_id;
    
    IF v_existing_swipe IS NOT NULL THEN
        RETURN QUERY SELECT false, 'Already swiped on this user', 0;
        RETURN;
    END IF;
    
    -- Check if already matched
    SELECT * INTO v_existing_match
    FROM public.matches
    WHERE (user1_id = LEAST(p_viewer_id, p_target_id) AND 
           user2_id = GREATEST(p_viewer_id, p_target_id))
    AND status = 'active';
    
    IF v_existing_match IS NOT NULL THEN
        RETURN QUERY SELECT false, 'Already matched with this user', 0;
        RETURN;
    END IF;
    
    -- Calculate compatibility
    SELECT overall_score INTO v_compatibility
    FROM public.calculate_compatibility_score(p_viewer_id, p_target_id);
    
    -- All checks passed
    RETURN QUERY SELECT true, 'Eligible for matching', COALESCE(v_compatibility, 75);
END;
$$;

-- =====================================
-- SECTION 4: GRANT PERMISSIONS
-- =====================================

GRANT EXECUTE ON FUNCTION public.get_filtered_potential_matches TO authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_compatibility_score TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_match_eligibility TO authenticated;

-- =====================================
-- SECTION 5: COMMENTS
-- =====================================

COMMENT ON FUNCTION public.get_filtered_potential_matches IS 'Retrieves potential matches for a user with filtering and pagination';
COMMENT ON FUNCTION public.calculate_compatibility_score IS 'Calculates compatibility scores between two users';
COMMENT ON FUNCTION public.check_match_eligibility IS 'Checks if two users are eligible to match';