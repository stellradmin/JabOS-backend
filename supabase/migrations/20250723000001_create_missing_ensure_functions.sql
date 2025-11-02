-- Create the missing ensure functions that the frontend expects
-- These functions handle graceful user and profile creation

-- ============================================================================
-- STEP 1: Create ensure_user_exists function
-- ============================================================================

CREATE OR REPLACE FUNCTION ensure_user_exists(user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    user_record RECORD;
    auth_user_record RECORD;
BEGIN
    -- First check if user record already exists
    SELECT * INTO user_record 
    FROM public.users 
    WHERE id = user_id;
    
    IF FOUND THEN
        RETURN TRUE;
    END IF;
    
    -- Get user info from auth.users
    SELECT * INTO auth_user_record 
    FROM auth.users 
    WHERE id = user_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Auth user with id % not found', user_id;
    END IF;
    
    -- Create user record with basic info from auth
    INSERT INTO public.users (
        id,
        auth_user_id,
        email,
        created_at,
        updated_at
    ) VALUES (
        user_id,
        user_id,
        auth_user_record.email,
        NOW(),
        NOW()
    )
    ON CONFLICT (id) DO NOTHING;
    
    RETURN TRUE;
EXCEPTION
    WHEN OTHERS THEN
        RAISE LOG 'Error in ensure_user_exists: %', SQLERRM;
        RETURN FALSE;
END;
$$;

-- ============================================================================
-- STEP 2: Create ensure_profile_exists function
-- ============================================================================

CREATE OR REPLACE FUNCTION ensure_profile_exists(user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    profile_record RECORD;
    auth_user_record RECORD;
BEGIN
    -- First check if profile already exists
    SELECT * INTO profile_record 
    FROM public.profiles 
    WHERE id = user_id;
    
    IF FOUND THEN
        RETURN TRUE;
    END IF;
    
    -- Get user info from auth.users
    SELECT * INTO auth_user_record 
    FROM auth.users 
    WHERE id = user_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Auth user with id % not found', user_id;
    END IF;
    
    -- Create profile record with basic info
    INSERT INTO public.profiles (
        id,
        username,
        display_name,
        bio,
        avatar_url,
        onboarding_completed,
        created_at,
        updated_at
    ) VALUES (
        user_id,
        NULL, -- Will be set during onboarding
        NULL, -- Will be set during onboarding
        NULL,
        NULL,
        FALSE,
        NOW(),
        NOW()
    )
    ON CONFLICT (id) DO NOTHING;
    
    RETURN TRUE;
EXCEPTION
    WHEN OTHERS THEN
        RAISE LOG 'Error in ensure_profile_exists: %', SQLERRM;
        RETURN FALSE;
END;
$$;

-- ============================================================================
-- STEP 3: Grant necessary permissions
-- ============================================================================

-- Grant execute permissions to authenticated users
GRANT EXECUTE ON FUNCTION ensure_user_exists(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION ensure_profile_exists(UUID) TO authenticated;

-- Grant to service_role as well for backend operations
GRANT EXECUTE ON FUNCTION ensure_user_exists(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION ensure_profile_exists(UUID) TO service_role;

-- ============================================================================
-- STEP 4: Add function comments for documentation
-- ============================================================================

COMMENT ON FUNCTION ensure_user_exists(UUID) IS 
'Ensures a user record exists in the users table for the given user_id. 
Creates the record if it does not exist, using data from auth.users.
Returns TRUE on success, FALSE on error.';

COMMENT ON FUNCTION ensure_profile_exists(UUID) IS 
'Ensures a profile record exists in the profiles table for the given user_id.
Creates a basic profile record if it does not exist.
Returns TRUE on success, FALSE on error.';

-- ============================================================================
-- STEP 5: Test the functions work correctly
-- ============================================================================

DO $$
BEGIN
    -- Verify functions exist and can be called
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p 
        JOIN pg_namespace n ON p.pronamespace = n.oid 
        WHERE n.nspname = 'public' 
        AND p.proname = 'ensure_user_exists'
    ) THEN
        RAISE EXCEPTION 'Function ensure_user_exists was not created';
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p 
        JOIN pg_namespace n ON p.pronamespace = n.oid 
        WHERE n.nspname = 'public' 
        AND p.proname = 'ensure_profile_exists'
    ) THEN
        RAISE EXCEPTION 'Function ensure_profile_exists was not created';
    END IF;
    
    RAISE NOTICE 'Successfully created ensure_user_exists and ensure_profile_exists functions';
END $$;