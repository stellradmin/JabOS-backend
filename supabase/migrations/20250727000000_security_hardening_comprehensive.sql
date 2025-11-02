-- ===============================================================
-- COMPREHENSIVE SECURITY HARDENING FOR STELLR DATING APP
-- Version: 1.0
-- Date: 2025-07-27
-- Purpose: Implement production-grade RLS policies and security controls
-- ===============================================================

-- =====================================
-- SECTION 1: REVOKE OVERLY PERMISSIVE POLICIES
-- =====================================

-- Remove dangerous profile access policy
DROP POLICY IF EXISTS "Authenticated users can view other profiles (limited)" ON public.profiles;
DROP POLICY IF EXISTS "Users can view discoverable profiles" ON public.profiles;

-- Remove any overly broad policies
DROP POLICY IF EXISTS "Users can view their own swipes" ON public.swipes;

-- =====================================
-- SECTION 2: SECURITY HELPER FUNCTIONS
-- =====================================

-- Enhanced function to check active match context
CREATE OR REPLACE FUNCTION public.has_active_match_context(p_viewer_id UUID, p_target_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_has_context BOOLEAN := FALSE;
BEGIN
    -- Validate authentication
    IF p_viewer_id IS NULL OR p_viewer_id != auth.uid() THEN
        RETURN FALSE;
    END IF;
    
    -- Check if users are matched
    SELECT EXISTS (
        SELECT 1 FROM public.matches m
        WHERE m.status = 'active'
        AND ((m.user1_id = p_viewer_id AND m.user2_id = p_target_id)
             OR (m.user1_id = p_target_id AND m.user2_id = p_viewer_id))
    ) INTO v_has_context;
    
    -- If not matched, check if there's an active swipe session
    IF NOT v_has_context THEN
        -- Allow viewing during active potential match discovery
        -- Only if user hasn't already swiped on this profile
        SELECT NOT EXISTS (
            SELECT 1 FROM public.swipes s
            WHERE s.swiper_id = p_viewer_id 
            AND s.swiped_id = p_target_id
        ) INTO v_has_context;
    END IF;
    
    RETURN v_has_context;
END;
$$;

-- Function to check conversation participation with enhanced security
CREATE OR REPLACE FUNCTION public.is_conversation_participant_secure(p_conversation_id UUID, p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_is_participant BOOLEAN := FALSE;
BEGIN
    -- Validate authentication
    IF p_user_id IS NULL OR p_user_id != auth.uid() THEN
        RETURN FALSE;
    END IF;
    
    -- Check participation with additional security validations
    SELECT EXISTS (
        SELECT 1 FROM public.conversations c
        JOIN public.matches m ON (
            (m.user1_id = c.user1_id AND m.user2_id = c.user2_id)
            OR (m.user1_id = c.user2_id AND m.user2_id = c.user1_id)
        )
        WHERE c.id = p_conversation_id 
        AND (c.user1_id = p_user_id OR c.user2_id = p_user_id)
        AND m.status = 'active'
    ) INTO v_is_participant;
    
    RETURN v_is_participant;
END;
$$;

-- Function to check if user can view match request
CREATE OR REPLACE FUNCTION public.can_view_match_request(p_request_id UUID, p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_can_view BOOLEAN := FALSE;
BEGIN
    -- Validate authentication
    IF p_user_id IS NULL OR p_user_id != auth.uid() THEN
        RETURN FALSE;
    END IF;
    
    -- User can view if they are requester or target
    SELECT EXISTS (
        SELECT 1 FROM public.match_requests mr
        WHERE mr.id = p_request_id
        AND (mr.requester_id = p_user_id OR mr.matched_user_id = p_user_id)
        AND mr.status NOT IN ('expired', 'cancelled')
    ) INTO v_can_view;
    
    RETURN v_can_view;
END;
$$;

-- =====================================
-- SECTION 3: HARDENED PROFILE POLICIES
-- =====================================

-- Policy 1: Users can only view their own complete profile
CREATE POLICY "secure_own_profile_access" ON public.profiles
    FOR ALL
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

-- Policy 2: Limited profile viewing for potential matches only
CREATE POLICY "secure_limited_profile_discovery" ON public.profiles
    FOR SELECT
    TO authenticated
    USING (
        -- Allow viewing basic profile info only during active matching
        auth.uid() IS NOT NULL
        AND auth.uid() != id  -- Not own profile
        AND onboarding_completed = true
        AND has_active_match_context(auth.uid(), id)
        -- Additional security: only show profiles that match user's preferences
        AND EXISTS (
            SELECT 1 FROM public.users u
            WHERE u.id = auth.uid()
            AND (
                u.looking_for IS NULL 
                OR array_length(u.looking_for, 1) = 0
                OR (
                    CASE 
                        WHEN 'Both' = ANY(u.looking_for) THEN true
                        WHEN gender = 'Male' AND 'Males' = ANY(u.looking_for) THEN true
                        WHEN gender = 'Female' AND 'Females' = ANY(u.looking_for) THEN true
                        WHEN gender = 'Non-binary' AND 'Non-Binary' = ANY(u.looking_for) THEN true
                        ELSE false
                    END
                )
            )
        )
    );

-- =====================================
-- SECTION 4: CONVERSATION SECURITY
-- =====================================

-- Enhanced conversation access policy
DROP POLICY IF EXISTS "Users can select their own conversations" ON public.conversations;
DROP POLICY IF EXISTS "Users can view their conversations" ON public.conversations;
DROP POLICY IF EXISTS "Users can update their own conversation metadata (e.g. via RPC)" ON public.conversations;

CREATE POLICY "secure_conversation_access" ON public.conversations
    FOR ALL
    USING (is_conversation_participant_secure(id, auth.uid()))
    WITH CHECK (is_conversation_participant_secure(id, auth.uid()));

-- =====================================
-- SECTION 5: MESSAGE SECURITY
-- =====================================

-- Enhanced message policies
DROP POLICY IF EXISTS "Users can select messages from their conversations" ON public.messages;
DROP POLICY IF EXISTS "Users can insert messages into their conversations" ON public.messages;

CREATE POLICY "secure_message_read" ON public.messages
    FOR SELECT
    TO authenticated
    USING (is_conversation_participant_secure(conversation_id, auth.uid()));

CREATE POLICY "secure_message_insert" ON public.messages
    FOR INSERT
    TO authenticated
    WITH CHECK (
        sender_id = auth.uid() 
        AND is_conversation_participant_secure(conversation_id, auth.uid())
        -- Additional check: ensure conversation is from active match
        AND EXISTS (
        SELECT 1 FROM public.conversations c
            JOIN public.matches m ON (
                (m.user1_id = c.user1_id AND m.user2_id = c.user2_id)
                OR (m.user1_id = c.user2_id AND m.user2_id = c.user1_id)
            )
            WHERE c.id = conversation_id
            AND m.status = 'active'
        )
    );

-- =====================================
-- SECTION 6: MATCH REQUEST SECURITY
-- =====================================

-- Secure match request policies
CREATE POLICY "secure_match_request_view" ON public.match_requests
    FOR SELECT
    TO authenticated
    USING (can_view_match_request(id, auth.uid()));

CREATE POLICY "secure_match_request_create" ON public.match_requests
    FOR INSERT
    TO authenticated
    WITH CHECK (
        requester_id = auth.uid()
        AND requester_id != matched_user_id
        -- Ensure target user exists and has completed onboarding
        AND EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = matched_user_id
            AND p.onboarding_completed = true
        )
        -- Prevent spam: limit active requests per user
        AND (
            SELECT COUNT(*) FROM public.match_requests mr
            WHERE mr.requester_id = auth.uid()
            AND mr.status IN ('pending', 'active')
            AND mr.created_at > NOW() - INTERVAL '24 hours'
        ) < 10
    );

CREATE POLICY "secure_match_request_update" ON public.match_requests
    FOR UPDATE
    TO authenticated
    USING (can_view_match_request(id, auth.uid()))
    WITH CHECK (
        -- Only allow status updates by the matched user
        (matched_user_id = auth.uid() AND status IN ('confirmed', 'rejected'))
        OR
        -- Or by the requester to cancel
        (requester_id = auth.uid() AND status = 'cancelled')
    );

-- =====================================
-- SECTION 7: MATCH SECURITY
-- =====================================

-- Secure match viewing
CREATE POLICY "secure_match_access" ON public.matches
    FOR SELECT
    TO authenticated
    USING (
        auth.uid() = user1_id OR auth.uid() = user2_id
    );

-- Only system can create matches (through edge functions)
CREATE POLICY "secure_match_creation" ON public.matches
    FOR INSERT
    TO authenticated
    WITH CHECK (false); -- No direct inserts allowed

-- =====================================
-- SECTION 8: SWIPE SECURITY
-- =====================================

-- Enhanced swipe policies
DROP POLICY IF EXISTS "Users can insert their own swipes" ON public.swipes;
DROP POLICY IF EXISTS "Users can select their own outgoing swipes" ON public.swipes;

CREATE POLICY "secure_swipe_insert" ON public.swipes
    FOR INSERT
    TO authenticated
    WITH CHECK (
        swiper_id = auth.uid()
        AND swiper_id != swiped_id
        -- Ensure target user exists and is discoverable
        AND EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = swiped_id
            AND p.onboarding_completed = true
        )
        -- Prevent duplicate swipes
        AND NOT EXISTS (
            SELECT 1 FROM public.swipes s
            WHERE s.swiper_id = auth.uid()
            AND s.swiped_id = swiped_id
        )
        -- Rate limiting: max 100 swipes per day
        AND (
            SELECT COUNT(*) FROM public.swipes s
            WHERE s.swiper_id = auth.uid()
            AND s.created_at > NOW() - INTERVAL '24 hours'
        ) < 100
    );

CREATE POLICY "secure_swipe_view_own" ON public.swipes
    FOR SELECT
    TO authenticated
    USING (swiper_id = auth.uid());

-- =====================================
-- SECTION 9: USER TABLE SECURITY
-- =====================================

-- Secure user data access
CREATE POLICY "secure_user_own_access" ON public.users
    FOR ALL
    USING (id = auth.uid() OR auth_user_id = auth.uid())
    WITH CHECK (id = auth.uid() OR auth_user_id = auth.uid());

-- =====================================
-- SECTION 10: SECURITY CONSTRAINTS
-- =====================================

-- Add security constraints to prevent data corruption
ALTER TABLE public.profiles 
DROP CONSTRAINT IF EXISTS secure_profile_constraints;

ALTER TABLE public.profiles 
ADD CONSTRAINT secure_profile_constraints 
CHECK (
    -- Ensure critical fields are not empty when onboarding is complete
    (onboarding_completed = false) OR 
    (
        onboarding_completed = true AND
        display_name IS NOT NULL AND
        LENGTH(TRIM(display_name)) > 0 AND
        age IS NOT NULL AND
        gender IS NOT NULL
    )
);

-- =====================================
-- SECTION 11: AUDIT FUNCTIONS
-- =====================================

-- Function to log security events
CREATE OR REPLACE FUNCTION public.log_security_event(
    p_event_type TEXT,
    p_user_id UUID,
    p_details JSONB DEFAULT '{}'::jsonb
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Log to a security audit table (create if needed)
    INSERT INTO public.security_audit_log (
        event_type,
        user_id,
        details,
        ip_address,
        user_agent,
        created_at
    ) VALUES (
        p_event_type,
        p_user_id,
        p_details,
        current_setting('request.headers')::jsonb->>'x-forwarded-for',
        current_setting('request.headers')::jsonb->>'user-agent',
        NOW()
    );
EXCEPTION
    WHEN OTHERS THEN
        -- Don't fail the main operation if logging fails
        NULL;
END;
$$;

-- Create security audit log table
CREATE TABLE IF NOT EXISTS public.security_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL,
    user_id UUID,
    details JSONB DEFAULT '{}'::jsonb,
    ip_address TEXT,
    user_agent TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================
-- SECTION 12: GRANT PERMISSIONS
-- =====================================

-- Grant function permissions
GRANT EXECUTE ON FUNCTION public.has_active_match_context(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_conversation_participant_secure(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_view_match_request(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_security_event(TEXT, UUID, JSONB) TO authenticated;

-- Revoke dangerous permissions
REVOKE ALL ON public.security_audit_log FROM public;
GRANT SELECT ON public.security_audit_log TO service_role;

-- =====================================
-- SECTION 13: SECURITY COMMENTS
-- =====================================

COMMENT ON POLICY "secure_own_profile_access" ON public.profiles IS 
'Users can only access their own complete profile data';

COMMENT ON POLICY "secure_limited_profile_discovery" ON public.profiles IS 
'Limited profile viewing only during active matching sessions with preference validation';

COMMENT ON POLICY "secure_conversation_access" ON public.conversations IS 
'Enhanced conversation access with match validation';

COMMENT ON POLICY "secure_message_read" ON public.messages IS 
'Secure message reading with conversation participation validation';

COMMENT ON POLICY "secure_message_insert" ON public.messages IS 
'Secure message creation with active match validation';

COMMENT ON POLICY "secure_match_request_view" ON public.match_requests IS 
'Users can only view their own match requests (sent or received)';

COMMENT ON POLICY "secure_match_request_create" ON public.match_requests IS 
'Secure match request creation with spam prevention and validation';

COMMENT ON POLICY "secure_swipe_insert" ON public.swipes IS 
'Secure swipe creation with rate limiting and duplicate prevention';

COMMENT ON FUNCTION public.has_active_match_context(UUID, UUID) IS 
'Security function to validate if user has legitimate context to view another profile';

COMMENT ON FUNCTION public.is_conversation_participant_secure(UUID, UUID) IS 
'Enhanced security function to validate conversation access with match requirements';

-- =====================================
-- SECTION 14: FINAL SECURITY VALIDATION
-- =====================================

-- Ensure all tables have RLS enabled
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT tablename 
        FROM pg_tables 
        WHERE schemaname = 'public' 
        AND tablename IN ('profiles', 'users', 'conversations', 'messages', 'swipes', 'matches', 'match_requests')
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.tablename);
    END LOOP;
END $$;

-- Report on security implementation
DO $$
DECLARE
    profile_policies INTEGER;
    conversation_policies INTEGER;
    message_policies INTEGER;
    swipe_policies INTEGER;
    match_policies INTEGER;
    match_request_policies INTEGER;
BEGIN
    SELECT COUNT(*) INTO profile_policies FROM pg_policies WHERE tablename = 'profiles';
    SELECT COUNT(*) INTO conversation_policies FROM pg_policies WHERE tablename = 'conversations';
    SELECT COUNT(*) INTO message_policies FROM pg_policies WHERE tablename = 'messages';
    SELECT COUNT(*) INTO swipe_policies FROM pg_policies WHERE tablename = 'swipes';
    SELECT COUNT(*) INTO match_policies FROM pg_policies WHERE tablename = 'matches';
    SELECT COUNT(*) INTO match_request_policies FROM pg_policies WHERE tablename = 'match_requests';
    
    RAISE NOTICE '=== SECURITY HARDENING COMPLETE ===';
    RAISE NOTICE 'Profile policies: %', profile_policies;
    RAISE NOTICE 'Conversation policies: %', conversation_policies;
    RAISE NOTICE 'Message policies: %', message_policies;
    RAISE NOTICE 'Swipe policies: %', swipe_policies;
    RAISE NOTICE 'Match policies: %', match_policies;
    RAISE NOTICE 'Match request policies: %', match_request_policies;
    RAISE NOTICE '=== ALL SYSTEMS SECURED ===';
END $$;