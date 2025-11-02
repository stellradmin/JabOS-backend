-- =============================================
-- JabOS Mobile - Supporting RPC Functions
-- Invite system, match confirmation, messaging
-- Adapted from Stellr production functions
-- =============================================

-- =============================================
-- FUNCTION: Get user's daily invite status
-- Returns remaining invites, total allowed, premium status
-- From Stellr's invite system
-- =============================================
CREATE OR REPLACE FUNCTION jabos_mobile.get_invite_status(
  p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'jabos_mobile'
AS $$
DECLARE
  v_invites_used INTEGER;
  v_invites_allowed INTEGER;
  v_is_premium BOOLEAN;
  v_last_reset_date DATE;
  v_subscription_status TEXT;
BEGIN
  -- Check if user has premium via JabOS membership plan
  SELECT EXISTS (
    SELECT 1
    FROM public.member_subscriptions ms
    JOIN public.membership_plans mp ON ms.membership_plan_id = mp.id
    WHERE ms.user_id = p_user_id
      AND ms.status = 'active'
      AND mp.allows_sparring = true
      AND mp.tier = 'premium' -- Assuming premium tier exists
  ) INTO v_is_premium;

  -- Set invites allowed based on premium status
  v_invites_allowed := CASE WHEN v_is_premium THEN 20 ELSE 5 END;
  v_subscription_status := CASE WHEN v_is_premium THEN 'premium' ELSE 'free' END;

  -- Count invites used today
  SELECT COUNT(*)
  INTO v_invites_used
  FROM jabos_mobile.invite_usage_log
  WHERE user_id = p_user_id
    AND DATE(used_at) = CURRENT_DATE;

  RETURN jsonb_build_object(
    'invites_used', v_invites_used,
    'invites_remaining', GREATEST(0, v_invites_allowed - v_invites_used),
    'invites_total', v_invites_allowed,
    'is_premium', v_is_premium,
    'subscription_status', v_subscription_status,
    'reset_date', CURRENT_DATE + INTERVAL '1 day'
  );
END;
$$;

-- =============================================
-- FUNCTION: Consume an invite (rate limiting)
-- Atomically checks and records invite usage
-- Returns true if invite available, false if limit reached
-- From Stellr's consume_invite function
-- =============================================
CREATE OR REPLACE FUNCTION jabos_mobile.consume_invite(
  p_user_id UUID,
  p_target_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'jabos_mobile'
AS $$
DECLARE
  v_status JSONB;
  v_invites_remaining INTEGER;
BEGIN
  -- Get current invite status
  v_status := jabos_mobile.get_invite_status(p_user_id);
  v_invites_remaining := (v_status->>'invites_remaining')::INTEGER;

  -- Check if invites available
  IF v_invites_remaining <= 0 THEN
    RETURN false;
  END IF;

  -- Record invite usage
  INSERT INTO jabos_mobile.invite_usage_log (
    user_id,
    organization_id,
    invited_user_id,
    used_at,
    subscription_status,
    metadata
  )
  SELECT
    p_user_id,
    mp.organization_id,
    p_target_user_id,
    NOW(),
    v_status->>'subscription_status',
    jsonb_build_object(
      'invites_remaining_after', v_invites_remaining - 1,
      'is_premium', (v_status->>'is_premium')::BOOLEAN
    )
  FROM public.member_profiles mp
  WHERE mp.user_id = p_user_id;

  RETURN true;
END;
$$;

-- =============================================
-- FUNCTION: Confirm training match
-- Creates match + conversation atomically
-- Awards XP to both users
-- From Stellr's confirm_system_match
-- =============================================
CREATE OR REPLACE FUNCTION jabos_mobile.confirm_training_match(
  p_current_user_id UUID,
  p_target_user_id UUID,
  p_match_request_id UUID DEFAULT NULL
)
RETURNS TABLE (
  match_id UUID,
  conversation_id UUID,
  xp_awarded INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'jabos_mobile'
AS $$
DECLARE
  v_match_id UUID;
  v_conversation_id UUID;
  v_user1_id UUID;
  v_user2_id UUID;
  v_organization_id UUID;
  v_compatibility JSONB;
BEGIN
  -- Ensure consistent ordering (user1_id < user2_id)
  v_user1_id := LEAST(p_current_user_id, p_target_user_id);
  v_user2_id := GREATEST(p_current_user_id, p_target_user_id);

  -- Get organization from current user
  SELECT organization_id INTO v_organization_id
  FROM public.member_profiles
  WHERE user_id = p_current_user_id;

  -- Calculate compatibility
  v_compatibility := jabos_mobile.calculate_training_compatibility(
    p_current_user_id,
    p_target_user_id
  );

  -- Create conversation first
  INSERT INTO jabos_mobile.conversations (
    participant_1_id,
    participant_2_id,
    created_at
  )
  VALUES (
    v_user1_id,
    v_user2_id,
    NOW()
  )
  ON CONFLICT (participant_1_id, participant_2_id) DO UPDATE
    SET updated_at = NOW()
  RETURNING id INTO v_conversation_id;

  -- Create match
  INSERT INTO jabos_mobile.training_matches (
    organization_id,
    user1_id,
    user2_id,
    matched_at,
    status,
    compatibility_score,
    physical_grade,
    style_grade,
    overall_score,
    physical_compatibility,
    style_compatibility,
    conversation_id,
    match_request_id
  )
  VALUES (
    v_organization_id,
    v_user1_id,
    v_user2_id,
    NOW(),
    'active',
    (v_compatibility->>'overallScore')::INTEGER,
    v_compatibility->>'PhysicalGrade',
    v_compatibility->>'StyleGrade',
    (v_compatibility->>'overallScore')::INTEGER,
    v_compatibility->'physicalCompatibility',
    v_compatibility->'styleCompatibility',
    v_conversation_id,
    p_match_request_id
  )
  ON CONFLICT (user1_id, user2_id) DO UPDATE
    SET status = 'active',
        matched_at = NOW(),
        conversation_id = v_conversation_id
  RETURNING id INTO v_match_id;

  -- Update match request status if provided
  IF p_match_request_id IS NOT NULL THEN
    UPDATE jabos_mobile.match_requests
    SET status = 'fulfilled',
        resulting_match_id = v_match_id,
        responded_at = NOW()
    WHERE id = p_match_request_id;
  END IF;

  -- Update conversation with match_id
  UPDATE jabos_mobile.conversations
  SET match_id = v_match_id
  WHERE id = v_conversation_id;

  -- Award XP to both users (25 XP for match creation)
  -- Using JabOS's existing award_xp RPC function
  PERFORM public.award_xp(
    p_user_id := v_user1_id,
    p_xp_amount := 25,
    p_category := 'sparring',
    p_activity_type := 'match_created',
    p_notes := 'Training partner matched'
  );

  PERFORM public.award_xp(
    p_user_id := v_user2_id,
    p_xp_amount := 25,
    p_category := 'sparring',
    p_activity_type := 'match_created',
    p_notes := 'Training partner matched'
  );

  -- Cache compatibility score for future queries
  INSERT INTO jabos_mobile.user_compatibility_cache (
    user1_id,
    user2_id,
    compatibility_score,
    physical_grade,
    style_grade,
    overall_score,
    is_recommended,
    physical_compatibility,
    style_compatibility,
    calculated_at,
    expires_at
  )
  VALUES (
    v_user1_id,
    v_user2_id,
    (v_compatibility->>'overallScore')::INTEGER,
    v_compatibility->>'PhysicalGrade',
    v_compatibility->>'StyleGrade',
    (v_compatibility->>'overallScore')::INTEGER,
    (v_compatibility->>'IsMatchRecommended')::BOOLEAN,
    v_compatibility->'physicalCompatibility',
    v_compatibility->'styleCompatibility',
    NOW(),
    NOW() + INTERVAL '7 days'
  )
  ON CONFLICT (user1_id, user2_id) DO UPDATE
    SET compatibility_score = EXCLUDED.compatibility_score,
        physical_grade = EXCLUDED.physical_grade,
        style_grade = EXCLUDED.style_grade,
        overall_score = EXCLUDED.overall_score,
        is_recommended = EXCLUDED.is_recommended,
        calculated_at = NOW(),
        expires_at = NOW() + INTERVAL '7 days';

  -- Return match and conversation IDs
  RETURN QUERY
  SELECT v_match_id, v_conversation_id, 25;
END;
$$;

-- =============================================
-- FUNCTION: Get user's conversations
-- Returns conversations with other participant details
-- From Stellr's get_user_conversations
-- =============================================
CREATE OR REPLACE FUNCTION jabos_mobile.get_user_conversations(
  p_user_id UUID
)
RETURNS TABLE (
  conversation_id UUID,
  other_user_id UUID,
  other_user_name TEXT,
  other_user_avatar TEXT,
  last_message_at TIMESTAMPTZ,
  last_message_content TEXT,
  unread_count BIGINT,
  match_id UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'jabos_mobile'
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id AS conversation_id,
    CASE
      WHEN c.participant_1_id = p_user_id THEN c.participant_2_id
      ELSE c.participant_1_id
    END AS other_user_id,
    u.display_name AS other_user_name,
    u.avatar_url AS other_user_avatar,
    c.last_message_at,
    c.last_message_content,
    (
      SELECT COUNT(*)
      FROM jabos_mobile.messages m
      WHERE m.conversation_id = c.id
        AND m.sender_id != p_user_id
        AND m.is_read = false
    ) AS unread_count,
    c.match_id
  FROM jabos_mobile.conversations c
  JOIN public.users u ON (
    CASE
      WHEN c.participant_1_id = p_user_id THEN c.participant_2_id
      ELSE c.participant_1_id
    END = u.id
  )
  WHERE c.participant_1_id = p_user_id
     OR c.participant_2_id = p_user_id
  ORDER BY c.last_message_at DESC NULLS LAST;
END;
$$;

-- =============================================
-- FUNCTION: Mark messages as read
-- Updates is_read flag and read_at timestamp
-- From Stellr's mark_messages_read
-- =============================================
CREATE OR REPLACE FUNCTION jabos_mobile.mark_messages_read(
  p_conversation_id UUID,
  p_user_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'jabos_mobile'
AS $$
DECLARE
  v_updated_count INTEGER;
BEGIN
  -- Verify user is participant in conversation
  IF NOT EXISTS (
    SELECT 1
    FROM jabos_mobile.conversations
    WHERE id = p_conversation_id
      AND (participant_1_id = p_user_id OR participant_2_id = p_user_id)
  ) THEN
    RAISE EXCEPTION 'User is not a participant in this conversation';
  END IF;

  -- Mark all unread messages from other user as read
  WITH updated AS (
    UPDATE jabos_mobile.messages
    SET is_read = true,
        read_at = NOW()
    WHERE conversation_id = p_conversation_id
      AND sender_id != p_user_id
      AND is_read = false
    RETURNING id
  )
  SELECT COUNT(*) INTO v_updated_count FROM updated;

  RETURN v_updated_count;
END;
$$;

-- =============================================
-- Grant execute permissions
-- =============================================
GRANT EXECUTE ON FUNCTION jabos_mobile.get_invite_status TO authenticated;
GRANT EXECUTE ON FUNCTION jabos_mobile.consume_invite TO authenticated;
GRANT EXECUTE ON FUNCTION jabos_mobile.confirm_training_match TO authenticated;
GRANT EXECUTE ON FUNCTION jabos_mobile.get_user_conversations TO authenticated;
GRANT EXECUTE ON FUNCTION jabos_mobile.mark_messages_read TO authenticated;

-- =============================================
-- COMMENTS
-- =============================================
COMMENT ON FUNCTION jabos_mobile.get_invite_status IS 'Get user''s daily invite status (5/day free, 20/day premium via JabOS membership plans)';
COMMENT ON FUNCTION jabos_mobile.consume_invite IS 'Atomically consume one invite (rate limiting)';
COMMENT ON FUNCTION jabos_mobile.confirm_training_match IS 'Create match + conversation atomically, award XP to both users';
COMMENT ON FUNCTION jabos_mobile.get_user_conversations IS 'Get all conversations for user with unread counts';
COMMENT ON FUNCTION jabos_mobile.mark_messages_read IS 'Mark all messages in conversation as read';
