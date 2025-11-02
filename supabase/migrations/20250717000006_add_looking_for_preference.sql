-- Add "Looking For" preference system to support proper gender matching
-- This prevents mismatched expectations and provides better user control

-- Step 1: Add looking_for column to users table
ALTER TABLE public.users 
ADD COLUMN IF NOT EXISTS looking_for TEXT[] DEFAULT NULL;

-- Step 2: Add constraint for valid looking_for values
ALTER TABLE public.users 
ADD CONSTRAINT users_looking_for_check 
CHECK (looking_for IS NULL OR looking_for <@ ARRAY['Males', 'Females', 'Both', 'Non-Binary', 'Transgender']);

-- Step 3: Fix existing gender validation to allow proper values
-- First update any invalid gender values
UPDATE public.profiles 
SET gender = CASE 
    WHEN LOWER(gender) = 'male' THEN 'Male'
    WHEN LOWER(gender) = 'female' THEN 'Female'
    WHEN LOWER(gender) = 'non-binary' THEN 'Non-binary'
    WHEN LOWER(gender) = 'other' THEN 'Other'
    WHEN gender IS NULL THEN 'Other'
    ELSE 'Other'
END
WHERE gender NOT IN ('Male', 'Female', 'Non-binary', 'Other') OR gender IS NULL;

-- Step 4: Update the validate_profile_data() function to accept correct gender values
CREATE OR REPLACE FUNCTION validate_profile_data()
RETURNS TRIGGER AS $$
BEGIN
    -- Validate gender (allow proper case-sensitive values)
    IF NEW.gender IS NOT NULL AND NEW.gender NOT IN ('Male', 'Female', 'Non-binary', 'Other', 'Prefer not to say') THEN
        RAISE EXCEPTION 'Invalid gender value. Must be: Male, Female, Non-binary, Other, or Prefer not to say';
    END IF;
    
    -- Add other validations as needed
    IF NEW.age IS NOT NULL AND (NEW.age < 18 OR NEW.age > 100) THEN
        RAISE EXCEPTION 'Age must be between 18 and 100';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Step 5: Add proper gender constraint to profiles table
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_gender_check;
ALTER TABLE public.profiles 
ADD CONSTRAINT profiles_gender_check 
CHECK (gender IN ('Male', 'Female', 'Non-binary', 'Other', 'Prefer not to say'));

-- Step 6: Fix matches status constraint (using correct table name)
UPDATE public.matches 
SET status = CASE 
    WHEN status NOT IN ('pending', 'confirmed', 'rejected', 'expired', 'active', 'cancelled') THEN 'pending'
    ELSE status
END;

ALTER TABLE public.matches DROP CONSTRAINT IF EXISTS matches_status_check;
ALTER TABLE public.matches 
ADD CONSTRAINT matches_status_check 
CHECK (status IN ('pending', 'confirmed', 'rejected', 'expired', 'active', 'cancelled'));

-- Step 7: Update preferences structure to include looking_for
-- Commented out due to missing preferences column
/*
UPDATE public.users 
SET preferences = COALESCE(preferences, '{}'::jsonb) || 
    jsonb_build_object('looking_for', COALESCE(looking_for, ARRAY['Males', 'Females']))
WHERE looking_for IS NOT NULL;
*/

-- Step 8: Create enhanced filtering function that uses looking_for preferences
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
    
    v_looking_for_match BOOLEAN := TRUE;
    v_mutual_looking_for BOOLEAN := TRUE;
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
    
    -- Check if viewer is looking for target's gender
    IF viewer_user.looking_for IS NOT NULL AND target_profile.gender IS NOT NULL THEN
        -- Map gender to looking_for format
        DECLARE
            target_gender_mapped TEXT;
        BEGIN
            target_gender_mapped := CASE target_profile.gender
                WHEN 'Male' THEN 'Males'
                WHEN 'Female' THEN 'Females'
                WHEN 'Non-binary' THEN 'Non-Binary'
                WHEN 'Other' THEN 'Non-Binary'  -- Map Other to Non-Binary for matching
                ELSE 'Non-Binary'
            END;
            
            -- Check if target's gender is in viewer's looking_for preferences
            IF NOT (target_gender_mapped = ANY(viewer_user.looking_for)) AND NOT ('Both' = ANY(viewer_user.looking_for)) THEN
                v_looking_for_match := FALSE;
            END IF;
        END;
    END IF;
    
    -- Check mutual interest: if target is looking for viewer's gender
    IF target_user.looking_for IS NOT NULL AND viewer_profile.gender IS NOT NULL THEN
        DECLARE
            viewer_gender_mapped TEXT;
        BEGIN
            viewer_gender_mapped := CASE viewer_profile.gender
                WHEN 'Male' THEN 'Males'
                WHEN 'Female' THEN 'Females'
                WHEN 'Non-binary' THEN 'Non-Binary'
                WHEN 'Other' THEN 'Non-Binary'
                ELSE 'Non-Binary'
            END;
            
            -- Check if viewer's gender is in target's looking_for preferences
            IF NOT (viewer_gender_mapped = ANY(target_user.looking_for)) AND NOT ('Both' = ANY(target_user.looking_for)) THEN
                v_mutual_looking_for := FALSE;
            END IF;
        END;
    END IF;
    
    -- Age preference check (existing logic)
    IF viewer_user.preferences IS NOT NULL AND 
       viewer_user.preferences->>'min_age' IS NOT NULL AND 
       viewer_user.preferences->>'max_age' IS NOT NULL AND
       target_profile.age IS NOT NULL THEN
        IF target_profile.age < (viewer_user.preferences->>'min_age')::INT OR
           target_profile.age > (viewer_user.preferences->>'max_age')::INT THEN
            v_age_eligible := FALSE;
        END IF;
    END IF;
    
    -- Politics filter (existing logic)
    IF viewer_profile.politics IS NOT NULL AND target_profile.politics IS NOT NULL THEN
        IF (viewer_profile.politics IN ('Liberal', 'Progressive') AND 
            target_profile.politics = 'Conservative') OR
           (viewer_profile.politics = 'Conservative' AND 
            target_profile.politics IN ('Liberal', 'Progressive')) THEN
            v_politics_compatible := FALSE;
        END IF;
    END IF;
    
    -- Kids preference filter (existing logic)
    IF viewer_profile.wants_kids IS NOT NULL AND target_profile.wants_kids IS NOT NULL THEN
        IF (viewer_profile.wants_kids = 'Yes' AND target_profile.wants_kids = 'No') OR
           (viewer_profile.wants_kids = 'No' AND target_profile.wants_kids = 'Yes') THEN
            v_kids_compatible := FALSE;
        END IF;
    END IF;
    
    RETURN jsonb_build_object(
        'is_eligible', v_looking_for_match AND v_mutual_looking_for AND v_age_eligible AND v_politics_compatible AND v_kids_compatible,
        'looking_for_match', v_looking_for_match,
        'mutual_looking_for', v_mutual_looking_for,
        'age_eligible', v_age_eligible,
        'politics_compatible', v_politics_compatible,
        'kids_compatible', v_kids_compatible,
        'gender_eligible', v_gender_eligible
    );
END;
$$;

-- Step 9: Update the compatibility calculation to use new filtering
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
    
    -- Filter eligibility using new function
    eligibility_result JSONB;
    v_is_eligible BOOLEAN := FALSE;
    
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
    
    -- Check eligibility using the new comprehensive filter
    eligibility_result := check_user_eligibility_filters(user_a_id, user_b_id);
    v_is_eligible := (eligibility_result->>'is_eligible')::BOOLEAN;
    
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
            'filter_results', eligibility_result,
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
    
    -- Construct result with new filter information
    v_calculation_result := jsonb_build_object(
        'overall_score', v_overall_score,
        'questionnaire_grade', questionnaire_grade,
        'astrological_grade', astrological_grade,
        'questionnaire_score', questionnaire_score,
        'astrological_score', astrological_score,
        'questionnaire_details', questionnaire_result,
        'astrological_details', astrological_result,
        
        -- Enhanced filter results with looking_for information
        'filter_results', eligibility_result,
        
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
        'algorithm_version', '5.0_looking_for',
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
            'algorithm_version', '5.0_looking_for'
        );
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.check_user_eligibility_filters(UUID, UUID) TO authenticated;

-- Add comments
COMMENT ON COLUMN public.users.looking_for IS 'Array of gender preferences the user is looking to match with: Males, Females, Both, Non-Binary, Transgender';
COMMENT ON FUNCTION public.check_user_eligibility_filters(UUID, UUID) IS 'Enhanced eligibility check including mutual looking_for preferences, age, politics, and kids compatibility';
COMMENT ON FUNCTION public.calculate_compatibility_scores(UUID, UUID) IS 'Complete compatibility calculation with enhanced filtering based on looking_for preferences and existing criteria';