-- CONSOLIDATE RLS POLICIES: Remove duplicates and simplify
-- Migration: consolidate_rls_policies
-- Date: 2025-01-16
-- Purpose: Clean up duplicate and overlapping RLS policies for better performance and clarity

-- =============================================================================
-- MATCHES TABLE - Consolidate 10+ policies into 4 clear policies
-- =============================================================================

-- Drop all existing policies on matches (including old and new policy names)
DROP POLICY IF EXISTS "Matches insertable by system" ON public.matches;
DROP POLICY IF EXISTS "Matches updatable by participants" ON public.matches;
DROP POLICY IF EXISTS "Matches viewable by participants" ON public.matches;
DROP POLICY IF EXISTS "No direct match deletion" ON public.matches;
DROP POLICY IF EXISTS "Service role can manage matches" ON public.matches;
DROP POLICY IF EXISTS "Service role has full access to matches" ON public.matches;
DROP POLICY IF EXISTS "System creates matches" ON public.matches;
DROP POLICY IF EXISTS "Users can select their own matches" ON public.matches;
DROP POLICY IF EXISTS "Users can update their matches" ON public.matches;
DROP POLICY IF EXISTS "Users can view their matches" ON public.matches;
-- Drop new consolidated policy names if they exist
DROP POLICY IF EXISTS "matches_select_policy" ON public.matches;
DROP POLICY IF EXISTS "matches_insert_policy" ON public.matches;
DROP POLICY IF EXISTS "matches_update_policy" ON public.matches;
DROP POLICY IF EXISTS "matches_delete_policy" ON public.matches;

-- Create consolidated, efficient RLS policies for matches

-- 1. SELECT: Users can view their own matches, service role can view all
CREATE POLICY "matches_select_policy" ON public.matches
    FOR SELECT
    USING (
        auth.role() = 'service_role'::text
        OR auth.uid() = user1_id
        OR auth.uid() = user2_id
    );

-- 2. INSERT: Only service role and security definer functions can create matches
-- Users cannot directly create matches - only via the confirm_system_match function
CREATE POLICY "matches_insert_policy" ON public.matches
    FOR INSERT
    WITH CHECK (auth.role() = 'service_role'::text);

-- 3. UPDATE: Users can update their own matches, service role can update all
CREATE POLICY "matches_update_policy" ON public.matches
    FOR UPDATE
    USING (
        auth.role() = 'service_role'::text
        OR auth.uid() = user1_id
        OR auth.uid() = user2_id
    )
    WITH CHECK (
        auth.role() = 'service_role'::text
        OR auth.uid() = user1_id
        OR auth.uid() = user2_id
    );

-- 4. DELETE: Nobody can delete matches directly (soft delete via status update instead)
CREATE POLICY "matches_delete_policy" ON public.matches
    FOR DELETE
    USING (false);

-- =============================================================================
-- CONVERSATIONS TABLE - Consolidate 7 policies into 4 clear policies
-- =============================================================================

-- Drop all existing policies on conversations (including old and new policy names)
DROP POLICY IF EXISTS "Conversations insertable by system" ON public.conversations;
DROP POLICY IF EXISTS "Conversations updatable by participants" ON public.conversations;
DROP POLICY IF EXISTS "Conversations viewable by participants" ON public.conversations;
DROP POLICY IF EXISTS "Service role can manage conversations" ON public.conversations;
DROP POLICY IF EXISTS "Users can select their own conversations" ON public.conversations;
DROP POLICY IF EXISTS "Users can update their own conversations" ON public.conversations;
DROP POLICY IF EXISTS "Users can view their conversations" ON public.conversations;
-- Drop new consolidated policy names if they exist
DROP POLICY IF EXISTS "conversations_select_policy" ON public.conversations;
DROP POLICY IF EXISTS "conversations_insert_policy" ON public.conversations;
DROP POLICY IF EXISTS "conversations_update_policy" ON public.conversations;
DROP POLICY IF EXISTS "conversations_delete_policy" ON public.conversations;

-- Create consolidated, efficient RLS policies for conversations

-- 1. SELECT: Users can view their own conversations, service role can view all
CREATE POLICY "conversations_select_policy" ON public.conversations
    FOR SELECT
    USING (
        auth.role() = 'service_role'::text
        OR auth.uid() = user1_id
        OR auth.uid() = user2_id
    );

-- 2. INSERT: Only service role and security definer functions can create conversations
CREATE POLICY "conversations_insert_policy" ON public.conversations
    FOR INSERT
    WITH CHECK (auth.role() = 'service_role'::text);

-- 3. UPDATE: Users can update their own conversations, service role can update all
CREATE POLICY "conversations_update_policy" ON public.conversations
    FOR UPDATE
    USING (
        auth.role() = 'service_role'::text
        OR auth.uid() = user1_id
        OR auth.uid() = user2_id
    )
    WITH CHECK (
        auth.role() = 'service_role'::text
        OR auth.uid() = user1_id
        OR auth.uid() = user2_id
    );

-- 4. DELETE: Nobody can delete conversations directly
CREATE POLICY "conversations_delete_policy" ON public.conversations
    FOR DELETE
    USING (false);

-- =============================================================================
-- MATCH_REQUESTS TABLE - Consolidate policies
-- =============================================================================

-- Drop existing policies on match_requests (including old and new policy names)
DROP POLICY IF EXISTS "Match requests own access" ON public.match_requests;
DROP POLICY IF EXISTS "Service role bypass RLS" ON public.match_requests;
DROP POLICY IF EXISTS "Service role has full access to match_requests" ON public.match_requests;
DROP POLICY IF EXISTS "Users can create match requests" ON public.match_requests;
DROP POLICY IF EXISTS "Users can delete their own match requests" ON public.match_requests;
DROP POLICY IF EXISTS "Users can update relevant match requests" ON public.match_requests;
DROP POLICY IF EXISTS "Users can view their match requests" ON public.match_requests;
-- Drop new consolidated policy names if they exist
DROP POLICY IF EXISTS "match_requests_select_policy" ON public.match_requests;
DROP POLICY IF EXISTS "match_requests_insert_policy" ON public.match_requests;
DROP POLICY IF EXISTS "match_requests_update_policy" ON public.match_requests;
DROP POLICY IF EXISTS "match_requests_delete_policy" ON public.match_requests;

-- Create consolidated, efficient RLS policies for match_requests

-- 1. SELECT: Users can view match requests they're involved in
CREATE POLICY "match_requests_select_policy" ON public.match_requests
    FOR SELECT
    USING (
        auth.role() = 'service_role'::text
        OR auth.uid() = requester_id
        OR auth.uid() = matched_user_id
    );

-- 2. INSERT: Users can create match requests where they are the requester
CREATE POLICY "match_requests_insert_policy" ON public.match_requests
    FOR INSERT
    WITH CHECK (
        auth.role() = 'service_role'::text
        OR (auth.uid() = requester_id AND requester_id <> matched_user_id)
    );

-- 3. UPDATE: Users can update match requests they're involved in
CREATE POLICY "match_requests_update_policy" ON public.match_requests
    FOR UPDATE
    USING (
        auth.role() = 'service_role'::text
        OR auth.uid() = requester_id
        OR auth.uid() = matched_user_id
    )
    WITH CHECK (
        auth.role() = 'service_role'::text
        OR auth.uid() = requester_id
        OR auth.uid() = matched_user_id
    );

-- 4. DELETE: Users can delete their own pending/rejected requests
CREATE POLICY "match_requests_delete_policy" ON public.match_requests
    FOR DELETE
    USING (
        auth.role() = 'service_role'::text
        OR (auth.uid() = requester_id AND status = ANY (ARRAY['pending'::text, 'rejected'::text]))
    );

-- Add comments documenting the policy structure
COMMENT ON POLICY "matches_select_policy" ON public.matches IS
'Users can view matches they are part of. Service role has full access.';

COMMENT ON POLICY "matches_insert_policy" ON public.matches IS
'Only service role and security definer functions can create matches. Direct user creation is blocked.';

COMMENT ON POLICY "conversations_select_policy" ON public.conversations IS
'Users can view conversations they are participants in. Service role has full access.';

COMMENT ON POLICY "conversations_insert_policy" ON public.conversations IS
'Only service role and security definer functions can create conversations.';
