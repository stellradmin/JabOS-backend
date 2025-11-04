-- Row Level Security Policies
-- Ensures multi-tenant data isolation

-- =============================================================================
-- ORGANIZATIONS
-- =============================================================================

-- Users can view organizations they belong to
DROP POLICY IF EXISTS "Users can view their organizations" ON public.organizations;
CREATE POLICY "Users can view their organizations"
  ON public.organizations FOR SELECT
  USING (
    id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Only owners can update their organization
DROP POLICY IF EXISTS "Owners can update their organization" ON public.organizations;
CREATE POLICY "Owners can update their organization"
  ON public.organizations FOR UPDATE
  USING (
    id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role = 'owner'
    )
  );

-- =============================================================================
-- USERS
-- =============================================================================

-- Users can view other users in their organization
DROP POLICY IF EXISTS "Users can view org members" ON public.users;
CREATE POLICY "Users can view org members"
  ON public.users FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Users can update their own profile
DROP POLICY IF EXISTS "Users can update own profile" ON public.users;
CREATE POLICY "Users can update own profile"
  ON public.users FOR UPDATE
  USING (id = auth.uid());

-- Owners and coaches can update org members
DROP POLICY IF EXISTS "Owners and coaches can update members" ON public.users;
CREATE POLICY "Owners and coaches can update members"
  ON public.users FOR UPDATE
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

-- =============================================================================
-- MEMBER PROFILES
-- =============================================================================

-- Users can view profiles in their organization
DROP POLICY IF EXISTS "Users can view org member profiles" ON public.member_profiles;
CREATE POLICY "Users can view org member profiles"
  ON public.member_profiles FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Users can update their own profile
DROP POLICY IF EXISTS "Users can update own member profile" ON public.member_profiles;
CREATE POLICY "Users can update own member profile"
  ON public.member_profiles FOR UPDATE
  USING (user_id = auth.uid());

-- =============================================================================
-- CLASSES
-- =============================================================================

-- Users can view classes in their organization
DROP POLICY IF EXISTS "Users can view org classes" ON public.classes;
CREATE POLICY "Users can view org classes"
  ON public.classes FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Owners and coaches can manage classes
DROP POLICY IF EXISTS "Owners and coaches can manage classes" ON public.classes;
CREATE POLICY "Owners and coaches can manage classes"
  ON public.classes FOR ALL
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

-- =============================================================================
-- CLASS INSTANCES
-- =============================================================================

-- Users can view class instances in their organization
DROP POLICY IF EXISTS "Users can view org class instances" ON public.class_instances;
CREATE POLICY "Users can view org class instances"
  ON public.class_instances FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Owners and coaches can manage class instances
DROP POLICY IF EXISTS "Owners and coaches can manage class instances" ON public.class_instances;
CREATE POLICY "Owners and coaches can manage class instances"
  ON public.class_instances FOR ALL
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

-- =============================================================================
-- BOOKINGS
-- =============================================================================

-- Users can view bookings in their organization
DROP POLICY IF EXISTS "Users can view org bookings" ON public.bookings;
CREATE POLICY "Users can view org bookings"
  ON public.bookings FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Users can create their own bookings
DROP POLICY IF EXISTS "Users can create own bookings" ON public.bookings;
CREATE POLICY "Users can create own bookings"
  ON public.bookings FOR INSERT
  WITH CHECK (
    user_id = auth.uid() AND
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Users can cancel their own bookings
DROP POLICY IF EXISTS "Users can cancel own bookings" ON public.bookings;
CREATE POLICY "Users can cancel own bookings"
  ON public.bookings FOR UPDATE
  USING (user_id = auth.uid());

-- Coaches can manage all bookings in their org
DROP POLICY IF EXISTS "Coaches can manage org bookings" ON public.bookings;
CREATE POLICY "Coaches can manage org bookings"
  ON public.bookings FOR ALL
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

-- =============================================================================
-- TIMER PRESETS
-- =============================================================================

-- Users can view timer presets in their organization
DROP POLICY IF EXISTS "Users can view org timer presets" ON public.timer_presets;
CREATE POLICY "Users can view org timer presets"
  ON public.timer_presets FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Users can create their own presets
DROP POLICY IF EXISTS "Users can create own timer presets" ON public.timer_presets;
CREATE POLICY "Users can create own timer presets"
  ON public.timer_presets FOR INSERT
  WITH CHECK (
    created_by = auth.uid() AND
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- =============================================================================
-- WORKOUT LOGS
-- =============================================================================

-- Users can view workout logs in their organization
DROP POLICY IF EXISTS "Users can view org workout logs" ON public.workout_logs;
CREATE POLICY "Users can view org workout logs"
  ON public.workout_logs FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Users can create their own workout logs
DROP POLICY IF EXISTS "Users can create own workout logs" ON public.workout_logs;
CREATE POLICY "Users can create own workout logs"
  ON public.workout_logs FOR INSERT
  WITH CHECK (
    user_id = auth.uid() AND
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Users can update their own workout logs
DROP POLICY IF EXISTS "Users can update own workout logs" ON public.workout_logs;
CREATE POLICY "Users can update own workout logs"
  ON public.workout_logs FOR UPDATE
  USING (user_id = auth.uid());

-- =============================================================================
-- SPARRING MATCHES
-- =============================================================================

-- Users can view sparring matches they're involved in or in their org
DROP POLICY IF EXISTS "Users can view org sparring matches" ON public.sparring_matches;
CREATE POLICY "Users can view org sparring matches"
  ON public.sparring_matches FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Users can create sparring matches in their org
DROP POLICY IF EXISTS "Users can create sparring matches" ON public.sparring_matches;
CREATE POLICY "Users can create sparring matches"
  ON public.sparring_matches FOR INSERT
  WITH CHECK (
    (member_1_id = auth.uid() OR member_2_id = auth.uid()) AND
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Users can update matches they're involved in
DROP POLICY IF EXISTS "Users can update own sparring matches" ON public.sparring_matches;
CREATE POLICY "Users can update own sparring matches"
  ON public.sparring_matches FOR UPDATE
  USING (
    member_1_id = auth.uid() OR member_2_id = auth.uid()
  );

-- =============================================================================
-- ATTENDANCE
-- =============================================================================

-- Users can view attendance in their organization
DROP POLICY IF EXISTS "Users can view org attendance" ON public.attendance;
CREATE POLICY "Users can view org attendance"
  ON public.attendance FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Coaches can create attendance records
DROP POLICY IF EXISTS "Coaches can create attendance" ON public.attendance;
CREATE POLICY "Coaches can create attendance"
  ON public.attendance FOR INSERT
  WITH CHECK (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

-- =============================================================================
-- MEMBERSHIP PLANS
-- =============================================================================

-- Users can view membership plans in their organization
DROP POLICY IF EXISTS "Users can view org membership plans" ON public.membership_plans;
CREATE POLICY "Users can view org membership plans"
  ON public.membership_plans FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    )
  );

-- Owners can manage membership plans
DROP POLICY IF EXISTS "Owners can manage membership plans" ON public.membership_plans;
CREATE POLICY "Owners can manage membership plans"
  ON public.membership_plans FOR ALL
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role = 'owner'
    )
  );

-- =============================================================================
-- MEMBER SUBSCRIPTIONS
-- =============================================================================

-- Users can view their own subscription
DROP POLICY IF EXISTS "Users can view own subscription" ON public.member_subscriptions;
CREATE POLICY "Users can view own subscription"
  ON public.member_subscriptions FOR SELECT
  USING (user_id = auth.uid());

-- Owners and coaches can view all subscriptions in their org
DROP POLICY IF EXISTS "Staff can view org subscriptions" ON public.member_subscriptions;
CREATE POLICY "Staff can view org subscriptions"
  ON public.member_subscriptions FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

-- =============================================================================
-- MESSAGES & CONVERSATIONS
-- =============================================================================
-- Note: Conversation-based messaging RLS policies are defined in 0001_create_base_schema.sql
-- The messages table uses conversation_id, not direct recipient_id
-- No additional policies needed here

-- =============================================================================
-- ANNOUNCEMENTS
-- =============================================================================

-- Users can view announcements in their organization
DROP POLICY IF EXISTS "Users can view org announcements" ON public.announcements;
CREATE POLICY "Users can view org announcements"
  ON public.announcements FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users WHERE id = auth.uid()
    ) AND
    is_draft = false
  );

-- Owners and coaches can manage announcements
DROP POLICY IF EXISTS "Staff can manage announcements" ON public.announcements;
CREATE POLICY "Staff can manage announcements"
  ON public.announcements FOR ALL
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role IN ('owner', 'coach')
    )
  );

-- =============================================================================
-- GYM METRICS
-- =============================================================================

-- Owners can view metrics for their organization
DROP POLICY IF EXISTS "Owners can view org metrics" ON public.gym_metrics;
CREATE POLICY "Owners can view org metrics"
  ON public.gym_metrics FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role = 'owner'
    )
  );

-- Service role can insert/update metrics (for cron jobs)
-- Note: This will be handled by service role key, no RLS policy needed
