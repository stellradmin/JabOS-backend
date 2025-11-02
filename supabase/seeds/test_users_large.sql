-- ==================================================================================
-- LARGE TEST DATA SEED - 1000 PERFORMANCE TEST USERS
-- ==================================================================================
-- Purpose: Generate 1000 realistic test users for performance testing
-- Usage: Run after test_users_small.sql for performance tests
-- Distribution:
--   - Ages: Normal distribution (18-65, peak at 25-35)
--   - Zodiac: Equal distribution (~83 per sign)
--   - Gender: 48% Male, 48% Female, 4% Non-binary
--   - Looking for: Realistic combinations
--   - Locations: 10 major cities
--   - Activities: Random realistic combinations
--   - Completeness: 80% complete, 20% edge cases
-- ==================================================================================

BEGIN;

RAISE NOTICE '==================================================================================';
RAISE NOTICE 'SEEDING LARGE TEST DATA - 1000 PERFORMANCE USERS';
RAISE NOTICE 'This may take 30-60 seconds...';
RAISE NOTICE '==================================================================================';
RAISE NOTICE '';

-- ============================================================================
-- HELPER: City Coordinates
-- ============================================================================
CREATE TEMP TABLE IF NOT EXISTS temp_cities (
    id INTEGER,
    name TEXT,
    lat NUMERIC,
    lng NUMERIC
);

INSERT INTO temp_cities (id, name, lat, lng) VALUES
    (1, 'San Francisco', 37.7749, -122.4194),
    (2, 'Los Angeles', 34.0522, -118.2437),
    (3, 'New York', 40.7128, -74.0060),
    (4, 'Chicago', 41.8781, -87.6298),
    (5, 'Miami', 25.7617, -80.1918),
    (6, 'Seattle', 47.6062, -122.3321),
    (7, 'Denver', 39.7392, -104.9903),
    (8, 'Austin', 30.2672, -97.7431),
    (9, 'Boston', 42.3601, -71.0589),
    (10, 'Portland', 45.5152, -122.6784);

-- ============================================================================
-- HELPER: Zodiac Signs
-- ============================================================================
CREATE TEMP TABLE IF NOT EXISTS temp_zodiac_signs (
    id INTEGER,
    sign TEXT
);

INSERT INTO temp_zodiac_signs (id, sign) VALUES
    (1, 'Aries'), (2, 'Taurus'), (3, 'Gemini'), (4, 'Cancer'),
    (5, 'Leo'), (6, 'Virgo'), (7, 'Libra'), (8, 'Scorpio'),
    (9, 'Sagittarius'), (10, 'Capricorn'), (11, 'Aquarius'), (12, 'Pisces');

-- ============================================================================
-- HELPER: Activity Types
-- ============================================================================
CREATE TEMP TABLE IF NOT EXISTS temp_activities (
    id INTEGER,
    activity TEXT
);

INSERT INTO temp_activities (id, activity) VALUES
    (1, 'Adventure'), (2, 'Dining'), (3, 'Cultural'),
    (4, 'Nightlife'), (5, 'Sports'), (6, 'Relaxation');

-- ============================================================================
-- MAIN GENERATION LOOP - 1000 USERS
-- ============================================================================

DO $$
DECLARE
    i INTEGER;
    user_id UUID;
    display_name TEXT;
    zodiac_sign TEXT;
    age INTEGER;
    gender TEXT;
    looking_for TEXT[];
    city_lat NUMERIC;
    city_lng NUMERIC;
    activity_prefs JSONB;
    gender_rand NUMERIC;
    age_rand NUMERIC;
    city_id INTEGER;
    zodiac_id INTEGER;
    is_edge_case BOOLEAN;
    activity_count INTEGER;
    selected_activities TEXT[];
    activity_obj JSONB := '{}'::jsonb;
    batch_size INTEGER := 100;
    current_batch INTEGER;
    total_created INTEGER := 0;
BEGIN
    -- Process in batches of 100 for better logging
    FOR current_batch IN 1..10 LOOP
        FOR i IN ((current_batch - 1) * batch_size + 1)..(current_batch * batch_size) LOOP
            -- Generate UUID with perf- prefix
            user_id := ('perf-0000-0000-0000-' || LPAD(i::TEXT, 12, '0'))::UUID;

            -- Age distribution: Normal distribution around 28, range 18-65
            -- Using random() to approximate normal distribution
            age_rand := (random() + random() + random()) / 3; -- Pseudo-normal
            age := 18 + FLOOR(age_rand * 47)::INTEGER; -- Range 18-65

            -- Zodiac: Cycle through all 12 signs evenly
            zodiac_id := (i % 12) + 1;
            SELECT sign INTO zodiac_sign FROM temp_zodiac_signs WHERE id = zodiac_id;

            -- Gender distribution: 48% Male, 48% Female, 4% Non-binary
            gender_rand := random();
            IF gender_rand < 0.48 THEN
                gender := 'Male';
            ELSIF gender_rand < 0.96 THEN
                gender := 'Female';
            ELSE
                gender := 'Non-binary';
            END IF;

            -- Looking for: Realistic based on gender
            IF gender = 'Male' THEN
                IF random() < 0.85 THEN
                    looking_for := ARRAY['Females'];
                ELSIF random() < 0.90 THEN
                    looking_for := ARRAY['Both'];
                ELSE
                    looking_for := ARRAY['Everyone'];
                END IF;
            ELSIF gender = 'Female' THEN
                IF random() < 0.85 THEN
                    looking_for := ARRAY['Males'];
                ELSIF random() < 0.90 THEN
                    looking_for := ARRAY['Both'];
                ELSE
                    looking_for := ARRAY['Everyone'];
                END IF;
            ELSE -- Non-binary
                IF random() < 0.60 THEN
                    looking_for := ARRAY['Everyone'];
                ELSE
                    looking_for := ARRAY['Both'];
                END IF;
            END IF;

            -- City: Distribute evenly across 10 cities
            city_id := (i % 10) + 1;
            SELECT lat, lng INTO city_lat, city_lng FROM temp_cities WHERE id = city_id;

            -- Edge cases: 20% of users have some issue
            is_edge_case := random() < 0.20;

            -- Activity preferences: Random 1-4 activities
            activity_count := 1 + FLOOR(random() * 4)::INTEGER; -- 1-4 activities
            selected_activities := ARRAY[]::TEXT[];
            activity_obj := '{}'::jsonb;

            IF NOT is_edge_case OR random() < 0.50 THEN
                -- Build activity preferences
                FOR j IN 1..activity_count LOOP
                    DECLARE
                        activity_name TEXT;
                    BEGIN
                        SELECT activity INTO activity_name
                        FROM temp_activities
                        ORDER BY random()
                        LIMIT 1;

                        IF NOT (activity_name = ANY(selected_activities)) THEN
                            selected_activities := array_append(selected_activities, activity_name);
                            activity_obj := activity_obj || jsonb_build_object(activity_name, true);
                        END IF;
                    END;
                END LOOP;
            ELSE
                -- Edge case: NULL or empty activities
                IF random() < 0.50 THEN
                    activity_obj := NULL;
                ELSE
                    activity_obj := '{}'::jsonb;
                END IF;
            END IF;

            -- Display name
            display_name := 'Perf User ' || i::TEXT;

            -- Create the user
            PERFORM public.generate_test_user(
                p_user_id := user_id,
                p_display_name := display_name,
                p_zodiac_sign := zodiac_sign,
                p_age := age,
                p_gender := gender,
                p_looking_for := looking_for,
                p_lat := city_lat,
                p_lng := city_lng,
                p_activity_prefs := activity_obj
            );

            -- Apply edge cases for 20% of users
            IF is_edge_case THEN
                DECLARE
                    edge_case_type INTEGER := FLOOR(random() * 5)::INTEGER;
                BEGIN
                    CASE edge_case_type
                        WHEN 0 THEN
                            -- No natal chart data
                            UPDATE public.users SET natal_chart_data = NULL WHERE id = user_id;
                        WHEN 1 THEN
                            -- No questionnaire responses
                            UPDATE public.users SET questionnaire_responses = NULL WHERE id = user_id;
                        WHEN 2 THEN
                            -- Incomplete onboarding
                            UPDATE public.profiles SET onboarding_completed = false WHERE id = user_id;
                        WHEN 3 THEN
                            -- NULL location
                            UPDATE public.users SET birth_lat = NULL, birth_lng = NULL WHERE id = user_id;
                        WHEN 4 THEN
                            -- NULL zodiac
                            UPDATE public.profiles SET zodiac_sign = NULL WHERE id = user_id;
                    END CASE;
                END;
            END IF;

            total_created := total_created + 1;
        END LOOP;

        RAISE NOTICE '✅ Batch % complete: %/1000 users created', current_batch, total_created;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '✅ All 1000 performance users created';
END $$;

-- ============================================================================
-- VERIFICATION
-- ============================================================================

RAISE NOTICE '';
RAISE NOTICE '--- Verification Summary ---';

DO $$
DECLARE
    perf_user_count INTEGER;
    perf_profile_count INTEGER;
    age_distribution TEXT;
    gender_distribution TEXT;
    zodiac_distribution TEXT;
BEGIN
    SELECT COUNT(*) INTO perf_user_count
    FROM public.users
    WHERE id::TEXT LIKE 'perf-%';

    SELECT COUNT(*) INTO perf_profile_count
    FROM public.profiles
    WHERE id::TEXT LIKE 'perf-%';

    RAISE NOTICE 'Created % users in public.users', perf_user_count;
    RAISE NOTICE 'Created % profiles in public.profiles', perf_profile_count;

    -- Age distribution
    RAISE NOTICE '';
    RAISE NOTICE 'Age Distribution:';
    FOR age_distribution IN
        SELECT '  ' || age_range || ': ' || count || ' users'
        FROM (
            SELECT
                CASE
                    WHEN age < 25 THEN '18-24'
                    WHEN age < 30 THEN '25-29'
                    WHEN age < 35 THEN '30-34'
                    WHEN age < 40 THEN '35-39'
                    WHEN age < 50 THEN '40-49'
                    ELSE '50+'
                END as age_range,
                COUNT(*) as count
            FROM public.profiles
            WHERE id::TEXT LIKE 'perf-%'
            GROUP BY age_range
            ORDER BY age_range
        ) AS age_dist
    LOOP
        RAISE NOTICE '%', age_distribution;
    END LOOP;

    -- Gender distribution
    RAISE NOTICE '';
    RAISE NOTICE 'Gender Distribution:';
    FOR gender_distribution IN
        SELECT '  ' || gender || ': ' || COUNT(*) || ' users (' ||
               ROUND(COUNT(*) * 100.0 / perf_profile_count, 1) || '%)'
        FROM public.profiles
        WHERE id::TEXT LIKE 'perf-%'
        GROUP BY gender
        ORDER BY COUNT(*) DESC
    LOOP
        RAISE NOTICE '%', gender_distribution;
    END LOOP;

    -- Zodiac distribution
    RAISE NOTICE '';
    RAISE NOTICE 'Zodiac Distribution (should be ~83 per sign):';
    FOR zodiac_distribution IN
        SELECT '  ' || COALESCE(zodiac_sign, 'NULL') || ': ' || COUNT(*) || ' users'
        FROM public.profiles
        WHERE id::TEXT LIKE 'perf-%'
        GROUP BY zodiac_sign
        ORDER BY COUNT(*) DESC
    LOOP
        RAISE NOTICE '%', zodiac_distribution;
    END LOOP;

    IF perf_user_count = 1000 AND perf_profile_count = 1000 THEN
        RAISE NOTICE '';
        RAISE NOTICE '✅ All 1000 performance test users created successfully';
    ELSE
        RAISE EXCEPTION 'Performance user creation mismatch: expected 1000, got % users and % profiles',
            perf_user_count, perf_profile_count;
    END IF;
END $$;

-- ============================================================================
-- CLEANUP TEMP TABLES
-- ============================================================================

DROP TABLE IF EXISTS temp_cities;
DROP TABLE IF EXISTS temp_zodiac_signs;
DROP TABLE IF EXISTS temp_activities;

RAISE NOTICE '';
RAISE NOTICE '==================================================================================';
RAISE NOTICE '✅ LARGE SEED COMPLETE - 1000 PERFORMANCE USERS READY';
RAISE NOTICE '==================================================================================';
RAISE NOTICE '';
RAISE NOTICE 'Distribution Summary:';
RAISE NOTICE '  - Ages: Normal distribution (18-65, peak 25-35)';
RAISE NOTICE '  - Zodiac: ~83 users per sign (evenly distributed)';
RAISE NOTICE '  - Gender: 48% Male, 48% Female, 4% Non-binary';
RAISE NOTICE '  - Locations: 10 major cities (evenly distributed)';
RAISE NOTICE '  - Activities: 1-4 random activities per user';
RAISE NOTICE '  - Completeness: 80% complete, 20% edge cases';
RAISE NOTICE '';
RAISE NOTICE 'Edge Cases (20%):';
RAISE NOTICE '  - NULL natal_chart_data';
RAISE NOTICE '  - NULL questionnaire_responses';
RAISE NOTICE '  - Incomplete onboarding';
RAISE NOTICE '  - NULL location';
RAISE NOTICE '  - NULL zodiac';
RAISE NOTICE '==================================================================================';

COMMIT;
