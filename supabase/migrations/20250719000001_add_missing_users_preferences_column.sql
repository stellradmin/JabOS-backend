-- Add Missing Database Columns
-- This migration adds multiple missing columns that are referenced throughout the codebase
-- but were missing from their respective table schemas

-- =====================================
-- ADD PREFERENCES COLUMN
-- =====================================

-- Add the missing columns to users table
ALTER TABLE public.users 
ADD COLUMN IF NOT EXISTS preferences JSONB DEFAULT '{}'::jsonb;

-- Add natal_chart_data column that is referenced in functions but missing
ALTER TABLE public.users 
ADD COLUMN IF NOT EXISTS natal_chart_data JSONB DEFAULT '{}'::jsonb;

-- Add direction column to swipes table that is referenced in migrations but missing
ALTER TABLE public.swipes 
ADD COLUMN IF NOT EXISTS direction TEXT DEFAULT 'right';

-- Add updated_at column to messages table that is referenced in migrations but missing
ALTER TABLE public.messages 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Add read_at column to messages table that is referenced in migrations but missing
ALTER TABLE public.messages 
ADD COLUMN IF NOT EXISTS read_at TIMESTAMPTZ;

-- =====================================
-- SET DEFAULT VALUES
-- =====================================

-- Update any existing users to have default preferences structure
UPDATE public.users 
SET preferences = jsonb_build_object(
    'min_age', 22,
    'max_age', 45,
    'max_distance_km', 50,
    'gender_preference', 'any',
    'show_distance', true,
    'show_age', true,
    'notifications_enabled', true,
    'discovery_enabled', true
)
WHERE preferences IS NULL OR preferences = '{}'::jsonb;

-- =====================================
-- ADD CONSTRAINTS AND VALIDATION
-- =====================================

-- Add constraint to ensure preferences has required structure
ALTER TABLE public.users 
ADD CONSTRAINT users_preferences_structure_check 
CHECK (
    preferences IS NOT NULL AND
    preferences ? 'min_age' AND
    preferences ? 'max_age' AND
    preferences ? 'max_distance_km' AND
    (preferences->>'min_age')::INT >= 18 AND
    (preferences->>'max_age')::INT <= 100 AND
    (preferences->>'min_age')::INT <= (preferences->>'max_age')::INT AND
    (preferences->>'max_distance_km')::INT > 0
);

-- =====================================
-- ADD PERFORMANCE INDEX
-- =====================================

-- Add GIN index for JSONB preferences for better performance
CREATE INDEX IF NOT EXISTS idx_users_preferences_gin 
ON public.users USING GIN (preferences);

-- Add specific indexes for commonly queried preference fields
CREATE INDEX IF NOT EXISTS idx_users_age_preferences 
ON public.users ((preferences->>'min_age'), (preferences->>'max_age'));

CREATE INDEX IF NOT EXISTS idx_users_distance_preference 
ON public.users ((preferences->>'max_distance_km'));

-- =====================================
-- CREATE HELPER FUNCTIONS
-- =====================================

-- Function to validate and update user preferences
CREATE OR REPLACE FUNCTION public.update_user_preferences(
    user_id UUID,
    new_preferences JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    updated_prefs JSONB;
    min_age_val INT;
    max_age_val INT;
    distance_val INT;
BEGIN
    -- Extract and validate values
    min_age_val := (new_preferences->>'min_age')::INT;
    max_age_val := (new_preferences->>'max_age')::INT;
    distance_val := (new_preferences->>'max_distance_km')::INT;
    
    -- Validate age range
    IF min_age_val < 18 OR min_age_val > 100 THEN
        RAISE EXCEPTION 'Minimum age must be between 18 and 100';
    END IF;
    
    IF max_age_val < 18 OR max_age_val > 100 THEN
        RAISE EXCEPTION 'Maximum age must be between 18 and 100';
    END IF;
    
    IF min_age_val > max_age_val THEN
        RAISE EXCEPTION 'Minimum age cannot be greater than maximum age';
    END IF;
    
    -- Validate distance
    IF distance_val <= 0 OR distance_val > 500 THEN
        RAISE EXCEPTION 'Distance must be between 1 and 500 km';
    END IF;
    
    -- Update preferences, preserving existing values not being changed
    UPDATE public.users 
    SET preferences = preferences || new_preferences,
        updated_at = NOW()
    WHERE id = user_id
    RETURNING preferences INTO updated_prefs;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', user_id;
    END IF;
    
    RETURN updated_prefs;
END;
$$;

-- Function to get user preferences with fallbacks
CREATE OR REPLACE FUNCTION public.get_user_preferences(user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    user_prefs JSONB;
BEGIN
    SELECT preferences INTO user_prefs
    FROM public.users 
    WHERE id = user_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', user_id;
    END IF;
    
    -- Return preferences with fallback defaults
    RETURN COALESCE(user_prefs, jsonb_build_object(
        'min_age', 22,
        'max_age', 45,
        'max_distance_km', 50,
        'gender_preference', 'any'
    ));
END;
$$;

-- =====================================
-- GRANT PERMISSIONS
-- =====================================

-- Grant permissions for the new functions
GRANT EXECUTE ON FUNCTION public.update_user_preferences(UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_preferences(UUID, JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_user_preferences(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_preferences(UUID) TO service_role;

-- =====================================
-- ADD COMMENTS
-- =====================================

COMMENT ON COLUMN public.users.preferences IS 'JSONB object containing user matching preferences including age range, distance, and display settings';
COMMENT ON COLUMN public.users.natal_chart_data IS 'JSONB object containing user natal chart data for astrological compatibility calculations';
COMMENT ON FUNCTION public.update_user_preferences(UUID, JSONB) IS 'Updates user preferences with validation and returns the updated preferences object';
COMMENT ON FUNCTION public.get_user_preferences(UUID) IS 'Retrieves user preferences with fallback defaults if preferences are missing';

-- =====================================
-- VERIFICATION
-- =====================================

-- Verify the column was added and has proper structure
DO $$
DECLARE
    column_exists BOOLEAN;
    user_count INTEGER;
    users_with_prefs INTEGER;
BEGIN
    -- Check if column exists
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' 
        AND table_name = 'users' 
        AND column_name = 'preferences'
    ) INTO column_exists;
    
    IF column_exists THEN
        RAISE NOTICE 'SUCCESS: preferences column added to users table';
        
        -- Count users and those with preferences
        SELECT COUNT(*) INTO user_count FROM public.users;
        SELECT COUNT(*) INTO users_with_prefs 
        FROM public.users 
        WHERE preferences IS NOT NULL AND preferences != '{}'::jsonb;
        
        RAISE NOTICE 'Total users: %, Users with preferences: %', user_count, users_with_prefs;
    ELSE
        RAISE EXCEPTION 'FAILED: preferences column was not added to users table';
    END IF;
END $$;

-- Log the migration completion
SELECT 
    'Users Preferences Column Migration Completed Successfully' as status,
    NOW() as completed_at,
    COUNT(*) as total_users,
    COUNT(*) FILTER (WHERE preferences IS NOT NULL) as users_with_preferences
FROM public.users;