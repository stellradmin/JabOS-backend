CREATE OR REPLACE FUNCTION confirm_system_match(
    p_current_user_id UUID,
    p_target_user_id UUID,
    p_source_match_request_id UUID DEFAULT NULL
)
RETURNS TABLE (
    match_id UUID,
    conversation_id UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user1_id UUID;
    v_user2_id UUID;
    v_match_id UUID;
    v_conversation_id UUID;
    v_existing_match RECORD;
    v_existing_conversation RECORD;
    v_calculation_result JSONB; -- For storing compatibility calculation
    v_overall_score INT;      -- For storing the numeric overall score
BEGIN
    -- Determine user1_id and user2_id to ensure consistent ordering
    IF p_current_user_id < p_target_user_id THEN
        v_user1_id := p_current_user_id;
        v_user2_id := p_target_user_id;
    ELSE
        v_user1_id := p_target_user_id;
        v_user2_id := p_current_user_id;
    END IF;

    -- 1. Check for an existing match or create a new one
    SELECT m.id, m.calculation_result INTO v_existing_match -- Also select existing calculation_result
    FROM public.matches m
    WHERE m.user1_id = v_user1_id AND m.user2_id = v_user2_id;

    IF v_existing_match IS NOT NULL THEN
        v_match_id := v_existing_match.id;
        RAISE NOTICE 'Match already exists: %', v_match_id;
        -- If match exists but calculation_result is NULL, calculate and update it
        IF v_existing_match.calculation_result IS NULL THEN
            RAISE NOTICE 'Existing match % is missing calculation_result. Calculating now.', v_match_id;
            SELECT public.calculate_compatibility_scores(v_user1_id, v_user2_id) INTO v_calculation_result;
            -- Ensure overallScore is extracted correctly if calculate_compatibility_scores returns it as text
            v_overall_score := (v_calculation_result->>'overallScore')::INT; 
            UPDATE public.matches 
            SET calculation_result = v_calculation_result, overall_score = v_overall_score 
            WHERE id = v_match_id;
            RAISE NOTICE 'Updated existing match % with calculation_result.', v_match_id;
        END IF;
    ELSE
        -- Calculate compatibility before creating the new match
        SELECT public.calculate_compatibility_scores(v_user1_id, v_user2_id) INTO v_calculation_result;
        v_overall_score := (v_calculation_result->>'overallScore')::INT; -- Extract numeric score

        INSERT INTO public.matches (user1_id, user2_id, status, calculation_result, overall_score)
        VALUES (v_user1_id, v_user2_id, 'active', v_calculation_result, v_overall_score)
        RETURNING id INTO v_match_id;
        RAISE NOTICE 'New match created: % with calculation result and score.', v_match_id;
    END IF;

    -- 2. Check for an existing conversation or create a new one
    SELECT id INTO v_existing_conversation
    FROM public.conversations c
    WHERE (c.user1_id = v_user1_id AND c.user2_id = v_user2_id)
       OR (c.user1_id = v_user2_id AND c.user2_id = v_user1_id);
    
    IF v_existing_conversation IS NOT NULL THEN
        v_conversation_id := v_existing_conversation.id;
        RAISE NOTICE 'Conversation already exists: %', v_conversation_id;
    ELSE
        INSERT INTO public.conversations (user1_id, user2_id, match_id)
        VALUES (v_user1_id, v_user2_id, v_match_id)
        RETURNING id INTO v_conversation_id;
        RAISE NOTICE 'New conversation created: %', v_conversation_id;
    END IF;

    -- 3. Update the source match_request if provided
    IF p_source_match_request_id IS NOT NULL THEN
        UPDATE public.match_requests
        SET 
            status = 'fulfilled',
            matched_user_id = p_target_user_id, 
            match_id = v_match_id 
        WHERE id = p_source_match_request_id
          AND user_id = p_current_user_id; 
        
        IF FOUND THEN
            RAISE NOTICE 'Match request % updated to fulfilled.', p_source_match_request_id;
        ELSE
            RAISE NOTICE 'Match request % not found or not owned by user %.', p_source_match_request_id, p_current_user_id;
        END IF;
    END IF;

    RETURN QUERY SELECT v_match_id, v_conversation_id;

EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Error in confirm_system_match RPC: %', SQLERRM;
        RETURN QUERY SELECT NULL::UUID, NULL::UUID; 
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_system_match(UUID, UUID, UUID) TO authenticated;
