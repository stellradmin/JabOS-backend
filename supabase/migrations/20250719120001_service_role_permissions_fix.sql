-- Service Role Permissions Fix for Edge Functions
-- This ensures edge functions can operate with proper permissions

-- =====================================
-- SECTION 1: SERVICE ROLE PERMISSIONS
-- =====================================

-- Grant comprehensive permissions to service role for all critical tables
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO service_role;

-- Ensure service role can bypass RLS when needed
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.swipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
-- Enable RLS for match_requests table if it exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        ALTER TABLE public.match_requests ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

-- =====================================
-- SECTION 2: RLS BYPASS FOR SERVICE ROLE
-- =====================================

-- Allow service role to bypass RLS for critical operations
CREATE POLICY "Service role bypass RLS" ON public.profiles
    FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "Service role bypass RLS" ON public.users
    FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "Service role bypass RLS" ON public.matches
    FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "Service role bypass RLS" ON public.swipes
    FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "Service role bypass RLS" ON public.conversations
    FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "Service role bypass RLS" ON public.messages
    FOR ALL USING (auth.role() = 'service_role');

-- Create RLS policy for match_requests table if it exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        CREATE POLICY "Service role bypass RLS" ON public.match_requests
            FOR ALL USING (auth.role() = 'service_role');
    END IF;
END $$;

-- =====================================
-- SECTION 3: AUTHENTICATED ROLE PERMISSIONS
-- =====================================

-- Ensure authenticated users have necessary basic permissions
GRANT SELECT ON public.profiles TO authenticated;
GRANT INSERT, SELECT, UPDATE ON public.users TO authenticated;
GRANT SELECT ON public.matches TO authenticated;
GRANT INSERT, SELECT ON public.swipes TO authenticated;
GRANT SELECT ON public.conversations TO authenticated;
GRANT SELECT, INSERT ON public.messages TO authenticated;
-- Grant permissions for match_requests table if it exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        GRANT INSERT, SELECT, UPDATE, DELETE ON public.match_requests TO authenticated;
    END IF;
END $$;

-- =====================================
-- SECTION 4: FUNCTION EXECUTION PERMISSIONS
-- =====================================

-- Ensure both roles can execute critical functions
GRANT EXECUTE ON FUNCTION public.get_filtered_potential_matches(UUID, UUID[], TEXT, INT, INT, INT, INT) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_filtered_potential_matches(UUID, UUID[], TEXT, INT, INT, INT, INT) TO authenticated;

GRANT EXECUTE ON FUNCTION public.calculate_compatibility_scores(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.calculate_compatibility_scores(UUID, UUID) TO authenticated;

-- Grant permissions for all existing functions to service role
DO $$
DECLARE
    func_record RECORD;
BEGIN
    FOR func_record IN 
        SELECT 
            routine_name,
            specific_name,
            routine_definition
        FROM information_schema.routines 
        WHERE routine_schema = 'public' 
        AND routine_type = 'FUNCTION'
    LOOP
        BEGIN
            -- Try to grant using specific name first (handles overloaded functions)
            EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I TO service_role', func_record.specific_name);
        EXCEPTION WHEN OTHERS THEN
            -- If that fails, try with routine name and log the issue
            BEGIN
                EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I TO service_role', func_record.routine_name);
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'Could not grant permissions for function: % (Error: %)', func_record.routine_name, SQLERRM;
            END;
        END;
    END LOOP;
END $$;

-- =====================================
-- SECTION 5: DEFAULT PRIVILEGES
-- =====================================

-- Set default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;

-- =====================================
-- SECTION 6: EDGE FUNCTION SPECIFIC POLICIES
-- =====================================

-- Create a more permissive policy for profiles to support matching
DROP POLICY IF EXISTS "Emergency profiles access for matching" ON public.profiles;
CREATE POLICY "Profiles accessible for matching" ON public.profiles
    FOR SELECT USING (
        -- Service role always has access
        auth.role() = 'service_role' OR
        -- Authenticated users can view completed profiles
        (auth.role() = 'authenticated' AND onboarding_completed = true) OR
        -- Users can always view their own profile
        (auth.role() = 'authenticated' AND auth.uid() = id)
    );

-- Ensure users table is accessible for edge functions
CREATE POLICY "Users accessible for edge functions" ON public.users
    FOR SELECT USING (
        auth.role() = 'service_role' OR
        auth.uid() = id
    );

-- =====================================
-- SECTION 7: VERIFICATION
-- =====================================

-- Verify permissions are correctly set
DO $$
DECLARE
    perm_count INTEGER;
BEGIN
    -- Check service role has table permissions
    SELECT COUNT(*) INTO perm_count
    FROM information_schema.table_privileges 
    WHERE grantee = 'service_role' 
    AND table_schema = 'public'
    AND privilege_type = 'SELECT';
    
    RAISE NOTICE 'Service role has SELECT permission on % tables', perm_count;
    
    -- Check function permissions
    SELECT COUNT(*) INTO perm_count
    FROM information_schema.routine_privileges 
    WHERE grantee = 'service_role' 
    AND routine_schema = 'public';
    
    RAISE NOTICE 'Service role has EXECUTE permission on % functions', perm_count;
END $$;

-- Add comment documenting this fix
COMMENT ON SCHEMA public IS 'Service role permissions updated for edge function compatibility - 2025-07-19';

-- Final status
SELECT 'Service Role Permissions Fix Applied Successfully' as status;