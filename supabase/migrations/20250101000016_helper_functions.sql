-- Helper Functions and Triggers

-- =============================================================================
-- UPDATED_AT TRIGGER FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply updated_at trigger to all tables
CREATE TRIGGER update_organizations_updated_at BEFORE UPDATE ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_member_profiles_updated_at BEFORE UPDATE ON public.member_profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_classes_updated_at BEFORE UPDATE ON public.classes
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_class_instances_updated_at BEFORE UPDATE ON public.class_instances
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_bookings_updated_at BEFORE UPDATE ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_timer_presets_updated_at BEFORE UPDATE ON public.timer_presets
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_workout_logs_updated_at BEFORE UPDATE ON public.workout_logs
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_sparring_matches_updated_at BEFORE UPDATE ON public.sparring_matches
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_attendance_updated_at BEFORE UPDATE ON public.attendance
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_membership_plans_updated_at BEFORE UPDATE ON public.membership_plans
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_member_subscriptions_updated_at BEFORE UPDATE ON public.member_subscriptions
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_messages_updated_at BEFORE UPDATE ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_announcements_updated_at BEFORE UPDATE ON public.announcements
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_gym_metrics_updated_at BEFORE UPDATE ON public.gym_metrics
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- =============================================================================
-- PERMISSION HELPER FUNCTIONS
-- =============================================================================

-- Check if user belongs to organization
CREATE OR REPLACE FUNCTION public.is_org_member(
  p_user_id UUID,
  p_organization_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = p_user_id
    AND organization_id = p_organization_id
  );
$$;

-- Check if user has specific role in organization
CREATE OR REPLACE FUNCTION public.has_role(
  p_user_id UUID,
  p_organization_id UUID,
  p_role TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = p_user_id
    AND organization_id = p_organization_id
    AND role = p_role
  );
$$;

-- Check if user is owner or coach
CREATE OR REPLACE FUNCTION public.is_staff(
  p_user_id UUID,
  p_organization_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = p_user_id
    AND organization_id = p_organization_id
    AND role IN ('owner', 'coach')
  );
$$;

-- Get user's organization ID
CREATE OR REPLACE FUNCTION public.get_user_organization(
  p_user_id UUID
)
RETURNS UUID
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT organization_id FROM public.users
  WHERE id = p_user_id
  LIMIT 1;
$$;

-- =============================================================================
-- BOOKING HELPER FUNCTIONS
-- =============================================================================

-- Check if class instance has available capacity
CREATE OR REPLACE FUNCTION public.has_available_capacity(
  p_class_instance_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
  v_max_capacity INTEGER;
  v_current_bookings INTEGER;
BEGIN
  -- Get max capacity (from instance override or parent class)
  SELECT
    COALESCE(ci.max_capacity, c.max_capacity) INTO v_max_capacity
  FROM public.class_instances ci
  JOIN public.classes c ON c.id = ci.class_id
  WHERE ci.id = p_class_instance_id;

  -- Count current confirmed bookings
  SELECT COUNT(*) INTO v_current_bookings
  FROM public.bookings
  WHERE class_instance_id = p_class_instance_id
  AND status = 'confirmed';

  RETURN v_current_bookings < v_max_capacity;
END;
$$;

-- Get user's active bookings for a specific class instance
CREATE OR REPLACE FUNCTION public.get_user_booking_status(
  p_user_id UUID,
  p_class_instance_id UUID
)
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT status FROM public.bookings
  WHERE user_id = p_user_id
  AND class_instance_id = p_class_instance_id
  AND status IN ('confirmed', 'waitlist')
  LIMIT 1;
$$;

-- =============================================================================
-- STATS UPDATE TRIGGERS
-- =============================================================================

-- Update class instance booking counts when booking changes
CREATE OR REPLACE FUNCTION public.update_class_instance_booking_stats()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    UPDATE public.class_instances
    SET total_bookings = (
      SELECT COUNT(*) FROM public.bookings
      WHERE class_instance_id = NEW.class_instance_id
      AND status IN ('confirmed', 'waitlist')
    )
    WHERE id = NEW.class_instance_id;

    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.class_instances
    SET total_bookings = (
      SELECT COUNT(*) FROM public.bookings
      WHERE class_instance_id = OLD.class_instance_id
      AND status IN ('confirmed', 'waitlist')
    )
    WHERE id = OLD.class_instance_id;

    RETURN OLD;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_class_instance_stats AFTER INSERT OR UPDATE OR DELETE ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.update_class_instance_booking_stats();

-- Update member profile stats when workout logged
CREATE OR REPLACE FUNCTION public.update_member_workout_stats()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.member_profiles
    SET total_workouts = total_workouts + 1
    WHERE user_id = NEW.user_id;

    RETURN NEW;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_member_stats_on_workout AFTER INSERT ON public.workout_logs
  FOR EACH ROW EXECUTE FUNCTION public.update_member_workout_stats();

-- Update member profile stats when attendance recorded
CREATE OR REPLACE FUNCTION public.update_member_attendance_stats()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.class_instance_id IS NOT NULL THEN
    UPDATE public.member_profiles
    SET total_classes_attended = total_classes_attended + 1
    WHERE user_id = NEW.user_id;

    RETURN NEW;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_member_stats_on_attendance AFTER INSERT ON public.attendance
  FOR EACH ROW EXECUTE FUNCTION public.update_member_attendance_stats();

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

-- Generate unique slug from name
CREATE OR REPLACE FUNCTION public.generate_slug(
  p_name TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_slug TEXT;
  v_counter INTEGER := 0;
  v_final_slug TEXT;
BEGIN
  -- Convert to lowercase, replace spaces with hyphens, remove special chars
  v_slug := lower(regexp_replace(p_name, '[^a-zA-Z0-9\s-]', '', 'g'));
  v_slug := regexp_replace(v_slug, '\s+', '-', 'g');
  v_slug := regexp_replace(v_slug, '-+', '-', 'g');
  v_slug := trim(both '-' from v_slug);

  v_final_slug := v_slug;

  -- Check for uniqueness and append counter if needed
  WHILE EXISTS (SELECT 1 FROM public.organizations WHERE slug = v_final_slug) LOOP
    v_counter := v_counter + 1;
    v_final_slug := v_slug || '-' || v_counter;
  END LOOP;

  RETURN v_final_slug;
END;
$$;

-- Grant execute permissions to authenticated users
GRANT EXECUTE ON FUNCTION public.is_org_member(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_role(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_staff(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_organization(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_available_capacity(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_booking_status(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_slug(TEXT) TO authenticated;
