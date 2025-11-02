-- Create Users Table
-- Extends Supabase Auth with organization and role information

CREATE TABLE IF NOT EXISTS public.users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  organization_id UUID REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Role within organization
  role TEXT NOT NULL CHECK (role IN ('owner', 'coach', 'member')),

  -- Profile information
  email TEXT NOT NULL,
  full_name TEXT NOT NULL,
  avatar_url TEXT,
  phone TEXT,

  -- Status
  is_active BOOLEAN DEFAULT true,
  last_login_at TIMESTAMP WITH TIME ZONE,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  UNIQUE(organization_id, email)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_users_organization_id ON public.users(organization_id);
CREATE INDEX IF NOT EXISTS idx_users_email ON public.users(email);
CREATE INDEX IF NOT EXISTS idx_users_role ON public.users(organization_id, role);

-- Enable Row Level Security
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.users IS 'User profiles linked to organizations with roles';
COMMENT ON COLUMN public.users.role IS 'User role: owner (gym owner), coach (trainer), member (gym member)';
COMMENT ON COLUMN public.users.organization_id IS 'Organization/gym this user belongs to';
