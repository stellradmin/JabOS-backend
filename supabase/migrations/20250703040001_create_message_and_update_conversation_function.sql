-- Create the missing create_message_and_update_conversation RPC function
-- This function is called by the messaging tests and Edge functions

CREATE OR REPLACE FUNCTION public.create_message_and_update_conversation(
    p_conversation_id UUID,
    p_sender_id UUID,
    p_content TEXT,
    p_media_url TEXT DEFAULT NULL,
    p_media_type TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_message_id UUID;
    v_conversation_exists BOOLEAN;
    v_is_participant BOOLEAN;
BEGIN
    -- Check if conversation exists
    SELECT EXISTS(
        SELECT 1 FROM public.conversations 
        WHERE id = p_conversation_id
    ) INTO v_conversation_exists;
    
    IF NOT v_conversation_exists THEN
        RAISE EXCEPTION 'Conversation with id % does not exist', p_conversation_id;
    END IF;
    
    -- Check if sender is a participant in the conversation
    SELECT public.is_conversation_participant(p_conversation_id, p_sender_id) INTO v_is_participant;
    
    IF NOT v_is_participant THEN
        RAISE EXCEPTION 'User % is not a participant in conversation %', p_sender_id, p_conversation_id;
    END IF;
    
    -- Insert the new message
    INSERT INTO public.messages (
        conversation_id,
        sender_id,
        content,
        media_url,
        media_type,
        created_at
    )
    VALUES (
        p_conversation_id,
        p_sender_id,
        p_content,
        p_media_url,
        p_media_type,
        NOW()
    )
    RETURNING id INTO v_message_id;
    
    -- Update the conversation with last message info
    UPDATE public.conversations
    SET 
        last_message_preview = CASE 
            WHEN LENGTH(p_content) > 100 THEN LEFT(p_content, 100) || '...'
            ELSE p_content
        END,
        last_message_at = NOW(),
        updated_at = NOW()
    WHERE id = p_conversation_id;
    
    -- Return the created message ID
    RETURN v_message_id;
    
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Error in create_message_and_update_conversation: %', SQLERRM;
        RETURN NULL;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION public.create_message_and_update_conversation(UUID, UUID, TEXT, TEXT, TEXT) TO authenticated;

-- Add comment
COMMENT ON FUNCTION public.create_message_and_update_conversation(UUID, UUID, TEXT, TEXT, TEXT) IS 
'Creates a new message in a conversation and updates the conversation last message info. Returns the message ID. Supports optional media_url and media_type parameters.';