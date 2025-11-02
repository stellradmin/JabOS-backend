-- Create Membership Plans Table
-- Defines gym membership tiers

CREATE TABLE IF NOT EXISTS public.membership_plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Plan details
  name TEXT NOT NULL,
  description TEXT,

  -- Pricing
  price_cents INTEGER NOT NULL CHECK (price_cents >= 0),
  billing_interval TEXT NOT NULL CHECK (billing_interval IN ('monthly', 'quarterly', 'annual', 'lifetime')),

  -- Benefits
  class_credits INTEGER, -- NULL = unlimited
  allows_sparring BOOLEAN DEFAULT true,
  allows_open_gym BOOLEAN DEFAULT true,
  priority_booking BOOLEAN DEFAULT false,

  -- Stripe integration
  stripe_price_id TEXT,
  stripe_product_id TEXT,

  -- Status
  is_active BOOLEAN DEFAULT true,
  is_featured BOOLEAN DEFAULT false,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_membership_plans_organization ON public.membership_plans(organization_id);
CREATE INDEX IF NOT EXISTS idx_membership_plans_active ON public.membership_plans(organization_id, is_active)
  WHERE is_active = true;

-- Enable Row Level Security
ALTER TABLE public.membership_plans ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.membership_plans IS 'Gym membership plans and pricing tiers';
COMMENT ON COLUMN public.membership_plans.class_credits IS 'Number of class credits per billing period. NULL = unlimited';
COMMENT ON COLUMN public.membership_plans.price_cents IS 'Price in cents (e.g., $99.00 = 9900)';
