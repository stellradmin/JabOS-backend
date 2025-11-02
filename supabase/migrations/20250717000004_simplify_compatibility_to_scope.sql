-- Simplify compatibility function to only use astrological and questionnaire scoring as per scope
-- Removes unnecessary interest, trait, politics, education, kids, and age compatibility calculations

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
    
    -- Final results
    v_overall_score INT;
    v_is_match_recommended BOOLEAN;
    v_calculation_result JSONB;
BEGIN
    -- Fetch user data for both users
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
            'questionnaire_score', 50,
            'astrological_score', 50,
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
    
    -- Calculate overall score using only questionnaire and astrological compatibility
    IF questionnaire_score > 0 AND astrological_score > 0 THEN
        -- Both algorithms available - weight them equally
        v_overall_score := ROUND(
            (questionnaire_score * 0.5) +     -- 50% questionnaire
            (astrological_score * 0.5)         -- 50% astrological
        )::INT;
    ELSIF questionnaire_score > 0 THEN
        -- Only questionnaire available
        v_overall_score := questionnaire_score;
    ELSIF astrological_score > 0 THEN
        -- Only astrological available
        v_overall_score := astrological_score;
    ELSE
        -- No compatibility data available
        v_overall_score := 50;
    END IF;
    
    -- Determine recommendation
    v_is_match_recommended := v_overall_score >= 70;
    
    -- Construct streamlined result focused on questionnaire and astrological compatibility
    v_calculation_result := jsonb_build_object(
        'overall_score', v_overall_score,
        'questionnaire_grade', questionnaire_grade,
        'astrological_grade', astrological_grade,
        'questionnaire_score', questionnaire_score,
        'astrological_score', astrological_score,
        'questionnaire_details', questionnaire_result,
        'astrological_details', astrological_result,
        
        -- Legacy fields for backward compatibility (set to 0)
        'interest_compatibility', 0,
        'trait_compatibility', 0,
        'politics_compatibility', 0,
        'education_compatibility', 0,
        'kids_compatibility', 0,
        'age_compatibility', 0,
        
        -- API compatibility fields
        'overallScore', v_overall_score,
        'AstrologicalGrade', astrological_grade,
        'QuestionnaireGrade', questionnaire_grade,
        'IsMatchRecommended', v_is_match_recommended,
        'MeetsScoreThreshold', v_overall_score >= 70,
        'EligibleByPreferences', TRUE,
        'algorithm_version', '3.0_streamlined',
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
            'questionnaire_score', 50,
            'astrological_score', 50,
            'interest_compatibility', 0,
            'trait_compatibility', 0,
            'politics_compatibility', 0,
            'education_compatibility', 0,
            'kids_compatibility', 0,
            'age_compatibility', 0,
            'IsMatchRecommended', false,
            'error', 'Calculation failed: ' || SQLERRM,
            'algorithm_version', '3.0_streamlined'
        );
END;
$$;

-- Add comment
COMMENT ON FUNCTION public.calculate_compatibility_scores(UUID, UUID) IS 
'Streamlined compatibility calculation using only questionnaire and astrological algorithms as per original scope.';