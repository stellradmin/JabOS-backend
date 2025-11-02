-- STELLR PRODUCTION SECURITY: Secure RLS Policies Implementation
-- Implements least-privilege access principles replacing overly permissive policies

-- Drop all overly permissive policies that allow any authenticated user access
DROP POLICY IF EXISTS "Profiles are viewable by authenticated users" ON public.profiles;
DROP POLICY IF EXISTS "Users can manage own data" ON public.users;
DROP POLICY IF EXISTS "Conversations for participants" ON public.conversations;
DROP POLICY IF EXISTS "Matches for participants" ON public.matches;
DROP POLICY IF EXISTS "Messages for conversation participants" ON public.messages;
DROP POLICY IF EXISTS "Swipes for participants" ON public.swipes;
DROP POLICY IF EXISTS "Audit logs for authenticated users" ON public.audit_logs;
DROP POLICY IF EXISTS "Emergency profiles access for matching" ON public.profiles;

-- =============================================================================
-- PROFILES TABLE: Secure profile access with proper restrictions
-- =============================================================================

CREATE POLICY "profiles_select_own" ON public.profiles
    FOR SELECT USING (
        auth.uid() = id
    );

CREATE POLICY "profiles_select_for_matching" ON public.profiles
    FOR SELECT USING (
        -- Service role has full access for system operations
        auth.role() = 'service_role' OR
        -- Users can view profiles they haven't already swiped on AND are eligible to match with
        (
            auth.uid() != id AND
            onboarding_completed = true AND
            -- Must not have already swiped on this user
            NOT EXISTS (
                SELECT 1 FROM public.swipes
                WHERE swiper_id = auth.uid() AND swiped_id = id
            ) AND
            -- Basic eligibility checks (age, gender preferences from viewer's settings)
            (
                (
                    NOT EXISTS (SELECT 1 FROM public.user_settings WHERE user_id = auth.uid()) OR
                    EXISTS (
                        SELECT 1 FROM public.user_settings us
                        WHERE us.user_id = auth.uid()
                        AND (us.gender_preference IS NULL OR us.gender_preference = 'all' OR us.gender_preference = gender)
                    )
                ) AND
                (age BETWEEN 18 AND 100) -- Basic age validation
            )
        )
    );

CREATE POLICY "profiles_update_own" ON public.profiles
    FOR UPDATE USING (
        auth.uid() = id
    );

CREATE POLICY "profiles_insert_own" ON public.profiles
    FOR INSERT WITH CHECK (
        auth.uid() = id
    );

-- =============================================================================  
-- MATCHES TABLE: Only match participants can access their matches
-- =============================================================================

CREATE POLICY "matches_select_participant" ON public.matches
    FOR SELECT USING (
        auth.role() = 'service_role' OR
        auth.uid() = user1_id OR 
        auth.uid() = user2_id
    );

CREATE POLICY "matches_insert_service" ON public.matches
    FOR INSERT WITH CHECK (
        auth.role() = 'service_role'
    );

CREATE POLICY "matches_update_participants" ON public.matches
    FOR UPDATE USING (
        auth.role() = 'service_role' OR
        (auth.uid() = user1_id OR auth.uid() = user2_id)
    );

-- =============================================================================
-- SWIPES TABLE: Users can only see their own swipes
-- =============================================================================

CREATE POLICY "swipes_select_own" ON public.swipes
    FOR SELECT USING (
        auth.role() = 'service_role' OR
        auth.uid() = swiper_id
    );

CREATE POLICY "swipes_insert_own" ON public.swipes
    FOR INSERT WITH CHECK (
        auth.uid() = swiper_id
    );

-- Users cannot update or delete swipes (immutable record)

-- =============================================================================
-- MATCH_REQUESTS TABLE: Requester and target can access their requests
-- =============================================================================

CREATE POLICY "match_requests_select_involved" ON public.match_requests
    FOR SELECT USING (
        auth.role() = 'service_role' OR
        auth.uid() = requester_id OR
        auth.uid() = matched_user_id
    );

CREATE POLICY "match_requests_insert_own" ON public.match_requests
    FOR INSERT WITH CHECK (
        auth.uid() = requester_id
    );

CREATE POLICY "match_requests_update_target" ON public.match_requests
    FOR UPDATE USING (
        auth.role() = 'service_role' OR
        -- Only the target can update to accept/reject
        auth.uid() = matched_user_id
    );

-- =============================================================================
-- CONVERSATIONS TABLE: Only conversation participants have access  
-- =============================================================================

CREATE POLICY "conversations_select_participants" ON public.conversations
    FOR SELECT USING (
        auth.role() = 'service_role' OR
        auth.uid() = user1_id OR
        auth.uid() = user2_id
    );

CREATE POLICY "conversations_insert_service" ON public.conversations
    FOR INSERT WITH CHECK (
        auth.role() = 'service_role'
    );

CREATE POLICY "conversations_update_participants" ON public.conversations
    FOR UPDATE USING (
        auth.role() = 'service_role' OR
        (auth.uid() = user1_id OR auth.uid() = user2_id)
    );

-- =============================================================================
-- MESSAGES TABLE: Only conversation participants can access messages
-- =============================================================================

CREATE POLICY "messages_select_conversation_participants" ON public.messages
    FOR SELECT USING (
        auth.role() = 'service_role' OR
        EXISTS (
            SELECT 1 FROM public.conversations c 
            WHERE c.id = conversation_id 
            AND (c.user1_id = auth.uid() OR c.user2_id = auth.uid())
        )
    );

CREATE POLICY "messages_insert_conversation_participants" ON public.messages
    FOR INSERT WITH CHECK (
        -- Must be a participant of the conversation
        EXISTS (
            SELECT 1 FROM public.conversations c 
            WHERE c.id = conversation_id 
            AND (c.user1_id = auth.uid() OR c.user2_id = auth.uid())
        ) AND
        -- Message sender must be the authenticated user
        sender_id = auth.uid()
    );

-- Messages are immutable - no update/delete policies

-- =============================================================================
-- ENCRYPTED_BIRTH_DATA TABLE: Only user can access their own encrypted data
-- NOTE: Table created in production only (SKIP_LOCAL_DEV migration)
-- =============================================================================

-- Skip for local development - table doesn't exist
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'encrypted_birth_data') THEN
        EXECUTE 'CREATE POLICY "encrypted_birth_data_select_own" ON public.encrypted_birth_data
            FOR SELECT USING (
                auth.role() = ''service_role'' OR
                auth.uid() = user_id
            )';

        EXECUTE 'CREATE POLICY "encrypted_birth_data_insert_own" ON public.encrypted_birth_data
            FOR INSERT WITH CHECK (
                auth.uid() = user_id
            )';

        EXECUTE 'CREATE POLICY "encrypted_birth_data_update_own" ON public.encrypted_birth_data
            FOR UPDATE USING (
                auth.role() = ''service_role'' OR
                auth.uid() = user_id
            )';
    END IF;
END $$;

-- =============================================================================
-- AUDIT_LOGS TABLE: Service role only for security logging
-- =============================================================================

-- Remove user access to audit logs - security sensitive
CREATE POLICY "audit_logs_service_only" ON public.audit_logs
    FOR ALL USING (
        auth.role() = 'service_role'
    );

-- =============================================================================
-- DATE_PROPOSALS TABLE: Only involved users can access proposals
-- NOTE: May not exist in all environments
-- =============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'date_proposals') THEN
        EXECUTE 'CREATE POLICY "date_proposals_select_involved" ON public.date_proposals
            FOR SELECT USING (
                auth.role() = ''service_role'' OR
                EXISTS (
                    SELECT 1 FROM public.conversations c
                    WHERE c.id = conversation_id
                    AND (c.user1_id = auth.uid() OR c.user2_id = auth.uid())
                )
            )';

        EXECUTE 'CREATE POLICY "date_proposals_insert_conversation_participant" ON public.date_proposals
            FOR INSERT WITH CHECK (
                EXISTS (
                    SELECT 1 FROM public.conversations c
                    WHERE c.id = conversation_id
                    AND (c.user1_id = auth.uid() OR c.user2_id = auth.uid())
                ) AND
                proposer_id = auth.uid()
            )';

        EXECUTE 'CREATE POLICY "date_proposals_update_participants" ON public.date_proposals
            FOR UPDATE USING (
                auth.role() = ''service_role'' OR
                EXISTS (
                    SELECT 1 FROM public.conversations c
                    WHERE c.id = conversation_id
                    AND (c.user1_id = auth.uid() OR c.user2_id = auth.uid())
                )
            )';
    END IF;
END $$;

-- =============================================================================
-- SECURITY AUDIT: Verify no overly permissive policies remain
-- =============================================================================

-- This query will help identify any remaining policies that allow broad access
-- Run this after migration to verify security:

/*
SELECT 
    schemaname,
    tablename, 
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies 
WHERE schemaname = 'public' 
AND (
    qual LIKE '%auth.role() = ''authenticated''%' OR
    with_check LIKE '%auth.role() = ''authenticated''%'
)
ORDER BY tablename, policyname;
*/

-- =============================================================================
-- PERFORMANCE OPTIMIZATION: Ensure proper indexes exist for RLS queries
-- =============================================================================

-- Index for efficient swipe checking in profiles policy
CREATE INDEX IF NOT EXISTS idx_swipes_swiper_swiped 
ON public.swipes (swiper_id, swiped_id);

-- Index for efficient conversation participant checking
CREATE INDEX IF NOT EXISTS idx_conversations_participants 
ON public.conversations (user1_id, user2_id);

-- Index for efficient match participant checking
CREATE INDEX IF NOT EXISTS idx_matches_participants 
ON public.matches (user1_id, user2_id);

-- Index for efficient message conversation checking
CREATE INDEX IF NOT EXISTS idx_messages_conversation 
ON public.messages (conversation_id, sender_id);

-- =============================================================================
-- SECURITY COMMENTS AND DOCUMENTATION
-- =============================================================================

COMMENT ON POLICY "profiles_select_for_matching" ON public.profiles IS 
'Allows users to view profiles for matching purposes with restrictions: no self-viewing, completed profiles only, no already-swiped users, basic eligibility checks';

COMMENT ON POLICY "matches_select_participant" ON public.matches IS 
'Match data only accessible to the two matched users and service role for system operations';

COMMENT ON POLICY "swipes_select_own" ON public.swipes IS 
'Users can only access their own swipe history, maintaining privacy of swipe actions';

COMMENT ON POLICY "audit_logs_service_only" ON public.audit_logs IS 
'Audit logs restricted to service role only for security monitoring and compliance';

-- End of secure RLS policies migration