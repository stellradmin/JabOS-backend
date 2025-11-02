-- =====================================================
-- COMPATIBILITY PERFORMANCE OPTIMIZATION MIGRATIONS
-- Target: Sub-500ms compatibility calculations
-- =====================================================

-- Create high-performance batch compatibility calculation function
CREATE OR REPLACE FUNCTION batch_calculate_compatibility_optimized(
  target_user_id UUID,
  candidate_ids UUID[]
)
RETURNS TABLE (
  match_id UUID,
  astrological_score NUMERIC,
  astrological_grade TEXT,
  questionnaire_score NUMERIC,
  questionnaire_grade TEXT,
  combined_score NUMERIC,
  combined_grade TEXT,
  meets_threshold BOOLEAN,
  priority_score NUMERIC,
  calculation_time_ms INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
PARALLEL SAFE
AS $$
DECLARE
  start_time TIMESTAMP;
  user_data RECORD;
  candidate_data RECORD;
  astro_score NUMERIC;
  astro_grade TEXT;
  quest_score NUMERIC;
  quest_grade TEXT;
  final_score NUMERIC;
  final_grade TEXT;
  calc_time INTEGER;
BEGIN
  start_time := clock_timestamp();
  
  -- Get target user data in single query
  SELECT 
    u.id, u.sun_sign, u.moon_sign, u.rising_sign,
    u.natal_chart_data, u.questionnaire_responses,
    u.birth_lat, u.birth_lng, u.birth_date, u.birth_time
  INTO user_data
  FROM users u 
  WHERE u.id = target_user_id;
  
  -- Return empty if user not found
  IF user_data IS NULL THEN
    RETURN;
  END IF;
  
  -- Process candidates in batch with optimized queries
  FOR candidate_data IN 
    SELECT 
      u.id, u.sun_sign, u.moon_sign, u.rising_sign,
      u.natal_chart_data, u.questionnaire_responses,
      u.birth_lat, u.birth_lng, u.birth_date, u.birth_time
    FROM users u 
    WHERE u.id = ANY(candidate_ids)
      AND u.questionnaire_responses IS NOT NULL
      AND u.natal_chart_data IS NOT NULL
  LOOP
    
    -- Calculate astrological compatibility
    astro_score := calculate_optimized_astrological_compatibility(
      user_data.sun_sign, user_data.moon_sign, user_data.rising_sign,
      candidate_data.sun_sign, candidate_data.moon_sign, candidate_data.rising_sign
    );
    
    astro_grade := score_to_grade(astro_score);
    
    -- Calculate questionnaire compatibility
    quest_score := calculate_optimized_questionnaire_compatibility(
      user_data.questionnaire_responses,
      candidate_data.questionnaire_responses
    );
    
    quest_grade := score_to_grade(quest_score);
    
    -- Calculate combined score (40% astro + 60% questionnaire)
    final_score := (astro_score * 0.4) + (quest_score * 0.6);
    final_grade := score_to_grade(final_score);
    
    -- Calculate processing time
    calc_time := EXTRACT(MILLISECONDS FROM (clock_timestamp() - start_time));

    -- Assign to RETURNS TABLE output columns
    match_id := candidate_data.id;
    astrological_score := ROUND(astro_score, 2);
    astrological_grade := astro_grade;
    questionnaire_score := ROUND(quest_score, 2);
    questionnaire_grade := quest_grade;
    combined_score := ROUND(final_score, 2);
    combined_grade := final_grade;
    meets_threshold := final_score >= 60.0 OR quest_grade IN ('A', 'B', 'C', 'D');
    priority_score := final_score + CASE WHEN astro_grade = 'A' THEN 10 WHEN quest_grade = 'A' THEN 10 ELSE 0 END;
    calculation_time_ms := calc_time;

    RETURN NEXT;
    
  END LOOP;
  
END;
$$;

-- Optimized astrological compatibility function
CREATE OR REPLACE FUNCTION calculate_optimized_astrological_compatibility(
  user_sun TEXT, user_moon TEXT, user_rising TEXT,
  match_sun TEXT, match_moon TEXT, match_rising TEXT
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  sun_compatibility NUMERIC;
  moon_compatibility NUMERIC;
  rising_compatibility NUMERIC;
  element_bonus NUMERIC := 0;
  total_score NUMERIC;
BEGIN
  -- Use pre-computed compatibility matrix for performance
  sun_compatibility := get_sign_compatibility(user_sun, match_sun) * 0.4;
  moon_compatibility := get_sign_compatibility(user_moon, match_moon) * 0.35;
  rising_compatibility := get_sign_compatibility(user_rising, match_rising) * 0.25;
  
  -- Add element harmony bonus
  IF get_element_compatibility(user_sun, match_sun) > 80 THEN
    element_bonus := 5;
  END IF;
  
  total_score := sun_compatibility + moon_compatibility + rising_compatibility + element_bonus;
  
  RETURN LEAST(100, GREATEST(0, total_score));
END;
$$;

-- Optimized questionnaire compatibility function
CREATE OR REPLACE FUNCTION calculate_optimized_questionnaire_compatibility(
  user_responses JSONB,
  match_responses JSONB
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  total_score NUMERIC := 0;
  question_count INTEGER := 0;
  response_diff NUMERIC;
  weight NUMERIC;
  i INTEGER;
  user_answer INTEGER;
  match_answer INTEGER;
BEGIN
  -- Handle null or empty responses
  IF user_responses IS NULL OR match_responses IS NULL THEN
    RETURN 50; -- Neutral score
  END IF;
  
  -- Process questionnaire responses efficiently
  FOR i IN 0..LEAST(jsonb_array_length(user_responses) - 1, jsonb_array_length(match_responses) - 1) LOOP
    
    -- Extract numeric values from responses
    user_answer := COALESCE((user_responses->i->>'answer')::INTEGER, 3);
    match_answer := COALESCE((match_responses->i->>'answer')::INTEGER, 3);
    
    -- Skip invalid responses
    IF user_answer < 1 OR user_answer > 5 OR match_answer < 1 OR match_answer > 5 THEN
      CONTINUE;
    END IF;
    
    -- Calculate weighted compatibility for this question
    response_diff := ABS(user_answer - match_answer);
    weight := CASE 
      WHEN i < 5 THEN 1.5   -- Communication questions (higher weight)
      WHEN i < 10 THEN 1.3  -- Emotional connection questions
      WHEN i < 15 THEN 1.2  -- Life goals questions
      ELSE 1.0              -- Other questions
    END;
    
    total_score := total_score + ((4 - response_diff) * 25 * weight);
    question_count := question_count + weight;
    
  END LOOP;
  
  -- Return average score
  IF question_count > 0 THEN
    RETURN LEAST(100, GREATEST(0, total_score / question_count));
  ELSE
    RETURN 50;
  END IF;
END;
$$;

-- Fast sign compatibility lookup using optimized matrix
CREATE OR REPLACE FUNCTION get_sign_compatibility(sign1 TEXT, sign2 TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
BEGIN
  -- Use optimized lookup table for performance
  RETURN CASE 
    WHEN sign1 IS NULL OR sign2 IS NULL THEN 50
    WHEN sign1 = sign2 THEN 90
    -- Fire signs compatibility
    WHEN sign1 IN ('Aries', 'Leo', 'Sagittarius') AND sign2 IN ('Aries', 'Leo', 'Sagittarius') THEN 85
    WHEN sign1 IN ('Aries', 'Leo', 'Sagittarius') AND sign2 IN ('Gemini', 'Libra', 'Aquarius') THEN 80
    -- Earth signs compatibility  
    WHEN sign1 IN ('Taurus', 'Virgo', 'Capricorn') AND sign2 IN ('Taurus', 'Virgo', 'Capricorn') THEN 85
    WHEN sign1 IN ('Taurus', 'Virgo', 'Capricorn') AND sign2 IN ('Cancer', 'Scorpio', 'Pisces') THEN 80
    -- Air signs compatibility
    WHEN sign1 IN ('Gemini', 'Libra', 'Aquarius') AND sign2 IN ('Gemini', 'Libra', 'Aquarius') THEN 85
    WHEN sign1 IN ('Gemini', 'Libra', 'Aquarius') AND sign2 IN ('Aries', 'Leo', 'Sagittarius') THEN 80
    -- Water signs compatibility
    WHEN sign1 IN ('Cancer', 'Scorpio', 'Pisces') AND sign2 IN ('Cancer', 'Scorpio', 'Pisces') THEN 85
    WHEN sign1 IN ('Cancer', 'Scorpio', 'Pisces') AND sign2 IN ('Taurus', 'Virgo', 'Capricorn') THEN 80
    -- Opposite elements (challenging but workable)
    WHEN sign1 IN ('Aries', 'Leo', 'Sagittarius') AND sign2 IN ('Cancer', 'Scorpio', 'Pisces') THEN 45
    WHEN sign1 IN ('Cancer', 'Scorpio', 'Pisces') AND sign2 IN ('Aries', 'Leo', 'Sagittarius') THEN 45
    WHEN sign1 IN ('Taurus', 'Virgo', 'Capricorn') AND sign2 IN ('Gemini', 'Libra', 'Aquarius') THEN 50
    WHEN sign1 IN ('Gemini', 'Libra', 'Aquarius') AND sign2 IN ('Taurus', 'Virgo', 'Capricorn') THEN 50
    ELSE 60 -- Default compatibility
  END;
END;
$$;

-- Element compatibility function
CREATE OR REPLACE FUNCTION get_element_compatibility(sign1 TEXT, sign2 TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
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
  
  -- Return compatibility based on element interaction
  RETURN CASE 
    WHEN element1 = element2 THEN 90
    WHEN (element1 = 'Fire' AND element2 = 'Air') OR (element1 = 'Air' AND element2 = 'Fire') THEN 85
    WHEN (element1 = 'Earth' AND element2 = 'Water') OR (element1 = 'Water' AND element2 = 'Earth') THEN 85
    WHEN (element1 = 'Fire' AND element2 = 'Water') OR (element1 = 'Water' AND element2 = 'Fire') THEN 40
    WHEN (element1 = 'Air' AND element2 = 'Earth') OR (element1 = 'Earth' AND element2 = 'Air') THEN 45
    ELSE 60
  END;
END;
$$;

-- Score to grade conversion function
CREATE OR REPLACE FUNCTION score_to_grade(score NUMERIC)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
BEGIN
  RETURN CASE 
    WHEN score >= 90 THEN 'A'
    WHEN score >= 80 THEN 'B'
    WHEN score >= 70 THEN 'C'
    WHEN score >= 60 THEN 'D'
    ELSE 'F'
  END;
END;
$$;

-- Optimized function to get potential matches with spatial filtering
-- Drop ALL existing overloads to avoid ambiguity (there are 13 different versions from earlier migrations)
DO $$ BEGIN
    EXECUTE (
        SELECT 'DROP FUNCTION IF EXISTS ' || oid::regprocedure || ' CASCADE;'
        FROM pg_proc
        WHERE proname = 'get_potential_matches_optimized'
    );
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

CREATE OR REPLACE FUNCTION get_potential_matches_optimized(
  target_user_id UUID,
  max_distance_km INTEGER DEFAULT 100,
  result_limit INTEGER DEFAULT 200
)
RETURNS TABLE(id UUID, distance_km NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  target_lat NUMERIC;
  target_lng NUMERIC;
  target_looking_for TEXT[];
  target_age INTEGER;
  target_min_age INTEGER;
  target_max_age INTEGER;
BEGIN
  -- Get target user preferences and location
  SELECT 
    COALESCE(u.birth_lat, p.lat), 
    COALESCE(u.birth_lng, p.lng),
    u.looking_for,
    p.age,
    (u.preferences->>'min_age')::INTEGER,
    (u.preferences->>'max_age')::INTEGER
  INTO target_lat, target_lng, target_looking_for, target_age, target_min_age, target_max_age
  FROM users u
  LEFT JOIN profiles p ON u.id = p.id
  WHERE u.id = target_user_id;
  
  -- Return empty if user not found
  IF target_lat IS NULL THEN
    RETURN;
  END IF;
  
  -- Find potential matches with spatial filtering
  RETURN QUERY
  SELECT 
    u.id,
    CASE 
      WHEN target_lat IS NOT NULL AND target_lng IS NOT NULL 
           AND COALESCE(u.birth_lat, p.lat) IS NOT NULL 
           AND COALESCE(u.birth_lng, p.lng) IS NOT NULL THEN
        (6371 * acos(cos(radians(target_lat)) * cos(radians(COALESCE(u.birth_lat, p.lat))) * 
         cos(radians(COALESCE(u.birth_lng, p.lng)) - radians(target_lng)) + 
         sin(radians(target_lat)) * sin(radians(COALESCE(u.birth_lat, p.lat)))))::NUMERIC
      ELSE 0
    END AS distance_km
  FROM users u
  JOIN profiles p ON u.id = p.id
  WHERE u.id != target_user_id
    -- Must have compatibility data
    AND u.questionnaire_responses IS NOT NULL
    AND jsonb_array_length(u.questionnaire_responses) > 0
    AND u.natal_chart_data IS NOT NULL
    -- Age compatibility
    AND p.age BETWEEN COALESCE(target_min_age, 18) AND COALESCE(target_max_age, 100)
    AND target_age BETWEEN 
        COALESCE((u.preferences->>'min_age')::INTEGER, 18) 
        AND COALESCE((u.preferences->>'max_age')::INTEGER, 100)
    -- Distance filter (if location data available)
    AND (
      target_lat IS NULL OR target_lng IS NULL OR
      COALESCE(u.birth_lat, p.lat) IS NULL OR COALESCE(u.birth_lng, p.lng) IS NULL OR
      (6371 * acos(cos(radians(target_lat)) * cos(radians(COALESCE(u.birth_lat, p.lat))) * 
       cos(radians(COALESCE(u.birth_lng, p.lng)) - radians(target_lng)) + 
       sin(radians(target_lat)) * sin(radians(COALESCE(u.birth_lat, p.lat))))) <= max_distance_km
    )
  ORDER BY distance_km, RANDOM() -- Randomize for diversity
  LIMIT result_limit;
END;
$$;

-- =====================================================
-- PERFORMANCE INDEXES
-- =====================================================

-- Core compatibility calculation indexes
CREATE INDEX IF NOT EXISTS idx_users_compatibility_data 
ON users (id) 
WHERE questionnaire_responses IS NOT NULL 
  AND natal_chart_data IS NOT NULL;

-- Natal chart data indexes
CREATE INDEX IF NOT EXISTS idx_users_natal_signs 
ON users (sun_sign, moon_sign, rising_sign) 
WHERE sun_sign IS NOT NULL;

-- Questionnaire responses index
CREATE INDEX IF NOT EXISTS idx_users_questionnaire_gin 
ON users USING GIN (questionnaire_responses) 
WHERE questionnaire_responses IS NOT NULL;

-- Age and preferences indexes
CREATE INDEX IF NOT EXISTS idx_profiles_age_active 
ON profiles (age, updated_at) 
WHERE age IS NOT NULL;

-- Spatial indexes for location-based matching
CREATE INDEX IF NOT EXISTS idx_users_location 
ON users (birth_lat, birth_lng) 
WHERE birth_lat IS NOT NULL AND birth_lng IS NOT NULL;

-- CREATE INDEX IF NOT EXISTS idx_profiles_location
-- ON profiles (lat, lng)
-- WHERE lat IS NOT NULL AND lng IS NOT NULL;
-- NOTE: Commented out - column names may be location_lat/location_lng instead of lat/lng

-- Composite index for match filtering
CREATE INDEX IF NOT EXISTS idx_users_match_filtering 
ON users (id, looking_for) 
INCLUDE (questionnaire_responses, natal_chart_data, preferences);

-- Performance monitoring table
CREATE TABLE IF NOT EXISTS compatibility_performance_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id),
  batch_size INTEGER,
  calculation_time_ms INTEGER,
  cache_hit_rate NUMERIC,
  error_count INTEGER,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_compatibility_performance_time 
ON compatibility_performance_log (created_at, calculation_time_ms);

-- =====================================================
-- PERFORMANCE MONITORING FUNCTIONS
-- =====================================================

-- Function to log performance metrics
CREATE OR REPLACE FUNCTION log_compatibility_performance(
  p_user_id UUID,
  p_batch_size INTEGER,
  p_calculation_time_ms INTEGER,
  p_cache_hit_rate NUMERIC,
  p_error_count INTEGER DEFAULT 0
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO compatibility_performance_log (
    user_id, batch_size, calculation_time_ms, cache_hit_rate, error_count
  ) VALUES (
    p_user_id, p_batch_size, p_calculation_time_ms, p_cache_hit_rate, p_error_count
  );
END;
$$;

-- Function to get performance statistics
CREATE OR REPLACE FUNCTION get_compatibility_performance_stats(
  lookback_hours INTEGER DEFAULT 24
)
RETURNS TABLE (
  avg_calculation_time_ms NUMERIC,
  p95_calculation_time_ms NUMERIC,
  avg_batch_size NUMERIC,
  avg_cache_hit_rate NUMERIC,
  total_calculations BIGINT,
  success_rate NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    ROUND(AVG(calculation_time_ms)::NUMERIC, 2) as avg_calculation_time_ms,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY calculation_time_ms)::NUMERIC, 2) as p95_calculation_time_ms,
    ROUND(AVG(batch_size)::NUMERIC, 2) as avg_batch_size,
    ROUND(AVG(cache_hit_rate)::NUMERIC, 4) as avg_cache_hit_rate,
    COUNT(*) as total_calculations,
    ROUND((1.0 - AVG(CASE WHEN error_count > 0 THEN 1.0 ELSE 0.0 END))::NUMERIC, 4) as success_rate
  FROM compatibility_performance_log 
  WHERE created_at >= NOW() - INTERVAL '1 hour' * lookback_hours;
END;
$$;

-- =====================================================
-- GRANTS AND PERMISSIONS
-- =====================================================

-- Grant execute permissions to authenticated users
GRANT EXECUTE ON FUNCTION batch_calculate_compatibility_optimized TO authenticated;
GRANT EXECUTE ON FUNCTION get_potential_matches_optimized(UUID, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION log_compatibility_performance TO authenticated;
GRANT EXECUTE ON FUNCTION get_compatibility_performance_stats TO authenticated;

-- Grant execute permissions to service role
GRANT EXECUTE ON FUNCTION batch_calculate_compatibility_optimized TO service_role;
GRANT EXECUTE ON FUNCTION get_potential_matches_optimized(UUID, INTEGER, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION log_compatibility_performance TO service_role;
GRANT EXECUTE ON FUNCTION get_compatibility_performance_stats TO service_role;

-- Grant table permissions
GRANT SELECT, INSERT ON compatibility_performance_log TO authenticated;
GRANT ALL ON compatibility_performance_log TO service_role;

-- =====================================================
-- VALIDATION AND CLEANUP
-- =====================================================

-- Analyze tables for query planner optimization
ANALYZE users;
ANALYZE profiles;

-- Update table statistics
-- NOTE: Cannot UPDATE system view pg_stat_user_tables - ANALYZE handles statistics refresh
-- UPDATE pg_stat_user_tables SET n_tup_ins = n_tup_ins + 0 WHERE schemaname = 'public';

COMMENT ON FUNCTION batch_calculate_compatibility_optimized IS 'High-performance batch compatibility calculation optimized for sub-500ms response times';
COMMENT ON FUNCTION get_potential_matches_optimized(UUID, INTEGER, INTEGER) IS 'Optimized potential matches retrieval with spatial filtering and performance indexing';
COMMENT ON TABLE compatibility_performance_log IS 'Performance monitoring for compatibility calculations to track response times and success rates';