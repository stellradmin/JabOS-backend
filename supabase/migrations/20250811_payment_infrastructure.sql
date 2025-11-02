-- ==================================================
-- PHASE 2: PAYMENT INFRASTRUCTURE FOUNDATION
-- ==================================================
-- Creates comprehensive payment tracking system with full audit trail
-- Apply this migration when you have database write access

-- 1. SUBSCRIPTIONS TABLE - Track user subscription details
CREATE TABLE IF NOT EXISTS public.subscriptions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    stripe_subscription_id TEXT UNIQUE NOT NULL,
    stripe_customer_id TEXT NOT NULL,
    
    -- Subscription details
    status TEXT NOT NULL CHECK (status IN ('trialing', 'active', 'incomplete', 'incomplete_expired', 'past_due', 'canceled', 'unpaid')),
    tier TEXT NOT NULL CHECK (tier IN ('free', 'premium_monthly', 'premium_3months', 'premium_6months')),
    price_id TEXT NOT NULL,
    
    -- Billing cycle info
    current_period_start TIMESTAMPTZ NOT NULL,
    current_period_end TIMESTAMPTZ NOT NULL,
    cancel_at_period_end BOOLEAN DEFAULT FALSE,
    canceled_at TIMESTAMPTZ NULL,
    trial_end TIMESTAMPTZ NULL,
    
    -- Financial tracking
    amount_per_period INTEGER NOT NULL, -- in cents
    currency TEXT NOT NULL DEFAULT 'usd',
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. TRANSACTIONS TABLE - Track all payment transactions
CREATE TABLE public.transactions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    subscription_id UUID REFERENCES public.subscriptions(id) ON DELETE SET NULL,
    
    -- Transaction identifiers
    stripe_payment_intent_id TEXT UNIQUE NOT NULL,
    stripe_charge_id TEXT NULL,
    stripe_invoice_id TEXT NULL,
    
    -- Transaction details
    type TEXT NOT NULL CHECK (type IN ('subscription_payment', 'one_time_payment', 'refund', 'chargeback')),
    status TEXT NOT NULL CHECK (status IN ('pending', 'succeeded', 'failed', 'canceled', 'refunded')),
    
    -- Financial details
    amount INTEGER NOT NULL, -- in cents
    currency TEXT NOT NULL DEFAULT 'usd',
    fee_amount INTEGER NULL, -- Stripe fees in cents
    net_amount INTEGER NULL, -- amount - fees
    
    -- Payment method info
    payment_method_type TEXT NULL, -- card, apple_pay, google_pay, etc.
    card_last4 TEXT NULL,
    card_brand TEXT NULL,
    
    -- Audit fields
    processed_at TIMESTAMPTZ NULL,
    failed_reason TEXT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. ONE-TIME PURCHASES TABLE - Track tickets and other single purchases
CREATE TABLE public.one_time_purchases (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    transaction_id UUID NOT NULL REFERENCES public.transactions(id) ON DELETE CASCADE,
    
    -- Purchase details
    product_type TEXT NOT NULL CHECK (product_type IN ('compatibility_ticket', 'premium_feature_unlock')),
    stripe_price_id TEXT NOT NULL,
    
    -- Status tracking
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'used', 'expired', 'refunded')),
    expires_at TIMESTAMPTZ NULL,
    used_at TIMESTAMPTZ NULL,
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. PAYMENT AUDIT LOG - Comprehensive financial audit trail
CREATE TABLE public.payment_audit_log (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
    
    -- Event identification
    event_type TEXT NOT NULL CHECK (event_type IN (
        'subscription_created', 'subscription_updated', 'subscription_canceled',
        'payment_succeeded', 'payment_failed', 'payment_method_attached',
        'invoice_created', 'invoice_paid', 'invoice_payment_failed',
        'customer_created', 'customer_updated',
        'webhook_received', 'webhook_processed', 'webhook_failed'
    )),
    
    -- Reference IDs
    stripe_event_id TEXT NULL,
    subscription_id UUID REFERENCES public.subscriptions(id) ON DELETE SET NULL,
    transaction_id UUID REFERENCES public.transactions(id) ON DELETE SET NULL,
    
    -- Event data
    event_data JSONB NOT NULL DEFAULT '{}',
    stripe_webhook_data JSONB NULL,
    
    -- Processing info
    processed_by TEXT DEFAULT 'system',
    error_message TEXT NULL,
    
    -- Timestamp
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ==================================================
-- INDEXES FOR PERFORMANCE
-- ==================================================

-- Subscriptions indexes
CREATE INDEX IF NOT EXISTS idx_subscriptions_user_id ON public.subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_stripe_customer_id ON public.subscriptions(stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON public.subscriptions(status);
CREATE INDEX IF NOT EXISTS idx_subscriptions_current_period_end ON public.subscriptions(current_period_end);

-- Transactions indexes
CREATE INDEX IF NOT EXISTS idx_transactions_user_id ON public.transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_transactions_subscription_id ON public.transactions(subscription_id);
CREATE INDEX IF NOT EXISTS idx_transactions_status ON public.transactions(status);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON public.transactions(created_at);

-- One-time purchases indexes
CREATE INDEX IF NOT EXISTS idx_one_time_purchases_user_id ON public.one_time_purchases(user_id);
CREATE INDEX IF NOT EXISTS idx_one_time_purchases_status ON public.one_time_purchases(status);
CREATE INDEX IF NOT EXISTS idx_one_time_purchases_expires_at ON public.one_time_purchases(expires_at);

-- Payment audit log indexes
CREATE INDEX IF NOT EXISTS idx_payment_audit_log_user_id ON public.payment_audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_payment_audit_log_event_type ON public.payment_audit_log(event_type);
CREATE INDEX IF NOT EXISTS idx_payment_audit_log_created_at ON public.payment_audit_log(created_at);
CREATE INDEX IF NOT EXISTS idx_payment_audit_log_stripe_event_id ON public.payment_audit_log(stripe_event_id);

-- ==================================================
-- ROW LEVEL SECURITY POLICIES
-- ==================================================

-- Enable RLS on all payment tables
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.one_time_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_audit_log ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist (from January migration)
DROP POLICY IF EXISTS "Users can view their own subscriptions" ON public.subscriptions;
DROP POLICY IF EXISTS "Service role manages subscriptions" ON public.subscriptions;
DROP POLICY IF EXISTS "Users can view their own transactions" ON public.transactions;
DROP POLICY IF EXISTS "Service role manages transactions" ON public.transactions;
DROP POLICY IF EXISTS "Users can view their own purchases" ON public.one_time_purchases;
DROP POLICY IF EXISTS "Service role manages purchases" ON public.one_time_purchases;
DROP POLICY IF EXISTS "Service role manages payment audit log" ON public.payment_audit_log;

-- Subscriptions policies
CREATE POLICY "Users can view their own subscriptions" ON public.subscriptions
    FOR SELECT USING (auth.uid() = user_id OR auth.role() = 'service_role');

CREATE POLICY "Service role manages subscriptions" ON public.subscriptions
    FOR ALL USING (auth.role() = 'service_role');

-- Transactions policies
CREATE POLICY "Users can view their own transactions" ON public.transactions
    FOR SELECT USING (auth.uid() = user_id OR auth.role() = 'service_role');

CREATE POLICY "Service role manages transactions" ON public.transactions
    FOR ALL USING (auth.role() = 'service_role');

-- One-time purchases policies
CREATE POLICY "Users can view their own purchases" ON public.one_time_purchases
    FOR SELECT USING (auth.uid() = user_id OR auth.role() = 'service_role');

CREATE POLICY "Service role manages purchases" ON public.one_time_purchases
    FOR ALL USING (auth.role() = 'service_role');

-- Payment audit log policies
CREATE POLICY "Service role manages payment audit log" ON public.payment_audit_log
    FOR ALL USING (auth.role() = 'service_role');

-- ==================================================
-- UPDATE EXISTING USERS TABLE
-- ==================================================

-- Ensure stripe_customer_id is unique on users table
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_stripe_customer_id 
ON public.users(stripe_customer_id) 
WHERE stripe_customer_id IS NOT NULL;