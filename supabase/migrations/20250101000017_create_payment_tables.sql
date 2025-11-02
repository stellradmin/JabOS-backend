-- Payment-related Tables for Stripe Integration

-- =============================================================================
-- STRIPE CUSTOMERS
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.stripe_customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE UNIQUE,
  stripe_customer_id TEXT NOT NULL UNIQUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stripe_customers_organization ON public.stripe_customers(organization_id);
CREATE INDEX IF NOT EXISTS idx_stripe_customers_stripe_id ON public.stripe_customers(stripe_customer_id);

ALTER TABLE public.stripe_customers ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.stripe_customers IS 'Maps organizations to Stripe customers';

-- =============================================================================
-- SUBSCRIPTIONS (JabOS Platform Subscriptions)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  stripe_subscription_id TEXT UNIQUE,
  stripe_customer_id TEXT,

  -- Subscription details
  tier TEXT NOT NULL CHECK (tier IN ('starter', 'growth', 'pro', 'enterprise')),
  status TEXT NOT NULL CHECK (status IN ('active', 'trialing', 'past_due', 'canceled', 'incomplete', 'incomplete_expired', 'paused')),

  -- Pricing
  amount_cents INTEGER NOT NULL,
  currency TEXT DEFAULT 'usd',
  interval TEXT NOT NULL CHECK (interval IN ('month', 'year')),

  -- Dates
  current_period_start TIMESTAMP WITH TIME ZONE,
  current_period_end TIMESTAMP WITH TIME ZONE,
  trial_start TIMESTAMP WITH TIME ZONE,
  trial_end TIMESTAMP WITH TIME ZONE,
  canceled_at TIMESTAMP WITH TIME ZONE,
  ended_at TIMESTAMP WITH TIME ZONE,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_organization ON public.subscriptions(organization_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_stripe_id ON public.subscriptions(stripe_subscription_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON public.subscriptions(status);

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.subscriptions IS 'JabOS platform subscriptions (not gym member subscriptions)';

-- =============================================================================
-- INVOICES
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  stripe_invoice_id TEXT UNIQUE,
  stripe_customer_id TEXT,

  -- Invoice details
  amount_due INTEGER NOT NULL,
  amount_paid INTEGER DEFAULT 0,
  currency TEXT DEFAULT 'usd',
  status TEXT NOT NULL CHECK (status IN ('draft', 'open', 'paid', 'void', 'uncollectible')),

  -- Dates
  invoice_date TIMESTAMP WITH TIME ZONE,
  due_date TIMESTAMP WITH TIME ZONE,
  paid_at TIMESTAMP WITH TIME ZONE,

  -- Links
  invoice_pdf TEXT,
  hosted_invoice_url TEXT,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_invoices_organization ON public.invoices(organization_id);
CREATE INDEX IF NOT EXISTS idx_invoices_stripe_id ON public.invoices(stripe_invoice_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status ON public.invoices(status);

ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.invoices IS 'Stripe invoices for platform subscriptions';

-- =============================================================================
-- PAYMENT METHODS
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.payment_methods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  stripe_payment_method_id TEXT UNIQUE,

  -- Card details (last 4, brand, etc.)
  type TEXT NOT NULL, -- card, bank_account, etc.
  card_brand TEXT,
  card_last4 TEXT,
  card_exp_month INTEGER,
  card_exp_year INTEGER,

  -- Status
  is_default BOOLEAN DEFAULT false,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payment_methods_organization ON public.payment_methods(organization_id);
CREATE INDEX IF NOT EXISTS idx_payment_methods_default ON public.payment_methods(organization_id, is_default)
  WHERE is_default = true;

ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.payment_methods IS 'Stored payment methods for organizations';

-- =============================================================================
-- RLS POLICIES FOR PAYMENT TABLES
-- =============================================================================

-- Stripe Customers
DROP POLICY IF EXISTS "Owners can view stripe customer" ON public.stripe_customers;
CREATE POLICY "Owners can view stripe customer"
  ON public.stripe_customers FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role = 'owner'
    )
  );

-- Subscriptions
DROP POLICY IF EXISTS "Owners can view subscriptions" ON public.subscriptions;
CREATE POLICY "Owners can view subscriptions"
  ON public.subscriptions FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role = 'owner'
    )
  );

-- Invoices
DROP POLICY IF EXISTS "Owners can view invoices" ON public.invoices;
CREATE POLICY "Owners can view invoices"
  ON public.invoices FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role = 'owner'
    )
  );

-- Payment Methods
DROP POLICY IF EXISTS "Owners can view payment methods" ON public.payment_methods;
CREATE POLICY "Owners can view payment methods"
  ON public.payment_methods FOR SELECT
  USING (
    organization_id IN (
      SELECT organization_id FROM public.users
      WHERE id = auth.uid() AND role = 'owner'
    )
  );

-- Triggers for updated_at
CREATE TRIGGER update_stripe_customers_updated_at BEFORE UPDATE ON public.stripe_customers
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_subscriptions_updated_at BEFORE UPDATE ON public.subscriptions
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_invoices_updated_at BEFORE UPDATE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_payment_methods_updated_at BEFORE UPDATE ON public.payment_methods
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
