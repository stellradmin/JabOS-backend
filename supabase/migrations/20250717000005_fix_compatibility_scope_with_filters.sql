-- Fix compatibility calculation to match original scope
-- Keep questionnaire and astrological scoring only
-- Move age, politics, and kids to FILTERING criteria (not scoring)

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
    
    -- Filter eligibility checks (not part of score)
    v_age_eligible BOOLEAN := TRUE;
    v_politics_compatible BOOLEAN := TRUE;
    v_kids_compatible BOOLEAN := TRUE;
    v_is_eligible BOOLEAN := TRUE;
    
    -- Final results
    v_overall_score INT;
    v_is_match_recommended BOOLEAN;
    v_calculation_result JSONB;
    
    age_difference INT := 0;
BEGIN
    -- Fetch user data for both users
    SELECT * INTO user_a_profile FROM public.profiles WHERE id = user_a_id;
    SELECT * INTO user_b_profile FROM public.profiles WHERE id = user_b_id;
    SELECT * INTO user_a_user FROM public.users WHERE id = user_a_id;
    SELECT * INTO user_b_user FROM public.users WHERE id = user_b_id;
    
    -- If no data found, return default
    IF user_a_profile IS NULL OR user_b_profile IS NULL THEN
        RETURN jsonb_build_object(
            'overall_score', 0,
            'questionnaire_grade', 'F',
            'astrological_grade', 'F',
            'questionnaire_score', 0,
            'astrological_score', 0,
            'IsMatchRecommended', false,
            'EligibleByPreferences', false,
            'error', 'User profiles not found'
        );
    END IF;
    
    -- FILTER CHECKS (These determine eligibility, NOT compatibility score)
    
    -- Age Filter: Check if users are within each other's age preferences
    IF user_a_profile.age IS NOT NULL AND user_b_profile.age IS NOT NULL THEN
        -- Check if user B's age is within user A's preferences
        IF user_a_user.preferences IS NOT NULL AND 
           user_a_user.preferences->>'min_age' IS NOT NULL AND 
           user_a_user.preferences->>'max_age' IS NOT NULL THEN
            IF user_b_profile.age < (user_a_user.preferences->>'min_age')::INT OR
               user_b_profile.age > (user_a_user.preferences->>'max_age')::INT THEN
                v_age_eligible := FALSE;
            END IF;
        END IF;
        
        -- Check if user A's age is within user B's preferences
        IF user_b_user.preferences IS NOT NULL AND 
           user_b_user.preferences->>'min_age' IS NOT NULL AND 
           user_b_user.preferences->>'max_age' IS NOT NULL THEN
            IF user_a_profile.age < (user_b_user.preferences->>'min_age')::INT OR
               user_a_profile.age > (user_b_user.preferences->>'max_age')::INT THEN
                v_age_eligible := FALSE;
            END IF;
        END IF;
    END IF;
    
    -- Politics Filter: Prevent Liberal/Progressive from matching with Conservative
    IF user_a_profile.politics IS NOT NULL AND user_b_profile.politics IS NOT NULL THEN
        IF (user_a_profile.politics IN ('Liberal', 'Progressive') AND 
            user_b_profile.politics = 'Conservative') OR
           (user_a_profile.politics = 'Conservative' AND 
            user_b_profile.politics IN ('Liberal', 'Progressive')) THEN
            v_politics_compatible := FALSE;
        END IF;
        -- Moderate can match with anyone
    END IF;
    
    -- Kids Filter: Prevent wants kids from matching with doesn't want kids
    IF user_a_profile.wants_kids IS NOT NULL AND user_b_profile.wants_kids IS NOT NULL THEN
        IF (user_a_profile.wants_kids = 'Yes' AND user_b_profile.wants_kids = 'No') OR
           (user_a_profile.wants_kids = 'No' AND user_b_profile.wants_kids = 'Yes') THEN
            v_kids_compatible := FALSE;
        END IF;
        -- 'Maybe' can match with anyone
    END IF;
    
    -- Overall eligibility
    v_is_eligible := v_age_eligible AND v_politics_compatible AND v_kids_compatible;
    
    -- If not eligible by filters, return early with zero scores
    IF NOT v_is_eligible THEN
        RETURN jsonb_build_object(
            'overall_score', 0,
            'questionnaire_grade', 'F',
            'astrological_grade', 'F',
            'questionnaire_score', 0,
            'astrological_score', 0,
            'IsMatchRecommended', false,
            'EligibleByPreferences', false,
            'filter_results', jsonb_build_object(
                'age_eligible', v_age_eligible,
                'politics_compatible', v_politics_compatible,
                'kids_compatible', v_kids_compatible
            ),
            'MeetsScoreThreshold', false,
            'overallScore', 0,
            'AstrologicalGrade', 'F',
            'QuestionnaireGrade', 'F'
        );
    END IF;
    
    -- COMPATIBILITY SCORING (Only for eligible matches)
    
    -- Calculate questionnaire compatibility if both users have responses
    IF user_a_user.questionnaire_responses IS NOT NULL AND 
       user_b_user.questionnaire_responses IS NOT NULL AND
       jsonb_array_length(user_a_user.questionnaire_responses) > 0 AND
       jsonb_array_length(user_b_user.questionnaire_responses) > 0 THEN
        questionnaire_result := calculate_questionnaire_compatibility(
            user_a_user.questionnaire_responses,
            user_b_user.questionnaire_responses
        );
        questionnaire_score := (questionnaire_result->>'overall_score')::INT;
        questionnaire_grade := questionnaire_result->>'grade';
    END IF;
    
    -- Calculate astrological compatibility if both users have natal chart data
    IF user_a_user.natal_chart_data IS NOT NULL AND 
       user_b_user.natal_chart_data IS NOT NULL AND
       user_a_user.natal_chart_data != 'null'::jsonb AND
       user_b_user.natal_chart_data != 'null'::jsonb THEN
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
        -- No compatibility data available but users are eligible
        v_overall_score := 50;
    END IF;
    
    -- Determine recommendation (only if eligible AND good compatibility)
    v_is_match_recommended := v_is_eligible AND v_overall_score >= 70;
    
    -- Construct result
    v_calculation_result := jsonb_build_object(
        'overall_score', v_overall_score,
        'questionnaire_grade', questionnaire_grade,
        'astrological_grade', astrological_grade,
        'questionnaire_score', questionnaire_score,
        'astrological_score', astrological_score,
        'questionnaire_details', questionnaire_result,
        'astrological_details', astrological_result,
        
        -- Filter results (for transparency)
        'filter_results', jsonb_build_object(
            'age_eligible', v_age_eligible,
            'politics_compatible', v_politics_compatible,
            'kids_compatible', v_kids_compatible
        ),
        
        -- Legacy fields for test compatibility (all removed features set to 0)
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
        'EligibleByPreferences', v_is_eligible,
        'algorithm_version', '4.0_filtered',
        'calculated_at', EXTRACT(EPOCH FROM NOW())
    );
    
    RETURN v_calculation_result;
    
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Error in calculate_compatibility_scores: %', SQLERRM;
        RETURN jsonb_build_object(
            'overall_score', 0,
            'questionnaire_grade', 'F',
            'astrological_grade', 'F',
            'questionnaire_score', 0,
            'astrological_score', 0,
            'interest_compatibility', 0,
            'trait_compatibility', 0,
            'politics_compatibility', 0,
            'education_compatibility', 0,
            'kids_compatibility', 0,
            'age_compatibility', 0,
            'IsMatchRecommended', false,
            'EligibleByPreferences', false,
            'error', 'Calculation failed: ' || SQLERRM,
            'algorithm_version', '4.0_filtered'
        );
END;
$$;

-- Update function comment
COMMENT ON FUNCTION public.calculate_compatibility_scores(UUID, UUID) IS 
'Calculates compatibility using questionnaire and astrological algorithms only. 
Applies hard filters for age preferences, political incompatibility (Liberal/Progressive vs Conservative), 
and kids preferences (wants vs does not want). Users failing filters are marked ineligible with zero scores.';

-- Create helper function to check if a user should see another user based on preferences
CREATE OR REPLACE FUNCTION public.check_user_eligibility_filters(
    viewer_id UUID,
    target_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    viewer_profile RECORD;
    target_profile RECORD;
    viewer_user RECORD;
    target_user RECORD;
    
    v_age_eligible BOOLEAN := TRUE;
    v_politics_compatible BOOLEAN := TRUE;
    v_kids_compatible BOOLEAN := TRUE;
    v_gender_eligible BOOLEAN := TRUE;
BEGIN
    -- Fetch user data
    SELECT * INTO viewer_profile FROM public.profiles WHERE id = viewer_id;
    SELECT * INTO target_profile FROM public.profiles WHERE id = target_id;
    SELECT * INTO viewer_user FROM public.users WHERE id = viewer_id;
    SELECT * INTO target_user FROM public.users WHERE id = target_id;
    
    -- Age preference check
    IF viewer_user.preferences IS NOT NULL AND 
       viewer_user.preferences->>'min_age' IS NOT NULL AND 
       viewer_user.preferences->>'max_age' IS NOT NULL AND
       target_profile.age IS NOT NULL THEN
        IF target_profile.age < (viewer_user.preferences->>'min_age')::INT OR
           target_profile.age > (viewer_user.preferences->>'max_age')::INT THEN
            v_age_eligible := FALSE;
        END IF;
    END IF;
    
    -- Gender preference check
    IF viewer_user.preferences IS NOT NULL AND 
       viewer_user.preferences->>'gender_preference' IS NOT NULL AND
       target_profile.gender IS NOT NULL THEN
        DECLARE
            pref TEXT := LOWER(viewer_user.preferences->>'gender_preference');
        BEGIN
            IF pref != 'any' AND pref != LOWER(target_profile.gender) THEN
                v_gender_eligible := FALSE;
            END IF;
        END;
    END IF;
    
    -- Politics filter
    IF viewer_profile.politics IS NOT NULL AND target_profile.politics IS NOT NULL THEN
        IF (viewer_profile.politics IN ('Liberal', 'Progressive') AND 
            target_profile.politics = 'Conservative') OR
           (viewer_profile.politics = 'Conservative' AND 
            target_profile.politics IN ('Liberal', 'Progressive')) THEN
            v_politics_compatible := FALSE;
        END IF;
    END IF;
    
    -- Kids preference filter
    IF viewer_profile.wants_kids IS NOT NULL AND target_profile.wants_kids IS NOT NULL THEN
        IF (viewer_profile.wants_kids = 'Yes' AND target_profile.wants_kids = 'No') OR
           (viewer_profile.wants_kids = 'No' AND target_profile.wants_kids = 'Yes') THEN
            v_kids_compatible := FALSE;
        END IF;
    END IF;
    
    RETURN jsonb_build_object(
        'is_eligible', v_age_eligible AND v_politics_compatible AND v_kids_compatible AND v_gender_eligible,
        'age_eligible', v_age_eligible,
        'politics_compatible', v_politics_compatible,
        'kids_compatible', v_kids_compatible,
        'gender_eligible', v_gender_eligible
    );
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.check_user_eligibility_filters(UUID, UUID) TO authenticated;

-- Add comment
COMMENT ON FUNCTION public.check_user_eligibility_filters(UUID, UUID) IS 
'Checks if viewer should see target user based on hard filters: age preferences, political compatibility, and kids preferences.';