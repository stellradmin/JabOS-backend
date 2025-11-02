-- =====================================================
-- HAS_ACTIVE_PREMIUM RPC FUNCTION
-- =====================================================
-- Creates database function to check if a user has active premium entitlement
-- Used by frontend RevenueCat service for server-side subscription verification
-- Date: 2025-10-25
-- =====================================================

BEGIN;

-- =====================================================
-- 1. CREATE FUNCTION
-- =====================================================

CREATE OR REPLACE FUNCTION has_active_premium(user_uuid UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_has_premium BOOLEAN;
BEGIN
    -- Check if user has an active 'premium' entitlement in revenuecat_entitlements table
    SELECT EXISTS (
        SELECT 1
        FROM revenuecat_entitlements
        WHERE user_id = (SELECT id FROM users WHERE auth_user_id = user_uuid)
        AND entitlement_id = 'premium'
        AND is_active = true
    ) INTO v_has_premium;

    -- If no entitlement record found, check profiles table as fallback
    -- This handles cases where subscription is synced but entitlements table hasn't been updated yet
    IF NOT v_has_premium THEN
        SELECT EXISTS (
            SELECT 1
            FROM profiles
            WHERE id = user_uuid
            AND subscription_status IN ('premium', 'premium_cancelled')
        ) INTO v_has_premium;
    END IF;

    RETURN COALESCE(v_has_premium, false);
END;
$$;

-- =====================================================
-- 2. GRANT PERMISSIONS
-- =====================================================

-- Allow authenticated users and service role to execute function
GRANT EXECUTE ON FUNCTION has_active_premium(UUID) TO authenticated, service_role, anon;

-- =====================================================
-- 3. ADD COMMENTS
-- =====================================================

COMMENT ON FUNCTION has_active_premium(UUID) IS 'Check if user has an active premium subscription entitlement. Returns true if user has active "premium" entitlement in RevenueCat or premium status in profiles table.';

-- =====================================================
-- 4. CREATE RELATED HELPER FUNCTIONS
-- =====================================================

-- Function to get all active entitlements for a user
CREATE OR REPLACE FUNCTION get_active_entitlements(user_uuid UUID)
RETURNS TABLE (
    entitlement_id TEXT,
    product_id TEXT,
    purchase_date TIMESTAMPTZ,
    expires_date TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.entitlement_id,
        e.product_id,
        e.purchase_date,
        e.expires_date
    FROM revenuecat_entitlements e
    JOIN users u ON e.user_id = u.id
    WHERE u.auth_user_id = user_uuid
    AND e.is_active = true
    ORDER BY e.purchase_date DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_active_entitlements(UUID) TO authenticated, service_role;

COMMENT ON FUNCTION get_active_entitlements(UUID) IS 'Get all active entitlements for a user. Returns entitlement details including product ID and expiration dates.';

-- Function to get subscription details for a user
CREATE OR REPLACE FUNCTION get_active_subscriptions(user_uuid UUID)
RETURNS TABLE (
    product_id TEXT,
    status TEXT,
    period_type TEXT,
    store TEXT,
    purchase_date TIMESTAMPTZ,
    expires_date TIMESTAMPTZ,
    will_renew BOOLEAN,
    is_sandbox BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    RETURN QUERY
    SELECT
        s.product_id,
        s.status,
        s.period_type,
        s.store,
        s.purchase_date,
        s.expires_date,
        s.will_renew,
        s.is_sandbox
    FROM revenuecat_subscriptions s
    JOIN users u ON s.user_id = u.id
    WHERE u.auth_user_id = user_uuid
    AND s.status IN ('active', 'in_grace_period')
    ORDER BY s.purchase_date DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_active_subscriptions(UUID) TO authenticated, service_role;

COMMENT ON FUNCTION get_active_subscriptions(UUID) IS 'Get all active subscriptions for a user. Returns subscription details including store, dates, and renewal status.';

-- =====================================================
-- 5. VALIDATION & MIGRATION CONFIRMATION
-- =====================================================

DO $$
DECLARE
    function_count INTEGER;
BEGIN
    -- Check if functions were created
    SELECT COUNT(*) INTO function_count
    FROM information_schema.routines
    WHERE routine_schema = 'public'
    AND routine_name IN ('has_active_premium', 'get_active_entitlements', 'get_active_subscriptions');

    RAISE NOTICE '✅ RevenueCat Premium Functions Migration Complete';
    RAISE NOTICE '  - Created % functions', function_count;
    RAISE NOTICE '  - has_active_premium(): Check if user has premium';
    RAISE NOTICE '  - get_active_entitlements(): Get user entitlements';
    RAISE NOTICE '  - get_active_subscriptions(): Get user subscriptions';
    RAISE NOTICE '  - Permissions granted to authenticated users';
END $$;

COMMIT;
