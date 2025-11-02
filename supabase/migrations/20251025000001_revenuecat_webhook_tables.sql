-- =====================================================
-- REVENUECAT WEBHOOK TABLES
-- =====================================================
-- Creates tables for RevenueCat webhook event processing,
-- subscription tracking, and entitlement management.
-- Date: 2025-10-25
-- =====================================================

BEGIN;

-- =====================================================
-- 1. REVENUECAT WEBHOOK EVENTS TABLE
-- =====================================================
-- Stores all webhook events from RevenueCat for deduplication and audit trail

CREATE TABLE IF NOT EXISTS revenuecat_webhook_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Event identification
    event_id TEXT NOT NULL UNIQUE,
    event_type TEXT NOT NULL,
    app_user_id TEXT NOT NULL,

    -- Event details
    product_id TEXT,
    entitlement_id TEXT,
    store TEXT CHECK (store IN ('app_store', 'play_store', 'stripe', 'promotional') OR store IS NULL),
    event_timestamp TIMESTAMPTZ NOT NULL,

    -- Processing status
    processed BOOLEAN NOT NULL DEFAULT false,
    processed_at TIMESTAMPTZ,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,

    -- Audit data
    raw_payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Constraints
    CHECK (event_id != ''),
    CHECK (event_type != ''),
    CHECK (app_user_id != '')
);

-- Indexes for webhook events
CREATE INDEX IF NOT EXISTS idx_revenuecat_webhook_events_event_id ON revenuecat_webhook_events(event_id);
CREATE INDEX IF NOT EXISTS idx_revenuecat_webhook_events_app_user_id ON revenuecat_webhook_events(app_user_id);
CREATE INDEX IF NOT EXISTS idx_revenuecat_webhook_events_event_type ON revenuecat_webhook_events(event_type);
CREATE INDEX IF NOT EXISTS idx_revenuecat_webhook_events_processed ON revenuecat_webhook_events(processed) WHERE NOT processed;
CREATE INDEX IF NOT EXISTS idx_revenuecat_webhook_events_created_at ON revenuecat_webhook_events(created_at DESC);

COMMENT ON TABLE revenuecat_webhook_events IS 'Stores all RevenueCat webhook events for deduplication and audit trail. Used to prevent duplicate event processing.';

-- =====================================================
-- 2. REVENUECAT SUBSCRIPTIONS TABLE
-- =====================================================
-- Tracks subscription state from RevenueCat

CREATE TABLE IF NOT EXISTS revenuecat_subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- User reference
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- RevenueCat identifiers
    revenuecat_subscriber_id TEXT NOT NULL,
    revenuecat_original_app_user_id TEXT NOT NULL,
    product_id TEXT NOT NULL,
    entitlement_id TEXT NOT NULL,

    -- Store information
    store TEXT NOT NULL CHECK (store IN ('app_store', 'play_store', 'stripe', 'promotional')),
    store_transaction_id TEXT,

    -- Subscription status
    status TEXT NOT NULL CHECK (status IN ('active', 'canceled', 'expired', 'billing_retry', 'in_grace_period')),
    period_type TEXT NOT NULL CHECK (period_type IN ('trial', 'intro', 'normal')),

    -- Dates
    purchase_date TIMESTAMPTZ NOT NULL,
    original_purchase_date TIMESTAMPTZ NOT NULL,
    expires_date TIMESTAMPTZ NOT NULL,

    -- Billing issues
    billing_issue_detected_at TIMESTAMPTZ,
    grace_period_expires_date TIMESTAMPTZ,
    unsubscribe_detected_at TIMESTAMPTZ,
    auto_resume_date TIMESTAMPTZ,

    -- Renewal status
    will_renew BOOLEAN NOT NULL DEFAULT true,

    -- Testing
    is_sandbox BOOLEAN NOT NULL DEFAULT false,

    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Unique constraint: one subscription per user per subscriber_id
    UNIQUE(user_id, revenuecat_subscriber_id)
);

-- Indexes for subscriptions
CREATE INDEX IF NOT EXISTS idx_revenuecat_subscriptions_user_id ON revenuecat_subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_revenuecat_subscriptions_status ON revenuecat_subscriptions(status);
CREATE INDEX IF NOT EXISTS idx_revenuecat_subscriptions_product_id ON revenuecat_subscriptions(product_id);
CREATE INDEX IF NOT EXISTS idx_revenuecat_subscriptions_expires_date ON revenuecat_subscriptions(expires_date);
CREATE INDEX IF NOT EXISTS idx_revenuecat_subscriptions_active ON revenuecat_subscriptions(user_id, status) WHERE status = 'active';

COMMENT ON TABLE revenuecat_subscriptions IS 'Tracks subscription state synced from RevenueCat API. Updated via webhook events and API polling.';

-- =====================================================
-- 3. REVENUECAT ENTITLEMENTS TABLE
-- =====================================================
-- Tracks entitlement state from RevenueCat

CREATE TABLE IF NOT EXISTS revenuecat_entitlements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- User reference
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- Entitlement details
    entitlement_id TEXT NOT NULL,
    product_id TEXT NOT NULL,

    -- Entitlement status
    is_active BOOLEAN NOT NULL DEFAULT false,

    -- Dates
    purchase_date TIMESTAMPTZ NOT NULL,
    expires_date TIMESTAMPTZ,

    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Unique constraint: one entitlement per user
    UNIQUE(user_id, entitlement_id)
);

-- Indexes for entitlements
CREATE INDEX IF NOT EXISTS idx_revenuecat_entitlements_user_id ON revenuecat_entitlements(user_id);
CREATE INDEX IF NOT EXISTS idx_revenuecat_entitlements_entitlement_id ON revenuecat_entitlements(entitlement_id);
CREATE INDEX IF NOT EXISTS idx_revenuecat_entitlements_is_active ON revenuecat_entitlements(user_id, entitlement_id, is_active) WHERE is_active = true;

COMMENT ON TABLE revenuecat_entitlements IS 'Tracks entitlement state synced from RevenueCat API. Used for access control and feature gating.';

-- =====================================================
-- 4. ENABLE ROW LEVEL SECURITY
-- =====================================================

ALTER TABLE revenuecat_webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE revenuecat_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE revenuecat_entitlements ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Service role can manage all webhook events
DO $$ BEGIN
    CREATE POLICY "Service role can manage webhook events" ON revenuecat_webhook_events
        FOR ALL USING (auth.role() = 'service_role');
EXCEPTION WHEN duplicate_object THEN
    NULL;
END $$;

-- RLS Policy: Users can view their own subscriptions
DO $$ BEGIN
    CREATE POLICY "Users can view their own subscriptions" ON revenuecat_subscriptions
        FOR SELECT USING (auth.uid() = (SELECT auth_user_id FROM users WHERE id = user_id));
EXCEPTION WHEN duplicate_object THEN
    NULL;
END $$;

-- RLS Policy: Service role can manage all subscriptions
DO $$ BEGIN
    CREATE POLICY "Service role can manage subscriptions" ON revenuecat_subscriptions
        FOR ALL USING (auth.role() = 'service_role');
EXCEPTION WHEN duplicate_object THEN
    NULL;
END $$;

-- RLS Policy: Users can view their own entitlements
DO $$ BEGIN
    CREATE POLICY "Users can view their own entitlements" ON revenuecat_entitlements
        FOR SELECT USING (auth.uid() = (SELECT auth_user_id FROM users WHERE id = user_id));
EXCEPTION WHEN duplicate_object THEN
    NULL;
END $$;

-- RLS Policy: Service role can manage all entitlements
DO $$ BEGIN
    CREATE POLICY "Service role can manage entitlements" ON revenuecat_entitlements
        FOR ALL USING (auth.role() = 'service_role');
EXCEPTION WHEN duplicate_object THEN
    NULL;
END $$;

-- =====================================================
-- 5. GRANTS
-- =====================================================

GRANT SELECT ON revenuecat_webhook_events TO service_role;
GRANT ALL ON revenuecat_webhook_events TO service_role;

GRANT SELECT ON revenuecat_subscriptions TO authenticated;
GRANT ALL ON revenuecat_subscriptions TO service_role;

GRANT SELECT ON revenuecat_entitlements TO authenticated;
GRANT ALL ON revenuecat_entitlements TO service_role;

-- =====================================================
-- 6. UPDATED_AT TRIGGER
-- =====================================================

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for revenuecat_subscriptions
CREATE TRIGGER update_revenuecat_subscriptions_updated_at
    BEFORE UPDATE ON revenuecat_subscriptions
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Trigger for revenuecat_entitlements
CREATE TRIGGER update_revenuecat_entitlements_updated_at
    BEFORE UPDATE ON revenuecat_entitlements
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- =====================================================
-- 7. VALIDATION & MIGRATION CONFIRMATION
-- =====================================================

DO $$
DECLARE
    table_count INTEGER;
BEGIN
    -- Check if all three tables were created
    SELECT COUNT(*) INTO table_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
    AND table_name IN ('revenuecat_webhook_events', 'revenuecat_subscriptions', 'revenuecat_entitlements');

    RAISE NOTICE '✅ RevenueCat Webhook Tables Migration Complete';
    RAISE NOTICE '  - Created % tables', table_count;
    RAISE NOTICE '  - RLS policies enabled for all tables';
    RAISE NOTICE '  - Indexes created for performance';
    RAISE NOTICE '  - Updated_at triggers configured';
END $$;

COMMIT;
