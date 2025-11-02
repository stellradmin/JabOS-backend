-- =============================================
-- JabOS Mobile - RPC Functions
-- Matching algorithm adapted from Stellr's astrological compatibility
-- Translates: Zodiac → Weight Class, Personality → Training Style
-- =============================================

-- =============================================
-- HELPER FUNCTION: Check if two weight classes are adjacent
-- Replaces Stellr's zodiac sign compatibility
-- =============================================
CREATE OR REPLACE FUNCTION jabos_mobile.is_adjacent_weight_class(
  wc1 TEXT,
  wc2 TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  weight_classes TEXT[] := ARRAY[
    'flyweight',              -- 1. ≤112 lbs
    'super_flyweight',        -- 2. ≤115 lbs
    'bantamweight',           -- 3. ≤118 lbs
    'super_bantamweight',     -- 4. ≤122 lbs
    'featherweight',          -- 5. ≤126 lbs
    'super_featherweight',    -- 6. ≤130 lbs
    'lightweight',            -- 7. ≤135 lbs
    'super_lightweight',      -- 8. ≤140 lbs
    'welterweight',           -- 9. ≤147 lbs
    'super_welterweight',     -- 10. ≤154 lbs
    'middleweight',           -- 11. ≤160 lbs
    'super_middleweight',     -- 12. ≤168 lbs
    'light_heavyweight',      -- 13. ≤175 lbs
    'cruiserweight',          -- 14. ≤200 lbs
    'heavyweight',            -- 15. ≤201+ lbs
    'super_heavyweight'       -- 16. ≤250+ lbs
  ];
  pos1 INT;
  pos2 INT;
BEGIN
  -- Find positions in array
  pos1 := array_position(weight_classes, wc1);
  pos2 := array_position(weight_classes, wc2);

  -- Return false if either not found
  IF pos1 IS NULL OR pos2 IS NULL THEN
    RETURN false;
  END IF;

  -- Adjacent if positions differ by exactly 1
  RETURN ABS(pos1 - pos2) = 1;
END;
$$;

-- =============================================
-- HELPER FUNCTION: Get adjacent weight classes
-- Returns array of weight classes within ±1 of given class
-- =============================================
CREATE OR REPLACE FUNCTION jabos_mobile.get_adjacent_weight_classes(
  wc TEXT
)
RETURNS TEXT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  weight_classes TEXT[] := ARRAY[
    'flyweight', 'super_flyweight', 'bantamweight', 'super_bantamweight',
    'featherweight', 'super_featherweight', 'lightweight', 'super_lightweight',
    'welterweight', 'super_welterweight', 'middleweight', 'super_middleweight',
    'light_heavyweight', 'cruiserweight', 'heavyweight', 'super_heavyweight'
  ];
  pos INT;
  result TEXT[] := ARRAY[]::TEXT[];
BEGIN
  pos := array_position(weight_classes, wc);

  IF pos IS NULL THEN
    RETURN result;
  END IF;

  -- Add previous class if exists
  IF pos > 1 THEN
    result := array_append(result, weight_classes[pos - 1]);
  END IF;

  -- Add current class
  result := array_append(result, weight_classes[pos]);

  -- Add next class if exists
  IF pos < array_length(weight_classes, 1) THEN
    result := array_append(result, weight_classes[pos + 1]);
  END IF;

  RETURN result;
END;
$$;

-- =============================================
-- HELPER FUNCTION: Check if experience levels are compatible
-- Replaces Stellr's age range compatibility
-- =============================================
CREATE OR REPLACE FUNCTION jabos_mobile.is_compatible_experience(
  exp1 TEXT,
  exp2 TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  exp_levels TEXT[] := ARRAY['beginner', 'intermediate', 'advanced', 'pro'];
  pos1 INT;
  pos2 INT;
BEGIN
  pos1 := array_position(exp_levels, exp1);
  pos2 := array_position(exp_levels, exp2);

  IF pos1 IS NULL OR pos2 IS NULL THEN
    RETURN false;
  END IF;

  -- Compatible if same level or ±1 level
  -- e.g., intermediate can match with beginner, intermediate, or advanced
  RETURN ABS(pos1 - pos2) <= 1;
END;
$$;

-- =============================================
-- HELPER FUNCTION: Get compatible experience levels
-- Returns array of experience levels within ±1 of given level
-- =============================================
CREATE OR REPLACE FUNCTION jabos_mobile.get_compatible_experience_levels(
  exp TEXT
)
RETURNS TEXT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  exp_levels TEXT[] := ARRAY['beginner', 'intermediate', 'advanced', 'pro'];
  pos INT;
  result TEXT[] := ARRAY[]::TEXT[];
BEGIN
  pos := array_position(exp_levels, exp);

  IF pos IS NULL THEN
    RETURN result;
  END IF;

  -- Add previous level if exists
  IF pos > 1 THEN
    result := array_append(result, exp_levels[pos - 1]);
  END IF;

  -- Add current level
  result := array_append(result, exp_levels[pos]);

  -- Add next level if exists
  IF pos < array_length(exp_levels, 1) THEN
    result := array_append(result, exp_levels[pos + 1]);
  END IF;

  RETURN result;
END;
$$;

-- =============================================
-- CORE FUNCTION: Calculate Training Compatibility
-- Adapted from Stellr's calculate_compatibility
-- Translates astrological compatibility → physical/training compatibility
-- =============================================
CREATE OR REPLACE FUNCTION jabos_mobile.calculate_training_compatibility(
  user_a_id UUID,
  user_b_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'jabos_mobile', 'auth', 'extensions'
AS $$
DECLARE
  v_score INTEGER := 0;
  v_user_a RECORD;
  v_user_b RECORD;
  v_prefs_a RECORD;
  v_prefs_b RECORD;
  v_physical_grade TEXT;
  v_style_grade TEXT;
  v_physical_details JSONB := '{}'::JSONB;
  v_style_details JSONB := '{}'::JSONB;
  v_training_type_overlap INT;
BEGIN
  -- Fetch member profiles from public schema
  SELECT * INTO v_user_a
  FROM public.member_profiles
  WHERE user_id = user_a_id;

  SELECT * INTO v_user_b
  FROM public.member_profiles
  WHERE user_id = user_b_id;

  -- Return null if either user not found
  IF v_user_a IS NULL OR v_user_b IS NULL THEN
    RETURN jsonb_build_object(
      'error', 'User profile not found',
      'overallScore', 0
    );
  END IF;

  -- Fetch training preferences
  SELECT * INTO v_prefs_a
  FROM jabos_mobile.training_preferences
  WHERE user_id = user_a_id;

  SELECT * INTO v_prefs_b
  FROM jabos_mobile.training_preferences
  WHERE user_id = user_b_id;

  -- ===================================================================
  -- PHYSICAL COMPATIBILITY (40 points) - Replaces Astrological Score
  -- Based on weight class proximity and experience level match
  -- ===================================================================

  -- Weight class proximity (25 points max)
  IF v_user_a.weight_class = v_user_b.weight_class THEN
    v_score := v_score + 25;
    v_physical_details := v_physical_details || jsonb_build_object(
      'weight_class_match', 'exact',
      'weight_class_a', v_user_a.weight_class,
      'weight_class_b', v_user_b.weight_class
    );
  ELSIF jabos_mobile.is_adjacent_weight_class(v_user_a.weight_class, v_user_b.weight_class) THEN
    v_score := v_score + 15;
    v_physical_details := v_physical_details || jsonb_build_object(
      'weight_class_match', 'adjacent',
      'weight_class_a', v_user_a.weight_class,
      'weight_class_b', v_user_b.weight_class
    );
  ELSE
    v_physical_details := v_physical_details || jsonb_build_object(
      'weight_class_match', 'different',
      'weight_class_a', v_user_a.weight_class,
      'weight_class_b', v_user_b.weight_class
    );
  END IF;

  -- Experience level match (15 points max)
  IF v_user_a.experience_level = v_user_b.experience_level THEN
    v_score := v_score + 15;
    v_physical_details := v_physical_details || jsonb_build_object(
      'experience_match', 'exact',
      'experience_a', v_user_a.experience_level,
      'experience_b', v_user_b.experience_level
    );
  ELSIF jabos_mobile.is_compatible_experience(v_user_a.experience_level, v_user_b.experience_level) THEN
    v_score := v_score + 10;
    v_physical_details := v_physical_details || jsonb_build_object(
      'experience_match', 'compatible',
      'experience_a', v_user_a.experience_level,
      'experience_b', v_user_b.experience_level
    );
  ELSE
    v_physical_details := v_physical_details || jsonb_build_object(
      'experience_match', 'incompatible',
      'experience_a', v_user_a.experience_level,
      'experience_b', v_user_b.experience_level
    );
  END IF;

  -- ===================================================================
  -- TRAINING STYLE COMPATIBILITY (30 points) - Replaces Questionnaire Score
  -- Based on training type preferences and intensity match
  -- ===================================================================

  -- Training type overlap (20 points max)
  -- This is the CORE MATCHING FEATURE like Stellr's activity preferences
  IF v_prefs_a.preferred_training_types IS NOT NULL
     AND v_prefs_b.preferred_training_types IS NOT NULL THEN

    SELECT COUNT(*) INTO v_training_type_overlap
    FROM UNNEST(v_prefs_a.preferred_training_types) AS type
    WHERE type = ANY(v_prefs_b.preferred_training_types);

    -- Award 5 points per overlapping training type (max 20)
    v_score := v_score + LEAST(v_training_type_overlap * 5, 20);

    v_style_details := v_style_details || jsonb_build_object(
      'training_type_overlap', v_training_type_overlap,
      'types_a', v_prefs_a.preferred_training_types,
      'types_b', v_prefs_b.preferred_training_types
    );
  ELSE
    v_style_details := v_style_details || jsonb_build_object(
      'training_type_overlap', 0,
      'note', 'One or both users have not set training preferences'
    );
  END IF;

  -- Intensity preference match (10 points max)
  IF v_prefs_a.intensity_preference IS NOT NULL
     AND v_prefs_b.intensity_preference IS NOT NULL THEN

    IF v_prefs_a.intensity_preference = v_prefs_b.intensity_preference THEN
      v_score := v_score + 10;
      v_style_details := v_style_details || jsonb_build_object(
        'intensity_match', true,
        'intensity_a', v_prefs_a.intensity_preference,
        'intensity_b', v_prefs_b.intensity_preference
      );
    ELSE
      v_style_details := v_style_details || jsonb_build_object(
        'intensity_match', false,
        'intensity_a', v_prefs_a.intensity_preference,
        'intensity_b', v_prefs_b.intensity_preference
      );
    END IF;
  END IF;

  -- ===================================================================
  -- AVAILABILITY & LOCATION (30 points) - Replaces Preference Score
  -- ===================================================================

  -- Same organization bonus (20 points)
  IF v_user_a.organization_id = v_user_b.organization_id THEN
    v_score := v_score + 20;
  END IF;

  -- Availability overlap (10 points) - simplified for MVP
  -- TODO: Implement actual availability comparison when availability system is built
  IF v_prefs_a.availability IS NOT NULL
     AND v_prefs_b.availability IS NOT NULL THEN
    v_score := v_score + 5;
  END IF;

  -- ===================================================================
  -- CALCULATE GRADES (A/B/C) - Same system as Stellr
  -- ===================================================================

  -- Physical grade (based on first 40 points possible)
  IF v_score >= 35 THEN
    v_physical_grade := 'A';
  ELSIF v_score >= 25 THEN
    v_physical_grade := 'B';
  ELSE
    v_physical_grade := 'C';
  END IF;

  -- Style grade (based on total score - includes training style + location)
  IF v_score >= 70 THEN
    v_style_grade := 'A';
  ELSIF v_score >= 50 THEN
    v_style_grade := 'B';
  ELSE
    v_style_grade := 'C';
  END IF;

  -- ===================================================================
  -- RETURN COMPATIBILITY RESULT
  -- Format matches Stellr's calculate_compatibility return structure
  -- ===================================================================
  RETURN jsonb_build_object(
    'EligibleByPreferences', true,
    'PhysicalGrade', v_physical_grade,
    'StyleGrade', v_style_grade,
    'overallScore', v_score,
    'MeetsScoreThreshold', v_score >= 50,
    'IsMatchRecommended', v_score >= 60,
    'physicalCompatibility', v_physical_details,
    'styleCompatibility', v_style_details,
    'sameOrganization', (v_user_a.organization_id = v_user_b.organization_id)
  );
END;
$$;

COMMENT ON FUNCTION jabos_mobile.calculate_training_compatibility IS
'Calculate compatibility between two training partners.
Scoring: Physical (40pts) + Training Style (30pts) + Location/Availability (30pts) = 100pts total.
Returns: Grades (A/B/C), scores, detailed compatibility breakdown.
Adapted from Stellr''s astrological compatibility algorithm.';

-- =============================================
-- Grant execute permissions
-- =============================================
GRANT EXECUTE ON FUNCTION jabos_mobile.is_adjacent_weight_class TO authenticated;
GRANT EXECUTE ON FUNCTION jabos_mobile.get_adjacent_weight_classes TO authenticated;
GRANT EXECUTE ON FUNCTION jabos_mobile.is_compatible_experience TO authenticated;
GRANT EXECUTE ON FUNCTION jabos_mobile.get_compatible_experience_levels TO authenticated;
GRANT EXECUTE ON FUNCTION jabos_mobile.calculate_training_compatibility TO authenticated;
