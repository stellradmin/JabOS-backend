-- EMERGENCY RLS POLICIES FOR NEW TABLES
-- Secure but functional policies for match_requests and matches tables

-- =====================================
-- SECTION 1: ENABLE RLS
-- =====================================

-- Enable RLS for match_requests table if it exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        ALTER TABLE public.match_requests ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;

-- =====================================
-- SECTION 2: MATCH REQUESTS POLICIES (if table exists)
-- =====================================

-- Note: match_requests table doesn't exist in current schema
-- All policies for this table are commented out until table is created

/*
-- Users can view their own match requests (sent or received)
CREATE POLICY "Users can view their match requests"
    ON public.match_requests
    FOR SELECT
    USING (
        auth.uid() IN (requester_id, matched_user_id)
    );

-- Users can create match requests
CREATE POLICY "Users can create match requests"
    ON public.match_requests
    FOR INSERT
    WITH CHECK (
        auth.uid() = requester_id
        AND requester_id != matched_user_id
        -- Ensure no existing active request
        AND NOT EXISTS (
            SELECT 1 FROM public.match_requests mr
            WHERE mr.requester_id = requester_id
            AND mr.matched_user_id = matched_user_id
            AND mr.status IN ('pending', 'active')
        )
    );

-- Users can update their own requests or requests made to them
CREATE POLICY "Users can update relevant match requests"
    ON public.match_requests
    FOR UPDATE
    USING (
        auth.uid() IN (requester_id, matched_user_id)
    )
    WITH CHECK (
        auth.uid() IN (requester_id, matched_user_id)
    );

-- Users can delete their own requests
CREATE POLICY "Users can delete their own match requests"
    ON public.match_requests
    FOR DELETE
    USING (
        auth.uid() = requester_id
        AND status IN ('pending', 'rejected')
    );
*/

-- =====================================
-- SECTION 3: MATCHES POLICIES
-- =====================================

-- Users can view their own matches
CREATE POLICY "Users can view their matches"
    ON public.matches
    FOR SELECT
    USING (
        auth.uid() IN (user1_id, user2_id)
        AND status = 'active'
    );

-- Only system can create matches (through functions)
CREATE POLICY "System creates matches"
    ON public.matches
    FOR INSERT
    WITH CHECK (false);

-- Users can update their own matches (e.g., block)
CREATE POLICY "Users can update their matches"
    ON public.matches
    FOR UPDATE
    USING (
        auth.uid() IN (user1_id, user2_id)
    )
    WITH CHECK (
        auth.uid() IN (user1_id, user2_id)
    );

-- No direct delete on matches (use status update instead)
CREATE POLICY "No direct match deletion"
    ON public.matches
    FOR DELETE
    USING (false);

-- =====================================
-- SECTION 4: SERVICE ROLE POLICIES
-- =====================================

-- Service role has full access to match_requests (if table exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        -- Drop policy if it exists
        EXECUTE 'DROP POLICY IF EXISTS "Service role has full access to match_requests" ON public.match_requests';
        
        -- Create the policy
        EXECUTE 'CREATE POLICY "Service role has full access to match_requests"
            ON public.match_requests
            FOR ALL
            USING (auth.jwt()::jsonb ->> ''role'' = ''service_role'')
            WITH CHECK (auth.jwt()::jsonb ->> ''role'' = ''service_role'')';
    END IF;
END $$;

CREATE POLICY "Service role has full access to matches"
    ON public.matches
    FOR ALL
    USING (auth.jwt()::jsonb ->> 'role' = 'service_role')
    WITH CHECK (auth.jwt()::jsonb ->> 'role' = 'service_role');

-- =====================================
-- SECTION 5: FUNCTION PERMISSIONS
-- =====================================

-- Create function to safely create matches (bypasses RLS)
CREATE OR REPLACE FUNCTION public.create_match_from_request(
    p_match_request_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_match_id UUID;
    v_request RECORD;
    v_user1_id UUID;
    v_user2_id UUID;
BEGIN
    -- Get the match request
    SELECT * INTO v_request
    FROM public.match_requests
    WHERE id = p_match_request_id
    AND status = 'confirmed';
    
    IF v_request IS NULL THEN
        RAISE EXCEPTION 'Match request not found or not confirmed';
    END IF;
    
    -- Order users consistently
    IF v_request.requester_id < v_request.matched_user_id THEN
        v_user1_id := v_request.requester_id;
        v_user2_id := v_request.matched_user_id;
    ELSE
        v_user1_id := v_request.matched_user_id;
        v_user2_id := v_request.requester_id;
    END IF;
    
    -- Create the match
    INSERT INTO public.matches (
        user1_id, 
        user2_id, 
        match_request_id,
        compatibility_score,
        astro_compatibility,
        questionnaire_compatibility
    )
    VALUES (
        v_user1_id,
        v_user2_id,
        p_match_request_id,
        v_request.compatibility_score,
        COALESCE((v_request.compatibility_details->>'astro_compatibility')::jsonb, '{}'::jsonb),
        COALESCE((v_request.compatibility_details->>'questionnaire_compatibility')::jsonb, '{}'::jsonb)
    )
    ON CONFLICT (user1_id, user2_id) DO UPDATE
    SET 
        match_request_id = EXCLUDED.match_request_id,
        compatibility_score = EXCLUDED.compatibility_score,
        updated_at = NOW()
    RETURNING id INTO v_match_id;
    
    -- Update the match request status
    UPDATE public.match_requests
    SET status = 'active', updated_at = NOW()
    WHERE id = p_match_request_id;
    
    RETURN v_match_id;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.create_match_from_request TO authenticated;

-- =====================================
-- SECTION 6: COMMENTS
-- =====================================

-- Note: Comments for match_requests policies are commented out since the table doesn't exist
-- COMMENT ON POLICY "Users can view their match requests" ON public.match_requests IS 'Users can see requests they sent or received';
-- COMMENT ON POLICY "Users can create match requests" ON public.match_requests IS 'Users can create new match requests with validation';
COMMENT ON POLICY "Users can view their matches" ON public.matches IS 'Users can only see their active matches';
COMMENT ON POLICY "System creates matches" ON public.matches IS 'Matches are created through functions, not directly';