-- ============================================================================
-- Unmatch and Conversation Deletion Migration
-- ============================================================================
-- Implements soft delete for audit trails and proper cascade deletion
-- Following security best practices for dating app data management

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Add Soft Delete Columns to Existing Tables
-- ----------------------------------------------------------------------------

-- Add soft delete columns to matches table
ALTER TABLE public.matches
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ DEFAULT NULL,
ADD COLUMN IF NOT EXISTS deleted_by UUID REFERENCES public.users(id),
ADD COLUMN IF NOT EXISTS deletion_reason TEXT CHECK (
    deletion_reason IN (
        'user_unmatch',
        'user_block',
        'admin_action',
        'policy_violation',
        'account_deletion'
    )
);

-- Add soft delete columns to conversations table
ALTER TABLE public.conversations
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ DEFAULT NULL,
ADD COLUMN IF NOT EXISTS deleted_by UUID REFERENCES public.users(id),
ADD COLUMN IF NOT EXISTS deletion_reason TEXT CHECK (
    deletion_reason IN (
        'user_deleted',
        'unmatch',
        'admin_action',
        'policy_violation',
        'account_deletion'
    )
),
ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ DEFAULT NULL,
ADD COLUMN IF NOT EXISTS archived_by UUID REFERENCES public.users(id);

-- Add soft delete columns to messages table
ALTER TABLE public.messages
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ DEFAULT NULL,
ADD COLUMN IF NOT EXISTS deleted_for_sender BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS deleted_for_recipient BOOLEAN DEFAULT FALSE;

-- ----------------------------------------------------------------------------
-- 2. Create Deletion Audit Table
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.deletion_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type TEXT NOT NULL CHECK (entity_type IN ('match', 'conversation', 'message')),
    entity_id UUID NOT NULL,
    deleted_by UUID NOT NULL REFERENCES public.users(id),
    deletion_reason TEXT NOT NULL,
    deletion_metadata JSONB DEFAULT '{}'::jsonb,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for deletion audit
CREATE INDEX idx_deletion_audit_entity ON public.deletion_audit(entity_type, entity_id);
CREATE INDEX idx_deletion_audit_user ON public.deletion_audit(deleted_by);
CREATE INDEX idx_deletion_audit_created ON public.deletion_audit(created_at);

-- Enable RLS on deletion audit
ALTER TABLE public.deletion_audit ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 3. Create Unmatch Function with Proper Transaction Handling
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.unmatch_users(
    p_user_id UUID,
    p_other_user_id UUID,
    p_reason TEXT DEFAULT 'user_unmatch',
    p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_match_id UUID;
    v_conversation_id UUID;
    v_result JSONB;
BEGIN
    -- Validate input parameters
    IF p_user_id IS NULL OR p_other_user_id IS NULL THEN
        RAISE EXCEPTION 'Both user IDs are required' USING ERRCODE = '22000';
    END IF;

    IF p_user_id = p_other_user_id THEN
        RAISE EXCEPTION 'Cannot unmatch from yourself' USING ERRCODE = '22000';
    END IF;

    -- Verify the calling user is part of the match
    IF auth.uid() != p_user_id THEN
        RAISE EXCEPTION 'Unauthorized: Can only unmatch your own matches' USING ERRCODE = '42501';
    END IF;

    -- Find the match record
    SELECT id, conversation_id INTO v_match_id, v_conversation_id
    FROM public.matches
    WHERE deleted_at IS NULL
        AND status = 'active'
        AND ((user1_id = p_user_id AND user2_id = p_other_user_id)
             OR (user1_id = p_other_user_id AND user2_id = p_user_id))
    FOR UPDATE;

    IF v_match_id IS NULL THEN
        RAISE EXCEPTION 'Match not found or already deleted' USING ERRCODE = '02000';
    END IF;

    -- Start transaction block
    BEGIN
        -- 1. Soft delete the match
        UPDATE public.matches
        SET 
            deleted_at = NOW(),
            deleted_by = p_user_id,
            deletion_reason = p_reason,
            status = 'inactive',
            updated_at = NOW()
        WHERE id = v_match_id;

        -- 2. Soft delete the conversation if it exists
        IF v_conversation_id IS NOT NULL THEN
            UPDATE public.conversations
            SET 
                deleted_at = NOW(),
                deleted_by = p_user_id,
                deletion_reason = 'unmatch',
                updated_at = NOW()
            WHERE id = v_conversation_id;

            -- 3. Mark messages as deleted for the user who unmatched
            UPDATE public.messages
            SET 
                deleted_for_sender = CASE 
                    WHEN sender_id = p_user_id THEN TRUE 
                    ELSE deleted_for_sender 
                END,
                deleted_for_recipient = CASE 
                    WHEN sender_id != p_user_id THEN TRUE 
                    ELSE deleted_for_recipient 
                END,
                updated_at = NOW()
            WHERE conversation_id = v_conversation_id;
        END IF;

        -- 4. Create audit log entry
        INSERT INTO public.deletion_audit (
            entity_type,
            entity_id,
            deleted_by,
            deletion_reason,
            deletion_metadata,
            ip_address,
            user_agent
        ) VALUES (
            'match',
            v_match_id,
            p_user_id,
            p_reason,
            jsonb_build_object(
                'other_user_id', p_other_user_id,
                'conversation_id', v_conversation_id,
                'user_metadata', p_metadata
            ),
            inet_client_addr(),
            current_setting('request.headers', true)::json->>'user-agent'
        );

        -- Build success response
        v_result := jsonb_build_object(
            'success', true,
            'match_id', v_match_id,
            'conversation_id', v_conversation_id,
            'deleted_at', NOW(),
            'message', 'Successfully unmatched'
        );

        RETURN v_result;

    EXCEPTION
        WHEN OTHERS THEN
            -- Rollback will happen automatically
            RAISE;
    END;

END;
$$;

-- ----------------------------------------------------------------------------
-- 4. Create Delete Conversation Function
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.delete_conversation(
    p_conversation_id UUID,
    p_hard_delete BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID;
    v_conversation RECORD;
    v_result JSONB;
BEGIN
    -- Get authenticated user
    v_user_id := auth.uid();
    
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
    END IF;

    -- Verify user is part of the conversation
    SELECT * INTO v_conversation
    FROM public.conversations
    WHERE id = p_conversation_id
        AND deleted_at IS NULL
        AND (user1_id = v_user_id OR user2_id = v_user_id)
    FOR UPDATE;

    IF v_conversation IS NULL THEN
        RAISE EXCEPTION 'Conversation not found or unauthorized' USING ERRCODE = '02000';
    END IF;

    IF p_hard_delete THEN
        -- Hard delete (only for special cases, requires additional permissions)
        IF NOT EXISTS (
            SELECT 1 FROM public.user_roles ur
            JOIN public.roles r ON ur.role_id = r.id
            WHERE ur.user_id = v_user_id
                AND r.name IN ('admin', 'moderator')
                AND ur.is_active = true
        ) THEN
            RAISE EXCEPTION 'Insufficient permissions for hard delete' USING ERRCODE = '42501';
        END IF;

        DELETE FROM public.messages WHERE conversation_id = p_conversation_id;
        DELETE FROM public.conversations WHERE id = p_conversation_id;
        
        v_result := jsonb_build_object(
            'success', true,
            'conversation_id', p_conversation_id,
            'action', 'hard_delete',
            'message', 'Conversation permanently deleted'
        );
    ELSE
        -- Soft delete
        UPDATE public.conversations
        SET 
            deleted_at = NOW(),
            deleted_by = v_user_id,
            deletion_reason = 'user_deleted',
            updated_at = NOW()
        WHERE id = p_conversation_id;

        -- Mark messages as deleted for this user
        UPDATE public.messages
        SET 
            deleted_for_sender = CASE 
                WHEN sender_id = v_user_id THEN TRUE 
                ELSE deleted_for_sender 
            END,
            deleted_for_recipient = CASE 
                WHEN sender_id != v_user_id THEN TRUE 
                ELSE deleted_for_recipient 
            END,
            updated_at = NOW()
        WHERE conversation_id = p_conversation_id;

        -- Create audit log
        INSERT INTO public.deletion_audit (
            entity_type,
            entity_id,
            deleted_by,
            deletion_reason,
            deletion_metadata
        ) VALUES (
            'conversation',
            p_conversation_id,
            v_user_id,
            'user_deleted',
            jsonb_build_object(
                'soft_delete', true,
                'conversation_data', row_to_json(v_conversation)
            )
        );

        v_result := jsonb_build_object(
            'success', true,
            'conversation_id', p_conversation_id,
            'action', 'soft_delete',
            'deleted_at', NOW(),
            'message', 'Conversation deleted successfully'
        );
    END IF;

    RETURN v_result;
END;
$$;

-- ----------------------------------------------------------------------------
-- 5. Create Archive Conversation Function
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.archive_conversation(
    p_conversation_id UUID,
    p_archive BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID;
    v_result JSONB;
BEGIN
    v_user_id := auth.uid();
    
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
    END IF;

    -- Verify user is part of the conversation
    IF NOT EXISTS (
        SELECT 1 FROM public.conversations
        WHERE id = p_conversation_id
            AND deleted_at IS NULL
            AND (user1_id = v_user_id OR user2_id = v_user_id)
    ) THEN
        RAISE EXCEPTION 'Conversation not found or unauthorized' USING ERRCODE = '02000';
    END IF;

    IF p_archive THEN
        -- Archive the conversation
        UPDATE public.conversations
        SET 
            archived_at = NOW(),
            archived_by = v_user_id,
            updated_at = NOW()
        WHERE id = p_conversation_id;

        v_result := jsonb_build_object(
            'success', true,
            'conversation_id', p_conversation_id,
            'archived_at', NOW(),
            'message', 'Conversation archived'
        );
    ELSE
        -- Unarchive the conversation
        UPDATE public.conversations
        SET 
            archived_at = NULL,
            archived_by = NULL,
            updated_at = NOW()
        WHERE id = p_conversation_id;

        v_result := jsonb_build_object(
            'success', true,
            'conversation_id', p_conversation_id,
            'unarchived_at', NOW(),
            'message', 'Conversation unarchived'
        );
    END IF;

    RETURN v_result;
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. Update RLS Policies to Handle Soft Deletes
-- ----------------------------------------------------------------------------

-- Drop existing policies if they exist
DROP POLICY IF EXISTS "Users can view their own matches" ON public.matches;
DROP POLICY IF EXISTS "Users can view their conversations" ON public.conversations;
DROP POLICY IF EXISTS "Users can view their messages" ON public.messages;

-- Create new policies that respect soft deletes
CREATE POLICY "Users can view their active matches"
ON public.matches FOR SELECT
USING (
    deleted_at IS NULL
    AND (user1_id = auth.uid() OR user2_id = auth.uid())
);

CREATE POLICY "Users can view their active conversations"
ON public.conversations FOR SELECT
USING (
    deleted_at IS NULL
    AND (user1_id = auth.uid() OR user2_id = auth.uid())
);

CREATE POLICY "Users can view their non-deleted messages"
ON public.messages FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM public.conversations c
        WHERE c.id = messages.conversation_id
            AND c.deleted_at IS NULL
            AND (c.user1_id = auth.uid() OR c.user2_id = auth.uid())
    )
    AND NOT (
        (sender_id = auth.uid() AND deleted_for_sender = TRUE)
        OR (sender_id != auth.uid() AND deleted_for_recipient = TRUE)
    )
);

-- Deletion audit is admin/system only
CREATE POLICY "Only admins can view deletion audit"
ON public.deletion_audit FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM public.user_roles ur
        JOIN public.roles r ON ur.role_id = r.id
        WHERE ur.user_id = auth.uid()
            AND r.name IN ('admin', 'moderator')
            AND ur.is_active = true
    )
);

-- ----------------------------------------------------------------------------
-- 7. Create Indexes for Performance
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_matches_soft_delete 
ON public.matches(deleted_at) 
WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_conversations_soft_delete 
ON public.conversations(deleted_at) 
WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_conversations_archived 
ON public.conversations(archived_at) 
WHERE archived_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_messages_deletion_flags 
ON public.messages(conversation_id, deleted_for_sender, deleted_for_recipient);

-- ----------------------------------------------------------------------------
-- 8. Grant Necessary Permissions
-- ----------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.unmatch_users TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_conversation TO authenticated;
GRANT EXECUTE ON FUNCTION public.archive_conversation TO authenticated;

COMMIT;