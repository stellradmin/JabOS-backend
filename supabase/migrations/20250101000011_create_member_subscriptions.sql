-- Create Member Subscriptions Table
-- Tracks gym member memberships (not JabOS platform subscriptions)

CREATE TABLE IF NOT EXISTS public.member_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  plan_id UUID NOT NULL REFERENCES public.membership_plans(id) ON DELETE RESTRICT,

  -- Status
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'paused', 'canceled', 'past_due', 'trialing')),

  -- Dates
  started_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  current_period_start TIMESTAMP WITH TIME ZONE,
  current_period_end TIMESTAMP WITH TIME ZONE,
  trial_ends_at TIMESTAMP WITH TIME ZONE,
  canceled_at TIMESTAMP WITH TIME ZONE,
  paused_at TIMESTAMP WITH TIME ZONE,

  -- Settings
  auto_renew BOOLEAN DEFAULT true,

  -- Credits (for limited plans)
  remaining_class_credits INTEGER,

  -- Stripe integration
  stripe_subscription_id TEXT,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  -- One active subscription per user per org
  UNIQUE(user_id, organization_id)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_member_subscriptions_user ON public.member_subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_member_subscriptions_organization ON public.member_subscriptions(organization_id);
CREATE INDEX IF NOT EXISTS idx_member_subscriptions_plan ON public.member_subscriptions(plan_id);
CREATE INDEX IF NOT EXISTS idx_member_subscriptions_status ON public.member_subscriptions(organization_id, status);
CREATE INDEX IF NOT EXISTS idx_member_subscriptions_expiring ON public.member_subscriptions(organization_id, current_period_end)
  WHERE status = 'active';

-- Enable Row Level Security
ALTER TABLE public.member_subscriptions ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.member_subscriptions IS 'Gym member subscriptions (not platform subscriptions)';
COMMENT ON COLUMN public.member_subscriptions.remaining_class_credits IS 'Class credits remaining in current period';
