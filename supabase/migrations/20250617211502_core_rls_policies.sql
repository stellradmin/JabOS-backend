-- migrations/000Y_core_rls_policies.sql

-- Helper function to check if a user is part of a conversation
CREATE OR REPLACE FUNCTION is_conversation_participant(p_conversation_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.conversations
    WHERE id = p_conversation_id AND (participant_1_id = p_user_id OR participant_2_id = p_user_id)
  );
$$;
GRANT EXECUTE ON FUNCTION is_conversation_participant(uuid, uuid) TO authenticated;

-- Helper function to check if a user is part of a match
CREATE OR REPLACE FUNCTION is_match_participant(p_match_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.matches
    WHERE id = p_match_id AND (user1_id = p_user_id OR user2_id = p_user_id)
  );
$$;
GRANT EXECUTE ON FUNCTION is_match_participant(uuid, uuid) TO authenticated;


-- RLS Policies for 'profiles' table
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can select their own profile" ON public.profiles;
CREATE POLICY "Users can select their own profile"
    ON public.profiles FOR SELECT
    USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update their own profile" ON public.profiles;
CREATE POLICY "Users can update their own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

-- Policy for viewing other profiles (e.g., for matching screen)
-- This should be restrictive. Consider what columns are truly needed.
-- For example, only allow viewing if there's a potential match context or if profiles are public by design.
-- A more advanced version might use a SECURITY DEFINER function to check complex conditions.
DROP POLICY IF EXISTS "Authenticated users can view other profiles (limited)" ON public.profiles;
CREATE POLICY "Authenticated users can view other profiles (limited)"
    ON public.profiles FOR SELECT
    TO authenticated
    USING (true); -- This is broad. Refine based on app logic (e.g., only show profiles that are "discoverable" or part of a match pool)
                  -- For now, allowing select, but actual data exposure should be controlled by SELECT grants on columns or views.


-- RLS Policies for 'conversations' table
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can select their own conversations" ON public.conversations;
CREATE POLICY "Users can select their own conversations"
    ON public.conversations FOR SELECT
    USING (auth.uid() = participant_1_id OR auth.uid() = participant_2_id);

-- Inserts into conversations are typically handled by backend logic (e.g., when a match is made)
-- or by RPC functions like create_message_and_update_conversation.
-- Direct inserts by users might not be needed if conversations are system-created.
-- If users can initiate, ensure user_id is one of the participants.
-- For updates (e.g. last_message_at), this is handled by the create_message_and_update_conversation RPC.
-- Allowing general updates via RLS might be too permissive.

DROP POLICY IF EXISTS "Users can update their own conversation metadata (e.g. via RPC)" ON public.conversations;
CREATE POLICY "Users can update their own conversation metadata (e.g. via RPC)"
    ON public.conversations FOR UPDATE
    USING (auth.uid() = participant_1_id OR auth.uid() = participant_2_id)
    WITH CHECK (auth.uid() = participant_1_id OR auth.uid() = participant_2_id);


-- RLS Policies for 'messages' table
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can select messages from their conversations" ON public.messages;
CREATE POLICY "Users can select messages from their conversations"
    ON public.messages FOR SELECT
    USING (is_conversation_participant(conversation_id, auth.uid()));

DROP POLICY IF EXISTS "Users can insert messages into their conversations" ON public.messages;
CREATE POLICY "Users can insert messages into their conversations"
    ON public.messages FOR INSERT
    WITH CHECK (sender_id = auth.uid() AND is_conversation_participant(conversation_id, auth.uid()));

-- Users should generally not update or delete messages directly, unless specific features require it (e.g., edit/delete own message).
-- This would need more granular policies. For now, disallow direct update/delete.


-- RLS Policies for 'matches' table
ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can select their own matches" ON public.matches;
CREATE POLICY "Users can select their own matches"
    ON public.matches FOR SELECT
    USING (auth.uid() = user1_id OR auth.uid() = user2_id);

-- Match creation is handled by record_swipe EF. Updates (e.g. status) might also be via EFs or RPCs.
-- Direct insert/update by users is likely not intended.


-- RLS Policies for 'swipes' table
ALTER TABLE public.swipes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can insert their own swipes" ON public.swipes;
CREATE POLICY "Users can insert their own swipes"
    ON public.swipes FOR INSERT
    WITH CHECK (swiper_id = auth.uid());

DROP POLICY IF EXISTS "Users can select their own outgoing swipes" ON public.swipes;
CREATE POLICY "Users can select their own outgoing swipes"
    ON public.swipes FOR SELECT
    USING (swiper_id = auth.uid());

-- Users should not be able to see who swiped on them directly via this table for privacy,
-- unless it results in a match. They also shouldn't update/delete swipes.

COMMENT ON POLICY "Authenticated users can view other profiles (limited)" ON public.profiles IS
'Allows authenticated users to view profiles. This is a broad policy and should be reviewed. Data exposure should be controlled by specific SELECT column permissions in functions/views or by refining the USING clause based on discoverability logic.';
