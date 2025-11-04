-- Churn Rescue System
-- Risk scoring, intervention tracking, and automated nudge orchestration

-- =============================================================================
-- MEMBER RISK SCORES TABLE
-- =============================================================================
-- Daily calculated risk scores for churn prediction
CREATE TABLE IF NOT EXISTS public.member_risk_scores (
  member_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  calculated_date DATE NOT NULL DEFAULT CURRENT_DATE,

  -- Risk assessment
  risk_score NUMERIC(4,3) NOT NULL CHECK (risk_score >= 0 AND risk_score <= 1),
  risk_band TEXT NOT NULL CHECK (risk_band IN ('low', 'medium', 'high')),

  -- Contributing factors (array of {factor, weight} objects)
  contributing_factors JSONB NOT NULL DEFAULT '[]'::jsonb,

  -- Behavioral metrics
  days_since_last_visit INTEGER,
  attendance_trend TEXT CHECK (attendance_trend IN ('declining', 'stable', 'improving')),
  avg_visits_4w NUMERIC(4,2),
  delta_vs_baseline NUMERIC(4,2),  -- Change from 12-week average
  variety_index NUMERIC(3,2),      -- 0-1 scale, diversity of class types attended
  streak_broken BOOLEAN DEFAULT false,

  -- Subscription context
  subscription_status TEXT,
  days_until_renewal INTEGER,

  -- Engagement metrics
  message_read_rate NUMERIC(3,2),   -- 0-1 scale
  last_message_sent_at TIMESTAMPTZ,
  last_message_read_at TIMESTAMPTZ,

  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  PRIMARY KEY (member_id, calculated_date)
);

-- =============================================================================
-- CHURN INTERVENTIONS TABLE
-- =============================================================================
-- Track all intervention attempts (automated and manual)
CREATE TABLE IF NOT EXISTS public.churn_interventions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Who initiated (NULL for automated)
  initiated_by UUID REFERENCES public.users(id) ON DELETE SET NULL,

  -- Intervention details
  intervention_type TEXT NOT NULL CHECK (intervention_type IN (
    'automated_nudge',
    'coach_message',
    'phone_call',
    'email',
    'in_person_conversation'
  )),

  -- Status tracking
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending',
    'sent',
    'delivered',
    'read',
    'responded',
    'failed',
    'canceled'
  )),

  -- Coach notes
  notes TEXT,

  -- Outcome tracking
  outcome TEXT CHECK (outcome IN (
    'member_returned',       -- Attended within 7 days
    'member_scheduled',      -- Booked future class
    'no_response',           -- No action taken
    'canceled_anyway',       -- Canceled subscription despite intervention
    'false_alarm'            -- Member wasn't actually at risk
  )),

  -- Value attribution
  estimated_value_retained NUMERIC(10,2),  -- Estimated revenue saved

  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ
);

-- =============================================================================
-- NUDGE QUEUE TABLE
-- =============================================================================
-- Queue for scheduled automated nudges
CREATE TABLE IF NOT EXISTS public.nudge_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Template configuration
  template_id TEXT NOT NULL CHECK (template_id IN (
    'streak_break',
    'inactivity_7d',
    'inactivity_14d',
    'ring_almost_complete',
    'subscription_expiring',
    'comeback_offer',
    'missing_favorite_class'
  )),

  -- Scheduling
  scheduled_for TIMESTAMPTZ NOT NULL,
  sent_at TIMESTAMPTZ,

  -- Generated message
  message_subject TEXT,
  message_body TEXT NOT NULL,

  -- Links to created records
  message_id UUID REFERENCES public.messages(id) ON DELETE SET NULL,
  intervention_id UUID REFERENCES public.churn_interventions(id) ON DELETE SET NULL,

  -- Status
  status TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN (
    'scheduled',
    'sent',
    'canceled',
    'failed'
  )),

  -- Context data for personalization
  metadata JSONB DEFAULT '{}'::jsonb,

  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- INDEXES FOR PERFORMANCE
-- =============================================================================

-- Member Risk Scores indexes
CREATE INDEX IF NOT EXISTS idx_risk_scores_member
  ON public.member_risk_scores(member_id, calculated_date DESC);

-- Index for recent risk scores by organization and band
-- Note: Date filtering must be done in queries (CURRENT_DATE not IMMUTABLE)
CREATE INDEX IF NOT EXISTS idx_risk_scores_org_band
  ON public.member_risk_scores(organization_id, risk_band, calculated_date DESC);

CREATE INDEX IF NOT EXISTS idx_risk_scores_high_risk
  ON public.member_risk_scores(organization_id, calculated_date DESC)
  WHERE risk_band = 'high';

CREATE INDEX IF NOT EXISTS idx_risk_scores_days_since_visit
  ON public.member_risk_scores(organization_id, days_since_last_visit DESC)
  WHERE days_since_last_visit > 7;

-- Churn Interventions indexes
CREATE INDEX IF NOT EXISTS idx_interventions_member
  ON public.churn_interventions(member_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_interventions_org_status
  ON public.churn_interventions(organization_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_interventions_outcome
  ON public.churn_interventions(organization_id, outcome)
  WHERE outcome IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_interventions_initiated_by
  ON public.churn_interventions(initiated_by, created_at DESC)
  WHERE initiated_by IS NOT NULL;

-- Nudge Queue indexes
CREATE INDEX IF NOT EXISTS idx_nudge_queue_scheduled
  ON public.nudge_queue(organization_id, scheduled_for ASC)
  WHERE status = 'scheduled';

CREATE INDEX IF NOT EXISTS idx_nudge_queue_member
  ON public.nudge_queue(member_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_nudge_queue_template
  ON public.nudge_queue(organization_id, template_id, status);

-- =============================================================================
-- ENABLE ROW LEVEL SECURITY
-- =============================================================================

ALTER TABLE public.member_risk_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.churn_interventions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.nudge_queue ENABLE ROW LEVEL SECURITY;

-- =============================================================================
-- COMMENTS FOR DOCUMENTATION
-- =============================================================================

COMMENT ON TABLE public.member_risk_scores IS 'Daily calculated churn risk scores for members';
COMMENT ON TABLE public.churn_interventions IS 'Tracks all intervention attempts to prevent churn';
COMMENT ON TABLE public.nudge_queue IS 'Queue for scheduled automated member nudges';

COMMENT ON COLUMN public.member_risk_scores.risk_score IS 'Churn probability score from 0 (no risk) to 1 (high risk)';
COMMENT ON COLUMN public.member_risk_scores.contributing_factors IS 'Array of factors contributing to risk score';
COMMENT ON COLUMN public.member_risk_scores.variety_index IS 'Diversity of class types attended (0-1)';
COMMENT ON COLUMN public.churn_interventions.estimated_value_retained IS 'Estimated revenue saved by successful intervention';
COMMENT ON COLUMN public.nudge_queue.metadata IS 'Context data: favorite_class, ring_progress, streak_days, etc.';
