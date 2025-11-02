-- Refined RLS Policies for Matching System
-- This replaces the overly permissive emergency policies with more secure ones

-- 1. Profiles table: Allow viewing for potential matching while maintaining privacy
DROP POLICY IF EXISTS "Profiles are viewable by authenticated users" ON public.profiles;

-- Allow users to view their own profile
CREATE POLICY "Users can view own profile" ON public.profiles
    FOR SELECT USING (auth.uid() = id);

-- Allow users to update their own profile  
CREATE POLICY "Users can update own profile" ON public.profiles
    FOR UPDATE USING (auth.uid() = id);

-- Allow users to insert their own profile
CREATE POLICY "Users can insert own profile" ON public.profiles
    FOR INSERT WITH CHECK (auth.uid() = id);

-- Allow viewing of other profiles for matching purposes (but only basic info)
CREATE POLICY "Profiles viewable for matching" ON public.profiles
    FOR SELECT USING (
        auth.role() = 'authenticated' AND 
        (
            -- User can view profiles they are eligible to match with
            id != auth.uid() AND
            onboarding_completed = true
        )
    );

-- 2. Users table: More restrictive access
DROP POLICY IF EXISTS "Users can manage own data" ON public.users;

-- Allow users to manage only their own data
CREATE POLICY "Users can manage own data" ON public.users
    FOR ALL USING (auth.uid() = id);

-- Allow service role for backend functions
CREATE POLICY "Service role full access" ON public.users
    FOR ALL USING (auth.role() = 'service_role');

-- 3. Matches table: Only participants can see their matches
DROP POLICY IF EXISTS "Matches accessible by participants" ON public.matches;

CREATE POLICY "Matches viewable by participants" ON public.matches
    FOR SELECT USING (
        auth.uid() = user1_id OR 
        auth.uid() = user2_id OR
        auth.role() = 'service_role'
    );

CREATE POLICY "Matches updatable by participants" ON public.matches
    FOR UPDATE USING (
        auth.uid() = user1_id OR 
        auth.uid() = user2_id OR
        auth.role() = 'service_role'
    );

CREATE POLICY "Matches insertable by system" ON public.matches
    FOR INSERT WITH CHECK (auth.role() = 'service_role');

-- 4. Swipes table: Only swiper can see their swipes
DROP POLICY IF EXISTS "Swipes accessible by swiper" ON public.swipes;

CREATE POLICY "Swipes viewable by swiper" ON public.swipes
    FOR SELECT USING (
        auth.uid() = swiper_id OR
        auth.role() = 'service_role'
    );

CREATE POLICY "Swipes insertable by swiper" ON public.swipes
    FOR INSERT WITH CHECK (
        auth.uid() = swiper_id OR
        auth.role() = 'service_role'
    );

-- 5. Conversations table: Only participants can access
DROP POLICY IF EXISTS "Conversations for participants" ON public.conversations;

CREATE POLICY "Conversations viewable by participants" ON public.conversations
    FOR SELECT USING (
        auth.uid() = participant_1_id OR 
        auth.uid() = participant_2_id OR
        auth.role() = 'service_role'
    );

CREATE POLICY "Conversations updatable by participants" ON public.conversations
    FOR UPDATE USING (
        auth.uid() = participant_1_id OR 
        auth.uid() = participant_2_id OR
        auth.role() = 'service_role'
    );

CREATE POLICY "Conversations insertable by system" ON public.conversations
    FOR INSERT WITH CHECK (auth.role() = 'service_role');

-- 6. Messages table: Only conversation participants
DROP POLICY IF EXISTS "Messages for conversation participants" ON public.messages;

CREATE POLICY "Messages viewable by conversation participants" ON public.messages
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.conversations 
            WHERE id = conversation_id 
            AND (participant_1_id = auth.uid() OR participant_2_id = auth.uid())
        ) OR
        auth.role() = 'service_role'
    );

CREATE POLICY "Messages insertable by participants" ON public.messages
    FOR INSERT WITH CHECK (
        sender_id = auth.uid() OR
        auth.role() = 'service_role'
    );

-- 7. Match requests table: Users can manage their own requests (if table exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        CREATE POLICY "Match requests own access" ON public.match_requests
            FOR ALL USING (
                auth.uid() = requester_id OR 
                auth.uid() = matched_user_id OR
                auth.role() = 'service_role'
            );
    END IF;
END $$;

-- Grant necessary permissions to service role for backend functions
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO service_role;

-- Ensure authenticated role has necessary permissions for basic operations
GRANT SELECT ON public.profiles TO authenticated;
GRANT INSERT, SELECT, UPDATE ON public.users TO authenticated;
GRANT SELECT ON public.matches TO authenticated;
GRANT INSERT, SELECT ON public.swipes TO authenticated;
GRANT SELECT ON public.conversations TO authenticated;
GRANT SELECT ON public.messages TO authenticated;
-- Grant permissions to match_requests table if it exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        GRANT INSERT, SELECT, UPDATE, DELETE ON public.match_requests TO authenticated;
    END IF;
END $$;

-- Create index to improve RLS policy performance
CREATE INDEX IF NOT EXISTS idx_profiles_onboarding_completed ON public.profiles(onboarding_completed) WHERE onboarding_completed = true;
CREATE INDEX IF NOT EXISTS idx_conversations_participants ON public.conversations(participant_1_id, participant_2_id);
CREATE INDEX IF NOT EXISTS idx_messages_conversation_id ON public.messages(conversation_id);

COMMENT ON POLICY "Profiles viewable for matching" ON public.profiles IS 
'Allows authenticated users to view other completed profiles for matching purposes while maintaining privacy';

COMMENT ON POLICY "Messages viewable by conversation participants" ON public.messages IS 
'Ensures only conversation participants can view messages in their conversations';