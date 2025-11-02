-- CRITICAL FIX: Add transaction safety, advisory locks, and error handling to confirm_system_match
-- Migration: fix_confirm_system_match_transaction_safety
-- Date: 2025-01-16
-- Purpose:
--   1. Add advisory locks to prevent race conditions
--   2. Add explicit error handling with proper exception blocks
--   3. Add comprehensive logging for debugging
--   4. Handle unique violations gracefully
--   5. Ensure atomic operations with proper rollback on errors

CREATE OR REPLACE FUNCTION public.confirm_system_match(
  p_current_user_id uuid,
  p_target_user_id uuid,
  p_source_match_request_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(match_id uuid, conversation_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_match_id UUID;
    v_conversation_id UUID;
    existing_match_id UUID;
    existing_conversation_id UUID;
    v_user1_id UUID;
    v_user2_id UUID;
    v_lock_key BIGINT;
BEGIN
    -- Input validation
    IF p_current_user_id IS NULL OR p_target_user_id IS NULL THEN
        RAISE EXCEPTION 'Both user IDs must be provided';
    END IF;

    IF p_current_user_id = p_target_user_id THEN
        RAISE EXCEPTION 'Cannot create a match with oneself';
    END IF;

    -- CRITICAL FIX: Advisory lock to prevent race conditions
    -- Create deterministic lock key from ordered user IDs
    IF p_current_user_id < p_target_user_id THEN
        v_user1_id := p_current_user_id;
        v_user2_id := p_target_user_id;
    ELSE
        v_user1_id := p_target_user_id;
        v_user2_id := p_current_user_id;
    END IF;

    -- Generate lock key from user pair (transaction-scoped advisory lock)
    v_lock_key := hashtext(v_user1_id::text || '-' || v_user2_id::text);
    PERFORM pg_advisory_xact_lock(v_lock_key);

    RAISE NOTICE 'confirm_system_match: Acquired lock % for users % and %', v_lock_key, v_user1_id, v_user2_id;

    -- Check if match already exists (with lock protection)
    SELECT id, conversation_id
    INTO existing_match_id, existing_conversation_id
    FROM public.matches
    WHERE user1_id = v_user1_id AND user2_id = v_user2_id;

    IF existing_match_id IS NOT NULL THEN
        RAISE NOTICE 'confirm_system_match: Match already exists (id: %), returning existing data', existing_match_id;
        RETURN QUERY SELECT existing_match_id, existing_conversation_id;
        RETURN;
    END IF;

    -- Begin atomic operations (implicit transaction, but explicit exception handling)
    BEGIN
        -- Create new match with ordered user IDs
        INSERT INTO public.matches (user1_id, user2_id, status, created_at)
        VALUES (v_user1_id, v_user2_id, 'active', NOW())
        RETURNING id INTO v_match_id;

        RAISE NOTICE 'confirm_system_match: Created match with id %', v_match_id;

        -- Create conversation with ordered user IDs
        INSERT INTO public.conversations (user1_id, user2_id, created_at)
        VALUES (v_user1_id, v_user2_id, NOW())
        RETURNING id INTO v_conversation_id;

        RAISE NOTICE 'confirm_system_match: Created conversation with id %', v_conversation_id;

        -- Update match with conversation reference
        UPDATE public.matches
        SET conversation_id = v_conversation_id, updated_at = NOW()
        WHERE id = v_match_id;

        RAISE NOTICE 'confirm_system_match: Linked match % to conversation %', v_match_id, v_conversation_id;

        -- Update match request status if provided
        IF p_source_match_request_id IS NOT NULL THEN
            UPDATE public.match_requests
            SET status = 'confirmed', updated_at = NOW()
            WHERE id = p_source_match_request_id;

            RAISE NOTICE 'confirm_system_match: Updated match_request % to confirmed', p_source_match_request_id;
        END IF;

        -- Return the created match and conversation IDs
        RETURN QUERY SELECT v_match_id, v_conversation_id;

    EXCEPTION
        WHEN unique_violation THEN
            -- Handle race condition where match was created between our check and insert
            RAISE NOTICE 'confirm_system_match: Unique violation caught, fetching existing match';

            SELECT id, conversation_id
            INTO existing_match_id, existing_conversation_id
            FROM public.matches
            WHERE user1_id = v_user1_id AND user2_id = v_user2_id;

            IF existing_match_id IS NOT NULL THEN
                RETURN QUERY SELECT existing_match_id, existing_conversation_id;
                RETURN;
            ELSE
                RAISE EXCEPTION 'Unique violation but no existing match found';
            END IF;

        WHEN OTHERS THEN
            -- Log the error and re-raise
            RAISE NOTICE 'confirm_system_match: Error occurred - SQLSTATE: %, SQLERRM: %', SQLSTATE, SQLERRM;
            RAISE EXCEPTION 'Failed to confirm match: %', SQLERRM;
    END;

END;
$function$;

-- Add comment to document the fix
COMMENT ON FUNCTION public.confirm_system_match(uuid, uuid, uuid) IS
'SECURITY-CRITICAL: Confirms a match between two users with transaction safety.
Features:
- Advisory locks prevent race conditions
- Atomic operations with automatic rollback on errors
- Handles unique violations gracefully
- Comprehensive error logging
- Idempotent - safe to call multiple times';
