-- Fix compatibility function return format to include top-level compatibility fields
-- This ensures the test validation passes and the API returns expected fields

CREATE OR REPLACE FUNCTION public.calculate_compatibility_scores(
    user_a_id UUID,
    user_b_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    user_a_profile RECORD;
    user_b_profile RECORD;
    user_a_user RECORD;
    user_b_user RECORD;
    
    -- Questionnaire compatibility
    questionnaire_result JSONB;
    questionnaire_score INT := 50;
    questionnaire_grade TEXT := 'C';
    
    -- Astrological compatibility
    astrological_result JSONB;
    astrological_score INT := 50;
    astrological_grade TEXT := 'C';
    
    -- Basic compatibility scores (for reference)
    v_interest_score FLOAT := 0;
    v_trait_score FLOAT := 0;
    v_politics_score FLOAT := 0;
    v_education_score FLOAT := 0;
    v_kids_score FLOAT := 0;
    v_age_score FLOAT := 0;
    
    -- Final results
    v_overall_score INT;
    v_is_match_recommended BOOLEAN;
    v_calculation_result JSONB;
    
    common_interests INT := 0;
    common_traits INT := 0;
    age_difference INT := 0;
BEGIN
    -- Fetch profile and user data for both users
    SELECT * INTO user_a_profile FROM public.profiles WHERE id = user_a_id;
    SELECT * INTO user_b_profile FROM public.profiles WHERE id = user_b_id;
    SELECT * INTO user_a_user FROM public.users WHERE id = user_a_id;
    SELECT * INTO user_b_user FROM public.users WHERE id = user_b_id;
    
    -- If no data found, return default
    IF user_a_profile IS NULL OR user_b_profile IS NULL THEN
        RETURN jsonb_build_object(
            'overall_score', 50,
            'questionnaire_grade', 'C',
            'astrological_grade', 'C',
            'interest_compatibility', 0,
            'trait_compatibility', 0,
            'politics_compatibility', 0,
            'education_compatibility', 0,
            'kids_compatibility', 0,
            'age_compatibility', 0,
            'IsMatchRecommended', false,
            'error', 'User profiles not found'
        );
    END IF;
    
    -- Calculate questionnaire compatibility if both users have responses
    IF user_a_user.questionnaire_responses IS NOT NULL AND user_b_user.questionnaire_responses IS NOT NULL THEN
        questionnaire_result := calculate_questionnaire_compatibility(
            user_a_user.questionnaire_responses,
            user_b_user.questionnaire_responses
        );
        questionnaire_score := (questionnaire_result->>'overall_score')::INT;
        questionnaire_grade := questionnaire_result->>'grade';
    END IF;
    
    -- Calculate astrological compatibility if both users have natal chart data
    IF user_a_user.natal_chart_data IS NOT NULL AND user_b_user.natal_chart_data IS NOT NULL THEN
        astrological_result := calculate_astrological_compatibility(
            user_a_user.natal_chart_data,
            user_b_user.natal_chart_data
        );
        astrological_score := (astrological_result->>'overall_score')::INT;
        astrological_grade := astrological_result->>'grade';
    END IF;
    
    -- Calculate basic compatibility scores for context
    
    -- Interest Compatibility
    IF user_a_profile.interests IS NOT NULL AND user_b_profile.interests IS NOT NULL THEN
        SELECT COUNT(*) INTO common_interests
        FROM (
            SELECT unnest(user_a_profile.interests) AS interest
            INTERSECT
            SELECT unnest(user_b_profile.interests) AS interest
        ) common;
        
        v_interest_score := LEAST(100, (common_interests::FLOAT / GREATEST(1, array_length(user_a_profile.interests, 1) + array_length(user_b_profile.interests, 1)) * 2) * 100);
    END IF;
    
    -- Trait Compatibility
    IF user_a_profile.traits IS NOT NULL AND user_b_profile.traits IS NOT NULL THEN
        SELECT COUNT(*) INTO common_traits
        FROM (
            SELECT unnest(user_a_profile.traits) AS trait
            INTERSECT
            SELECT unnest(user_b_profile.traits) AS trait
        ) common;
        
        v_trait_score := LEAST(100, (common_traits::FLOAT / GREATEST(1, array_length(user_a_profile.traits, 1) + array_length(user_b_profile.traits, 1)) * 2) * 100);
    END IF;
    
    -- Politics Compatibility
    IF user_a_profile.politics IS NOT NULL AND user_b_profile.politics IS NOT NULL THEN
        IF user_a_profile.politics = user_b_profile.politics THEN
            v_politics_score := 100;
        ELSIF 
            (user_a_profile.politics IN ('Liberal', 'Progressive') AND user_b_profile.politics IN ('Liberal', 'Progressive')) OR
            (user_a_profile.politics IN ('Conservative', 'Traditional') AND user_b_profile.politics IN ('Conservative', 'Traditional'))
        THEN
            v_politics_score := 75;
        ELSIF user_a_profile.politics = 'Moderate' OR user_b_profile.politics = 'Moderate' THEN
            v_politics_score := 50;
        ELSE
            v_politics_score := 25;
        END IF;
    END IF;
    
    -- Education Compatibility
    IF user_a_profile.education_level IS NOT NULL AND user_b_profile.education_level IS NOT NULL THEN
        IF user_a_profile.education_level = user_b_profile.education_level THEN
            v_education_score := 100;
        ELSE
            v_education_score := 70;
        END IF;
    END IF;
    
    -- Kids Compatibility
    IF user_a_profile.wants_kids IS NOT NULL AND user_b_profile.wants_kids IS NOT NULL THEN
        IF user_a_profile.wants_kids = user_b_profile.wants_kids THEN
            v_kids_score := 100;
        ELSIF (user_a_profile.wants_kids = 'Maybe' OR user_b_profile.wants_kids = 'Maybe') THEN
            v_kids_score := 60;
        ELSE
            v_kids_score := 20;
        END IF;
    END IF;
    
    -- Age Compatibility
    IF user_a_profile.age IS NOT NULL AND user_b_profile.age IS NOT NULL THEN
        age_difference := ABS(user_a_profile.age - user_b_profile.age);
        v_age_score := GREATEST(0, 100 - (age_difference * 5));
    END IF;
    
    -- Calculate overall score as weighted average of questionnaire and astrological compatibility
    -- Give more weight to sophisticated algorithms when available
    IF questionnaire_score > 0 AND astrological_score > 0 THEN
        -- Both algorithms available - weight them heavily
        v_overall_score := ROUND(
            (questionnaire_score * 0.4) +     -- 40% questionnaire
            (astrological_score * 0.4) +      -- 40% astrological
            (v_interest_score * 0.05) +       -- 5% interests
            (v_trait_score * 0.05) +          -- 5% traits
            (v_politics_score * 0.025) +      -- 2.5% politics
            (v_education_score * 0.025) +     -- 2.5% education
            (v_kids_score * 0.025) +          -- 2.5% kids
            (v_age_score * 0.025)             -- 2.5% age
        )::INT;
    ELSIF questionnaire_score > 0 THEN
        -- Only questionnaire available - weight it more heavily
        v_overall_score := ROUND(
            (questionnaire_score * 0.6) +     -- 60% questionnaire
            (v_interest_score * 0.1) +        -- 10% interests
            (v_trait_score * 0.1) +           -- 10% traits
            (v_politics_score * 0.05) +       -- 5% politics
            (v_education_score * 0.05) +      -- 5% education
            (v_kids_score * 0.05) +           -- 5% kids
            (v_age_score * 0.05)              -- 5% age
        )::INT;
    ELSIF astrological_score > 0 THEN
        -- Only astrological available - weight it more heavily
        v_overall_score := ROUND(
            (astrological_score * 0.6) +      -- 60% astrological
            (v_interest_score * 0.1) +        -- 10% interests
            (v_trait_score * 0.1) +           -- 10% traits
            (v_politics_score * 0.05) +       -- 5% politics
            (v_education_score * 0.05) +      -- 5% education
            (v_kids_score * 0.05) +           -- 5% kids
            (v_age_score * 0.05)              -- 5% age
        )::INT;
    ELSE
        -- Fallback to basic compatibility
        v_overall_score := ROUND(
            (v_interest_score * 0.25) +       -- 25% interests
            (v_trait_score * 0.20) +          -- 20% traits
            (v_politics_score * 0.15) +       -- 15% politics
            (v_education_score * 0.10) +      -- 10% education
            (v_kids_score * 0.15) +           -- 15% kids
            (v_age_score * 0.15)              -- 15% age
        )::INT;
    END IF;
    
    -- Determine recommendation
    v_is_match_recommended := v_overall_score >= 70;
    
    -- Construct comprehensive result with both nested and top-level compatibility scores
    v_calculation_result := jsonb_build_object(
        'overall_score', v_overall_score,
        'questionnaire_grade', questionnaire_grade,
        'astrological_grade', astrological_grade,
        'questionnaire_score', questionnaire_score,
        'astrological_score', astrological_score,
        
        -- Top-level compatibility scores for API compatibility
        'interest_compatibility', v_interest_score,
        'trait_compatibility', v_trait_score,
        'politics_compatibility', v_politics_score,
        'education_compatibility', v_education_score,
        'kids_compatibility', v_kids_score,
        'age_compatibility', v_age_score,
        
        'questionnaire_details', questionnaire_result,
        'astrological_details', astrological_result,
        'basic_compatibility', jsonb_build_object(
            'interest_compatibility', v_interest_score,
            'trait_compatibility', v_trait_score,
            'politics_compatibility', v_politics_score,
            'education_compatibility', v_education_score,
            'kids_compatibility', v_kids_score,
            'age_compatibility', v_age_score
        ),
        'overallScore', v_overall_score,
        'AstrologicalGrade', astrological_grade,
        'QuestionnaireGrade', questionnaire_grade,
        'IsMatchRecommended', v_is_match_recommended,
        'MeetsScoreThreshold', v_overall_score >= 70,
        'EligibleByPreferences', TRUE,
        'algorithm_version', '2.0_complete',
        'calculated_at', EXTRACT(EPOCH FROM NOW())
    );
    
    RETURN v_calculation_result;
    
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Error in calculate_compatibility_scores: %', SQLERRM;
        RETURN jsonb_build_object(
            'overall_score', 50,
            'questionnaire_grade', 'C',
            'astrological_grade', 'C',
            'interest_compatibility', 0,
            'trait_compatibility', 0,
            'politics_compatibility', 0,
            'education_compatibility', 0,
            'kids_compatibility', 0,
            'age_compatibility', 0,
            'IsMatchRecommended', false,
            'error', 'Calculation failed: ' || SQLERRM,
            'algorithm_version', '2.0_complete'
        );
END;
$$;