-- Fix conversations table column names to match RPC functions and ensure consistency
-- This migration renames participant_1_id/participant_2_id to user1_id/user2_id
-- CORRECTED VERSION: Properly handles function signature changes

-- ============================================================================
-- STEP 1: Rename columns in conversations table
-- ============================================================================

-- Check if we need to rename columns (only rename if old columns exist)
DO $$
BEGIN
    -- Rename participant_1_id to user1_id if it exists
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'conversations' 
        AND column_name = 'participant_1_id'
        AND table_schema = 'public'
    ) THEN
        ALTER TABLE public.conversations RENAME COLUMN participant_1_id TO user1_id;
        RAISE NOTICE 'Renamed participant_1_id to user1_id';
    ELSE
        RAISE NOTICE 'Column participant_1_id does not exist, skipping rename';
    END IF;
    
    -- Rename participant_2_id to user2_id if it exists
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'conversations' 
        AND column_name = 'participant_2_id'
        AND table_schema = 'public'
    ) THEN
        ALTER TABLE public.conversations RENAME COLUMN participant_2_id TO user2_id;
        RAISE NOTICE 'Renamed participant_2_id to user2_id';
    ELSE
        RAISE NOTICE 'Column participant_2_id does not exist, skipping rename';
    END IF;
END $$;

-- ============================================================================
-- STEP 2: Update RLS policies to use new column names
-- ============================================================================

-- Drop old policies that use participant_1_id/participant_2_id
DROP POLICY IF EXISTS "Users can select their own conversations" ON public.conversations;
DROP POLICY IF EXISTS "Users can update their own conversation metadata (e.g. via RPC)" ON public.conversations;
DROP POLICY IF EXISTS "Users can view their conversations" ON public.conversations;

-- Create new policies with correct column names
CREATE POLICY "Users can select their own conversations" 
    ON public.conversations FOR SELECT
    USING (auth.uid() = user1_id OR auth.uid() = user2_id);

CREATE POLICY "Users can update their own conversations" 
    ON public.conversations FOR UPDATE
    USING (auth.uid() = user1_id OR auth.uid() = user2_id);

CREATE POLICY "Users can view their conversations" 
    ON public.conversations FOR ALL
    USING (auth.uid() = user1_id OR auth.uid() = user2_id);

-- ============================================================================
-- STEP 3: Update helper functions - DROP and RECREATE to change signatures
-- ============================================================================

-- First, drop policies that depend on is_conversation_participant function
DROP POLICY IF EXISTS "Users can select messages from their conversations" ON public.messages;
DROP POLICY IF EXISTS "Users can insert messages into their conversations" ON public.messages;

-- Drop existing functions
DROP FUNCTION IF EXISTS is_conversation_participant(uuid, uuid);
DROP FUNCTION IF EXISTS get_user_conversations(UUID);

-- Create is_conversation_participant function
CREATE OR REPLACE FUNCTION is_conversation_participant(p_conversation_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.conversations
    WHERE id = p_conversation_id AND (user1_id = p_user_id OR user2_id = p_user_id)
  );
$$;

-- Create get_user_conversations function with correct signature
CREATE OR REPLACE FUNCTION get_user_conversations(p_user_id UUID)
RETURNS TABLE(
    id UUID,
    user1_id UUID,
    user2_id UUID,
    created_at TIMESTAMP WITH TIME ZONE,
    updated_at TIMESTAMP WITH TIME ZONE,
    last_message_at TIMESTAMP WITH TIME ZONE,
    last_message_content TEXT,
    other_participant JSONB
) 
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        c.id,
        c.user1_id,
        c.user2_id,
        c.created_at,
        c.updated_at,
        c.last_message_at,
        c.last_message_content,
        CASE 
            WHEN c.user1_id = p_user_id THEN 
                jsonb_build_object(
                    'id', p2.id,
                    'display_name', COALESCE(p2.display_name, 'Unknown'),
                    'avatar_url', p2.avatar_url
                )
            ELSE 
                jsonb_build_object(
                    'id', p1.id,
                    'display_name', COALESCE(p1.display_name, 'Unknown'),
                    'avatar_url', p1.avatar_url
                )
        END as other_participant
    FROM conversations c
    LEFT JOIN profiles p1 ON c.user1_id = p1.id
    LEFT JOIN profiles p2 ON c.user2_id = p2.id
    WHERE c.user1_id = p_user_id OR c.user2_id = p_user_id
    ORDER BY c.last_message_at DESC NULLS LAST;
END;
$$;

-- ============================================================================
-- STEP 4: Create/update indexes for new column names
-- ============================================================================

-- Drop old indexes if they exist
DROP INDEX IF EXISTS idx_conversations_participant_1_id;
DROP INDEX IF EXISTS idx_conversations_participant_2_id;

-- Create new indexes with correct column names
CREATE INDEX IF NOT EXISTS idx_conversations_user1_id ON public.conversations(user1_id);
CREATE INDEX IF NOT EXISTS idx_conversations_user2_id ON public.conversations(user2_id);

-- Create composite index for user lookups
CREATE INDEX IF NOT EXISTS idx_conversations_users ON public.conversations(user1_id, user2_id);

-- ============================================================================
-- STEP 5: Update column comments
-- ============================================================================

COMMENT ON COLUMN public.conversations.user1_id IS 'First user in conversation';
COMMENT ON COLUMN public.conversations.user2_id IS 'Second user in conversation';

-- ============================================================================
-- STEP 6: Recreate message policies that depend on is_conversation_participant
-- ============================================================================

-- Recreate message policies with the updated function
CREATE POLICY "Users can select messages from their conversations"
    ON public.messages FOR SELECT
    USING (is_conversation_participant(conversation_id, auth.uid()));

CREATE POLICY "Users can insert messages into their conversations"
    ON public.messages FOR INSERT
    WITH CHECK (is_conversation_participant(conversation_id, auth.uid()));

-- ============================================================================
-- STEP 7: Grant necessary permissions
-- ============================================================================

-- Ensure functions have proper permissions
GRANT EXECUTE ON FUNCTION is_conversation_participant(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_conversations(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_conversations(UUID) TO service_role;

-- ============================================================================
-- STEP 8: Validate the changes
-- ============================================================================

DO $$
BEGIN
    -- Verify that the new columns exist
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'conversations' 
        AND column_name = 'user1_id'
        AND table_schema = 'public'
    ) THEN
        RAISE EXCEPTION 'Column user1_id does not exist in conversations table';
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'conversations' 
        AND column_name = 'user2_id'
        AND table_schema = 'public'
    ) THEN
        RAISE EXCEPTION 'Column user2_id does not exist in conversations table';
    END IF;
    
    -- Verify functions exist
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p 
        JOIN pg_namespace n ON p.pronamespace = n.oid 
        WHERE n.nspname = 'public' 
        AND p.proname = 'get_user_conversations'
    ) THEN
        RAISE EXCEPTION 'Function get_user_conversations does not exist';
    END IF;
    
    RAISE NOTICE 'Conversations table column renaming completed successfully';
END $$;