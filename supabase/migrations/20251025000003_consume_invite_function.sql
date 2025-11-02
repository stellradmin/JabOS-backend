-- =====================================================
-- CONSUME INVITE FUNCTION
-- =====================================================
-- Atomically check and decrement daily_invites_remaining
-- Uses optimistic locking (FOR UPDATE) to prevent race conditions
-- Date: 2025-10-25
-- =====================================================

BEGIN;

CREATE OR REPLACE FUNCTION consume_invite(user_uuid UUID)
RETURNS TABLE (
    success BOOLEAN,
    remaining_after INTEGER,
    subscription_status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_remaining INTEGER;
    v_last_reset DATE;
    v_today DATE;
    v_subscription TEXT;
    v_total INTEGER;
BEGIN
    v_today := CURRENT_DATE;

    -- Lock row for update and get current status
    SELECT
        daily_invites_remaining,
        last_invite_reset_date,
        subscription_status
    INTO
        v_remaining,
        v_last_reset,
        v_subscription
    FROM profiles
    WHERE id = user_uuid
    FOR UPDATE; -- Optimistic lock to prevent race conditions

    -- If no user found, return failure
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 0, 'free'::TEXT;
        RETURN;
    END IF;

    -- Calculate total based on subscription
    v_total := CASE WHEN v_subscription IN ('premium', 'premium_cancelled') THEN 20 ELSE 5 END;

    -- Reset if needed (new day)
    IF v_last_reset IS NULL OR v_last_reset < v_today THEN
        v_remaining := v_total;
        v_last_reset := v_today;
    END IF;

    -- Check if user has invites remaining
    IF v_remaining <= 0 THEN
        RETURN QUERY SELECT FALSE, 0, v_subscription;
        RETURN;
    END IF;

    -- Consume one invite (atomic decrement)
    UPDATE profiles
    SET
        daily_invites_remaining = v_remaining - 1,
        last_invite_reset_date = v_last_reset
    WHERE id = user_uuid;

    -- Return success with remaining count
    RETURN QUERY SELECT TRUE, v_remaining - 1, v_subscription;
END;
$$;

-- =====================================================
-- GRANTS
-- =====================================================

GRANT EXECUTE ON FUNCTION consume_invite(UUID) TO service_role;

-- =====================================================
-- VALIDATION & MIGRATION CONFIRMATION
-- =====================================================

DO $$
BEGIN
    RAISE NOTICE '✅ consume_invite Function Created';
    RAISE NOTICE '  - Atomically checks and decrements daily_invites_remaining';
    RAISE NOTICE '  - Uses FOR UPDATE lock to prevent race conditions';
    RAISE NOTICE '  - Automatically resets invites if date has changed';
    RAISE NOTICE '  - Returns success status, remaining count, and subscription tier';
END $$;

COMMIT;
