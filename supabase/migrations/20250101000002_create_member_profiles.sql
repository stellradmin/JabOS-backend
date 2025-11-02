-- Create Member Profiles Table
-- Extended information for gym members

CREATE TABLE IF NOT EXISTS public.member_profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES public.users(id) ON DELETE CASCADE UNIQUE,
  organization_id UUID REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Boxing-specific information
  weight_class TEXT CHECK (weight_class IN (
    'flyweight', 'super_flyweight', 'bantamweight', 'super_bantamweight',
    'featherweight', 'super_featherweight', 'lightweight', 'super_lightweight',
    'welterweight', 'super_welterweight', 'middleweight', 'super_middleweight',
    'light_heavyweight', 'cruiserweight', 'heavyweight', 'super_heavyweight'
  )),
  experience_level TEXT CHECK (experience_level IN ('beginner', 'intermediate', 'advanced', 'pro')),
  stance TEXT CHECK (stance IN ('orthodox', 'southpaw', 'switch')),

  -- Personal information
  date_of_birth DATE,
  gender TEXT,
  height_cm INTEGER,
  weight_kg DECIMAL(5,2),

  -- Emergency contact
  emergency_contact_name TEXT,
  emergency_contact_phone TEXT,
  emergency_contact_relationship TEXT,

  -- Legal
  waiver_signed BOOLEAN DEFAULT false,
  waiver_signed_at TIMESTAMP WITH TIME ZONE,
  medical_conditions TEXT,

  -- Profile details
  bio TEXT,
  goals TEXT,
  looking_for_sparring BOOLEAN DEFAULT false,

  -- Stats (denormalized for performance)
  total_workouts INTEGER DEFAULT 0,
  total_classes_attended INTEGER DEFAULT 0,
  total_sparring_sessions INTEGER DEFAULT 0,
  current_streak_days INTEGER DEFAULT 0,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_member_profiles_user_id ON public.member_profiles(user_id);
CREATE INDEX IF NOT EXISTS idx_member_profiles_organization_id ON public.member_profiles(organization_id);
CREATE INDEX IF NOT EXISTS idx_member_profiles_experience ON public.member_profiles(organization_id, experience_level);
CREATE INDEX IF NOT EXISTS idx_member_profiles_sparring ON public.member_profiles(organization_id, looking_for_sparring)
  WHERE looking_for_sparring = true;

-- Enable Row Level Security
ALTER TABLE public.member_profiles ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.member_profiles IS 'Extended profile information for gym members';
COMMENT ON COLUMN public.member_profiles.looking_for_sparring IS 'Flag for sparring matchmaker feature';
COMMENT ON COLUMN public.member_profiles.current_streak_days IS 'Consecutive days with workout or class attendance';
