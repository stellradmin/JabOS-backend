-- Create Announcements Table
-- Gym-wide announcements and news

CREATE TABLE IF NOT EXISTS public.announcements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Author
  author_id UUID NOT NULL REFERENCES public.users(id) ON DELETE SET NULL,

  -- Content
  title TEXT NOT NULL CHECK (char_length(title) <= 200),
  content TEXT NOT NULL,

  -- Visibility
  target_audience TEXT DEFAULT 'all' CHECK (target_audience IN ('all', 'members', 'coaches', 'specific')),

  -- Scheduling
  published_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  expires_at TIMESTAMP WITH TIME ZONE,

  -- Display
  is_pinned BOOLEAN DEFAULT false,
  is_draft BOOLEAN DEFAULT false,

  -- Priority
  priority TEXT DEFAULT 'normal' CHECK (priority IN ('low', 'normal', 'high', 'urgent')),

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_announcements_organization ON public.announcements(organization_id, published_at DESC);
CREATE INDEX IF NOT EXISTS idx_announcements_active ON public.announcements(organization_id, published_at)
  WHERE is_draft = false AND (expires_at IS NULL OR expires_at > NOW());
CREATE INDEX IF NOT EXISTS idx_announcements_pinned ON public.announcements(organization_id, is_pinned)
  WHERE is_pinned = true;

-- Enable Row Level Security
ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.announcements IS 'Gym announcements and news';
COMMENT ON COLUMN public.announcements.is_pinned IS 'Pinned to top of announcement feed';
COMMENT ON COLUMN public.announcements.target_audience IS 'Who can see this announcement';
