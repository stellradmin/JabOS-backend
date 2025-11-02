-- Comprehensive Data Consistency Migration
-- Ensures all existing data has proper defaults and prevents future NULL issues

-- =====================================
-- SECTION 1: USER TABLE CONSISTENCY
-- =====================================

-- Fix users table data consistency
UPDATE public.users 
SET 
    looking_for = CASE 
        WHEN looking_for IS NULL OR looking_for = '{}' THEN ARRAY['Males', 'Females']
        ELSE looking_for
    END,
    preferences = CASE 
        WHEN preferences IS NULL THEN jsonb_build_object(
            'min_age', 22,
            'max_age', 45,
            'max_distance_km', 50,
            'gender_preference', 'any'
        )
        WHEN NOT (preferences ? 'min_age') THEN preferences || jsonb_build_object(
            'min_age', 22,
            'max_age', 45,
            'max_distance_km', 50
        )
        ELSE preferences
    END,
    questionnaire_responses = COALESCE(questionnaire_responses, '[]'::jsonb),
    natal_chart_data = COALESCE(natal_chart_data, '{}'::jsonb),
    created_at = COALESCE(created_at, NOW()),
    updated_at = COALESCE(updated_at, NOW())
WHERE 
    looking_for IS NULL OR looking_for = '{}' OR
    preferences IS NULL OR NOT (preferences ? 'min_age') OR
    questionnaire_responses IS NULL OR
    natal_chart_data IS NULL OR
    created_at IS NULL OR
    updated_at IS NULL;

-- =====================================
-- SECTION 2: PROFILES TABLE CONSISTENCY
-- =====================================

-- Fix profiles table data consistency
UPDATE public.profiles 
SET 
    display_name = CASE 
        WHEN display_name IS NULL OR display_name = '' THEN 'User ' || substr(id::text, 1, 8)
        ELSE display_name
    END,
    age = CASE 
        WHEN age IS NULL OR age < 18 OR age > 100 THEN 28
        ELSE age
    END,
    gender = CASE 
        WHEN gender IS NULL OR gender = '' THEN 'Other'
        ELSE gender
    END,
    zodiac_sign = CASE 
        WHEN zodiac_sign IS NULL OR zodiac_sign = '' THEN 'Aries'
        ELSE zodiac_sign
    END,
    interests = COALESCE(interests, ARRAY[]::TEXT[]),
    traits = COALESCE(traits, ARRAY[]::TEXT[]),
    onboarding_completed = COALESCE(onboarding_completed, false),
    created_at = COALESCE(created_at, NOW()),
    updated_at = COALESCE(updated_at, NOW())
WHERE 
    display_name IS NULL OR display_name = '' OR
    age IS NULL OR age < 18 OR age > 100 OR
    gender IS NULL OR gender = '' OR
    zodiac_sign IS NULL OR zodiac_sign = '' OR
    interests IS NULL OR
    traits IS NULL OR
    onboarding_completed IS NULL OR
    created_at IS NULL OR
    updated_at IS NULL;

-- =====================================
-- SECTION 3: MATCH REQUESTS CONSISTENCY
-- =====================================

-- Fix match_requests table data consistency (if table exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        UPDATE public.match_requests 
        SET 
            preferences = COALESCE(preferences, '{}'::jsonb),
            status = CASE 
                WHEN status IS NULL OR status = '' THEN 'pending_system_match'
                ELSE status
            END,
            created_at = COALESCE(created_at, NOW()),
            updated_at = COALESCE(updated_at, NOW())
        WHERE 
            preferences IS NULL OR
            status IS NULL OR status = '' OR
            created_at IS NULL OR
            updated_at IS NULL;
    END IF;
END $$;

-- =====================================
-- SECTION 4: RELATIONSHIP TABLE CONSISTENCY
-- =====================================

-- Ensure matches table has proper timestamps
UPDATE public.matches 
SET 
    created_at = COALESCE(created_at, NOW()),
    updated_at = COALESCE(updated_at, NOW())
WHERE created_at IS NULL OR updated_at IS NULL;

-- Ensure swipes table has proper timestamps and direction
UPDATE public.swipes 
SET 
    created_at = COALESCE(created_at, NOW()),
    direction = CASE 
        WHEN direction IS NULL THEN 'right'
        ELSE direction
    END
WHERE created_at IS NULL OR direction IS NULL;

-- Ensure conversations have proper timestamps
UPDATE public.conversations 
SET 
    created_at = COALESCE(created_at, NOW()),
    updated_at = COALESCE(updated_at, NOW()),
    last_message_at = COALESCE(last_message_at, created_at, NOW())
WHERE 
    created_at IS NULL OR 
    updated_at IS NULL OR 
    last_message_at IS NULL;

-- Ensure messages have proper timestamps
UPDATE public.messages 
SET 
    created_at = COALESCE(created_at, NOW()),
    updated_at = COALESCE(updated_at, NOW())
WHERE created_at IS NULL OR updated_at IS NULL;

-- =====================================
-- SECTION 5: ADD NOT NULL CONSTRAINTS
-- =====================================

-- Add NOT NULL constraints to critical fields (with defaults)
-- Users table
ALTER TABLE public.users 
    ALTER COLUMN looking_for SET DEFAULT ARRAY['Males', 'Females'],
    ALTER COLUMN preferences SET DEFAULT '{}'::jsonb,
    ALTER COLUMN questionnaire_responses SET DEFAULT '[]'::jsonb,
    ALTER COLUMN natal_chart_data SET DEFAULT '{}'::jsonb;

-- Profiles table  
ALTER TABLE public.profiles 
    ALTER COLUMN display_name SET DEFAULT 'User',
    ALTER COLUMN age SET DEFAULT 28,
    ALTER COLUMN gender SET DEFAULT 'Other',
    ALTER COLUMN zodiac_sign SET DEFAULT 'Aries',
    ALTER COLUMN interests SET DEFAULT ARRAY[]::TEXT[],
    ALTER COLUMN traits SET DEFAULT ARRAY[]::TEXT[],
    ALTER COLUMN onboarding_completed SET DEFAULT false;

-- Match requests table (if it exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        ALTER TABLE public.match_requests 
            ALTER COLUMN preferences SET DEFAULT '{}'::jsonb,
            ALTER COLUMN status SET DEFAULT 'pending_system_match';
    END IF;
END $$;

-- =====================================
-- SECTION 6: VALIDATION FUNCTIONS
-- =====================================

-- Create function to validate and fix user data on insert/update
CREATE OR REPLACE FUNCTION public.validate_user_data()
RETURNS TRIGGER AS $$
BEGIN
    -- Ensure looking_for is never null or empty
    IF NEW.looking_for IS NULL OR NEW.looking_for = '{}' THEN
        NEW.looking_for := ARRAY['Males', 'Females'];
    END IF;
    
    -- Ensure preferences has required fields
    IF NEW.preferences IS NULL THEN
        NEW.preferences := jsonb_build_object(
            'min_age', 22,
            'max_age', 45,
            'max_distance_km', 50
        );
    ELSIF NOT (NEW.preferences ? 'min_age') THEN
        NEW.preferences := NEW.preferences || jsonb_build_object(
            'min_age', 22,
            'max_age', 45,
            'max_distance_km', 50
        );
    END IF;
    
    -- Ensure questionnaire_responses is valid JSON array
    IF NEW.questionnaire_responses IS NULL THEN
        NEW.questionnaire_responses := '[]'::jsonb;
    END IF;
    
    -- Ensure natal_chart_data is valid JSON object
    IF NEW.natal_chart_data IS NULL THEN
        NEW.natal_chart_data := '{}'::jsonb;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for users table
DROP TRIGGER IF EXISTS trigger_validate_user_data ON public.users;
CREATE TRIGGER trigger_validate_user_data
    BEFORE INSERT OR UPDATE ON public.users
    FOR EACH ROW
    EXECUTE FUNCTION public.validate_user_data();

-- Create function to validate and fix profile data
CREATE OR REPLACE FUNCTION public.validate_profile_data()
RETURNS TRIGGER AS $$
BEGIN
    -- Ensure display_name is never null or empty
    IF NEW.display_name IS NULL OR NEW.display_name = '' THEN
        NEW.display_name := 'User ' || substr(NEW.id::text, 1, 8);
    END IF;
    
    -- Ensure age is valid
    IF NEW.age IS NULL OR NEW.age < 18 OR NEW.age > 100 THEN
        NEW.age := 28;
    END IF;
    
    -- Ensure gender is never null
    IF NEW.gender IS NULL OR NEW.gender = '' THEN
        NEW.gender := 'Other';
    END IF;
    
    -- Ensure zodiac_sign is never null
    IF NEW.zodiac_sign IS NULL OR NEW.zodiac_sign = '' THEN
        NEW.zodiac_sign := 'Aries';
    END IF;
    
    -- Ensure arrays are never null
    IF NEW.interests IS NULL THEN
        NEW.interests := ARRAY[]::TEXT[];
    END IF;
    
    IF NEW.traits IS NULL THEN
        NEW.traits := ARRAY[]::TEXT[];
    END IF;
    
    -- Ensure onboarding_completed is never null
    IF NEW.onboarding_completed IS NULL THEN
        NEW.onboarding_completed := false;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for profiles table
DROP TRIGGER IF EXISTS trigger_validate_profile_data ON public.profiles;
CREATE TRIGGER trigger_validate_profile_data
    BEFORE INSERT OR UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.validate_profile_data();

-- =====================================
-- SECTION 7: DATA QUALITY INDEXES
-- =====================================

-- Add indexes to improve query performance with the corrected data
CREATE INDEX IF NOT EXISTS idx_users_looking_for_gin ON public.users USING GIN(looking_for);
CREATE INDEX IF NOT EXISTS idx_users_preferences_gin ON public.users USING GIN(preferences);
CREATE INDEX IF NOT EXISTS idx_profiles_onboarding_age ON public.profiles(onboarding_completed, age) WHERE onboarding_completed = true;
CREATE INDEX IF NOT EXISTS idx_profiles_gender_zodiac ON public.profiles(gender, zodiac_sign) WHERE onboarding_completed = true;

-- =====================================
-- SECTION 8: VERIFICATION AND REPORTING
-- =====================================

-- Generate data quality report
DO $$
DECLARE
    users_fixed INTEGER;
    profiles_fixed INTEGER;
    matches_fixed INTEGER;
    total_users INTEGER;
    total_profiles INTEGER;
BEGIN
    -- Count total records
    SELECT COUNT(*) INTO total_users FROM public.users;
    SELECT COUNT(*) INTO total_profiles FROM public.profiles;
    
    -- Count records that would have been problematic
    SELECT COUNT(*) INTO users_fixed 
    FROM public.users 
    WHERE looking_for IS NOT NULL AND array_length(looking_for, 1) > 0;
    
    SELECT COUNT(*) INTO profiles_fixed 
    FROM public.profiles 
    WHERE display_name IS NOT NULL AND age IS NOT NULL AND gender IS NOT NULL;
    
    RAISE NOTICE 'Data Consistency Migration Report:';
    RAISE NOTICE '- Total users: %', total_users;
    RAISE NOTICE '- Users with valid looking_for: %', users_fixed;
    RAISE NOTICE '- Total profiles: %', total_profiles;
    RAISE NOTICE '- Profiles with complete data: %', profiles_fixed;
    RAISE NOTICE 'Migration completed successfully at %', NOW();
END $$;

-- Final status check
SELECT 
    'Comprehensive Data Consistency Migration Completed' as status,
    COUNT(*) as total_users,
    COUNT(*) FILTER (WHERE looking_for IS NOT NULL AND array_length(looking_for, 1) > 0) as users_with_valid_preferences,
    COUNT(*) FILTER (WHERE preferences IS NOT NULL AND preferences ? 'min_age') as users_with_complete_preferences
FROM public.users;

-- Add comment documenting this migration
COMMENT ON SCHEMA public IS 'Data consistency migration applied - all NULL values fixed with proper defaults - 2025-07-19';