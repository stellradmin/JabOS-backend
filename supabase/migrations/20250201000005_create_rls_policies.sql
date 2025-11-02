-- =============================================
-- JabOS Mobile - Row Level Security Policies
-- Multi-tenant security adapted from Stellr
-- =============================================

-- Enable RLS on all jabos_mobile tables
ALTER TABLE jabos_mobile.partner_swipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE jabos_mobile.training_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE jabos_mobile.training_matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE jabos_mobile.match_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE jabos_mobile.invite_usage_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE jabos_mobile.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE jabos_mobile.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE jabos_mobile.user_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE jabos_mobile.issue_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE jabos_mobile.user_compatibility_cache ENABLE ROW LEVEL SECURITY;

-- =============================================
-- PARTNER_SWIPES POLICIES
-- Users can only see and create their own swipes
-- =============================================

CREATE POLICY "Users can view their own swipes"
  ON jabos_mobile.partner_swipes
  FOR SELECT
  USING (swiper_id = auth.uid());

CREATE POLICY "Users can create their own swipes"
  ON jabos_mobile.partner_swipes
  FOR INSERT
  WITH CHECK (swiper_id = auth.uid());

-- =============================================
-- TRAINING_PREFERENCES POLICIES
-- Users can manage their own preferences
-- =============================================

CREATE POLICY "Users can view their own preferences"
  ON jabos_mobile.training_preferences
  FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "Users can insert their own preferences"
  ON jabos_mobile.training_preferences
  FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update their own preferences"
  ON jabos_mobile.training_preferences
  FOR UPDATE
  USING (user_id = auth.uid());

-- =============================================
-- TRAINING_MATCHES POLICIES
-- Users can see matches they're involved in
-- =============================================

CREATE POLICY "Users can view their own matches"
  ON jabos_mobile.training_matches
  FOR SELECT
  USING (
    user1_id = auth.uid()
    OR user2_id = auth.uid()
  );

CREATE POLICY "System can create matches"
  ON jabos_mobile.training_matches
  FOR INSERT
  WITH CHECK (true); -- Enforced via SECURITY DEFINER functions

CREATE POLICY "Users can update their own matches"
  ON jabos_mobile.training_matches
  FOR UPDATE
  USING (
    user1_id = auth.uid()
    OR user2_id = auth.uid()
  );

-- =============================================
-- MATCH_REQUESTS POLICIES
-- Users can see requests they sent or received
-- =============================================

CREATE POLICY "Users can view their match requests"
  ON jabos_mobile.match_requests
  FOR SELECT
  USING (
    requester_id = auth.uid()
    OR target_id = auth.uid()
  );

CREATE POLICY "Users can create match requests"
  ON jabos_mobile.match_requests
  FOR INSERT
  WITH CHECK (requester_id = auth.uid());

CREATE POLICY "Users can respond to match requests"
  ON jabos_mobile.match_requests
  FOR UPDATE
  USING (target_id = auth.uid());

-- =============================================
-- INVITE_USAGE_LOG POLICIES
-- Users can see their own invite history
-- =============================================

CREATE POLICY "Users can view their own invite usage"
  ON jabos_mobile.invite_usage_log
  FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "System can log invite usage"
  ON jabos_mobile.invite_usage_log
  FOR INSERT
  WITH CHECK (true); -- Enforced via SECURITY DEFINER functions

-- =============================================
-- CONVERSATIONS POLICIES
-- Users can see conversations they're part of
-- =============================================

CREATE POLICY "Users can view their own conversations"
  ON jabos_mobile.conversations
  FOR SELECT
  USING (
    participant_1_id = auth.uid()
    OR participant_2_id = auth.uid()
  );

CREATE POLICY "System can create conversations"
  ON jabos_mobile.conversations
  FOR INSERT
  WITH CHECK (true); -- Created via confirm_training_match function

CREATE POLICY "Users can update their conversations"
  ON jabos_mobile.conversations
  FOR UPDATE
  USING (
    participant_1_id = auth.uid()
    OR participant_2_id = auth.uid()
  );

-- =============================================
-- MESSAGES POLICIES
-- Users can see messages in their conversations
-- =============================================

CREATE POLICY "Users can view messages in their conversations"
  ON jabos_mobile.messages
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM jabos_mobile.conversations c
      WHERE c.id = conversation_id
        AND (c.participant_1_id = auth.uid() OR c.participant_2_id = auth.uid())
    )
  );

CREATE POLICY "Users can send messages in their conversations"
  ON jabos_mobile.messages
  FOR INSERT
  WITH CHECK (
    sender_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM jabos_mobile.conversations c
      WHERE c.id = conversation_id
        AND (c.participant_1_id = auth.uid() OR c.participant_2_id = auth.uid())
    )
  );

CREATE POLICY "Users can update their own messages"
  ON jabos_mobile.messages
  FOR UPDATE
  USING (sender_id = auth.uid());

-- =============================================
-- USER_BLOCKS POLICIES
-- Bidirectional visibility (users can see if they're blocked)
-- Adapted from Stellr's production RLS fix
-- =============================================

CREATE POLICY "Users can view blocks involving them"
  ON jabos_mobile.user_blocks
  FOR SELECT
  USING (
    blocking_user_id = auth.uid()
    OR blocked_user_id = auth.uid()
  );

CREATE POLICY "Users can create blocks"
  ON jabos_mobile.user_blocks
  FOR INSERT
  WITH CHECK (blocking_user_id = auth.uid());

CREATE POLICY "Users can remove their own blocks"
  ON jabos_mobile.user_blocks
  FOR DELETE
  USING (blocking_user_id = auth.uid());

-- =============================================
-- ISSUE_REPORTS POLICIES
-- Users can see their own reports
-- Admins/coaches can see all reports in their org
-- =============================================

CREATE POLICY "Users can view their own reports"
  ON jabos_mobile.issue_reports
  FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "Users can create reports"
  ON jabos_mobile.issue_reports
  FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Coaches can view org reports"
  ON jabos_mobile.issue_reports
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('coach', 'owner')
        AND u.organization_id = issue_reports.organization_id
    )
  );

CREATE POLICY "Coaches can update org reports"
  ON jabos_mobile.issue_reports
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('coach', 'owner')
        AND u.organization_id = issue_reports.organization_id
    )
  );

-- =============================================
-- USER_COMPATIBILITY_CACHE POLICIES
-- Users can see cached scores involving them
-- =============================================

CREATE POLICY "Users can view their compatibility cache"
  ON jabos_mobile.user_compatibility_cache
  FOR SELECT
  USING (
    user1_id = auth.uid()
    OR user2_id = auth.uid()
  );

CREATE POLICY "System can manage compatibility cache"
  ON jabos_mobile.user_compatibility_cache
  FOR ALL
  USING (true); -- Managed via SECURITY DEFINER functions

-- =============================================
-- COMMENTS
-- =============================================
COMMENT ON POLICY "Users can view their own swipes" ON jabos_mobile.partner_swipes IS
  'Users can only see swipes they created';

COMMENT ON POLICY "Users can view blocks involving them" ON jabos_mobile.user_blocks IS
  'Bidirectional visibility - users can see if they blocked someone OR if they are blocked';

COMMENT ON POLICY "Coaches can view org reports" ON jabos_mobile.issue_reports IS
  'Coaches and owners can view and manage all issue reports in their organization';
