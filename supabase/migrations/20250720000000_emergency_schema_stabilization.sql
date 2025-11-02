-- EMERGENCY SCHEMA STABILIZATION
-- Phase 1: Create missing tables and standardize column names
-- This migration addresses all critical schema issues identified in the audit

-- =====================================
-- SECTION 1: CREATE MISSING TABLES
-- =====================================

-- Create match_requests table that is referenced everywhere but missing
CREATE TABLE IF NOT EXISTS public.match_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    matched_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'rejected', 'expired', 'active', 'cancelled')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '72 hours'),
    compatibility_score INTEGER,
    compatibility_details JSONB DEFAULT '{}'::jsonb,
    
    -- Prevent duplicate requests
    UNIQUE(requester_id, matched_user_id),
    -- Prevent self-requests
    CHECK (requester_id != matched_user_id)
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_match_requests_requester_id ON public.match_requests(requester_id);
CREATE INDEX IF NOT EXISTS idx_match_requests_matched_user_id ON public.match_requests(matched_user_id);
CREATE INDEX IF NOT EXISTS idx_match_requests_status ON public.match_requests(status);
CREATE INDEX IF NOT EXISTS idx_match_requests_created_at ON public.match_requests(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_match_requests_expires_at ON public.match_requests(expires_at);

-- Add updated_at trigger
CREATE TRIGGER set_updated_at_match_requests
    BEFORE UPDATE ON public.match_requests
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_updated_at();

-- =====================================
-- SECTION 2: CREATE MATCHES TABLE
-- =====================================

-- Create matches table with standardized column names
CREATE TABLE IF NOT EXISTS public.matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Standardized column names
    user1_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    user2_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    -- Link to match request
    match_request_id UUID REFERENCES public.match_requests(id) ON DELETE SET NULL,
    -- Link to conversation
    conversation_id UUID REFERENCES public.conversations(id) ON DELETE SET NULL,
    -- Match details
    matched_at TIMESTAMPTZ DEFAULT NOW(),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'blocked')),
    -- Compatibility scores
    compatibility_score INTEGER,
    astro_compatibility JSONB DEFAULT '{}'::jsonb,
    questionnaire_compatibility JSONB DEFAULT '{}'::jsonb,
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Ensure users are ordered consistently (user1_id < user2_id)
    CHECK (user1_id < user2_id),
    -- Prevent duplicate matches
    UNIQUE(user1_id, user2_id)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_matches_user1_id ON public.matches(user1_id);
CREATE INDEX IF NOT EXISTS idx_matches_user2_id ON public.matches(user2_id);
CREATE INDEX IF NOT EXISTS idx_matches_conversation_id ON public.matches(conversation_id);
CREATE INDEX IF NOT EXISTS idx_matches_match_request_id ON public.matches(match_request_id);
CREATE INDEX IF NOT EXISTS idx_matches_matched_at ON public.matches(matched_at DESC);
CREATE INDEX IF NOT EXISTS idx_matches_status ON public.matches(status);

-- Add updated_at trigger
CREATE TRIGGER set_updated_at_matches
    BEFORE UPDATE ON public.matches
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_updated_at();

-- =====================================
-- SECTION 3: FIX CONVERSATIONS TABLE
-- =====================================

-- Add missing columns to conversations if they don't exist
ALTER TABLE public.conversations 
ADD COLUMN IF NOT EXISTS match_id UUID REFERENCES public.match_requests(id) ON DELETE SET NULL;

ALTER TABLE public.conversations 
ADD COLUMN IF NOT EXISTS unread_counts JSONB DEFAULT '{}'::jsonb;

-- Create index for match_id
CREATE INDEX IF NOT EXISTS idx_conversations_match_id ON public.conversations(match_id);

-- =====================================
-- SECTION 4: CREATE HELPER FUNCTIONS
-- =====================================

-- Function to get or create a match between two users
CREATE OR REPLACE FUNCTION public.get_or_create_match(
    p_user1_id UUID,
    p_user2_id UUID,
    p_match_request_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_match_id UUID;
    v_ordered_user1 UUID;
    v_ordered_user2 UUID;
BEGIN
    -- Order users consistently
    IF p_user1_id < p_user2_id THEN
        v_ordered_user1 := p_user1_id;
        v_ordered_user2 := p_user2_id;
    ELSE
        v_ordered_user1 := p_user2_id;
        v_ordered_user2 := p_user1_id;
    END IF;
    
    -- Try to get existing match
    SELECT id INTO v_match_id
    FROM public.matches
    WHERE user1_id = v_ordered_user1 AND user2_id = v_ordered_user2;
    
    -- Create new match if doesn't exist
    IF v_match_id IS NULL THEN
        INSERT INTO public.matches (user1_id, user2_id, match_request_id)
        VALUES (v_ordered_user1, v_ordered_user2, p_match_request_id)
        RETURNING id INTO v_match_id;
    END IF;
    
    RETURN v_match_id;
END;
$$;

-- Function to check if two users have matched
CREATE OR REPLACE FUNCTION public.check_mutual_match(
    p_user1_id UUID,
    p_user2_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mutual_likes BOOLEAN;
BEGIN
    -- Check if both users have liked each other
    SELECT EXISTS (
        SELECT 1 FROM public.swipes 
        WHERE swiper_id = p_user1_id 
        AND swiped_id = p_user2_id 
        AND swipe_type = 'like'
    ) AND EXISTS (
        SELECT 1 FROM public.swipes 
        WHERE swiper_id = p_user2_id 
        AND swiped_id = p_user1_id 
        AND swipe_type = 'like'
    ) INTO v_mutual_likes;
    
    RETURN v_mutual_likes;
END;
$$;

-- =====================================
-- SECTION 5: ADD COMMENTS
-- =====================================

COMMENT ON TABLE public.match_requests IS 'Tracks match requests between users with expiration and status';
COMMENT ON TABLE public.matches IS 'Confirmed matches between users with compatibility scores';
COMMENT ON COLUMN public.matches.user1_id IS 'First user in match (always lower UUID for consistency)';
COMMENT ON COLUMN public.matches.user2_id IS 'Second user in match (always higher UUID for consistency)';

-- =====================================
-- SECTION 6: DATA MIGRATION
-- =====================================

-- Migrate any existing match data to standardized format
-- This is a placeholder - adjust based on your existing data

-- =====================================
-- SECTION 7: GRANT PERMISSIONS
-- =====================================

-- Grant necessary permissions
GRANT ALL ON public.match_requests TO authenticated;
GRANT ALL ON public.matches TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_or_create_match TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_mutual_match TO authenticated;