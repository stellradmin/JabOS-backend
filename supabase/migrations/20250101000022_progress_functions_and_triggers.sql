-- Progress System Helper Functions and Triggers
-- XP calculation, level progression, streak tracking, achievements, and RLS policies

-- =============================================================================
-- LEVEL CALCULATION FUNCTIONS
-- =============================================================================

-- Calculate member level from total XP
CREATE OR REPLACE FUNCTION public.calculate_level_from_xp(
  p_total_xp INTEGER,
  p_organization_id UUID
)
RETURNS TABLE(level INTEGER, xp_for_next_level INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
  thresholds INTEGER[];
  i INTEGER;
BEGIN
  -- Get level thresholds from org settings (fallback to defaults)
  SELECT COALESCE(
    ARRAY(SELECT jsonb_array_elements_text(settings->'xp_settings'->'level_thresholds')::INTEGER),
    ARRAY[0,100,250,450,700,1000,1350,1750,2200,2700,3250]
  ) INTO thresholds
  FROM public.organizations
  WHERE id = p_organization_id;

  -- Find current level by iterating through thresholds
  FOR i IN REVERSE array_length(thresholds, 1)..1 LOOP
    IF p_total_xp >= thresholds[i] THEN
      -- Return level and XP needed for next level
      RETURN QUERY SELECT
        i AS level,
        COALESCE(thresholds[i+1], thresholds[i] + 500) AS xp_for_next_level;
      RETURN;
    END IF;
  END LOOP;

  -- Default to level 1 if no match (shouldn't happen)
  RETURN QUERY SELECT 1 AS level, COALESCE(thresholds[2], 100) AS xp_for_next_level;
END;
$$;

-- =============================================================================
-- XP AWARD AND PROGRESS UPDATE TRIGGERS
-- =============================================================================

-- Update member progress when XP transaction is inserted
CREATE OR REPLACE FUNCTION public.update_member_progress_on_xp()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  new_level_data RECORD;
  old_level INTEGER;
  new_total_xp INTEGER;
BEGIN
  -- Get current level before update
  SELECT current_level INTO old_level
  FROM public.member_progress
  WHERE member_id = NEW.member_id;

  -- Upsert member_progress with new XP total
  INSERT INTO public.member_progress (
    member_id,
    organization_id,
    total_xp,
    current_level,
    xp_for_next_level,
    updated_at
  )
  VALUES (
    NEW.member_id,
    NEW.organization_id,
    NEW.amount,
    1,
    100,
    NOW()
  )
  ON CONFLICT (member_id) DO UPDATE
  SET
    total_xp = member_progress.total_xp + NEW.amount,
    updated_at = NOW()
  RETURNING total_xp INTO new_total_xp;

  -- Recalculate level based on new XP total
  SELECT * INTO new_level_data
  FROM public.calculate_level_from_xp(new_total_xp, NEW.organization_id);

  -- Update level if it changed
  UPDATE public.member_progress
  SET
    current_level = new_level_data.level,
    xp_for_next_level = new_level_data.xp_for_next_level
  WHERE member_id = NEW.member_id;

  -- If level increased, check for level-based achievements
  IF old_level IS NOT NULL AND new_level_data.level > old_level THEN
    PERFORM public.check_and_award_achievements(
      NEW.member_id,
      NEW.organization_id,
      'level_reached',
      new_level_data.level
    );
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER xp_transaction_update_progress
  AFTER INSERT ON public.xp_transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.update_member_progress_on_xp();

-- =============================================================================
-- STREAK CALCULATION TRIGGER
-- =============================================================================

-- Update streak when attendance is recorded
CREATE OR REPLACE FUNCTION public.update_streak_on_attendance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  last_attendance_date DATE;
  current_streak INTEGER;
  org_id UUID;
  new_streak INTEGER;
BEGIN
  -- Get org_id from member
  SELECT organization_id INTO org_id
  FROM public.users
  WHERE id = NEW.user_id;

  -- Get last attendance date and current streak
  SELECT
    MAX(check_in_time::DATE),
    COALESCE(mp.current_streak_days, 0)
  INTO last_attendance_date, current_streak
  FROM public.attendance a
  JOIN public.member_profiles mp ON a.user_id = mp.user_id
  WHERE a.user_id = NEW.user_id
    AND a.check_in_time < NEW.check_in_time
  GROUP BY mp.current_streak_days;

  -- Calculate new streak
  IF last_attendance_date IS NULL THEN
    -- First ever attendance
    new_streak := 1;
  ELSIF NEW.check_in_time::DATE = last_attendance_date THEN
    -- Same day attendance (don't increment)
    new_streak := COALESCE(current_streak, 1);
  ELSIF NEW.check_in_time::DATE = last_attendance_date + INTERVAL '1 day' THEN
    -- Consecutive day
    new_streak := COALESCE(current_streak, 0) + 1;
  ELSIF NEW.check_in_time::DATE <= last_attendance_date + INTERVAL '2 days' THEN
    -- Within grace period (48 hours) - keep streak
    new_streak := COALESCE(current_streak, 1);
  ELSE
    -- Streak broken, reset to 1
    new_streak := 1;
  END IF;

  -- Update member profile with new streak
  UPDATE public.member_profiles
  SET current_streak_days = new_streak
  WHERE user_id = NEW.user_id;

  -- Update member_progress last_activity_date
  UPDATE public.member_progress
  SET last_activity_date = NEW.check_in_time::DATE
  WHERE member_id = NEW.user_id;

  -- Check for streak-based achievements
  IF new_streak IN (7, 30, 90) THEN
    PERFORM public.check_and_award_achievements(
      NEW.user_id,
      org_id,
      'streak_days',
      new_streak
    );
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER attendance_update_streak
  AFTER INSERT ON public.attendance
  FOR EACH ROW
  EXECUTE FUNCTION public.update_streak_on_attendance();

-- =============================================================================
-- ACHIEVEMENT CHECK AND AWARD FUNCTIONS
-- =============================================================================

-- Check and award achievements based on trigger
CREATE OR REPLACE FUNCTION public.check_and_award_achievements(
  p_member_id UUID,
  p_organization_id UUID,
  p_trigger_type TEXT,
  p_trigger_value INTEGER
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  achievement_record RECORD;
BEGIN
  -- Find matching achievements that haven't been earned yet
  FOR achievement_record IN
    SELECT a.id, a.name, a.xp_reward
    FROM public.achievements a
    WHERE a.organization_id = p_organization_id
      AND a.trigger_type = p_trigger_type
      AND a.trigger_value = p_trigger_value
      AND a.is_active = true
      AND NOT EXISTS (
        SELECT 1 FROM public.member_achievements ma
        WHERE ma.member_id = p_member_id
          AND ma.achievement_id = a.id
      )
  LOOP
    -- Award the achievement
    INSERT INTO public.member_achievements (
      member_id,
      organization_id,
      achievement_id,
      earned_at
    )
    VALUES (
      p_member_id,
      p_organization_id,
      achievement_record.id,
      NOW()
    )
    ON CONFLICT (member_id, achievement_id) DO NOTHING;

    -- Award XP if applicable
    IF achievement_record.xp_reward > 0 THEN
      INSERT INTO public.xp_transactions (
        organization_id,
        member_id,
        amount,
        reason,
        related_type,
        related_id,
        metadata,
        created_at
      )
      VALUES (
        p_organization_id,
        p_member_id,
        achievement_record.xp_reward,
        'milestone_' || replace(lower(achievement_record.name), ' ', '_'),
        'achievement',
        achievement_record.id,
        jsonb_build_object('achievement_name', achievement_record.name),
        NOW()
      );
    END IF;
  END LOOP;
END;
$$;

-- =============================================================================
-- SPARRING ELIGIBILITY CHECK FUNCTION
-- =============================================================================

-- Check if member is eligible for sparring (multi-gate check)
CREATE OR REPLACE FUNCTION public.check_sparring_eligibility(
  p_member_id UUID
)
RETURNS TABLE(
  eligible BOOLEAN,
  reasons TEXT[]
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
  v_organization_id UUID;
  v_experience_level TEXT;
  v_sparring_eligible BOOLEAN;
  v_membership_allows BOOLEAN;
  v_reasons TEXT[] := ARRAY[]::TEXT[];
BEGIN
  -- Get member details
  SELECT
    u.organization_id,
    mp.experience_level,
    mp.sparring_eligible
  INTO
    v_organization_id,
    v_experience_level,
    v_sparring_eligible
  FROM public.users u
  JOIN public.member_profiles mp ON u.id = mp.user_id
  WHERE u.id = p_member_id;

  -- Check membership plan allows sparring
  SELECT COALESCE(
    (SELECT allows_sparring
     FROM public.membership_plans plan
     JOIN public.member_subscriptions sub ON plan.id = sub.membership_plan_id
     WHERE sub.user_id = p_member_id
       AND sub.status = 'active'
     LIMIT 1),
    false
  ) INTO v_membership_allows;

  -- Build eligibility response
  IF NOT v_membership_allows THEN
    v_reasons := array_append(v_reasons, 'Membership plan does not include sparring');
  END IF;

  IF v_experience_level = 'beginner' THEN
    v_reasons := array_append(v_reasons, 'Experience level: beginner (requires intermediate+)');
  END IF;

  IF NOT COALESCE(v_sparring_eligible, false) THEN
    v_reasons := array_append(v_reasons, 'Coach approval required');
  END IF;

  -- Member is eligible if all gates pass
  RETURN QUERY SELECT
    (array_length(v_reasons, 1) IS NULL OR array_length(v_reasons, 1) = 0) AS eligible,
    v_reasons AS reasons;
END;
$$;

-- =============================================================================
-- RING PROGRESS CALCULATION
-- =============================================================================

-- Update ring progress for a member
CREATE OR REPLACE FUNCTION public.update_ring_progress(
  p_member_id UUID,
  p_organization_id UUID,
  p_ring_type TEXT
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  week_start DATE;
  current_progress JSONB;
  ring_target INTEGER;
BEGIN
  -- Get start of current week (Monday)
  week_start := date_trunc('week', CURRENT_DATE)::DATE;

  -- Get target classes per ring from org settings
  SELECT COALESCE(
    (settings->'xp_settings'->>'ring_completion_target')::INTEGER,
    4
  ) INTO ring_target
  FROM public.organizations
  WHERE id = p_organization_id;

  -- Get current ring progress
  SELECT weekly_ring_progress INTO current_progress
  FROM public.member_progress
  WHERE member_id = p_member_id;

  -- Calculate new progress percentage (0-100)
  -- Count classes of this ring type this week
  WITH weekly_classes AS (
    SELECT COUNT(DISTINCT a.id)::INTEGER as count
    FROM public.attendance a
    JOIN public.class_instances ci ON a.class_instance_id = ci.id
    JOIN public.classes c ON ci.class_id = c.id
    WHERE a.user_id = p_member_id
      AND a.check_in_time >= week_start
      AND a.check_in_time < week_start + INTERVAL '7 days'
      -- TODO: Filter by ring type based on org settings class_type_map
  )
  UPDATE public.member_progress
  SET
    weekly_ring_progress = jsonb_set(
      COALESCE(weekly_ring_progress, '{}'::jsonb),
      ARRAY[p_ring_type],
      to_jsonb(LEAST(100, (SELECT count FROM weekly_classes) * 100 / ring_target))
    ),
    week_start_date = week_start,
    updated_at = NOW()
  WHERE member_id = p_member_id;
END;
$$;

-- =============================================================================
-- WEEKLY RING RESET FUNCTION (called by cron)
-- =============================================================================

-- Reset ring progress at start of each week
CREATE OR REPLACE FUNCTION public.reset_weekly_rings()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  week_start DATE;
BEGIN
  week_start := date_trunc('week', CURRENT_DATE)::DATE;

  -- Reset all member ring progress if new week
  UPDATE public.member_progress
  SET
    weekly_ring_progress = '{"strike": 0, "defense": 0, "sparring": 0, "conditioning": 0}'::jsonb,
    week_start_date = week_start,
    updated_at = NOW()
  WHERE week_start_date < week_start
     OR week_start_date IS NULL;
END;
$$;

-- =============================================================================
-- ROW LEVEL SECURITY POLICIES
-- =============================================================================

-- XP Transactions Policies
DROP POLICY IF EXISTS "Users can view own xp transactions" ON public.xp_transactions;
CREATE POLICY "Users can view own xp transactions"
  ON public.xp_transactions FOR SELECT
  USING (
    member_id = auth.uid()
    OR organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

-- Member Progress Policies
DROP POLICY IF EXISTS "Users can view own progress" ON public.member_progress;
CREATE POLICY "Users can view own progress"
  ON public.member_progress FOR SELECT
  USING (
    member_id = auth.uid()
    OR organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

DROP POLICY IF EXISTS "System can update member progress" ON public.member_progress;
CREATE POLICY "System can update member progress"
  ON public.member_progress FOR ALL
  USING (true)
  WITH CHECK (true);

-- Achievements Policies
DROP POLICY IF EXISTS "Users can view org achievements" ON public.achievements;
CREATE POLICY "Users can view org achievements"
  ON public.achievements FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Owners can manage achievements" ON public.achievements;
CREATE POLICY "Owners can manage achievements"
  ON public.achievements FOR ALL
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role = 'owner'
    )
  );

-- Member Achievements Policies
DROP POLICY IF EXISTS "Users can view org member achievements" ON public.member_achievements;
CREATE POLICY "Users can view org member achievements"
  ON public.member_achievements FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "System can insert member achievements" ON public.member_achievements;
CREATE POLICY "System can insert member achievements"
  ON public.member_achievements FOR INSERT
  WITH CHECK (true);

-- Member Risk Scores Policies
DROP POLICY IF EXISTS "Staff can view risk scores" ON public.member_risk_scores;
CREATE POLICY "Staff can view risk scores"
  ON public.member_risk_scores FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

DROP POLICY IF EXISTS "System can manage risk scores" ON public.member_risk_scores;
CREATE POLICY "System can manage risk scores"
  ON public.member_risk_scores FOR ALL
  USING (true)
  WITH CHECK (true);

-- Churn Interventions Policies
DROP POLICY IF EXISTS "Staff can view interventions" ON public.churn_interventions;
CREATE POLICY "Staff can view interventions"
  ON public.churn_interventions FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

DROP POLICY IF EXISTS "Staff can create interventions" ON public.churn_interventions;
CREATE POLICY "Staff can create interventions"
  ON public.churn_interventions FOR INSERT
  WITH CHECK (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

DROP POLICY IF EXISTS "Staff can update interventions" ON public.churn_interventions;
CREATE POLICY "Staff can update interventions"
  ON public.churn_interventions FOR UPDATE
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

-- Nudge Queue Policies
DROP POLICY IF EXISTS "System can manage nudge queue" ON public.nudge_queue;
CREATE POLICY "System can manage nudge queue"
  ON public.nudge_queue FOR ALL
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS "Staff can view nudge queue" ON public.nudge_queue;
CREATE POLICY "Staff can view nudge queue"
  ON public.nudge_queue FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

-- =============================================================================
-- UPDATED_AT TRIGGERS
-- =============================================================================

CREATE TRIGGER update_member_progress_updated_at
  BEFORE UPDATE ON public.member_progress
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_achievements_updated_at
  BEFORE UPDATE ON public.achievements
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- =============================================================================
-- GRANT PERMISSIONS
-- =============================================================================

GRANT EXECUTE ON FUNCTION public.calculate_level_from_xp(INTEGER, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_and_award_achievements(UUID, UUID, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_sparring_eligibility(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_ring_progress(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reset_weekly_rings() TO authenticated;
