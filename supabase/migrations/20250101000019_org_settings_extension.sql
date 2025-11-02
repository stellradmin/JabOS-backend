-- Organization Settings Extension
-- Adds XP configuration, churn settings, and sparring eligibility tracking

-- =============================================================================
-- EXTEND MEMBER PROFILES WITH SPARRING ELIGIBILITY
-- =============================================================================

-- Add sparring eligibility tracking fields
ALTER TABLE public.member_profiles
ADD COLUMN IF NOT EXISTS sparring_eligible BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.member_profiles
ADD COLUMN IF NOT EXISTS sparring_approved_by UUID REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE public.member_profiles
ADD COLUMN IF NOT EXISTS sparring_approved_at TIMESTAMPTZ;

ALTER TABLE public.member_profiles
ADD COLUMN IF NOT EXISTS sparring_approval_notes TEXT;

-- Create index for sparring eligibility queries
CREATE INDEX IF NOT EXISTS idx_member_profiles_sparring_eligible
  ON public.member_profiles(organization_id, sparring_eligible)
  WHERE sparring_eligible = true;

-- =============================================================================
-- SET DEFAULT XP & CHURN SETTINGS FOR ORGANIZATIONS
-- =============================================================================

-- Function to initialize default settings for existing organizations
CREATE OR REPLACE FUNCTION public.initialize_org_xp_settings()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  -- Update existing organizations without xp_settings
  UPDATE public.organizations
  SET settings = jsonb_set(
    COALESCE(settings, '{}'::jsonb),
    '{xp_settings}',
    jsonb_build_object(
      'enabled', true,
      'ring_categories', jsonb_build_object(
        'strike', jsonb_build_array(),
        'defense', jsonb_build_array(),
        'sparring', jsonb_build_array(),
        'conditioning', jsonb_build_array()
      ),
      'tier_weights', jsonb_build_object(
        'beginner', 30,
        'intermediate', 40,
        'advanced', 50,
        'pro', 60
      ),
      'streak_multipliers', jsonb_build_object(
        '7', 1.25,
        '30', 1.5,
        '90', 2.0
      ),
      'milestone_classes', jsonb_build_array(10, 25, 50, 100, 250, 500),
      'level_thresholds', jsonb_build_array(
        0, 100, 250, 450, 700, 1000, 1350, 1750, 2200, 2700,
        3250, 3850, 4500, 5200, 5950, 6750, 7600, 8500, 9450, 10450,
        11500, 12600, 13750, 14950, 16200, 17500, 18850, 20250, 21700, 23200,
        24750, 26350, 28000, 29700, 31450, 33250, 35100, 37000, 38950, 40950,
        43000, 45100, 47250, 49450, 51700, 54000, 56350, 58750, 61200, 63700
      ),
      'ring_completion_target', 4,
      'variety_bonus_xp', 10
    ),
    true
  )
  WHERE settings->>'xp_settings' IS NULL;

  -- Add churn rescue settings
  UPDATE public.organizations
  SET settings = jsonb_set(
    COALESCE(settings, '{}'::jsonb),
    '{churn_settings}',
    jsonb_build_object(
      'enabled', true,
      'risk_weights', jsonb_build_object(
        'no_attendance_7d', 0.2,
        'no_attendance_14d', 0.4,
        'no_attendance_30d', 0.6,
        'attendance_declining', 0.3,
        'variety_low', 0.2,
        'streak_broken', 0.2,
        'subscription_expiring_soon', 0.25
      ),
      'nudge_frequency_days', 7,
      'max_nudges_per_week', 2,
      'quiet_hours_start', '22:00',
      'quiet_hours_end', '08:00',
      'high_risk_threshold', 0.7,
      'medium_risk_threshold', 0.4
    ),
    true
  )
  WHERE settings->>'churn_settings' IS NULL;
END;
$$;

-- Execute the initialization function
SELECT public.initialize_org_xp_settings();

-- Drop the function after execution (cleanup)
DROP FUNCTION public.initialize_org_xp_settings();

-- =============================================================================
-- SEED DEFAULT ACHIEVEMENTS FOR ALL ORGANIZATIONS
-- =============================================================================

-- Function to create default achievements for an organization
CREATE OR REPLACE FUNCTION public.seed_default_achievements(p_org_id UUID)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  -- Insert default achievements if they don't exist
  INSERT INTO public.achievements (organization_id, name, description, icon, xp_reward, trigger_type, trigger_value, is_active)
  VALUES
    -- Class milestones
    (p_org_id, 'First Step', 'Completed your first class', '🥊', 50, 'class_count', 1, true),
    (p_org_id, 'Getting Started', 'Completed 10 classes', '💪', 100, 'class_count', 10, true),
    (p_org_id, 'Regular', 'Completed 25 classes', '🔥', 150, 'class_count', 25, true),
    (p_org_id, 'Committed', 'Completed 50 classes', '⭐', 200, 'class_count', 50, true),
    (p_org_id, 'Century', 'Completed 100 classes', '💯', 300, 'class_count', 100, true),
    (p_org_id, 'Unstoppable', 'Completed 250 classes', '🏆', 500, 'class_count', 250, true),

    -- Streak milestones
    (p_org_id, 'Week Warrior', '7-day training streak', '🔥', 100, 'streak_days', 7, true),
    (p_org_id, 'Month Master', '30-day training streak', '📅', 300, 'streak_days', 30, true),
    (p_org_id, 'Quarter Champion', '90-day training streak', '👑', 1000, 'streak_days', 90, true),

    -- Sparring achievements
    (p_org_id, 'First Spar', 'Completed your first sparring session', '🥊', 150, 'sparring_count', 1, true),
    (p_org_id, 'Sparring Regular', 'Completed 10 sparring sessions', '🥷', 250, 'sparring_count', 10, true),

    -- Level achievements
    (p_org_id, 'Level 5', 'Reached Level 5', '⬆️', 100, 'level_reached', 5, true),
    (p_org_id, 'Level 10', 'Reached Level 10', '⬆️⬆️', 250, 'level_reached', 10, true),
    (p_org_id, 'Level 25', 'Reached Level 25', '⬆️⬆️⬆️', 500, 'level_reached', 25, true),
    (p_org_id, 'Level 50', 'Reached Level 50', '🌟', 1000, 'level_reached', 50, true)
  ON CONFLICT (organization_id, name) DO NOTHING;
END;
$$;

-- Seed achievements for all existing organizations
DO $$
DECLARE
  org_record RECORD;
BEGIN
  FOR org_record IN SELECT id FROM public.organizations LOOP
    PERFORM public.seed_default_achievements(org_record.id);
  END LOOP;
END $$;

-- Create trigger to seed achievements for new organizations
CREATE OR REPLACE FUNCTION public.seed_achievements_for_new_org()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM public.seed_default_achievements(NEW.id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER seed_achievements_on_org_create
  AFTER INSERT ON public.organizations
  FOR EACH ROW
  EXECUTE FUNCTION public.seed_achievements_for_new_org();

-- =============================================================================
-- INITIALIZE MEMBER PROGRESS FOR EXISTING MEMBERS
-- =============================================================================

-- Insert member_progress records for existing members
INSERT INTO public.member_progress (
  member_id,
  organization_id,
  total_xp,
  current_level,
  xp_for_next_level,
  last_activity_date,
  weekly_ring_progress,
  week_start_date
)
SELECT
  u.id as member_id,
  u.organization_id,
  0 as total_xp,
  1 as current_level,
  100 as xp_for_next_level,
  NULL as last_activity_date,
  '{"strike": 0, "defense": 0, "sparring": 0, "conditioning": 0}'::jsonb as weekly_ring_progress,
  date_trunc('week', CURRENT_DATE)::date as week_start_date
FROM public.users u
WHERE u.role = 'member'
  AND NOT EXISTS (
    SELECT 1 FROM public.member_progress mp
    WHERE mp.member_id = u.id
  )
ON CONFLICT (member_id) DO NOTHING;

-- =============================================================================
-- COMMENTS FOR DOCUMENTATION
-- =============================================================================

COMMENT ON COLUMN public.member_profiles.sparring_eligible IS 'Multi-gate check: membership plan + experience + coach approval';
COMMENT ON COLUMN public.member_profiles.sparring_approved_by IS 'Coach who approved sparring access';
COMMENT ON COLUMN public.member_profiles.sparring_approved_at IS 'When sparring was approved';
COMMENT ON COLUMN public.member_profiles.sparring_approval_notes IS 'Coach notes on sparring approval decision';

-- Grant execute permission on the seed function
GRANT EXECUTE ON FUNCTION public.seed_default_achievements(UUID) TO authenticated;
