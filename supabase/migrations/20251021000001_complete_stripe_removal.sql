-- =====================================================
-- COMPLETE STRIPE INFRASTRUCTURE REMOVAL
-- =====================================================
-- This migration completes the removal of all Stripe infrastructure
-- Ensures EXCLUSIVE RevenueCat subscription management
-- Date: 2025-10-21
-- =====================================================

BEGIN;

-- =====================================================
-- 1. REMOVE STRIPE_CUSTOMER_ID FROM USERS TABLE
-- =====================================================

-- Drop the column and all its dependencies (indexes, constraints)
DO $$
BEGIN
    ALTER TABLE users DROP COLUMN IF EXISTS stripe_customer_id CASCADE;
    RAISE NOTICE '✅ Removed stripe_customer_id column from users table';
END $$;

-- =====================================================
-- 2. VALIDATION: ENSURE NO STRIPE REMNANTS
-- =====================================================

DO $$
DECLARE
    stripe_column_count INTEGER;
    stripe_table_count INTEGER;
BEGIN
    -- Check for any remaining Stripe columns in users table
    SELECT COUNT(*) INTO stripe_column_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
    AND table_name = 'users'
    AND column_name LIKE '%stripe%';

    IF stripe_column_count > 0 THEN
        RAISE EXCEPTION '❌ ERROR: % Stripe column(s) still exist in users table!', stripe_column_count;
    ELSE
        RAISE NOTICE '✅ Users table verified: No Stripe columns remain';
    END IF;

    -- Check for any remaining Stripe-related tables
    SELECT COUNT(*) INTO stripe_table_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
    AND (
        table_name LIKE '%stripe%'
        OR table_name IN (
            'subscriptions', 'payments', 'payment_methods',
            'invoices', 'subscription_plans', 'one_time_purchases'
        )
    );

    IF stripe_table_count > 0 THEN
        RAISE WARNING '⚠️  WARNING: % Stripe-related table(s) still exist', stripe_table_count;
    ELSE
        RAISE NOTICE '✅ Database verified: No Stripe tables remain';
    END IF;

    -- Verify RevenueCat infrastructure exists
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'revenuecat_subscriptions') THEN
        RAISE EXCEPTION '❌ ERROR: revenuecat_subscriptions table missing!';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'revenuecat_entitlements') THEN
        RAISE EXCEPTION '❌ ERROR: revenuecat_entitlements table missing!';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'revenuecat_products') THEN
        RAISE EXCEPTION '❌ ERROR: revenuecat_products table missing!';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'revenuecat_webhook_events') THEN
        RAISE EXCEPTION '❌ ERROR: revenuecat_webhook_events table missing!';
    END IF;

    RAISE NOTICE '✅ RevenueCat infrastructure verified: All tables exist';

    -- Verify subscription_status and subscription_tier still exist (used by RevenueCat)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'users'
        AND column_name = 'subscription_status'
    ) THEN
        RAISE EXCEPTION '❌ ERROR: subscription_status column missing from users table!';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'users'
        AND column_name = 'subscription_tier'
    ) THEN
        RAISE EXCEPTION '❌ ERROR: subscription_tier column missing from users table!';
    END IF;

    RAISE NOTICE '✅ Users table verified: subscription_status and subscription_tier present';
END $$;

-- =====================================================
-- 3. DOCUMENTATION
-- =====================================================

COMMENT ON TABLE users IS 'User accounts - Stripe infrastructure removed, using EXCLUSIVE RevenueCat subscription management';
COMMENT ON COLUMN users.subscription_status IS 'Subscription status synced from revenuecat_subscriptions table';
COMMENT ON COLUMN users.subscription_tier IS 'Subscription tier mapped from revenuecat_subscriptions.product_id';

COMMIT;

-- =====================================================
-- SUMMARY
-- =====================================================
-- ✅ Removed: stripe_customer_id column (and all constraints/indexes)
-- ✅ Verified: No Stripe columns remain in users table
-- ✅ Verified: All RevenueCat tables exist
-- ✅ Verified: subscription_status and subscription_tier retained for RevenueCat
-- =====================================================
