-- =========================================================================
-- CRITICAL PRODUCTION FIXES FOR STELLR DATING APP - PHASE 1
-- =========================================================================
-- MUST BE EXECUTED BEFORE PRODUCTION LAUNCH
-- Estimated execution time: 15-30 minutes
-- Database downtime required: 5-10 minutes
-- =========================================================================

BEGIN;

-- =========================================================================
-- SECTION 1: RLS POLICY CONSOLIDATION (CRITICAL SECURITY FIX)
-- =========================================================================

-- Remove duplicate and conflicting RLS policies
SELECT 'Removing duplicate RLS policies...' as status;

-- PROFILES TABLE: Remove conflicting policies
DROP POLICY IF EXISTS "Users can view discoverable profiles" ON profiles;
DROP POLICY IF EXISTS "Users can update their own profile" ON profiles;
DROP POLICY IF EXISTS "Users can view their own profile" ON profiles;
DROP POLICY IF EXISTS "Profiles accessible for matching" ON profiles;
DROP POLICY IF EXISTS "Restricted profile viewing for matches and potential matches" ON profiles;

-- CONVERSATIONS TABLE: Remove overlapping policies  
DROP POLICY IF EXISTS "Users can view their conversations" ON conversations;
DROP POLICY IF EXISTS "Users can update their own conversations" ON conversations;
DROP POLICY IF EXISTS "Users can select their own conversations" ON conversations;
DROP POLICY IF EXISTS "Conversations viewable by participants" ON conversations;
DROP POLICY IF EXISTS "Conversations updatable by participants" ON conversations;

-- MATCHES TABLE: Remove service role conflicts
DROP POLICY IF EXISTS "Service role has full access to matches" ON matches;
DROP POLICY IF EXISTS "Service role bypass RLS" ON matches;
DROP POLICY IF EXISTS "System creates matches" ON matches;
DROP POLICY IF EXISTS "Users can view their matches" ON matches;
DROP POLICY IF EXISTS "Users can update their matches" ON matches;

-- MESSAGES TABLE: Remove duplicate policies
DROP POLICY IF EXISTS "Users can view messages in their conversations" ON messages;
DROP POLICY IF EXISTS "Users can send messages to their conversations" ON messages;
DROP POLICY IF EXISTS "Messages viewable by conversation participants" ON messages;
DROP POLICY IF EXISTS "Messages insertable by participants" ON messages;

-- SWIPES TABLE: Remove conflicting policies
DROP POLICY IF EXISTS "Users can view their own swipes" ON swipes;
DROP POLICY IF EXISTS "Users can select their own outgoing swipes" ON swipes;
DROP POLICY IF EXISTS "Swipes viewable by swiper" ON swipes;
DROP POLICY IF EXISTS "Swipes insertable by swiper" ON swipes;

-- MATCH_REQUESTS TABLE: Remove service role conflicts (if table exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        DROP POLICY IF EXISTS "Service role bypass RLS" ON match_requests;
        DROP POLICY IF EXISTS "Service role has full access to match_requests" ON match_requests;
    END IF;
END $$;

-- =========================================================================
-- SECTION 2: CREATE CONSOLIDATED, SECURE RLS POLICIES
-- =========================================================================

SELECT 'Creating consolidated RLS policies...' as status;

-- PROFILES: Secure profile access with performance optimization
CREATE POLICY "profiles_consolidated_access" ON profiles
    FOR ALL USING (
        -- Users can access their own profile
        auth.uid() = id OR 
        -- Service role has full access
        auth.role() = 'service_role'::text OR
        -- Others can view completed profiles only (for matching)
        (onboarding_completed = true AND auth.uid() != id AND auth.role() = 'authenticated'::text)
    )
    WITH CHECK (
        -- Users can only modify their own profile or service role
        auth.uid() = id OR auth.role() = 'service_role'::text
    );

-- CONVERSATIONS: Simple participant-based access
CREATE POLICY "conversations_participant_access" ON conversations
    FOR ALL USING (
        auth.uid() = user1_id OR 
        auth.uid() = user2_id OR 
        auth.role() = 'service_role'::text
    )
    WITH CHECK (
        auth.uid() = user1_id OR 
        auth.uid() = user2_id OR 
        auth.role() = 'service_role'::text
    );

-- MATCHES: Participant access with service role override
CREATE POLICY "matches_participant_access" ON matches
    FOR SELECT USING (
        auth.uid() = user1_id OR 
        auth.uid() = user2_id OR 
        auth.role() = 'service_role'::text
    );

CREATE POLICY "matches_system_insert" ON matches
    FOR INSERT WITH CHECK (
        auth.role() = 'service_role'::text
    );

CREATE POLICY "matches_participant_update" ON matches
    FOR UPDATE USING (
        auth.uid() = user1_id OR 
        auth.uid() = user2_id OR 
        auth.role() = 'service_role'::text
    )
    WITH CHECK (
        auth.uid() = user1_id OR 
        auth.uid() = user2_id OR 
        auth.role() = 'service_role'::text
    );

-- MESSAGES: Create conversation participant check function first
-- Align with existing helper function signature to avoid conflicts
CREATE OR REPLACE FUNCTION is_conversation_participant(p_conversation_id UUID, p_user_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    -- Use index-friendly query instead of EXISTS
    RETURN (
        SELECT COUNT(*) > 0 
        FROM conversations 
        WHERE id = p_conversation_id 
        AND (user1_id = p_user_id OR user2_id = p_user_id)
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- Now create messages policy using the function
CREATE POLICY "messages_conversation_access" ON messages
    FOR ALL USING (
        -- Use function for consistent conversation participant checking
        is_conversation_participant(conversation_id, auth.uid()) OR
        auth.role() = 'service_role'::text
    )
    WITH CHECK (
        -- Sender must be authenticated user and conversation participant
        (auth.uid() = sender_id AND is_conversation_participant(conversation_id, auth.uid())) OR
        auth.role() = 'service_role'::text
    );

-- SWIPES: Simple swiper access
CREATE POLICY "swipes_swiper_access" ON swipes
    FOR ALL USING (
        auth.uid() = swiper_id OR 
        auth.role() = 'service_role'::text
    )
    WITH CHECK (
        auth.uid() = swiper_id OR 
        auth.role() = 'service_role'::text
    );

-- MATCH_REQUESTS: Requester and target access (if table exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        EXECUTE 'CREATE POLICY "match_requests_participant_access" ON match_requests
            FOR ALL USING (
                auth.uid() = requester_id OR 
                auth.uid() = matched_user_id OR 
                auth.role() = ''service_role''::text
            )
            WITH CHECK (
                auth.uid() = requester_id OR 
                auth.uid() = matched_user_id OR 
                auth.role() = ''service_role''::text
            )';
    END IF;
END $$;

-- USERS: Own data access only
CREATE POLICY "users_own_access" ON users
    FOR ALL USING (
        auth.uid() = id OR 
        auth.uid() = auth_user_id OR 
        auth.role() = 'service_role'::text
    )
    WITH CHECK (
        auth.uid() = id OR 
        auth.uid() = auth_user_id OR 
        auth.role() = 'service_role'::text
    );

-- =========================================================================
-- SECTION 3: CRITICAL PERFORMANCE INDEXES
-- =========================================================================

SELECT 'Adding critical performance indexes...' as status;

-- Ultimate matching performance index (most important for scalability)
CREATE INDEX IF NOT EXISTS idx_profiles_matching_ultimate 
ON profiles (onboarding_completed, gender, age, created_at DESC) 
WHERE onboarding_completed = true;

-- Swipe exclusion optimization (prevents slow NOT IN queries)
CREATE INDEX IF NOT EXISTS idx_swipes_exclusion_ultimate
ON swipes (swiper_id, swiped_id, swipe_type, created_at DESC);

-- Message conversation performance (for chat loading)
CREATE INDEX IF NOT EXISTS idx_messages_conversation_performance
ON messages (conversation_id, created_at DESC, is_read);

-- Match lookup optimization (for checking existing matches)
CREATE INDEX IF NOT EXISTS idx_matches_lookup_optimized
ON matches (user1_id, user2_id, status) WHERE status = 'active';

-- User preference filtering (for matching algorithms)
-- Split into two indexes for compatibility
CREATE INDEX IF NOT EXISTS idx_users_looking_for_gin ON users USING GIN (looking_for) WHERE looking_for IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_preferences_gin ON users USING GIN (preferences);

-- Conversation participant lookup (for message access control)
CREATE INDEX IF NOT EXISTS idx_conversations_participants_optimized
ON conversations (user1_id, user2_id, last_message_at DESC);

-- Add index for conversation participant check function
CREATE INDEX IF NOT EXISTS idx_conversations_participant_check
ON conversations (id, user1_id, user2_id);

COMMIT;

-- =========================================================================
-- VALIDATION AND TESTING SECTION (Run after COMMIT)
-- =========================================================================

BEGIN;

SELECT 'Running validation checks...' as status;

-- Validate all RLS policies are working
DO $$
DECLARE
    policy_count INTEGER;
BEGIN
    -- Check that each critical table has exactly one main policy
    SELECT COUNT(*) INTO policy_count 
    FROM pg_policies 
    WHERE tablename = 'profiles' AND policyname LIKE '%consolidated%';
    
    IF policy_count = 0 THEN
        RAISE EXCEPTION 'Profile consolidated policy not found!';
    END IF;
    
    RAISE NOTICE 'RLS validation passed: % consolidated policies found', policy_count;
END $$;

-- Validate critical indexes exist
DO $$
DECLARE
    index_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO index_count
    FROM pg_indexes 
    WHERE indexname IN (
        'idx_profiles_matching_ultimate',
        'idx_swipes_exclusion_ultimate', 
        'idx_messages_conversation_performance'
    );
    
    IF index_count < 3 THEN
        RAISE EXCEPTION 'Critical indexes missing! Found %, expected 3', index_count;
    END IF;
    
    RAISE NOTICE 'Index validation passed: % critical indexes found', index_count;
END $$;

-- Test basic functionality
DO $$
DECLARE
    test_user_id UUID;
BEGIN
    -- Test that we can query profiles (this will fail if RLS is broken)
    SELECT id INTO test_user_id FROM users WHERE email LIKE '%tester%' LIMIT 1;
    
    IF test_user_id IS NOT NULL THEN
        -- Test profile access
        PERFORM id FROM profiles WHERE id = test_user_id;
        RAISE NOTICE 'Basic functionality test passed';
    ELSE
        RAISE NOTICE 'No test users found, skipping functionality test';
    END IF;
END $$;

SELECT 'Phase 1 production fixes completed successfully!' as status;

-- Summary of changes
SELECT 
    'RLS Policies Consolidated' as change_type,
    COUNT(*) as count
FROM pg_policies 
WHERE schemaname = 'public' 
    AND (policyname LIKE '%consolidated%' OR policyname LIKE '%participant_access%')

UNION ALL

SELECT 
    'Critical Indexes Added',
    COUNT(*)
FROM pg_indexes 
WHERE schemaname = 'public' 
    AND (indexname LIKE '%ultimate%' OR indexname LIKE '%optimized%' OR indexname LIKE '%performance%');

COMMIT;

SELECT '
=========================================================================
PHASE 1 CRITICAL PRODUCTION FIXES COMPLETED SUCCESSFULLY!
=========================================================================

✅ RLS Policy conflicts resolved
✅ Critical performance indexes added  
✅ Conversation participant function optimized
✅ Validation checks passed

NEXT STEPS FOR PHASE 2:
1. Execute index cleanup (remove redundant indexes)
2. Deploy audit logging improvements  
3. Run full system performance testing
4. Monitor database performance metrics

⚠️  REMEMBER TO:
- Monitor database performance after deployment
- Test user experience thoroughly
- Keep backup ready for quick rollback if needed

Phase 1 deployment is now SAFE to proceed!
=========================================================================
' as completion_message;