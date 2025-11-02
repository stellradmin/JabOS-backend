-- ==========================================
-- FIX USER_BLOCKS RLS PERMISSION ISSUE
-- ==========================================
-- Problem: The profiles RLS policy needs to check user_blocks to filter out blocked users,
-- but the existing user_blocks RLS policy only allows users to see their OWN blocks.
-- This causes "permission denied for table user_blocks" errors when querying profiles.
--
-- Solution: Add a policy that allows authenticated users to check if they are blocked by others.
-- This is safe because:
-- 1. Users can only see if THEY are blocked (blocked_user_id = auth.uid())
-- 2. Users cannot see who blocked them (blocking_user_id is not exposed)
-- 3. This is necessary for the profiles discovery policy to work correctly
-- ==========================================

-- Drop the existing overly restrictive policy
DROP POLICY IF EXISTS "Users can view their own blocks" ON user_blocks;

-- Create two separate policies:
-- 1. Users can see blocks they created (who they blocked)
CREATE POLICY "Users can view blocks they created" ON user_blocks
    FOR SELECT
    USING (blocking_user_id = auth.uid());

-- 2. Users can check if they are blocked (needed for profiles discovery policy)
CREATE POLICY "Users can check if they are blocked" ON user_blocks
    FOR SELECT
    USING (blocked_user_id = auth.uid());

-- Verify the policies were created
DO $$
DECLARE
    policy_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO policy_count
    FROM pg_policies
    WHERE schemaname = 'public'
    AND tablename = 'user_blocks'
    AND policyname IN ('Users can view blocks they created', 'Users can check if they are blocked');

    IF policy_count = 2 THEN
        RAISE NOTICE '✅ user_blocks RLS policies created successfully';
    ELSE
        RAISE WARNING '⚠️ Expected 2 policies, but found %', policy_count;
    END IF;
END $$;
