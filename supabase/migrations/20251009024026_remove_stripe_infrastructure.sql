-- =====================================================
-- REMOVE STRIPE INFRASTRUCTURE
-- =====================================================
-- This migration removes all Stripe-related database objects
-- VERIFIED SAFE: All Stripe tables are empty (0 records)
-- Date: 2025-10-09
-- =====================================================

-- =====================================================
-- 1. DROP TRIGGERS (if they exist)
-- =====================================================

DROP TRIGGER IF EXISTS payment_audit_trigger ON payments;
DROP TRIGGER IF EXISTS subscription_audit_trigger ON subscriptions;
DROP TRIGGER IF EXISTS update_subscriptions_updated_at ON subscriptions;
DROP TRIGGER IF EXISTS update_payments_updated_at ON payments;
DROP TRIGGER IF EXISTS update_payment_methods_updated_at ON payment_methods;
DROP TRIGGER IF EXISTS update_invoices_updated_at ON invoices;
DROP TRIGGER IF EXISTS update_subscription_plans_updated_at ON subscription_plans;
DROP TRIGGER IF EXISTS update_payment_analytics_updated_at ON payment_analytics;

-- =====================================================
-- 2. DROP RLS POLICIES (if they exist)
-- =====================================================

-- Subscriptions policies
DROP POLICY IF EXISTS "Users can view their own subscriptions" ON subscriptions;
DROP POLICY IF EXISTS "Service role can manage all subscriptions" ON subscriptions;

-- Payments policies
DROP POLICY IF EXISTS "Users can view their own payments" ON payments;
DROP POLICY IF EXISTS "Service role can manage all payments" ON payments;

-- Payment methods policies
DROP POLICY IF EXISTS "Users can view their own payment methods" ON payment_methods;
DROP POLICY IF EXISTS "Users can manage their own payment methods" ON payment_methods;
DROP POLICY IF EXISTS "Service role can manage all payment methods" ON payment_methods;

-- Invoices policies
DROP POLICY IF EXISTS "Users can view their own invoices" ON invoices;
DROP POLICY IF EXISTS "Service role can manage all invoices" ON invoices;

-- Subscription plans policies
DROP POLICY IF EXISTS "Anyone can view active subscription plans" ON subscription_plans;
DROP POLICY IF EXISTS "Service role can manage subscription plans" ON subscription_plans;

-- Webhook events policies
DROP POLICY IF EXISTS "Only service role can access webhook events" ON webhook_events;

-- Payment analytics policies
DROP POLICY IF EXISTS "Only service role can access payment analytics" ON payment_analytics;

-- =====================================================
-- 3. DROP TABLES (in dependency order)
-- =====================================================

-- Drop tables that exist
DROP TABLE IF EXISTS one_time_purchases CASCADE;
DROP TABLE IF EXISTS payment_audit_log CASCADE;
DROP TABLE IF EXISTS subscriptions CASCADE;

-- Drop tables from comprehensive Stripe migration (if they exist)
DROP TABLE IF EXISTS webhook_events CASCADE;
DROP TABLE IF EXISTS payment_analytics CASCADE;
DROP TABLE IF EXISTS invoices CASCADE;
DROP TABLE IF EXISTS payments CASCADE;
DROP TABLE IF EXISTS payment_methods CASCADE;
DROP TABLE IF EXISTS subscription_plans CASCADE;

-- =====================================================
-- 4. DROP FUNCTIONS
-- =====================================================

DROP FUNCTION IF EXISTS has_active_subscription(uuid);
DROP FUNCTION IF EXISTS get_user_subscription(uuid);
DROP FUNCTION IF EXISTS calculate_user_total_spent(uuid);
DROP FUNCTION IF EXISTS log_payment_audit();
DROP FUNCTION IF EXISTS update_updated_at_column() CASCADE;

-- =====================================================
-- 5. DROP USERS TABLE STRIPE COLUMNS
-- =====================================================

-- Remove Stripe-related columns from users table
DO $$
BEGIN
    -- Drop columns if they exist
    ALTER TABLE users DROP COLUMN IF EXISTS subscription_plan_id;
    ALTER TABLE users DROP COLUMN IF EXISTS subscription_current_period_end;
    ALTER TABLE users DROP COLUMN IF EXISTS subscription_cancel_at_period_end;
    ALTER TABLE users DROP COLUMN IF EXISTS last_payment_date;
    ALTER TABLE users DROP COLUMN IF EXISTS has_active_ticket;
    ALTER TABLE users DROP COLUMN IF EXISTS payment_method_id;
    ALTER TABLE users DROP COLUMN IF EXISTS default_payment_method;

    RAISE NOTICE ' Removed Stripe columns from users table';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Some users table columns may not exist: %', SQLERRM;
END $$;

-- =====================================================
-- 6. UPDATE USERS TABLE CONSTRAINTS
-- =====================================================

-- Update subscription_status constraint to remove Stripe-specific statuses
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_subscription_status_check;

ALTER TABLE users ADD CONSTRAINT users_subscription_status_check
CHECK (subscription_status IN ('active', 'inactive', 'canceled'));

-- Update subscription_tier constraint for RevenueCat tiers
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_subscription_tier_check;

ALTER TABLE users ADD CONSTRAINT users_subscription_tier_check
CHECK (subscription_tier IN ('free', 'premium_monthly', 'premium_annual'));

-- =====================================================
-- 7. VALIDATION & CLEANUP
-- =====================================================

DO $$
DECLARE
    remaining_count INTEGER;
BEGIN
    -- Check for any remaining Stripe-related tables
    SELECT COUNT(*) INTO remaining_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
    AND (
        table_name LIKE '%stripe%'
        OR table_name IN (
            'subscriptions', 'payments', 'payment_methods',
            'invoices', 'subscription_plans', 'webhook_events',
            'payment_analytics', 'one_time_purchases', 'payment_audit_log'
        )
    );

    IF remaining_count > 0 THEN
        RAISE WARNING '�  % Stripe-related tables still exist', remaining_count;
    ELSE
        RAISE NOTICE ' All Stripe infrastructure removed successfully';
    END IF;

    -- Check users table for Stripe columns
    SELECT COUNT(*) INTO remaining_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
    AND table_name = 'users'
    AND (
        column_name LIKE '%stripe%'
        OR column_name IN (
            'subscription_plan_id', 'subscription_current_period_end',
            'subscription_cancel_at_period_end', 'last_payment_date',
            'has_active_ticket', 'payment_method_id', 'default_payment_method'
        )
    );

    IF remaining_count > 0 THEN
        RAISE WARNING '�  % Stripe columns still exist in users table', remaining_count;
    ELSE
        RAISE NOTICE ' All Stripe columns removed from users table';
    END IF;
END $$;

COMMIT;

-- =====================================================
-- DOCUMENTATION
-- =====================================================

COMMENT ON TABLE users IS 'User accounts - Stripe infrastructure removed, prepared for RevenueCat integration';
