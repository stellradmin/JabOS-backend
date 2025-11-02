-- =====================================================
-- REVENUECAT INTEGRATION SCHEMA
-- =====================================================
-- This migration creates the RevenueCat subscription system
-- Replaces Stripe with RevenueCat for mobile IAP management
-- Date: 2025-10-09
-- =====================================================

BEGIN;

-- =====================================================
-- 1. REVENUECAT SUBSCRIPTIONS TABLE
-- =====================================================

CREATE TABLE IF NOT EXISTS revenuecat_subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- RevenueCat identifiers
    revenuecat_subscriber_id TEXT UNIQUE NOT NULL,
    revenuecat_original_app_user_id TEXT NOT NULL,

    -- Subscription details
    product_id TEXT NOT NULL, -- e.g., 'premium_monthly', 'premium_annual'
    entitlement_id TEXT NOT NULL, -- e.g., 'premium', 'pro'
    store TEXT NOT NULL CHECK (store IN ('app_store', 'play_store', 'stripe', 'promotional')),

    -- Status tracking
    status TEXT NOT NULL CHECK (status IN ('active', 'expired', 'grace_period', 'billing_retry', 'canceled', 'paused')),
    is_active BOOLEAN GENERATED ALWAYS AS (status IN ('active', 'grace_period', 'billing_retry')) STORED,

    -- Period tracking
    period_type TEXT NOT NULL CHECK (period_type IN ('trial', 'intro', 'normal')),
    purchase_date TIMESTAMPTZ NOT NULL,
    original_purchase_date TIMESTAMPTZ NOT NULL,
    expires_date TIMESTAMPTZ,
    billing_issue_detected_at TIMESTAMPTZ,
    grace_period_expires_date TIMESTAMPTZ,

    -- Pricing info
    price_in_purchased_currency NUMERIC(10,2),
    currency TEXT,

    -- Cancellation tracking
    unsubscribe_detected_at TIMESTAMPTZ,
    will_renew BOOLEAN NOT NULL DEFAULT true,
    auto_resume_date TIMESTAMPTZ,

    -- Platform-specific data
    store_transaction_id TEXT,
    store_original_transaction_id TEXT,
    is_sandbox BOOLEAN NOT NULL DEFAULT false,

    -- Metadata
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_rc_subs_user_id ON revenuecat_subscriptions(user_id);
CREATE INDEX idx_rc_subs_subscriber_id ON revenuecat_subscriptions(revenuecat_subscriber_id);
CREATE INDEX idx_rc_subs_status ON revenuecat_subscriptions(status);
CREATE INDEX idx_rc_subs_is_active ON revenuecat_subscriptions(is_active) WHERE is_active = true;
CREATE INDEX idx_rc_subs_expires_date ON revenuecat_subscriptions(expires_date);
CREATE INDEX idx_rc_subs_product_id ON revenuecat_subscriptions(product_id);

-- =====================================================
-- 2. REVENUECAT PRODUCTS TABLE
-- =====================================================

CREATE TABLE IF NOT EXISTS revenuecat_products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Product identifiers
    product_id TEXT UNIQUE NOT NULL,
    store_product_id TEXT NOT NULL, -- Platform-specific ID
    store TEXT NOT NULL CHECK (store IN ('app_store', 'play_store')),

    -- Product details
    display_name TEXT NOT NULL,
    description TEXT,
    product_type TEXT NOT NULL CHECK (product_type IN ('subscription', 'consumable', 'non_consumable')),

    -- Subscription details (if applicable)
    subscription_period TEXT, -- 'P1M' (1 month), 'P1Y' (1 year), etc.
    trial_period TEXT, -- 'P3D' (3 days), 'P1W' (1 week), etc.
    intro_period TEXT,

    -- Pricing
    price_usd NUMERIC(10,2),
    price_metadata JSONB DEFAULT '{}'::jsonb, -- Store multiple currency prices

    -- Entitlement mapping
    entitlement_ids TEXT[] NOT NULL DEFAULT '{}',

    -- Configuration
    is_active BOOLEAN NOT NULL DEFAULT true,
    sort_order INTEGER DEFAULT 0,

    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_rc_products_product_id ON revenuecat_products(product_id);
CREATE INDEX idx_rc_products_is_active ON revenuecat_products(is_active) WHERE is_active = true;
CREATE INDEX idx_rc_products_sort_order ON revenuecat_products(sort_order);

-- =====================================================
-- 3. REVENUECAT WEBHOOK EVENTS TABLE
-- =====================================================

CREATE TABLE IF NOT EXISTS revenuecat_webhook_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Event identification
    event_id TEXT UNIQUE NOT NULL,
    event_type TEXT NOT NULL,

    -- Related entities
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    app_user_id TEXT NOT NULL,

    -- Event data
    product_id TEXT,
    entitlement_id TEXT,
    store TEXT,
    event_timestamp TIMESTAMPTZ NOT NULL,

    -- Processing tracking
    processed BOOLEAN NOT NULL DEFAULT false,
    processed_at TIMESTAMPTZ,
    processing_attempts INTEGER NOT NULL DEFAULT 0,
    last_processing_error TEXT,

    -- Full payload
    raw_payload JSONB NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_rc_webhooks_event_id ON revenuecat_webhook_events(event_id);
CREATE INDEX idx_rc_webhooks_event_type ON revenuecat_webhook_events(event_type);
CREATE INDEX idx_rc_webhooks_user_id ON revenuecat_webhook_events(user_id);
CREATE INDEX idx_rc_webhooks_processed ON revenuecat_webhook_events(processed) WHERE processed = false;
CREATE INDEX idx_rc_webhooks_created_at ON revenuecat_webhook_events(created_at);

-- =====================================================
-- 4. REVENUECAT ENTITLEMENTS TABLE
-- =====================================================

CREATE TABLE IF NOT EXISTS revenuecat_entitlements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- Entitlement details
    entitlement_id TEXT NOT NULL,
    product_id TEXT NOT NULL,

    -- Status
    is_active BOOLEAN NOT NULL DEFAULT true,

    -- Period tracking
    purchase_date TIMESTAMPTZ NOT NULL,
    expires_date TIMESTAMPTZ,

    -- Source subscription
    subscription_id UUID REFERENCES revenuecat_subscriptions(id) ON DELETE SET NULL,

    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE(user_id, entitlement_id)
);

-- Indexes
CREATE INDEX idx_rc_entitlements_user_id ON revenuecat_entitlements(user_id);
CREATE INDEX idx_rc_entitlements_is_active ON revenuecat_entitlements(is_active) WHERE is_active = true;
CREATE INDEX idx_rc_entitlements_expires_date ON revenuecat_entitlements(expires_date);

-- =====================================================
-- 5. INSERT DEFAULT PRODUCTS
-- =====================================================

INSERT INTO revenuecat_products (product_id, store_product_id, store, display_name, description, product_type, subscription_period, price_usd, entitlement_ids, sort_order) VALUES
-- App Store Products
('premium_monthly_ios', 'stellr_premium_monthly', 'app_store', 'Premium Monthly', 'Premium subscription billed monthly', 'subscription', 'P1M', 14.99, ARRAY['premium'], 1),
('premium_annual_ios', 'stellr_premium_annual', 'app_store', 'Premium Annual', 'Premium subscription billed annually', 'subscription', 'P1Y', 99.99, ARRAY['premium'], 2),

-- Play Store Products
('premium_monthly_android', 'stellr.premium.monthly', 'play_store', 'Premium Monthly', 'Premium subscription billed monthly', 'subscription', 'P1M', 14.99, ARRAY['premium'], 3),
('premium_annual_android', 'stellr.premium.annual', 'play_store', 'Premium Annual', 'Premium subscription billed annually', 'subscription', 'P1Y', 99.99, ARRAY['premium'], 4)

ON CONFLICT (product_id) DO UPDATE SET
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    price_usd = EXCLUDED.price_usd,
    updated_at = NOW();

-- =====================================================
-- 6. RLS POLICIES
-- =====================================================

ALTER TABLE revenuecat_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE revenuecat_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE revenuecat_webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE revenuecat_entitlements ENABLE ROW LEVEL SECURITY;

-- Subscriptions policies
CREATE POLICY "Users can view their own subscriptions" ON revenuecat_subscriptions
    FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Service role can manage all subscriptions" ON revenuecat_subscriptions
    FOR ALL USING (auth.role() = 'service_role');

-- Products policies (public read)
CREATE POLICY "Anyone can view active products" ON revenuecat_products
    FOR SELECT USING (is_active = true);

CREATE POLICY "Service role can manage products" ON revenuecat_products
    FOR ALL USING (auth.role() = 'service_role');

-- Webhook events policies (service role only)
CREATE POLICY "Only service role can access webhooks" ON revenuecat_webhook_events
    FOR ALL USING (auth.role() = 'service_role');

-- Entitlements policies
CREATE POLICY "Users can view their own entitlements" ON revenuecat_entitlements
    FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Service role can manage entitlements" ON revenuecat_entitlements
    FOR ALL USING (auth.role() = 'service_role');

-- =====================================================
-- 7. UTILITY FUNCTIONS
-- =====================================================

-- Function to check if user has active premium
CREATE OR REPLACE FUNCTION has_active_premium(user_uuid UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM revenuecat_entitlements
        WHERE user_id = user_uuid
        AND entitlement_id = 'premium'
        AND is_active = true
        AND (expires_date IS NULL OR expires_date > NOW())
    );
END;
$$;

-- Function to get user's active subscriptions
CREATE OR REPLACE FUNCTION get_active_subscriptions(user_uuid UUID)
RETURNS TABLE (
    subscription_id UUID,
    product_id TEXT,
    status TEXT,
    expires_date TIMESTAMPTZ,
    will_renew BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    RETURN QUERY
    SELECT
        rs.id,
        rs.product_id,
        rs.status,
        rs.expires_date,
        rs.will_renew
    FROM revenuecat_subscriptions rs
    WHERE rs.user_id = user_uuid
    AND rs.is_active = true
    ORDER BY rs.created_at DESC;
END;
$$;

-- =====================================================
-- 8. TRIGGERS FOR UPDATED_AT
-- =====================================================

CREATE OR REPLACE FUNCTION update_revenuecat_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER update_rc_subscriptions_updated_at
    BEFORE UPDATE ON revenuecat_subscriptions
    FOR EACH ROW
    EXECUTE FUNCTION update_revenuecat_updated_at();

CREATE TRIGGER update_rc_products_updated_at
    BEFORE UPDATE ON revenuecat_products
    FOR EACH ROW
    EXECUTE FUNCTION update_revenuecat_updated_at();

CREATE TRIGGER update_rc_entitlements_updated_at
    BEFORE UPDATE ON revenuecat_entitlements
    FOR EACH ROW
    EXECUTE FUNCTION update_revenuecat_updated_at();

-- =====================================================
-- 9. GRANTS
-- =====================================================

GRANT SELECT ON revenuecat_products TO authenticated, anon;
GRANT SELECT ON revenuecat_subscriptions TO authenticated;
GRANT SELECT ON revenuecat_entitlements TO authenticated;

GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role;

-- =====================================================
-- 10. VALIDATION
-- =====================================================

DO $$
DECLARE
    table_count INTEGER;
    product_count INTEGER;
BEGIN
    -- Count RevenueCat tables
    SELECT COUNT(*) INTO table_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
    AND table_name LIKE 'revenuecat_%';

    -- Count products
    SELECT COUNT(*) INTO product_count
    FROM revenuecat_products;

    RAISE NOTICE ' Created % RevenueCat tables', table_count;
    RAISE NOTICE ' Inserted % default products', product_count;
    RAISE NOTICE ' RevenueCat schema migration complete';
END $$;

COMMIT;

-- =====================================================
-- DOCUMENTATION
-- =====================================================

COMMENT ON TABLE revenuecat_subscriptions IS 'RevenueCat subscription records synced from App Store and Play Store';
COMMENT ON TABLE revenuecat_products IS 'Product catalog for in-app purchases';
COMMENT ON TABLE revenuecat_webhook_events IS 'RevenueCat webhook events for audit and processing';
COMMENT ON TABLE revenuecat_entitlements IS 'User entitlements derived from active subscriptions';
