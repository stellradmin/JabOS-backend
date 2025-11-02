-- Create the missing batch_calculate_compatibility RPC function
-- This is critical for preventing runtime crashes in the matching engine

-- Drop all existing functions that might have different signatures
DROP FUNCTION IF EXISTS batch_calculate_compatibility CASCADE;
DROP FUNCTION IF EXISTS calculate_natal_compatibility CASCADE;
DROP FUNCTION IF EXISTS calculate_sign_compatibility CASCADE;
DROP FUNCTION IF EXISTS calculate_element_harmony CASCADE;
DROP FUNCTION IF EXISTS calculate_modality_balance CASCADE;
DROP FUNCTION IF EXISTS calculate_questionnaire_compatibility CASCADE;
DROP FUNCTION IF EXISTS calculate_answer_similarity CASCADE;
DROP FUNCTION IF EXISTS calculate_shared_values CASCADE;
DROP FUNCTION IF EXISTS calculate_lifestyle_match CASCADE;
DROP FUNCTION IF EXISTS calculate_communication_compatibility CASCADE;

CREATE OR REPLACE FUNCTION batch_calculate_compatibility(
  user_id UUID,
  potential_match_ids UUID[]
)
RETURNS TABLE (
  match_id UUID,
  natal_score NUMERIC,
  questionnaire_score NUMERIC,
  combined_score NUMERIC,
  compatibility_factors JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  user_profile RECORD;
  user_natal RECORD;
  user_questionnaire JSONB;
BEGIN
  -- Get current user's profile data
  SELECT 
    p.*,
    u.birth_date,
    u.birth_time,
    u.birth_city,
    u.birth_lat,
    u.birth_lng,
    u.sun_sign,
    u.moon_sign,
    u.rising_sign,
    u.questionnaire_responses
  INTO user_profile
  FROM profiles p
  JOIN users u ON p.id = u.id
  WHERE p.id = user_id;

  -- Return empty if user not found
  IF user_profile IS NULL THEN
    RETURN;
  END IF;

  -- Store user's natal data
  user_natal := ROW(
    user_profile.sun_sign,
    user_profile.moon_sign,
    user_profile.rising_sign,
    user_profile.birth_date,
    user_profile.birth_time,
    user_profile.birth_lat,
    user_profile.birth_lng
  );
  
  user_questionnaire := COALESCE(user_profile.questionnaire_responses, '{}'::JSONB);

  -- Calculate compatibility for each potential match
  RETURN QUERY
  WITH match_data AS (
    SELECT 
      p.id,
      p.name,
      u.birth_date,
      u.birth_time,
      u.birth_city,
      u.birth_lat,
      u.birth_lng,
      u.sun_sign,
      u.moon_sign,
      u.rising_sign,
      u.questionnaire_responses
    FROM profiles p
    JOIN users u ON p.id = u.id
    WHERE p.id = ANY(potential_match_ids)
  ),
  natal_calculations AS (
    SELECT 
      md.id,
      -- Calculate natal compatibility score
      CASE 
        WHEN md.sun_sign IS NOT NULL AND user_natal.sun_sign IS NOT NULL THEN
          calculate_natal_compatibility(
            user_natal.sun_sign,
            user_natal.moon_sign,
            user_natal.rising_sign,
            md.sun_sign,
            md.moon_sign,
            md.rising_sign
          )
        ELSE 0
      END AS natal_score,
      -- Generate natal compatibility factors
      JSONB_BUILD_OBJECT(
        'sun_compatibility', calculate_sign_compatibility(user_natal.sun_sign, md.sun_sign),
        'moon_compatibility', calculate_sign_compatibility(user_natal.moon_sign, md.moon_sign),
        'rising_compatibility', calculate_sign_compatibility(user_natal.rising_sign, md.rising_sign),
        'element_harmony', calculate_element_harmony(user_natal.sun_sign, md.sun_sign),
        'modality_balance', calculate_modality_balance(user_natal.sun_sign, md.sun_sign)
      ) AS natal_factors
    FROM match_data md
  ),
  questionnaire_calculations AS (
    SELECT 
      md.id,
      -- Calculate questionnaire compatibility score
      CASE 
        WHEN md.questionnaire_responses IS NOT NULL 
          AND jsonb_array_length(COALESCE(md.questionnaire_responses, '[]'::JSONB)) > 0 THEN
          calculate_questionnaire_compatibility(
            user_questionnaire,
            md.questionnaire_responses
          )
        ELSE 0
      END AS questionnaire_score,
      -- Generate questionnaire compatibility factors
      JSONB_BUILD_OBJECT(
        'shared_values', calculate_shared_values(user_questionnaire, md.questionnaire_responses),
        'lifestyle_match', calculate_lifestyle_match(user_questionnaire, md.questionnaire_responses),
        'communication_style', calculate_communication_compatibility(user_questionnaire, md.questionnaire_responses),
        'relationship_goals', calculate_relationship_goals_match(user_questionnaire, md.questionnaire_responses)
      ) AS questionnaire_factors
    FROM match_data md
  )
  SELECT 
    nc.id AS match_id,
    ROUND(nc.natal_score::NUMERIC, 2) AS natal_score,
    ROUND(qc.questionnaire_score::NUMERIC, 2) AS questionnaire_score,
    ROUND(((nc.natal_score * 0.4) + (qc.questionnaire_score * 0.6))::NUMERIC, 2) AS combined_score,
    JSONB_BUILD_OBJECT(
      'natal', nc.natal_factors,
      'questionnaire', qc.questionnaire_factors,
      'calculated_at', NOW(),
      'algorithm_version', '2.0'
    ) AS compatibility_factors
  FROM natal_calculations nc
  JOIN questionnaire_calculations qc ON nc.id = qc.id
  ORDER BY combined_score DESC;
END;
$$;

-- Helper function: Calculate natal compatibility between two users
CREATE OR REPLACE FUNCTION calculate_natal_compatibility(
  user_sun TEXT,
  user_moon TEXT,
  user_rising TEXT,
  match_sun TEXT,
  match_moon TEXT,
  match_rising TEXT
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  sun_score NUMERIC;
  moon_score NUMERIC;
  rising_score NUMERIC;
  total_score NUMERIC;
BEGIN
  -- Calculate individual compatibility scores
  sun_score := calculate_sign_compatibility(user_sun, match_sun) * 0.4;
  moon_score := calculate_sign_compatibility(user_moon, match_moon) * 0.35;
  rising_score := calculate_sign_compatibility(user_rising, match_rising) * 0.25;
  
  -- Add bonus for element harmony
  total_score := sun_score + moon_score + rising_score;
  
  -- Add synastry bonus
  IF calculate_element_harmony(user_sun, match_sun) > 70 THEN
    total_score := total_score * 1.1;
  END IF;
  
  -- Ensure score is between 0 and 100
  RETURN LEAST(100, GREATEST(0, total_score));
END;
$$;

-- Helper function: Calculate sign compatibility
CREATE OR REPLACE FUNCTION calculate_sign_compatibility(sign1 TEXT, sign2 TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  compatibility_matrix JSONB := '{
    "Aries": {"Aries": 85, "Taurus": 45, "Gemini": 90, "Cancer": 50, "Leo": 95, "Virgo": 55, "Libra": 75, "Scorpio": 60, "Sagittarius": 95, "Capricorn": 50, "Aquarius": 85, "Pisces": 60},
    "Taurus": {"Aries": 45, "Taurus": 90, "Gemini": 50, "Cancer": 85, "Leo": 55, "Virgo": 95, "Libra": 60, "Scorpio": 75, "Sagittarius": 45, "Capricorn": 90, "Aquarius": 50, "Pisces": 85},
    "Gemini": {"Aries": 90, "Taurus": 50, "Gemini": 85, "Cancer": 55, "Leo": 85, "Virgo": 60, "Libra": 95, "Scorpio": 45, "Sagittarius": 75, "Capricorn": 50, "Aquarius": 95, "Pisces": 55},
    "Cancer": {"Aries": 50, "Taurus": 85, "Gemini": 55, "Cancer": 90, "Leo": 60, "Virgo": 75, "Libra": 50, "Scorpio": 95, "Sagittarius": 45, "Capricorn": 75, "Aquarius": 55, "Pisces": 95},
    "Leo": {"Aries": 95, "Taurus": 55, "Gemini": 85, "Cancer": 60, "Leo": 85, "Virgo": 50, "Libra": 85, "Scorpio": 55, "Sagittarius": 95, "Capricorn": 45, "Aquarius": 75, "Pisces": 60},
    "Virgo": {"Aries": 55, "Taurus": 95, "Gemini": 60, "Cancer": 75, "Leo": 50, "Virgo": 90, "Libra": 55, "Scorpio": 85, "Sagittarius": 50, "Capricorn": 95, "Aquarius": 55, "Pisces": 75},
    "Libra": {"Aries": 75, "Taurus": 60, "Gemini": 95, "Cancer": 50, "Leo": 85, "Virgo": 55, "Libra": 85, "Scorpio": 60, "Sagittarius": 85, "Capricorn": 55, "Aquarius": 95, "Pisces": 60},
    "Scorpio": {"Aries": 60, "Taurus": 75, "Gemini": 45, "Cancer": 95, "Leo": 55, "Virgo": 85, "Libra": 60, "Scorpio": 90, "Sagittarius": 55, "Capricorn": 85, "Aquarius": 60, "Pisces": 95},
    "Sagittarius": {"Aries": 95, "Taurus": 45, "Gemini": 75, "Cancer": 45, "Leo": 95, "Virgo": 50, "Libra": 85, "Scorpio": 55, "Sagittarius": 85, "Capricorn": 50, "Aquarius": 85, "Pisces": 55},
    "Capricorn": {"Aries": 50, "Taurus": 90, "Gemini": 50, "Cancer": 75, "Leo": 45, "Virgo": 95, "Libra": 55, "Scorpio": 85, "Sagittarius": 50, "Capricorn": 90, "Aquarius": 60, "Pisces": 85},
    "Aquarius": {"Aries": 85, "Taurus": 50, "Gemini": 95, "Cancer": 55, "Leo": 75, "Virgo": 55, "Libra": 95, "Scorpio": 60, "Sagittarius": 85, "Capricorn": 60, "Aquarius": 85, "Pisces": 60},
    "Pisces": {"Aries": 60, "Taurus": 85, "Gemini": 55, "Cancer": 95, "Leo": 60, "Virgo": 75, "Libra": 60, "Scorpio": 95, "Sagittarius": 55, "Capricorn": 85, "Aquarius": 60, "Pisces": 90}
  }'::JSONB;
BEGIN
  IF sign1 IS NULL OR sign2 IS NULL THEN
    RETURN 50; -- Default neutral score
  END IF;
  
  RETURN COALESCE((compatibility_matrix->sign1->sign2)::NUMERIC, 50);
END;
$$;

-- Helper function: Calculate element harmony
CREATE OR REPLACE FUNCTION calculate_element_harmony(sign1 TEXT, sign2 TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  element1 TEXT;
  element2 TEXT;
BEGIN
  -- Determine elements
  element1 := CASE 
    WHEN sign1 IN ('Aries', 'Leo', 'Sagittarius') THEN 'Fire'
    WHEN sign1 IN ('Taurus', 'Virgo', 'Capricorn') THEN 'Earth'
    WHEN sign1 IN ('Gemini', 'Libra', 'Aquarius') THEN 'Air'
    WHEN sign1 IN ('Cancer', 'Scorpio', 'Pisces') THEN 'Water'
    ELSE 'Unknown'
  END;
  
  element2 := CASE 
    WHEN sign2 IN ('Aries', 'Leo', 'Sagittarius') THEN 'Fire'
    WHEN sign2 IN ('Taurus', 'Virgo', 'Capricorn') THEN 'Earth'
    WHEN sign2 IN ('Gemini', 'Libra', 'Aquarius') THEN 'Air'
    WHEN sign2 IN ('Cancer', 'Scorpio', 'Pisces') THEN 'Water'
    ELSE 'Unknown'
  END;
  
  -- Calculate harmony
  IF element1 = element2 THEN
    RETURN 90;
  ELSIF (element1 = 'Fire' AND element2 = 'Air') OR (element1 = 'Air' AND element2 = 'Fire') THEN
    RETURN 85;
  ELSIF (element1 = 'Earth' AND element2 = 'Water') OR (element1 = 'Water' AND element2 = 'Earth') THEN
    RETURN 85;
  ELSIF (element1 = 'Fire' AND element2 = 'Water') OR (element1 = 'Water' AND element2 = 'Fire') THEN
    RETURN 40;
  ELSIF (element1 = 'Air' AND element2 = 'Earth') OR (element1 = 'Earth' AND element2 = 'Air') THEN
    RETURN 45;
  ELSE
    RETURN 60;
  END IF;
END;
$$;

-- Helper function: Calculate modality balance
CREATE OR REPLACE FUNCTION calculate_modality_balance(sign1 TEXT, sign2 TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  modality1 TEXT;
  modality2 TEXT;
BEGIN
  -- Determine modalities
  modality1 := CASE 
    WHEN sign1 IN ('Aries', 'Cancer', 'Libra', 'Capricorn') THEN 'Cardinal'
    WHEN sign1 IN ('Taurus', 'Leo', 'Scorpio', 'Aquarius') THEN 'Fixed'
    WHEN sign1 IN ('Gemini', 'Virgo', 'Sagittarius', 'Pisces') THEN 'Mutable'
    ELSE 'Unknown'
  END;
  
  modality2 := CASE 
    WHEN sign2 IN ('Aries', 'Cancer', 'Libra', 'Capricorn') THEN 'Cardinal'
    WHEN sign2 IN ('Taurus', 'Leo', 'Scorpio', 'Aquarius') THEN 'Fixed'
    WHEN sign2 IN ('Gemini', 'Virgo', 'Sagittarius', 'Pisces') THEN 'Mutable'
    ELSE 'Unknown'
  END;
  
  -- Calculate balance
  IF modality1 = modality2 THEN
    RETURN 70; -- Same modality can work but may lack balance
  ELSIF (modality1 = 'Cardinal' AND modality2 = 'Fixed') OR (modality1 = 'Fixed' AND modality2 = 'Cardinal') THEN
    RETURN 80; -- Good balance of initiative and stability
  ELSIF (modality1 = 'Cardinal' AND modality2 = 'Mutable') OR (modality1 = 'Mutable' AND modality2 = 'Cardinal') THEN
    RETURN 85; -- Great balance of leadership and adaptability
  ELSIF (modality1 = 'Fixed' AND modality2 = 'Mutable') OR (modality1 = 'Mutable' AND modality2 = 'Fixed') THEN
    RETURN 75; -- Balance of stability and flexibility
  ELSE
    RETURN 60;
  END IF;
END;
$$;

-- Helper function: Calculate questionnaire compatibility
CREATE OR REPLACE FUNCTION calculate_questionnaire_compatibility(
  user_responses JSONB,
  match_responses JSONB
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  total_score NUMERIC := 0;
  question_count INTEGER := 0;
  user_answer TEXT;
  match_answer TEXT;
  question_weight NUMERIC;
  compatibility_score NUMERIC;
BEGIN
  -- If either has no responses, return 0
  IF user_responses IS NULL OR match_responses IS NULL OR 
     jsonb_array_length(COALESCE(user_responses, '[]'::JSONB)) = 0 OR
     jsonb_array_length(COALESCE(match_responses, '[]'::JSONB)) = 0 THEN
    RETURN 0;
  END IF;
  
  -- Calculate compatibility for each question
  FOR i IN 0..LEAST(jsonb_array_length(user_responses) - 1, jsonb_array_length(match_responses) - 1) LOOP
    user_answer := user_responses->i->>'answer';
    match_answer := match_responses->i->>'answer';
    
    -- Skip if either answer is null
    CONTINUE WHEN user_answer IS NULL OR match_answer IS NULL;
    
    -- Determine question weight based on category
    question_weight := CASE (user_responses->i->>'category')
      WHEN 'values' THEN 1.5
      WHEN 'lifestyle' THEN 1.2
      WHEN 'personality' THEN 1.0
      WHEN 'preferences' THEN 0.8
      ELSE 1.0
    END;
    
    -- Calculate compatibility for this question
    IF user_answer = match_answer THEN
      compatibility_score := 100;
    ELSIF calculate_answer_similarity(user_answer, match_answer) > 0.7 THEN
      compatibility_score := 80;
    ELSIF calculate_answer_similarity(user_answer, match_answer) > 0.4 THEN
      compatibility_score := 60;
    ELSE
      compatibility_score := 30;
    END IF;
    
    total_score := total_score + (compatibility_score * question_weight);
    question_count := question_count + question_weight;
  END LOOP;
  
  -- Return average score
  IF question_count > 0 THEN
    RETURN LEAST(100, total_score / question_count);
  ELSE
    RETURN 0;
  END IF;
END;
$$;

-- Helper function: Calculate answer similarity
CREATE OR REPLACE FUNCTION calculate_answer_similarity(answer1 TEXT, answer2 TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  -- Simple similarity calculation
  -- In production, this could use more sophisticated NLP techniques
  IF answer1 = answer2 THEN
    RETURN 1.0;
  ELSIF LENGTH(answer1) > 0 AND LENGTH(answer2) > 0 THEN
    -- Basic text similarity
    RETURN 1.0 - (levenshtein(LOWER(answer1), LOWER(answer2))::NUMERIC / GREATEST(LENGTH(answer1), LENGTH(answer2)));
  ELSE
    RETURN 0;
  END IF;
END;
$$;

-- Helper functions for questionnaire factors
CREATE OR REPLACE FUNCTION calculate_shared_values(user_responses JSONB, match_responses JSONB)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  -- Calculate shared values based on value-related questions
  -- This is a simplified implementation
  RETURN calculate_questionnaire_category_match(user_responses, match_responses, 'values');
END;
$$;

CREATE OR REPLACE FUNCTION calculate_lifestyle_match(user_responses JSONB, match_responses JSONB)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN calculate_questionnaire_category_match(user_responses, match_responses, 'lifestyle');
END;
$$;

CREATE OR REPLACE FUNCTION calculate_communication_compatibility(user_responses JSONB, match_responses JSONB)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN calculate_questionnaire_category_match(user_responses, match_responses, 'communication');
END;
$$;

CREATE OR REPLACE FUNCTION calculate_relationship_goals_match(user_responses JSONB, match_responses JSONB)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN calculate_questionnaire_category_match(user_responses, match_responses, 'goals');
END;
$$;

-- Generic helper for category matching
CREATE OR REPLACE FUNCTION calculate_questionnaire_category_match(
  user_responses JSONB,
  match_responses JSONB,
  category TEXT
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  category_score NUMERIC := 0;
  category_count INTEGER := 0;
BEGIN
  IF user_responses IS NULL OR match_responses IS NULL THEN
    RETURN 50; -- Default neutral score
  END IF;
  
  -- Calculate match for specific category
  FOR i IN 0..LEAST(jsonb_array_length(user_responses) - 1, jsonb_array_length(match_responses) - 1) LOOP
    IF (user_responses->i->>'category') = category AND (match_responses->i->>'category') = category THEN
      IF (user_responses->i->>'answer') = (match_responses->i->>'answer') THEN
        category_score := category_score + 100;
      ELSE
        category_score := category_score + 40;
      END IF;
      category_count := category_count + 1;
    END IF;
  END LOOP;
  
  IF category_count > 0 THEN
    RETURN category_score / category_count;
  ELSE
    RETURN 60; -- Default if no questions in category
  END IF;
END;
$$;

-- Add levenshtein function if not exists (for text similarity)
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION batch_calculate_compatibility TO authenticated;
GRANT EXECUTE ON FUNCTION batch_calculate_compatibility TO service_role;

-- Add index for performance
CREATE INDEX IF NOT EXISTS idx_users_natal_data ON users(sun_sign, moon_sign, rising_sign);
CREATE INDEX IF NOT EXISTS idx_users_questionnaire ON users USING GIN (questionnaire_responses);

COMMENT ON FUNCTION batch_calculate_compatibility IS 'Calculate compatibility scores for multiple potential matches including both natal and questionnaire compatibility';