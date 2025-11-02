-- Create Sparring Matches Table
-- Tracks sparring sessions and matchmaking

CREATE TABLE IF NOT EXISTS public.sparring_matches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Participants
  member_1_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  member_2_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

  -- Schedule
  scheduled_at TIMESTAMP WITH TIME ZONE,
  duration_minutes INTEGER DEFAULT 15 CHECK (duration_minutes > 0),

  -- Status
  status TEXT DEFAULT 'proposed' CHECK (status IN ('proposed', 'confirmed', 'completed', 'canceled')),

  -- Details
  rounds INTEGER,
  round_duration_minutes INTEGER DEFAULT 3,
  is_light_sparring BOOLEAN DEFAULT true,

  -- Notes
  notes TEXT,
  member_1_feedback TEXT,
  member_2_feedback TEXT,

  -- Class association
  class_instance_id UUID REFERENCES public.class_instances(id) ON DELETE SET NULL,

  -- Metadata
  proposed_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
  confirmed_at TIMESTAMP WITH TIME ZONE,
  completed_at TIMESTAMP WITH TIME ZONE,
  canceled_at TIMESTAMP WITH TIME ZONE,
  cancellation_reason TEXT,

  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  -- Prevent self-sparring
  CONSTRAINT different_members CHECK (member_1_id != member_2_id)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_sparring_matches_organization ON public.sparring_matches(organization_id);
CREATE INDEX IF NOT EXISTS idx_sparring_matches_member_1 ON public.sparring_matches(member_1_id);
CREATE INDEX IF NOT EXISTS idx_sparring_matches_member_2 ON public.sparring_matches(member_2_id);
CREATE INDEX IF NOT EXISTS idx_sparring_matches_scheduled ON public.sparring_matches(organization_id, scheduled_at);
CREATE INDEX IF NOT EXISTS idx_sparring_matches_status ON public.sparring_matches(organization_id, status);

-- Composite index for finding user's matches
CREATE INDEX IF NOT EXISTS idx_sparring_matches_user_participation
  ON public.sparring_matches(organization_id, member_1_id, member_2_id, status);

-- Enable Row Level Security
ALTER TABLE public.sparring_matches ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.sparring_matches IS 'Sparring sessions and matchmaking';
COMMENT ON COLUMN public.sparring_matches.status IS 'Match status: proposed, confirmed, completed, canceled';
COMMENT ON COLUMN public.sparring_matches.is_light_sparring IS 'Light/technical sparring vs hard sparring';
