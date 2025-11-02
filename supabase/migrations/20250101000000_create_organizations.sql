-- Create Organizations (Gyms) Table
-- Each organization represents a gym using JabOS

CREATE TABLE IF NOT EXISTS public.organizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  slug TEXT UNIQUE NOT NULL,
  logo_url TEXT,
  timezone TEXT DEFAULT 'America/New_York',

  -- Subscription details
  subscription_tier TEXT DEFAULT 'starter' CHECK (subscription_tier IN ('starter', 'growth', 'pro', 'enterprise')),
  subscription_status TEXT DEFAULT 'trialing' CHECK (subscription_status IN ('trialing', 'active', 'past_due', 'canceled', 'paused')),
  trial_ends_at TIMESTAMP WITH TIME ZONE,

  -- Stripe integration
  stripe_customer_id TEXT UNIQUE,
  stripe_subscription_id TEXT,

  -- Contact information
  email TEXT,
  phone TEXT,
  address TEXT,
  city TEXT,
  state TEXT,
  zip_code TEXT,
  country TEXT DEFAULT 'US',

  -- Settings
  settings JSONB DEFAULT '{}'::jsonb,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  CONSTRAINT valid_slug CHECK (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$')
);

-- Create index on slug for fast lookups
CREATE INDEX IF NOT EXISTS idx_organizations_slug ON public.organizations(slug);

-- Create index on stripe_customer_id for webhook processing
CREATE INDEX IF NOT EXISTS idx_organizations_stripe_customer_id ON public.organizations(stripe_customer_id);

-- Enable Row Level Security
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;

-- Comments for documentation
COMMENT ON TABLE public.organizations IS 'Organizations (gyms) using JabOS platform';
COMMENT ON COLUMN public.organizations.slug IS 'URL-safe identifier used in path: jabos.app/[slug]';
COMMENT ON COLUMN public.organizations.subscription_tier IS 'Pricing tier: starter, growth, pro, enterprise';
COMMENT ON COLUMN public.organizations.subscription_status IS 'Current subscription status';
COMMENT ON COLUMN public.organizations.settings IS 'Organization-specific settings and preferences';
