-- Create Users Table (Web Platform)
-- Note: This table was already created by 0001_create_base_schema.sql
-- This migration adds columns if they don't exist

-- Add columns that might be missing from the mobile schema
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES public.organizations(id) ON DELETE CASCADE;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS role TEXT CHECK (role IN ('owner', 'coach', 'member'));
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS full_name TEXT;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS phone TEXT;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT true;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMP WITH TIME ZONE;

-- Create indexes (will skip if already exist)
CREATE INDEX IF NOT EXISTS idx_users_organization_id ON public.users(organization_id) WHERE organization_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_email ON public.users(email);
CREATE INDEX IF NOT EXISTS idx_users_role ON public.users(organization_id, role) WHERE organization_id IS NOT NULL AND role IS NOT NULL;

-- Enable Row Level Security (idempotent)
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Add unique constraint if not exists
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'users_organization_email_key'
  ) THEN
    ALTER TABLE public.users ADD CONSTRAINT users_organization_email_key UNIQUE(organization_id, email);
  END IF;
END $$;

-- Comments
COMMENT ON TABLE public.users IS 'User profiles linked to organizations with roles';
COMMENT ON COLUMN public.users.role IS 'User role: owner (gym owner), coach (trainer), member (gym member)';
COMMENT ON COLUMN public.users.organization_id IS 'Organization/gym this user belongs to';
