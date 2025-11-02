-- =====================================================
-- INVITE SYSTEM SCHEMA
-- =====================================================
-- This migration creates the invite tracking system for Stellr Beta
-- Integrates with RevenueCat for premium tier (20 invites/day vs 5 free)
-- Date: 2025-10-25
-- =====================================================

BEGIN;

-- =====================================================
-- 1. ADD INVITE TRACKING COLUMNS TO PROFILES TABLE
-- =====================================================

-- Add subscription and invite tracking columns to profiles
ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS subscription_status TEXT DEFAULT 'free' CHECK (subscription_status IN ('free', 'premium', 'premium_cancelled')),
ADD COLUMN IF NOT EXISTS subscription_platform TEXT CHECK (subscription_platform IN ('ios', 'android') OR subscription_platform IS NULL),
ADD COLUMN IF NOT EXISTS revenue_cat_user_id TEXT,
ADD COLUMN IF NOT EXISTS daily_invites_remaining INTEGER DEFAULT 5 CHECK (daily_invites_remaining >= 0),
ADD COLUMN IF NOT EXISTS last_invite_reset_date DATE DEFAULT CURRENT_DATE;

-- Create unique constraint on revenue_cat_user_id
ALTER TABLE profiles
ADD CONSTRAINT profiles_revenue_cat_user_id_key UNIQUE (revenue_cat_user_id);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_profiles_revenue_cat ON profiles(revenue_cat_user_id) WHERE revenue_cat_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_profiles_subscription_status ON profiles(subscription_status);
CREATE INDEX IF NOT EXISTS idx_profiles_last_invite_reset ON profiles(last_invite_reset_date);

-- Add comments for documentation
COMMENT ON COLUMN profiles.subscription_status IS 'User subscription tier: free (5 invites/day), premium (20 invites/day), or premium_cancelled (active until expiration)';
COMMENT ON COLUMN profiles.subscription_platform IS 'Platform where subscription was purchased: ios or android';
COMMENT ON COLUMN profiles.revenue_cat_user_id IS 'RevenueCat app_user_id for subscription tracking (maps to auth.users.id)';
COMMENT ON COLUMN profiles.daily_invites_remaining IS 'Number of invites remaining for today (resets daily)';
COMMENT ON COLUMN profiles.last_invite_reset_date IS 'Date when invites were last reset (used to determine if daily reset is needed)';

-- =====================================================
-- 2. CREATE INVITE USAGE LOG TABLE
-- =====================================================

CREATE TABLE IF NOT EXISTS invite_usage_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    invited_user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    used_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    subscription_status TEXT NOT NULL CHECK (subscription_status IN ('free', 'premium', 'premium_cancelled')),

    -- Metadata for analytics
    metadata JSONB DEFAULT '{}'::jsonb,

    -- Prevent duplicate logging
    UNIQUE(user_id, invited_user_id, used_at)
);

-- Create indexes for analytics and queries
CREATE INDEX IF NOT EXISTS idx_invite_usage_user_id ON invite_usage_log(user_id);
CREATE INDEX IF NOT EXISTS idx_invite_usage_invited_user_id ON invite_usage_log(invited_user_id);
CREATE INDEX IF NOT EXISTS idx_invite_usage_user_date ON invite_usage_log(user_id, used_at DESC);
CREATE INDEX IF NOT EXISTS idx_invite_usage_date ON invite_usage_log(used_at DESC);
CREATE INDEX IF NOT EXISTS idx_invite_usage_subscription_status ON invite_usage_log(subscription_status);

-- Add table comment
COMMENT ON TABLE invite_usage_log IS 'Tracks daily invite usage for analytics, rate limiting, and audit trail. Captures subscription status at time of use.';

-- =====================================================
-- 3. ENABLE ROW LEVEL SECURITY
-- =====================================================

ALTER TABLE invite_usage_log ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Users can view their own invite usage
CREATE POLICY "Users can view their own invite usage" ON invite_usage_log
    FOR SELECT USING (auth.uid() = user_id);

-- RLS Policy: Service role can manage all invite logs
CREATE POLICY "Service role can manage invite usage logs" ON invite_usage_log
    FOR ALL USING (auth.role() = 'service_role');

-- =====================================================
-- 4. CREATE HELPER FUNCTIONS
-- =====================================================

-- Function to check if user has invites available
CREATE OR REPLACE FUNCTION has_invites_available(user_uuid UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_remaining INTEGER;
    v_last_reset DATE;
    v_today DATE;
BEGIN
    -- Get current date
    v_today := CURRENT_DATE;

    -- Get user's invite status
    SELECT daily_invites_remaining, last_invite_reset_date
    INTO v_remaining, v_last_reset
    FROM profiles
    WHERE id = user_uuid;

    -- If no record found, return false
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- If last reset was not today, user will get fresh invites on next check
    -- Return true if they have invites OR if reset is pending
    RETURN v_remaining > 0 OR v_last_reset < v_today;
END;
$$;

-- Function to get user invite status
CREATE OR REPLACE FUNCTION get_invite_status(user_uuid UUID)
RETURNS TABLE (
    remaining INTEGER,
    total INTEGER,
    is_premium BOOLEAN,
    needs_reset BOOLEAN,
    last_reset DATE
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_subscription_status TEXT;
    v_remaining INTEGER;
    v_last_reset DATE;
    v_today DATE;
    v_is_premium BOOLEAN;
    v_total INTEGER;
    v_needs_reset BOOLEAN;
BEGIN
    -- Get current date
    v_today := CURRENT_DATE;

    -- Get user's subscription and invite status
    SELECT
        subscription_status,
        daily_invites_remaining,
        last_invite_reset_date
    INTO
        v_subscription_status,
        v_remaining,
        v_last_reset
    FROM profiles
    WHERE id = user_uuid;

    -- Determine if user is premium
    v_is_premium := v_subscription_status IN ('premium', 'premium_cancelled');

    -- Set total based on subscription
    v_total := CASE WHEN v_is_premium THEN 20 ELSE 5 END;

    -- Check if reset is needed
    v_needs_reset := (v_last_reset IS NULL OR v_last_reset < v_today);

    -- If reset needed, remaining should be total
    IF v_needs_reset THEN
        v_remaining := v_total;
    END IF;

    RETURN QUERY SELECT v_remaining, v_total, v_is_premium, v_needs_reset, v_last_reset;
END;
$$;

-- =====================================================
-- 5. GRANTS
-- =====================================================

GRANT SELECT ON invite_usage_log TO authenticated;
GRANT ALL ON invite_usage_log TO service_role;

GRANT EXECUTE ON FUNCTION has_invites_available(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_invite_status(UUID) TO authenticated, service_role;

-- =====================================================
-- 6. VALIDATION & MIGRATION CONFIRMATION
-- =====================================================

DO $$
DECLARE
    column_count INTEGER;
    table_exists BOOLEAN;
    function_count INTEGER;
BEGIN
    -- Check if columns were added to profiles
    SELECT COUNT(*) INTO column_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
    AND table_name = 'profiles'
    AND column_name IN ('subscription_status', 'revenue_cat_user_id', 'daily_invites_remaining', 'last_invite_reset_date');

    -- Check if invite_usage_log table exists
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'invite_usage_log'
    ) INTO table_exists;

    -- Check if helper functions exist
    SELECT COUNT(*) INTO function_count
    FROM information_schema.routines
    WHERE routine_schema = 'public'
    AND routine_name IN ('has_invites_available', 'get_invite_status');

    RAISE NOTICE '✅ Invite System Migration Complete';
    RAISE NOTICE '  - Added % columns to profiles table', column_count;
    RAISE NOTICE '  - invite_usage_log table created: %', table_exists;
    RAISE NOTICE '  - Created % helper functions', function_count;
    RAISE NOTICE '  - RLS policies enabled for invite_usage_log';
    RAISE NOTICE '  - Indexes created for performance';
END $$;

COMMIT;

-- =====================================================
-- DOCUMENTATION
-- =====================================================

COMMENT ON FUNCTION has_invites_available(UUID) IS 'Check if user has invites available today (accounts for pending daily reset)';
COMMENT ON FUNCTION get_invite_status(UUID) IS 'Get detailed invite status for a user including remaining, total, premium status, and reset status';
