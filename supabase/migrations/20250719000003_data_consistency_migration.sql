-- Data Consistency Migration for Matching System
-- Ensures all gender values are consistent and populates missing looking_for preferences

-- 1. Standardize gender values in profiles table
UPDATE public.profiles 
SET gender = CASE 
    WHEN LOWER(TRIM(gender)) IN ('male', 'm') THEN 'Male'
    WHEN LOWER(TRIM(gender)) IN ('female', 'f') THEN 'Female'
    WHEN LOWER(TRIM(gender)) IN ('non-binary', 'nonbinary', 'nb', 'enby') THEN 'Non-binary'
    WHEN LOWER(TRIM(gender)) IN ('other', 'prefer not to say', 'trans', 'transgender') THEN 'Other'
    WHEN gender IS NULL OR TRIM(gender) = '' THEN 'Other'
    ELSE COALESCE(gender, 'Other')
END
WHERE gender IS NULL 
   OR gender NOT IN ('Male', 'Female', 'Non-binary', 'Other');

-- 2. Populate missing looking_for preferences based on typical patterns
-- If looking_for is null, set default preferences
UPDATE public.users 
SET looking_for = CASE 
    -- Default heterosexual preferences based on profile gender
    WHEN (
        SELECT gender FROM public.profiles WHERE id = users.id
    ) = 'Male' THEN ARRAY['Females']
    WHEN (
        SELECT gender FROM public.profiles WHERE id = users.id  
    ) = 'Female' THEN ARRAY['Males']
    -- For non-binary and other, default to all options
    ELSE ARRAY['Males', 'Females', 'Non-Binary']
END
WHERE looking_for IS NULL 
   OR looking_for = '{}';

-- 3. Update preferences JSONB to include looking_for if missing
UPDATE public.users 
SET preferences = COALESCE(preferences, '{}'::jsonb) || 
    jsonb_build_object('looking_for', looking_for)
WHERE preferences IS NULL 
   OR NOT (preferences ? 'looking_for')
   OR preferences->>'looking_for' IS NULL;

-- 4. Ensure age values are reasonable (fix any outliers)
UPDATE public.profiles 
SET age = CASE 
    WHEN age IS NULL THEN 25  -- Default age if missing
    WHEN age < 18 THEN 18     -- Minimum age
    WHEN age > 100 THEN 35    -- Reasonable default for outliers
    ELSE age
END
WHERE age IS NULL OR age < 18 OR age > 100;

-- 5. Clean up interests arrays (remove null/empty entries)
UPDATE public.profiles 
SET interests = (
    SELECT array_agg(DISTINCT interest)
    FROM unnest(interests) AS interest
    WHERE interest IS NOT NULL 
      AND TRIM(interest) != ''
      AND LENGTH(TRIM(interest)) > 0
)
WHERE interests IS NOT NULL 
  AND (
    NULL = ANY(interests) 
    OR '' = ANY(interests)
    OR array_length(interests, 1) != (
        SELECT count(DISTINCT interest)
        FROM unnest(interests) AS interest
        WHERE interest IS NOT NULL AND TRIM(interest) != ''
    )
  );

-- 6. Clean up traits arrays (remove null/empty entries)
UPDATE public.profiles 
SET traits = (
    SELECT array_agg(DISTINCT trait)
    FROM unnest(traits) AS trait
    WHERE trait IS NOT NULL 
      AND TRIM(trait) != ''
      AND LENGTH(TRIM(trait)) > 0
)
WHERE traits IS NOT NULL 
  AND (
    NULL = ANY(traits) 
    OR '' = ANY(traits)
    OR array_length(traits, 1) != (
        SELECT count(DISTINCT trait)
        FROM unnest(traits) AS trait
        WHERE trait IS NOT NULL AND TRIM(trait) != ''
    )
  );

-- 7. Set onboarding_completed = true for users with sufficient data
UPDATE public.profiles 
SET onboarding_completed = true
WHERE onboarding_completed IS NOT true
  AND display_name IS NOT NULL 
  AND age IS NOT NULL 
  AND gender IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM public.users 
    WHERE id = profiles.id 
      AND looking_for IS NOT NULL 
      AND array_length(looking_for, 1) > 0
  );

-- 8. Add constraints to prevent future data inconsistencies
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_age_check;
ALTER TABLE public.profiles 
ADD CONSTRAINT profiles_age_check 
CHECK (age IS NULL OR (age >= 18 AND age <= 120));

-- Ensure gender constraint is in place
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_gender_check;
ALTER TABLE public.profiles 
ADD CONSTRAINT profiles_gender_check 
CHECK (gender IN ('Male', 'Female', 'Non-binary', 'Other'));

-- Ensure looking_for constraint is in place  
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_looking_for_check;
ALTER TABLE public.users 
ADD CONSTRAINT users_looking_for_check 
CHECK (
    looking_for IS NULL 
    OR (
        looking_for <@ ARRAY['Males', 'Females', 'Both', 'Non-Binary', 'Transgender']
        AND array_length(looking_for, 1) > 0
    )
);

-- 9. Create validation function for profile completeness
CREATE OR REPLACE FUNCTION public.is_profile_complete(user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    profile_complete BOOLEAN := false;
BEGIN
    SELECT (
        p.display_name IS NOT NULL AND
        p.age IS NOT NULL AND 
        p.gender IS NOT NULL AND
        p.onboarding_completed = true AND
        u.looking_for IS NOT NULL AND
        array_length(u.looking_for, 1) > 0
    )
    INTO profile_complete
    FROM public.profiles p
    JOIN public.users u ON p.id = u.id
    WHERE p.id = user_id;
    
    RETURN COALESCE(profile_complete, false);
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.is_profile_complete(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_profile_complete(UUID) TO service_role;

-- 10. Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_profiles_gender_age ON public.profiles(gender, age) WHERE onboarding_completed = true;
CREATE INDEX IF NOT EXISTS idx_users_looking_for ON public.users USING GIN(looking_for) WHERE looking_for IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_profiles_interests ON public.profiles USING GIN(interests) WHERE interests IS NOT NULL;

-- Add comments
COMMENT ON FUNCTION public.is_profile_complete(UUID) IS 'Checks if a user profile has all required fields for matching';
COMMENT ON CONSTRAINT profiles_age_check ON public.profiles IS 'Ensures age is within reasonable bounds (18-120)';
COMMENT ON CONSTRAINT profiles_gender_check ON public.profiles IS 'Ensures gender uses standardized values';
COMMENT ON CONSTRAINT users_looking_for_check ON public.users IS 'Ensures looking_for contains valid preference values';

-- Report on data cleanup
DO $$
DECLARE
    total_profiles INT;
    complete_profiles INT;
    profiles_with_looking_for INT;
BEGIN
    SELECT COUNT(*) INTO total_profiles FROM public.profiles;
    SELECT COUNT(*) INTO complete_profiles FROM public.profiles WHERE onboarding_completed = true;
    SELECT COUNT(*) INTO profiles_with_looking_for 
    FROM public.users 
    WHERE looking_for IS NOT NULL AND array_length(looking_for, 1) > 0;
    
    RAISE NOTICE 'Data cleanup complete:';
    RAISE NOTICE '- Total profiles: %', total_profiles;
    RAISE NOTICE '- Complete profiles: %', complete_profiles;
    RAISE NOTICE '- Profiles with looking_for preferences: %', profiles_with_looking_for;
    RAISE NOTICE '- Completion rate: %%%', ROUND((complete_profiles::NUMERIC / NULLIF(total_profiles, 0)) * 100, 1);
END;
$$;