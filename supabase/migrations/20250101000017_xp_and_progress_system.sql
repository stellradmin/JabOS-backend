-- XP and Progress System
-- Gamification features: XP tracking, levels, achievements, and progress rings

-- =============================================================================
-- XP TRANSACTIONS TABLE
-- =============================================================================
-- Audit trail for all XP awards
CREATE TABLE IF NOT EXISTS public.xp_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  member_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  amount INTEGER NOT NULL CHECK (amount != 0),  -- Can be positive or negative
  reason TEXT NOT NULL CHECK (reason IN (
    'class_attendance',
    'workout_log',
    'sparring_complete',
    'streak_bonus',
    'milestone_10_classes',
    'milestone_25_classes',
    'milestone_50_classes',
    'milestone_100_classes',
    'first_sparring_match',
    'level_up',
    'manual_adjustment'
  )),

  -- Link to the originating event
  related_type TEXT CHECK (related_type IN ('attendance', 'workout', 'sparring', 'achievement')),
  related_id UUID,

  -- Additional context as JSON
  metadata JSONB DEFAULT '{}'::jsonb,

  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- MEMBER PROGRESS TABLE
-- =============================================================================
-- Denormalized progress data for fast queries
CREATE TABLE IF NOT EXISTS public.member_progress (
  member_id UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- XP and Level
  total_xp INTEGER NOT NULL DEFAULT 0 CHECK (total_xp >= 0),
  current_level INTEGER NOT NULL DEFAULT 1 CHECK (current_level >= 1 AND current_level <= 50),
  xp_for_next_level INTEGER NOT NULL DEFAULT 100,

  -- Activity tracking
  last_activity_date DATE,

  -- Weekly ring progress (resets each week)
  -- Structure: {strike: 0-100, defense: 0-100, sparring: 0-100, conditioning: 0-100}
  weekly_ring_progress JSONB NOT NULL DEFAULT '{"strike": 0, "defense": 0, "sparring": 0, "conditioning": 0}'::jsonb,
  week_start_date DATE,  -- Track which week this progress is for

  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- ACHIEVEMENTS TABLE
-- =============================================================================
-- Achievement definitions (configurable per organization)
CREATE TABLE IF NOT EXISTS public.achievements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Achievement details
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  icon TEXT,  -- Icon name, emoji, or URL

  -- Reward
  xp_reward INTEGER NOT NULL DEFAULT 0 CHECK (xp_reward >= 0),

  -- Trigger configuration
  trigger_type TEXT NOT NULL CHECK (trigger_type IN (
    'class_count',          -- Triggered after N classes
    'streak_days',          -- Triggered after N consecutive days
    'sparring_count',       -- Triggered after N sparring sessions
    'level_reached',        -- Triggered when reaching specific level
    'workout_count',        -- Triggered after N workouts
    'ring_completion',      -- Triggered when completing all rings
    'manual'                -- Manually awarded by staff
  )),
  trigger_value INTEGER,    -- The threshold value (e.g., 10 for "10 classes")

  -- Status
  is_active BOOLEAN NOT NULL DEFAULT true,

  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Ensure unique achievement names per org
  UNIQUE(organization_id, name)
);

-- =============================================================================
-- MEMBER ACHIEVEMENTS TABLE
-- =============================================================================
-- Track which achievements each member has earned
CREATE TABLE IF NOT EXISTS public.member_achievements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  achievement_id UUID NOT NULL REFERENCES public.achievements(id) ON DELETE CASCADE,

  -- When it was earned
  earned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Prevent duplicate achievements
  UNIQUE(member_id, achievement_id)
);

-- =============================================================================
-- INDEXES FOR PERFORMANCE
-- =============================================================================

-- XP Transactions indexes
CREATE INDEX IF NOT EXISTS idx_xp_transactions_member
  ON public.xp_transactions(member_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_xp_transactions_org
  ON public.xp_transactions(organization_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_xp_transactions_reason
  ON public.xp_transactions(organization_id, reason);

-- Member Progress indexes
CREATE INDEX IF NOT EXISTS idx_member_progress_org
  ON public.member_progress(organization_id);

CREATE INDEX IF NOT EXISTS idx_member_progress_level
  ON public.member_progress(organization_id, current_level DESC);

CREATE INDEX IF NOT EXISTS idx_member_progress_activity
  ON public.member_progress(organization_id, last_activity_date DESC NULLS LAST);

-- Achievements indexes
CREATE INDEX IF NOT EXISTS idx_achievements_org_active
  ON public.achievements(organization_id, is_active)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_achievements_trigger
  ON public.achievements(organization_id, trigger_type);

-- Member Achievements indexes
CREATE INDEX IF NOT EXISTS idx_member_achievements_member
  ON public.member_achievements(member_id, earned_at DESC);

CREATE INDEX IF NOT EXISTS idx_member_achievements_org
  ON public.member_achievements(organization_id, earned_at DESC);

CREATE INDEX IF NOT EXISTS idx_member_achievements_achievement
  ON public.member_achievements(achievement_id);

-- =============================================================================
-- ENABLE ROW LEVEL SECURITY
-- =============================================================================

ALTER TABLE public.xp_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_achievements ENABLE ROW LEVEL SECURITY;

-- =============================================================================
-- COMMENTS FOR DOCUMENTATION
-- =============================================================================

COMMENT ON TABLE public.xp_transactions IS 'Audit trail of all XP awards and adjustments';
COMMENT ON TABLE public.member_progress IS 'Denormalized member progress data for performance';
COMMENT ON TABLE public.achievements IS 'Achievement definitions configurable per organization';
COMMENT ON TABLE public.member_achievements IS 'Tracks which achievements each member has earned';

COMMENT ON COLUMN public.member_progress.weekly_ring_progress IS 'Progress toward weekly ring goals (0-100 per category)';
COMMENT ON COLUMN public.xp_transactions.metadata IS 'Additional context: class_name, ring_type, streak_days, etc.';
COMMENT ON COLUMN public.achievements.trigger_type IS 'Type of event that triggers this achievement';
COMMENT ON COLUMN public.achievements.trigger_value IS 'Threshold value for triggering (e.g., 10 for "10 classes")';
