-- ==================================================================================
-- SMALL TEST DATA SEED - 20 DIVERSE EDGE-CASE USERS
-- ==================================================================================
-- Purpose: Generate 20 carefully designed test users covering all edge cases
-- Usage: Run after 01_create_test_tables.sql
-- Coverage: Zodiac signs, ages, genders, locations, activities, NULL cases
-- ==================================================================================

BEGIN;

RAISE NOTICE '==================================================================================';
RAISE NOTICE 'SEEDING SMALL TEST DATA - 20 EDGE-CASE USERS';
RAISE NOTICE '==================================================================================';
RAISE NOTICE '';

-- ============================================================================
-- USER 001: Aries Male SF - Base Case
-- ============================================================================
-- Purpose: Standard baseline user for comparisons
-- Location: San Francisco (37.7749, -122.4194)
-- Activity: Adventure, Dining

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000001';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Aries Male SF',
        p_zodiac_sign := 'Aries',
        p_age := 25,
        p_gender := 'Male',
        p_looking_for := ARRAY['Females'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Adventure": true, "Dining": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 001: Aries Male SF (baseline)';
END $$;

-- ============================================================================
-- USER 002: Taurus Female SF - Distance 0km from User 001
-- ============================================================================
-- Purpose: Same location test, perfect match candidate for 001
-- Location: San Francisco (37.7749, -122.4194) - SAME coordinates
-- Activity: Dining, Cultural

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000002';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Taurus Female SF',
        p_zodiac_sign := 'Taurus',
        p_age := 30,
        p_gender := 'Female',
        p_looking_for := ARRAY['Males'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Dining": true, "Cultural": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 002: Taurus Female SF (distance: 0km from 001)';
END $$;

-- ============================================================================
-- USER 003: Gemini Male LA - Distance ~559km from User 001
-- ============================================================================
-- Purpose: Test distance filtering (SF to LA known distance)
-- Location: Los Angeles (34.0522, -118.2437)
-- Activity: Nightlife, Sports

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000003';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Gemini Male LA',
        p_zodiac_sign := 'Gemini',
        p_age := 28,
        p_gender := 'Male',
        p_looking_for := ARRAY['Females'],
        p_lat := 34.0522,
        p_lng := -118.2437,
        p_activity_prefs := '{"Nightlife": true, "Sports": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 003: Gemini Male LA (distance: ~559km from 001)';
END $$;

-- ============================================================================
-- USER 004: Cancer Female NYC - Distance ~4000km from User 001
-- ============================================================================
-- Purpose: Very far distance test, "Both" preference
-- Location: New York City (40.7128, -74.0060)
-- Activity: Cultural, Relaxation

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000004';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Cancer Female NYC',
        p_zodiac_sign := 'Cancer',
        p_age := 35,
        p_gender := 'Female',
        p_looking_for := ARRAY['Both'],
        p_lat := 40.7128,
        p_lng := -74.0060,
        p_activity_prefs := '{"Cultural": true, "Relaxation": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 004: Cancer Female NYC (distance: ~4000km, looking for Both)';
END $$;

-- ============================================================================
-- USER 005: Leo Non-Binary SF - "Everyone" Preference
-- ============================================================================
-- Purpose: Non-binary gender test, "Everyone" looking_for
-- Location: San Francisco (37.7849, -122.4094) - Slightly offset
-- Activity: All activities

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000005';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Leo NB SF',
        p_zodiac_sign := 'Leo',
        p_age := 22,
        p_gender := 'Non-binary',
        p_looking_for := ARRAY['Everyone'],
        p_lat := 37.7849,
        p_lng := -122.4094,
        p_activity_prefs := '{"Adventure": true, "Dining": true, "Cultural": true, "Nightlife": true, "Sports": true, "Relaxation": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 005: Leo Non-Binary (looking for Everyone, all activities)';
END $$;

-- ============================================================================
-- USER 006: Virgo Male No Location - NULL Coordinates
-- ============================================================================
-- Purpose: Test NULL location handling
-- Location: NULL, NULL
-- Activity: Adventure

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000006';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Virgo Male NoLoc',
        p_zodiac_sign := 'Virgo',
        p_age := 40,
        p_gender := 'Male',
        p_looking_for := ARRAY['Females'],
        p_lat := NULL,
        p_lng := NULL,
        p_activity_prefs := '{"Adventure": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 006: Virgo Male NoLoc (NULL location test)';
END $$;

-- ============================================================================
-- USER 007: Libra Female - NULL Activity Preferences
-- ============================================================================
-- Purpose: Test NULL activity_preferences handling
-- Location: San Francisco
-- Activity: NULL

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000007';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Libra Female NULL',
        p_zodiac_sign := 'Libra',
        p_age := 18,
        p_gender := 'Female',
        p_looking_for := ARRAY['Males'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := NULL
    );

    -- Override to set NULL activity_preferences
    UPDATE public.users
    SET activity_preferences = NULL
    WHERE id = user_id;

    RAISE NOTICE '✅ Created User 007: Libra Female (NULL activity_preferences)';
END $$;

-- ============================================================================
-- USER 008: Scorpio Male - Empty Activity Preferences
-- ============================================================================
-- Purpose: Test empty JSONB object for activities
-- Location: San Francisco
-- Activity: {} (empty object)

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000008';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Scorpio Male Empty',
        p_zodiac_sign := 'Scorpio',
        p_age := 50,
        p_gender := 'Male',
        p_looking_for := ARRAY['Females'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{}'::jsonb
    );
    RAISE NOTICE '✅ Created User 008: Scorpio Male (empty activity_preferences {})';
END $$;

-- ============================================================================
-- USER 009: Sagittarius Female Old - Age Max Boundary (65)
-- ============================================================================
-- Purpose: Test maximum age boundary
-- Location: San Francisco
-- Activity: Adventure

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000009';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Sagittarius F Old',
        p_zodiac_sign := 'Sagittarius',
        p_age := 65,
        p_gender := 'Female',
        p_looking_for := ARRAY['Males'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Adventure": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 009: Sagittarius Female (age 65 - max boundary)';
END $$;

-- ============================================================================
-- USER 010: Capricorn Male Young - Age Min Boundary (18)
-- ============================================================================
-- Purpose: Test minimum age boundary
-- Location: San Francisco
-- Activity: Sports

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000010';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Capricorn M Young',
        p_zodiac_sign := 'Capricorn',
        p_age := 18,
        p_gender := 'Male',
        p_looking_for := ARRAY['Females'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Sports": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 010: Capricorn Male (age 18 - min boundary)';
END $$;

-- ============================================================================
-- USER 011: Aquarius - NULL Zodiac Sign
-- ============================================================================
-- Purpose: Test NULL zodiac_sign handling
-- Location: San Francisco
-- Activity: Dining

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000011';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Aquarius NULL',
        p_zodiac_sign := NULL,
        p_age := 30,
        p_gender := 'Female',
        p_looking_for := ARRAY['Males'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Dining": true}'::jsonb
    );

    -- Override zodiac to NULL
    UPDATE public.profiles
    SET zodiac_sign = NULL
    WHERE id = user_id;

    RAISE NOTICE '✅ Created User 011: Aquarius (NULL zodiac_sign)';
END $$;

-- ============================================================================
-- USER 012: Pisces Incomplete - Onboarding Not Completed
-- ============================================================================
-- Purpose: Test onboarding_completed filter (should be excluded)
-- Location: San Francisco
-- Activity: Adventure

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000012';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Pisces Incomplete',
        p_zodiac_sign := 'Pisces',
        p_age := 28,
        p_gender := 'Male',
        p_looking_for := ARRAY['Females'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Adventure": true}'::jsonb
    );

    -- Mark as incomplete onboarding
    UPDATE public.profiles
    SET onboarding_completed = false
    WHERE id = user_id;

    RAISE NOTICE '✅ Created User 012: Pisces (onboarding_completed=false - should be excluded)';
END $$;

-- ============================================================================
-- USER 013: Aries Female - No Natal Chart Data
-- ============================================================================
-- Purpose: Test natal_chart_data exclusion
-- Location: San Francisco
-- Activity: Dining

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000013';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Aries NoChart',
        p_zodiac_sign := 'Aries',
        p_age := 30,
        p_gender := 'Female',
        p_looking_for := ARRAY['Males'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Dining": true}'::jsonb
    );

    -- Set natal_chart_data to NULL
    UPDATE public.users
    SET natal_chart_data = NULL
    WHERE id = user_id;

    RAISE NOTICE '✅ Created User 013: Aries NoChart (natal_chart_data=NULL - should be excluded)';
END $$;

-- ============================================================================
-- USER 014: Taurus Male - No Questionnaire Responses
-- ============================================================================
-- Purpose: Test questionnaire_responses exclusion
-- Location: San Francisco
-- Activity: Adventure

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000014';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Taurus NoQuiz',
        p_zodiac_sign := 'Taurus',
        p_age := 28,
        p_gender := 'Male',
        p_looking_for := ARRAY['Females'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Adventure": true}'::jsonb
    );

    -- Set questionnaire_responses to NULL
    UPDATE public.users
    SET questionnaire_responses = NULL
    WHERE id = user_id;

    RAISE NOTICE '✅ Created User 014: Taurus NoQuiz (questionnaire_responses=NULL - should be excluded)';
END $$;

-- ============================================================================
-- USER 015: Gemini Female Premium - Subscription Active
-- ============================================================================
-- Purpose: Test premium user ordering
-- Location: San Francisco
-- Activity: Cultural

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000015';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Gemini Premium',
        p_zodiac_sign := 'Gemini',
        p_age := 32,
        p_gender := 'Female',
        p_looking_for := ARRAY['Males'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Cultural": true}'::jsonb
    );

    -- Set as premium user
    UPDATE public.users
    SET subscription_status = 'active',
        subscription_tier = 'premium'
    WHERE id = user_id;

    RAISE NOTICE '✅ Created User 015: Gemini Premium (subscription_status=active)';
END $$;

-- ============================================================================
-- USER 016: Cancer - Case Sensitivity Test (lowercase)
-- ============================================================================
-- Purpose: Test case insensitivity in filters
-- Location: San Francisco
-- Activity: adventure (lowercase)

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000016';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Cancer Case Test',
        p_zodiac_sign := 'cancer',  -- lowercase
        p_age := 29,
        p_gender := 'Male',
        p_looking_for := ARRAY['females'],  -- lowercase
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"adventure": true}'::jsonb  -- lowercase key
    );
    RAISE NOTICE '✅ Created User 016: Cancer (lowercase strings for case test)';
END $$;

-- ============================================================================
-- USER 017: Leo Female Tokyo - Very Far Distance (~8000km)
-- ============================================================================
-- Purpose: Test very long distance filtering
-- Location: Tokyo (35.6762, 139.6503)
-- Activity: Dining

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000017';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Leo Far Tokyo',
        p_zodiac_sign := 'Leo',
        p_age := 27,
        p_gender := 'Female',
        p_looking_for := ARRAY['Males'],
        p_lat := 35.6762,
        p_lng := 139.6503,
        p_activity_prefs := '{"Dining": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 017: Leo Tokyo (distance: ~8000km from SF)';
END $$;

-- ============================================================================
-- USER 018: Virgo Male - For Block Tests
-- ============================================================================
-- Purpose: Will be used in block exclusion tests
-- Location: San Francisco
-- Activity: Sports

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000018';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Virgo Blocked',
        p_zodiac_sign := 'Virgo',
        p_age := 31,
        p_gender := 'Male',
        p_looking_for := ARRAY['Females'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Sports": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 018: Virgo (for block tests)';
END $$;

-- ============================================================================
-- USER 019: Libra Female - For Match Tests
-- ============================================================================
-- Purpose: Will be used in match exclusion tests
-- Location: San Francisco
-- Activity: Cultural

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000019';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Libra Matched',
        p_zodiac_sign := 'Libra',
        p_age := 26,
        p_gender := 'Female',
        p_looking_for := ARRAY['Males'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Cultural": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 019: Libra (for match tests)';
END $$;

-- ============================================================================
-- USER 020: Scorpio Male - For Swipe Cache Tests
-- ============================================================================
-- Purpose: Will be used in swipe exclusion tests
-- Location: San Francisco
-- Activity: Nightlife

DO $$
DECLARE
    user_id UUID := 'test-0000-0000-0000-000000000020';
BEGIN
    PERFORM public.generate_test_user(
        p_user_id := user_id,
        p_display_name := 'Scorpio Swiped',
        p_zodiac_sign := 'Scorpio',
        p_age := 33,
        p_gender := 'Male',
        p_looking_for := ARRAY['Females'],
        p_lat := 37.7749,
        p_lng := -122.4194,
        p_activity_prefs := '{"Nightlife": true}'::jsonb
    );
    RAISE NOTICE '✅ Created User 020: Scorpio (for swipe cache tests)';
END $$;

-- ============================================================================
-- VERIFICATION
-- ============================================================================

RAISE NOTICE '';
RAISE NOTICE '--- Verification Summary ---';

DO $$
DECLARE
    user_count INTEGER;
    profile_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO user_count
    FROM public.users
    WHERE id::TEXT LIKE 'test-%';

    SELECT COUNT(*) INTO profile_count
    FROM public.profiles
    WHERE id::TEXT LIKE 'test-%';

    RAISE NOTICE 'Created % users in public.users', user_count;
    RAISE NOTICE 'Created % profiles in public.profiles', profile_count;

    IF user_count = 20 AND profile_count = 20 THEN
        RAISE NOTICE '✅ All 20 test users created successfully';
    ELSE
        RAISE EXCEPTION 'User creation mismatch: expected 20, got % users and % profiles', user_count, profile_count;
    END IF;
END $$;

RAISE NOTICE '';
RAISE NOTICE '==================================================================================';
RAISE NOTICE '✅ SMALL SEED COMPLETE - 20 TEST USERS READY';
RAISE NOTICE '==================================================================================';
RAISE NOTICE '';
RAISE NOTICE 'User Summary:';
RAISE NOTICE '  - 001-002: SF location (0km distance)';
RAISE NOTICE '  - 003: LA location (~559km)';
RAISE NOTICE '  - 004: NYC location (~4000km)';
RAISE NOTICE '  - 005: Non-binary, Everyone preference';
RAISE NOTICE '  - 006: NULL location';
RAISE NOTICE '  - 007: NULL activities';
RAISE NOTICE '  - 008: Empty activities {}';
RAISE NOTICE '  - 009: Age 65 (max boundary)';
RAISE NOTICE '  - 010: Age 18 (min boundary)';
RAISE NOTICE '  - 011: NULL zodiac';
RAISE NOTICE '  - 012: Incomplete onboarding (excluded)';
RAISE NOTICE '  - 013: NULL natal_chart_data (excluded)';
RAISE NOTICE '  - 014: NULL questionnaire (excluded)';
RAISE NOTICE '  - 015: Premium user';
RAISE NOTICE '  - 016: Lowercase strings (case test)';
RAISE NOTICE '  - 017: Tokyo location (~8000km)';
RAISE NOTICE '  - 018-020: Reserved for exclusion tests';
RAISE NOTICE '==================================================================================';

COMMIT;
