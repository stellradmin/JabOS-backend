-- =============================================
-- JabOS Mobile - Core Schema Migration
-- Adapted from Stellr production database
-- Purpose: Partner matching, messaging, and training coordination
-- =============================================

-- Create jabos_mobile schema to isolate from main JabOS web platform
CREATE SCHEMA IF NOT EXISTS jabos_mobile;

-- =============================================
-- 1. PARTNER SWIPES TABLE
-- Tracks like/pass actions (adapted from Stellr's swipes table)
-- =============================================
CREATE TABLE jabos_mobile.partner_swipes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Multi-tenant isolation
  organization_id UUID REFERENCES public.organizations(id) NOT NULL,

  -- Swipe participants
  swiper_id UUID REFERENCES public.users(id) NOT NULL,
  swiped_id UUID REFERENCES public.users(id) NOT NULL,

  -- Swipe action
  swipe_type TEXT NOT NULL CHECK (swipe_type IN ('like', 'pass')),

  -- Metadata
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),

  -- Prevent duplicate swipes
  UNIQUE(swiper_id, swiped_id)
);

-- =============================================
-- 2. TRAINING PREFERENCES TABLE
-- User preferences for partner matching (adapted from Stellr's activity_preferences)
-- =============================================
CREATE TABLE jabos_mobile.training_preferences (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES public.users(id) UNIQUE NOT NULL,
  organization_id UUID REFERENCES public.organizations(id) NOT NULL,

  -- Weight class preferences (replaces zodiac_sign filtering)
  preferred_weight_classes TEXT[], -- e.g., ['welterweight', 'super_welterweight', 'any']

  -- Experience level preferences
  preferred_experience_levels TEXT[], -- e.g., ['intermediate', 'advanced']

  -- Training type preferences (replaces activity_preferences in Stellr)
  -- This is the core matching feature - bidirectional like Stellr's activities
  preferred_training_types TEXT[], -- e.g., ['sparring_light', 'technique_drilling', 'pad_work']

  -- Intensity preference
  intensity_preference TEXT CHECK (intensity_preference IN ('light', 'moderate', 'hard')),

  -- Availability (simplified for MVP)
  availability JSONB, -- { weekdays: bool, weekends: bool, times: ['morning', 'evening'] }

  -- Cross-gym matching (replaces distance preference)
  allow_cross_gym BOOLEAN DEFAULT false,
  max_distance_km INTEGER DEFAULT 25, -- For cross-gym matching

  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================
-- 3. TRAINING MATCHES TABLE
-- Confirmed matches (adapted from Stellr's matches table)
-- =============================================
CREATE TABLE jabos_mobile.training_matches (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Multi-tenant isolation
  organization_id UUID REFERENCES public.organizations(id) NOT NULL,

  -- Match participants (user1_id is always the lower UUID for consistency)
  user1_id UUID REFERENCES public.users(id) NOT NULL,
  user2_id UUID REFERENCES public.users(id) NOT NULL,

  -- Match metadata
  matched_at TIMESTAMPTZ DEFAULT NOW(),
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'completed', 'inactive', 'cancelled')),

  -- Compatibility scoring (adapted from Stellr's astrological/questionnaire scores)
  compatibility_score INTEGER, -- 0-100
  physical_grade TEXT, -- A, B, C (was astrological_grade in Stellr)
  style_grade TEXT,    -- A, B, C (was questionnaire_grade in Stellr)
  overall_score INTEGER,

  -- Compatibility details
  physical_compatibility JSONB, -- Weight class proximity, experience match details
  style_compatibility JSONB,    -- Training style overlap details

  -- Link to conversation
  conversation_id UUID, -- Will be FK after conversations table created

  -- Link to actual sparring session (if session occurred)
  sparring_match_id UUID REFERENCES public.sparring_matches(id),

  -- Source of match (adapted from Stellr's match_request_id)
  match_request_id UUID, -- Will be FK after match_requests table created

  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),

  -- Ensure consistent ordering and no duplicates
  UNIQUE(user1_id, user2_id),
  CHECK (user1_id < user2_id) -- Enforce ordering
);

-- =============================================
-- 4. MATCH REQUESTS TABLE
-- Invite/request system (from Stellr)
-- User can send match requests which can be accepted/declined
-- =============================================
CREATE TABLE jabos_mobile.match_requests (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Multi-tenant isolation
  organization_id UUID REFERENCES public.organizations(id) NOT NULL,

  -- Request participants
  requester_id UUID REFERENCES public.users(id) NOT NULL,
  target_id UUID REFERENCES public.users(id) NOT NULL,

  -- Request status
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'expired', 'fulfilled')),

  -- Compatibility data at time of request
  compatibility_score INTEGER,
  compatibility_details JSONB,

  -- Response tracking
  responded_at TIMESTAMPTZ,
  decline_reason TEXT,

  -- Expiration (requests expire after 7 days)
  expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '7 days'),

  -- Link to resulting match (if accepted)
  resulting_match_id UUID, -- Will be FK after adding constraint

  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),

  -- Can't request yourself
  CHECK (requester_id != target_id)
);

-- =============================================
-- 5. INVITE USAGE LOG TABLE
-- Rate limiting system (from Stellr)
-- Track daily invite consumption (5/day free, 20/day premium via membership plans)
-- =============================================
CREATE TABLE jabos_mobile.invite_usage_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- User who sent invite
  user_id UUID REFERENCES public.users(id) NOT NULL,
  organization_id UUID REFERENCES public.organizations(id) NOT NULL,

  -- Who was invited
  invited_user_id UUID REFERENCES public.users(id) NOT NULL,

  -- Usage tracking
  used_at TIMESTAMPTZ DEFAULT NOW(),

  -- Subscription status at time of use
  subscription_status TEXT, -- 'free', 'premium'

  -- Additional metadata
  metadata JSONB,

  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================
-- 6. CONVERSATIONS TABLE
-- Messaging between matched partners (from Stellr, unchanged)
-- =============================================
CREATE TABLE jabos_mobile.conversations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Conversation participants (no organization_id - conversations span organizations)
  participant_1_id UUID REFERENCES public.users(id) NOT NULL,
  participant_2_id UUID REFERENCES public.users(id) NOT NULL,

  -- Link to match
  match_id UUID REFERENCES jabos_mobile.training_matches(id),

  -- Last message metadata (for conversation list)
  last_message_at TIMESTAMPTZ,
  last_message_content TEXT,

  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),

  -- Ensure unique conversation per pair
  UNIQUE(participant_1_id, participant_2_id),
  CHECK (participant_1_id < participant_2_id) -- Enforce ordering
);

-- =============================================
-- 7. MESSAGES TABLE
-- Individual messages (from Stellr, unchanged)
-- =============================================
CREATE TABLE jabos_mobile.messages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Message details
  conversation_id UUID REFERENCES jabos_mobile.conversations(id) NOT NULL,
  sender_id UUID REFERENCES public.users(id) NOT NULL,
  content TEXT NOT NULL,

  -- Message type
  message_type TEXT DEFAULT 'text' CHECK (message_type IN ('text', 'photo', 'system')),

  -- Read status
  is_read BOOLEAN DEFAULT false,
  delivered_at TIMESTAMPTZ,
  read_at TIMESTAMPTZ,
  sent_at TIMESTAMPTZ DEFAULT NOW(),

  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================
-- 8. USER BLOCKS TABLE
-- User blocking system (from Stellr)
-- =============================================
CREATE TABLE jabos_mobile.user_blocks (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Block relationship
  blocking_user_id UUID REFERENCES public.users(id) NOT NULL,
  blocked_user_id UUID REFERENCES public.users(id) NOT NULL,
  organization_id UUID REFERENCES public.organizations(id) NOT NULL,

  -- Reason
  reason TEXT,

  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),

  -- Prevent duplicate blocks
  UNIQUE(blocking_user_id, blocked_user_id),
  CHECK (blocking_user_id != blocked_user_id)
);

-- =============================================
-- 9. ISSUE REPORTS TABLE
-- User reporting system (from Stellr)
-- =============================================
CREATE TABLE jabos_mobile.issue_reports (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Reporter
  user_id UUID REFERENCES public.users(id),
  organization_id UUID REFERENCES public.organizations(id),

  -- Report details
  issue_description TEXT NOT NULL,
  status TEXT DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'resolved', 'closed')),

  -- Admin response
  admin_notes TEXT,
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES public.users(id),

  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================
-- 10. COMPATIBILITY SCORE CACHE TABLE
-- Pre-calculated compatibility scores (from Stellr)
-- Performance optimization - cache expires after 7 days
-- =============================================
CREATE TABLE jabos_mobile.user_compatibility_cache (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- User pair (user1_id is always lower UUID)
  user1_id UUID REFERENCES public.users(id) NOT NULL,
  user2_id UUID REFERENCES public.users(id) NOT NULL,

  -- Compatibility scores
  compatibility_score INTEGER NOT NULL, -- 0-100
  physical_grade TEXT,                  -- A, B, C
  style_grade TEXT,                     -- A, B, C
  overall_score INTEGER,
  is_recommended BOOLEAN DEFAULT false,

  -- Compatibility details
  physical_compatibility JSONB,
  style_compatibility JSONB,

  -- Cache management
  calculated_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '7 days'),

  -- Ensure unique cache entry per pair
  UNIQUE(user1_id, user2_id),
  CHECK (user1_id < user2_id)
);

-- =============================================
-- Add foreign key constraints that reference tables created above
-- =============================================
ALTER TABLE jabos_mobile.training_matches
  ADD CONSTRAINT fk_conversation
  FOREIGN KEY (conversation_id)
  REFERENCES jabos_mobile.conversations(id)
  ON DELETE SET NULL;

ALTER TABLE jabos_mobile.training_matches
  ADD CONSTRAINT fk_match_request
  FOREIGN KEY (match_request_id)
  REFERENCES jabos_mobile.match_requests(id)
  ON DELETE SET NULL;

ALTER TABLE jabos_mobile.match_requests
  ADD CONSTRAINT fk_resulting_match
  FOREIGN KEY (resulting_match_id)
  REFERENCES jabos_mobile.training_matches(id)
  ON DELETE SET NULL;

-- =============================================
-- INDEXES FOR PERFORMANCE
-- Based on Stellr's production indexes
-- =============================================

-- Partner swipes indexes
CREATE INDEX idx_partner_swipes_swiper ON jabos_mobile.partner_swipes(swiper_id);
CREATE INDEX idx_partner_swipes_swiped ON jabos_mobile.partner_swipes(swiped_id);
CREATE INDEX idx_partner_swipes_org ON jabos_mobile.partner_swipes(organization_id);
CREATE INDEX idx_partner_swipes_created ON jabos_mobile.partner_swipes(created_at DESC);

-- Training preferences indexes
CREATE INDEX idx_training_prefs_user ON jabos_mobile.training_preferences(user_id);
CREATE INDEX idx_training_prefs_org ON jabos_mobile.training_preferences(organization_id);

-- Training matches indexes
CREATE INDEX idx_training_matches_user1 ON jabos_mobile.training_matches(user1_id);
CREATE INDEX idx_training_matches_user2 ON jabos_mobile.training_matches(user2_id);
CREATE INDEX idx_training_matches_org ON jabos_mobile.training_matches(organization_id);
CREATE INDEX idx_training_matches_status ON jabos_mobile.training_matches(status);
CREATE INDEX idx_training_matches_created ON jabos_mobile.training_matches(created_at DESC);

-- Match requests indexes
CREATE INDEX idx_match_requests_requester ON jabos_mobile.match_requests(requester_id);
CREATE INDEX idx_match_requests_target ON jabos_mobile.match_requests(target_id);
CREATE INDEX idx_match_requests_status ON jabos_mobile.match_requests(status);
CREATE INDEX idx_match_requests_expires ON jabos_mobile.match_requests(expires_at);

-- Invite usage indexes
CREATE INDEX idx_invite_usage_user ON jabos_mobile.invite_usage_log(user_id);
CREATE INDEX idx_invite_usage_date ON jabos_mobile.invite_usage_log(used_at);

-- Conversations indexes
CREATE INDEX idx_conversations_participant1 ON jabos_mobile.conversations(participant_1_id);
CREATE INDEX idx_conversations_participant2 ON jabos_mobile.conversations(participant_2_id);
CREATE INDEX idx_conversations_match ON jabos_mobile.conversations(match_id);
CREATE INDEX idx_conversations_last_message ON jabos_mobile.conversations(last_message_at DESC);

-- Messages indexes
CREATE INDEX idx_messages_conversation ON jabos_mobile.messages(conversation_id);
CREATE INDEX idx_messages_sender ON jabos_mobile.messages(sender_id);
CREATE INDEX idx_messages_created ON jabos_mobile.messages(created_at DESC);
CREATE INDEX idx_messages_is_read ON jabos_mobile.messages(is_read) WHERE is_read = false;

-- User blocks indexes
CREATE INDEX idx_user_blocks_blocker ON jabos_mobile.user_blocks(blocking_user_id);
CREATE INDEX idx_user_blocks_blocked ON jabos_mobile.user_blocks(blocked_user_id);

-- Compatibility cache indexes
CREATE INDEX idx_compatibility_user1 ON jabos_mobile.user_compatibility_cache(user1_id);
CREATE INDEX idx_compatibility_user2 ON jabos_mobile.user_compatibility_cache(user2_id);
CREATE INDEX idx_compatibility_expires ON jabos_mobile.user_compatibility_cache(expires_at);
CREATE INDEX idx_compatibility_recommended ON jabos_mobile.user_compatibility_cache(is_recommended) WHERE is_recommended = true;

-- =============================================
-- COMMENTS FOR DOCUMENTATION
-- =============================================
COMMENT ON SCHEMA jabos_mobile IS 'JabOS Mobile partner matching system - adapted from Stellr dating app architecture';
COMMENT ON TABLE jabos_mobile.partner_swipes IS 'Tracks like/pass actions on potential training partners';
COMMENT ON TABLE jabos_mobile.training_preferences IS 'User preferences for partner matching - training types, weight classes, experience levels';
COMMENT ON TABLE jabos_mobile.training_matches IS 'Confirmed matches between training partners';
COMMENT ON TABLE jabos_mobile.match_requests IS 'Invitation system for partner matching (rate limited)';
COMMENT ON TABLE jabos_mobile.invite_usage_log IS 'Tracks daily invite consumption for rate limiting (5/day free, 20/day premium)';
COMMENT ON TABLE jabos_mobile.conversations IS 'Messaging conversations between matched partners';
COMMENT ON TABLE jabos_mobile.messages IS 'Individual messages within conversations';
COMMENT ON TABLE jabos_mobile.user_blocks IS 'User blocking system for safety';
COMMENT ON TABLE jabos_mobile.issue_reports IS 'User-reported issues and safety concerns';
COMMENT ON TABLE jabos_mobile.user_compatibility_cache IS 'Pre-calculated compatibility scores (7-day cache)';
