-- Fix conversations table constraint and add missing confirm_system_match function
-- This addresses the user1_lt_user2 constraint violation

-- Step 1: Remove the problematic constraint if it exists
ALTER TABLE public.conversations DROP CONSTRAINT IF EXISTS user1_lt_user2;

-- Step 2: Add the missing confirm_system_match function with proper user ID ordering
CREATE OR REPLACE FUNCTION public.confirm_system_match(
    p_current_user_id UUID,
    p_target_user_id UUID,
    p_source_match_request_id UUID DEFAULT NULL
)
RETURNS TABLE(match_id UUID, conversation_id UUID)
LANGUAGE plpgsql
AS $$
DECLARE
    v_match_id UUID;
    v_conversation_id UUID;
    existing_match_id UUID;
    v_user1_id UUID;
    v_user2_id UUID;
BEGIN
    -- Ensure consistent user ordering for both matches and conversations
    IF p_current_user_id < p_target_user_id THEN
        v_user1_id := p_current_user_id;
        v_user2_id := p_target_user_id;
    ELSE
        v_user1_id := p_target_user_id;
        v_user2_id := p_current_user_id;
    END IF;
    
    -- Check if match already exists
    SELECT id INTO existing_match_id
    FROM public.matches
    WHERE (user1_id = v_user1_id AND user2_id = v_user2_id);
    
    IF existing_match_id IS NOT NULL THEN
        -- Match already exists, return existing data
        SELECT conversation_id INTO v_conversation_id
        FROM public.matches
        WHERE id = existing_match_id;
        
        RETURN QUERY SELECT existing_match_id, v_conversation_id;
        RETURN;
    END IF;
    
    -- Create new match with ordered user IDs
    INSERT INTO public.matches (user1_id, user2_id, status, created_at)
    VALUES (v_user1_id, v_user2_id, 'active', NOW())
    RETURNING id INTO v_match_id;
    
    -- Create conversation with ordered user IDs
    INSERT INTO public.conversations (user1_id, user2_id, created_at)
    VALUES (v_user1_id, v_user2_id, NOW())
    RETURNING id INTO v_conversation_id;
    
    -- Update match with conversation reference
    UPDATE public.matches 
    SET conversation_id = v_conversation_id
    WHERE id = v_match_id;
    
    -- Update match request status if provided
    IF p_source_match_request_id IS NOT NULL THEN
        UPDATE public.match_requests
        SET status = 'confirmed', updated_at = NOW()
        WHERE id = p_source_match_request_id;
    END IF;
    
    RETURN QUERY SELECT v_match_id, v_conversation_id;
END;
$$;

-- Step 3: Grant permissions
GRANT EXECUTE ON FUNCTION public.confirm_system_match(UUID, UUID, UUID) TO authenticated;

-- Step 4: Add comment
COMMENT ON FUNCTION public.confirm_system_match(UUID, UUID, UUID) IS 
'Creates a confirmed match between two users and associated conversation, ensuring proper user ID ordering and handling duplicates.';