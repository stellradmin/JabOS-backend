-- Comprehensive Stripe Integration for Stellr Dating App
-- This migration creates a production-ready payment and subscription system

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ========================================
-- 1. UPDATE EXISTING USERS TABLE
-- ========================================

-- Add new Stripe-related columns to users table
ALTER TABLE users 
ADD COLUMN IF NOT EXISTS subscription_plan_id text,
ADD COLUMN IF NOT EXISTS subscription_current_period_end timestamptz,
ADD COLUMN IF NOT EXISTS subscription_cancel_at_period_end boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS last_payment_date timestamptz,
ADD COLUMN IF NOT EXISTS has_active_ticket boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS payment_method_id text,
ADD COLUMN IF NOT EXISTS default_payment_method text;

-- Update subscription_status to use proper enum values
ALTER TABLE users 
DROP CONSTRAINT IF EXISTS users_subscription_status_check;

ALTER TABLE users 
ADD CONSTRAINT users_subscription_status_check 
CHECK (subscription_status IN ('active', 'inactive', 'trialing', 'past_due', 'canceled', 'unpaid', 'incomplete', 'incomplete_expired'));

-- Update subscription_tier to include new tiers
ALTER TABLE users 
DROP CONSTRAINT IF EXISTS users_subscription_tier_check;

ALTER TABLE users 
ADD CONSTRAINT users_subscription_tier_check 
CHECK (subscription_tier IN ('free', 'premium_1_month', 'premium_3_months', 'premium_6_months', 'premium_lifetime'));

-- ========================================
-- 2. CREATE SUBSCRIPTIONS TABLE
-- ========================================

CREATE TABLE IF NOT EXISTS subscriptions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    stripe_subscription_id text UNIQUE NOT NULL,
    stripe_customer_id text NOT NULL,
    stripe_price_id text NOT NULL,
    status text NOT NULL CHECK (status IN ('active', 'trialing', 'past_due', 'canceled', 'unpaid', 'incomplete', 'incomplete_expired')),
    current_period_start timestamptz NOT NULL,
    current_period_end timestamptz NOT NULL,
    cancel_at_period_end boolean DEFAULT false,
    canceled_at timestamptz,
    trial_start timestamptz,
    trial_end timestamptz,
    metadata jsonb DEFAULT '{}',
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

-- Create indexes for subscriptions table
CREATE INDEX IF NOT EXISTS idx_subscriptions_user_id ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_stripe_subscription_id ON subscriptions(stripe_subscription_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_stripe_customer_id ON subscriptions(stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON subscriptions(status);
CREATE INDEX IF NOT EXISTS idx_subscriptions_current_period_end ON subscriptions(current_period_end);

-- ========================================
-- 3. CREATE PAYMENTS TABLE
-- ========================================

CREATE TABLE IF NOT EXISTS payments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    stripe_payment_intent_id text UNIQUE,
    stripe_charge_id text,
    stripe_invoice_id text,
    stripe_subscription_id text,
    amount bigint NOT NULL, -- Amount in cents
    currency text NOT NULL DEFAULT 'usd',
    status text NOT NULL CHECK (status IN ('requires_payment_method', 'requires_confirmation', 'requires_action', 'processing', 'requires_capture', 'canceled', 'succeeded', 'failed')),
    payment_method_type text, -- card, apple_pay, google_pay, etc.
    payment_method_id text,
    description text,
    receipt_email text,
    receipt_url text,
    failure_reason text,
    refunded boolean DEFAULT false,
    refund_amount bigint DEFAULT 0,
    metadata jsonb DEFAULT '{}',
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

-- Create indexes for payments table
CREATE INDEX IF NOT EXISTS idx_payments_user_id ON payments(user_id);
CREATE INDEX IF NOT EXISTS idx_payments_stripe_payment_intent_id ON payments(stripe_payment_intent_id);
CREATE INDEX IF NOT EXISTS idx_payments_stripe_subscription_id ON payments(stripe_subscription_id);
CREATE INDEX IF NOT EXISTS idx_payments_status ON payments(status);
CREATE INDEX IF NOT EXISTS idx_payments_created_at ON payments(created_at);

-- ========================================
-- 4. CREATE PAYMENT_METHODS TABLE
-- ========================================

CREATE TABLE IF NOT EXISTS payment_methods (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    stripe_payment_method_id text UNIQUE NOT NULL,
    type text NOT NULL, -- card, bank_account, etc.
    card_brand text, -- visa, mastercard, amex, etc.
    card_last4 text,
    card_exp_month integer,
    card_exp_year integer,
    is_default boolean DEFAULT false,
    metadata jsonb DEFAULT '{}',
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

-- Create indexes for payment_methods table
CREATE INDEX IF NOT EXISTS idx_payment_methods_user_id ON payment_methods(user_id);
CREATE INDEX IF NOT EXISTS idx_payment_methods_stripe_payment_method_id ON payment_methods(stripe_payment_method_id);
CREATE INDEX IF NOT EXISTS idx_payment_methods_is_default ON payment_methods(is_default);

-- ========================================
-- 5. CREATE INVOICES TABLE
-- ========================================

CREATE TABLE IF NOT EXISTS invoices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    stripe_invoice_id text UNIQUE NOT NULL,
    stripe_subscription_id text,
    stripe_payment_intent_id text,
    status text NOT NULL CHECK (status IN ('draft', 'open', 'paid', 'uncollectible', 'void')),
    amount_due bigint NOT NULL,
    amount_paid bigint DEFAULT 0,
    amount_remaining bigint DEFAULT 0,
    currency text NOT NULL DEFAULT 'usd',
    period_start timestamptz,
    period_end timestamptz,
    due_date timestamptz,
    paid_at timestamptz,
    invoice_pdf text, -- URL to PDF
    hosted_invoice_url text,
    description text,
    metadata jsonb DEFAULT '{}',
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

-- Create indexes for invoices table
CREATE INDEX IF NOT EXISTS idx_invoices_user_id ON invoices(user_id);
CREATE INDEX IF NOT EXISTS idx_invoices_stripe_invoice_id ON invoices(stripe_invoice_id);
CREATE INDEX IF NOT EXISTS idx_invoices_stripe_subscription_id ON invoices(stripe_subscription_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status ON invoices(status);
CREATE INDEX IF NOT EXISTS idx_invoices_due_date ON invoices(due_date);

-- ========================================
-- 6. CREATE SUBSCRIPTION_PLANS TABLE
-- ========================================

CREATE TABLE IF NOT EXISTS subscription_plans (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    stripe_price_id text UNIQUE NOT NULL,
    stripe_product_id text NOT NULL,
    name text NOT NULL,
    description text,
    amount bigint NOT NULL, -- Amount in cents
    currency text NOT NULL DEFAULT 'usd',
    interval_type text NOT NULL CHECK (interval_type IN ('month', 'year', 'one_time')),
    interval_count integer DEFAULT 1,
    trial_period_days integer DEFAULT 0,
    features jsonb DEFAULT '{}', -- List of features included
    is_active boolean DEFAULT true,
    sort_order integer DEFAULT 0,
    metadata jsonb DEFAULT '{}',
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

-- Create indexes for subscription_plans table
CREATE INDEX IF NOT EXISTS idx_subscription_plans_stripe_price_id ON subscription_plans(stripe_price_id);
CREATE INDEX IF NOT EXISTS idx_subscription_plans_is_active ON subscription_plans(is_active);
CREATE INDEX IF NOT EXISTS idx_subscription_plans_sort_order ON subscription_plans(sort_order);

-- ========================================
-- 7. INSERT INITIAL SUBSCRIPTION PLANS
-- ========================================

INSERT INTO subscription_plans (stripe_price_id, stripe_product_id, name, description, amount, interval_type, interval_count, features, sort_order) VALUES
('price_1Ri7WFHOApbUaURNW5ncBSqv', 'prod_stellr_premium', '1 Month Premium', 'Premium subscription for 1 month', 999, 'month', 1, '{"unlimited_matches": true, "advanced_filters": true, "read_receipts": true, "priority_support": true}', 1),
('price_1Ri7WSHOApbUaURN09XZ1YeZ', 'prod_stellr_premium', '3 Months Premium', 'Premium subscription for 3 months', 2499, 'month', 3, '{"unlimited_matches": true, "advanced_filters": true, "read_receipts": true, "priority_support": true, "discount": "17% off"}', 2),
('price_1Ri7WdHOApbUaURNh0bq2cKI', 'prod_stellr_premium', '6 Months Premium', 'Premium subscription for 6 months', 4499, 'month', 6, '{"unlimited_matches": true, "advanced_filters": true, "read_receipts": true, "priority_support": true, "discount": "25% off"}', 3),
('price_1Ri7WpHOApbUaURNo89Bh0vN', 'prod_stellr_ticket', 'Premium Ticket', 'One-time premium access ticket', 299, 'one_time', 1, '{"premium_access": true, "limited_time": true}', 4)
ON CONFLICT (stripe_price_id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    amount = EXCLUDED.amount,
    features = EXCLUDED.features,
    updated_at = now();

-- ========================================
-- 8. CREATE WEBHOOK_EVENTS TABLE
-- ========================================

CREATE TABLE IF NOT EXISTS webhook_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    stripe_event_id text UNIQUE NOT NULL,
    event_type text NOT NULL,
    processed boolean DEFAULT false,
    processing_attempts integer DEFAULT 0,
    last_processing_error text,
    data jsonb NOT NULL,
    created_at timestamptz DEFAULT now(),
    processed_at timestamptz
);

-- Create indexes for webhook_events table
CREATE INDEX IF NOT EXISTS idx_webhook_events_stripe_event_id ON webhook_events(stripe_event_id);
CREATE INDEX IF NOT EXISTS idx_webhook_events_event_type ON webhook_events(event_type);
CREATE INDEX IF NOT EXISTS idx_webhook_events_processed ON webhook_events(processed);
CREATE INDEX IF NOT EXISTS idx_webhook_events_created_at ON webhook_events(created_at);

-- ========================================
-- 9. CREATE PAYMENT_ANALYTICS TABLE
-- ========================================

CREATE TABLE IF NOT EXISTS payment_analytics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    date date NOT NULL,
    total_revenue bigint DEFAULT 0,
    subscription_revenue bigint DEFAULT 0,
    one_time_revenue bigint DEFAULT 0,
    new_subscriptions integer DEFAULT 0,
    canceled_subscriptions integer DEFAULT 0,
    active_subscriptions integer DEFAULT 0,
    failed_payments integer DEFAULT 0,
    successful_payments integer DEFAULT 0,
    churn_rate numeric(5,2) DEFAULT 0.00,
    mrr bigint DEFAULT 0, -- Monthly Recurring Revenue
    metadata jsonb DEFAULT '{}',
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    UNIQUE(date)
);

-- Create indexes for payment_analytics table
CREATE INDEX IF NOT EXISTS idx_payment_analytics_date ON payment_analytics(date);

-- ========================================
-- 10. CREATE UPDATED_AT TRIGGERS
-- ========================================

-- Function to update the updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Create triggers for updated_at columns
CREATE TRIGGER update_subscriptions_updated_at BEFORE UPDATE ON subscriptions FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_payments_updated_at BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_payment_methods_updated_at BEFORE UPDATE ON payment_methods FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_invoices_updated_at BEFORE UPDATE ON invoices FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_subscription_plans_updated_at BEFORE UPDATE ON subscription_plans FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_payment_analytics_updated_at BEFORE UPDATE ON payment_analytics FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ========================================
-- 11. CREATE RLS POLICIES
-- ========================================

-- Enable RLS on all new tables
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscription_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_analytics ENABLE ROW LEVEL SECURITY;

-- Subscriptions policies
CREATE POLICY "Users can view their own subscriptions" ON subscriptions FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Service role can manage all subscriptions" ON subscriptions FOR ALL USING (auth.role() = 'service_role');

-- Payments policies
CREATE POLICY "Users can view their own payments" ON payments FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Service role can manage all payments" ON payments FOR ALL USING (auth.role() = 'service_role');

-- Payment methods policies
CREATE POLICY "Users can view their own payment methods" ON payment_methods FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Users can manage their own payment methods" ON payment_methods FOR ALL USING (user_id = auth.uid());
CREATE POLICY "Service role can manage all payment methods" ON payment_methods FOR ALL USING (auth.role() = 'service_role');

-- Invoices policies
CREATE POLICY "Users can view their own invoices" ON invoices FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Service role can manage all invoices" ON invoices FOR ALL USING (auth.role() = 'service_role');

-- Subscription plans policies (public read access)
CREATE POLICY "Anyone can view active subscription plans" ON subscription_plans FOR SELECT USING (is_active = true);
CREATE POLICY "Service role can manage subscription plans" ON subscription_plans FOR ALL USING (auth.role() = 'service_role');

-- Webhook events policies (service role only)
CREATE POLICY "Only service role can access webhook events" ON webhook_events FOR ALL USING (auth.role() = 'service_role');

-- Payment analytics policies (service role only)
CREATE POLICY "Only service role can access payment analytics" ON payment_analytics FOR ALL USING (auth.role() = 'service_role');

-- ========================================
-- 12. CREATE UTILITY FUNCTIONS
-- ========================================

-- Function to check if user has active subscription
CREATE OR REPLACE FUNCTION has_active_subscription(user_uuid uuid)
RETURNS boolean AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM subscriptions 
        WHERE user_id = user_uuid 
        AND status = 'active' 
        AND current_period_end > now()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get user's current subscription
CREATE OR REPLACE FUNCTION get_user_subscription(user_uuid uuid)
RETURNS TABLE (
    subscription_id uuid,
    status text,
    current_period_end timestamptz,
    plan_name text,
    amount bigint
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        s.id,
        s.status,
        s.current_period_end,
        sp.name,
        sp.amount
    FROM subscriptions s
    JOIN subscription_plans sp ON s.stripe_price_id = sp.stripe_price_id
    WHERE s.user_id = user_uuid
    AND s.status IN ('active', 'trialing')
    ORDER BY s.created_at DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to calculate user's total spent
CREATE OR REPLACE FUNCTION calculate_user_total_spent(user_uuid uuid)
RETURNS bigint AS $$
BEGIN
    RETURN COALESCE(
        (SELECT SUM(amount) FROM payments WHERE user_id = user_uuid AND status = 'succeeded'),
        0
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ========================================
-- 13. CREATE AUDIT TRIGGERS FOR PAYMENT EVENTS
-- ========================================

-- Function to log payment events to audit_logs
CREATE OR REPLACE FUNCTION log_payment_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_logs (
            user_id, 
            operation_type, 
            table_name, 
            record_id, 
            new_data,
            context
        ) VALUES (
            NEW.user_id,
            'payment_created',
            TG_TABLE_NAME,
            NEW.id,
            to_jsonb(NEW),
            jsonb_build_object(
                'stripe_payment_intent_id', NEW.stripe_payment_intent_id,
                'amount', NEW.amount,
                'currency', NEW.currency,
                'status', NEW.status
            )
        );
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_logs (
            user_id, 
            operation_type, 
            table_name, 
            record_id, 
            old_data,
            new_data,
            context
        ) VALUES (
            NEW.user_id,
            'payment_updated',
            TG_TABLE_NAME,
            NEW.id,
            to_jsonb(OLD),
            to_jsonb(NEW),
            jsonb_build_object(
                'status_changed', OLD.status != NEW.status,
                'old_status', OLD.status,
                'new_status', NEW.status
            )
        );
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create audit triggers
CREATE TRIGGER payment_audit_trigger 
    AFTER INSERT OR UPDATE ON payments 
    FOR EACH ROW EXECUTE FUNCTION log_payment_audit();

CREATE TRIGGER subscription_audit_trigger 
    AFTER INSERT OR UPDATE ON subscriptions 
    FOR EACH ROW EXECUTE FUNCTION log_payment_audit();

-- ========================================
-- 14. GRANT PERMISSIONS
-- ========================================

-- Grant necessary permissions to authenticated users
GRANT SELECT ON subscription_plans TO authenticated;
GRANT SELECT ON subscriptions TO authenticated;
GRANT SELECT ON payments TO authenticated;
GRANT SELECT ON payment_methods TO authenticated;
GRANT SELECT ON invoices TO authenticated;

-- Grant all permissions to service role
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;

-- ========================================
-- MIGRATION COMPLETE
-- ========================================

-- Insert a record to track this migration only if audit_logs exists
DO $$
BEGIN
    IF to_regclass('public.audit_logs') IS NOT NULL THEN
        INSERT INTO audit_logs (
            operation_type,
            table_name,
            context
        ) VALUES (
            'migration_completed',
            'comprehensive_stripe_integration',
            jsonb_build_object(
                'migration_name', 'comprehensive_stripe_integration',
                'tables_created', ARRAY['subscriptions', 'payments', 'payment_methods', 'invoices', 'subscription_plans', 'webhook_events', 'payment_analytics'],
                'migration_date', now()
            )
        );
    END IF;
END$$;

COMMENT ON EXTENSION "uuid-ossp" IS 'Comprehensive Stripe integration migration completed successfully';
