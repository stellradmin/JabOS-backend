-- Create Timer Presets Table
-- Stores round timer configurations for boxing workouts

CREATE TABLE IF NOT EXISTS public.timer_presets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Preset details
  name TEXT NOT NULL,
  description TEXT,

  -- Timer configuration
  rounds INTEGER NOT NULL CHECK (rounds > 0 AND rounds <= 50),
  round_duration_seconds INTEGER NOT NULL CHECK (round_duration_seconds > 0),
  rest_duration_seconds INTEGER NOT NULL CHECK (rest_duration_seconds >= 0),
  warning_seconds INTEGER DEFAULT 10 CHECK (warning_seconds >= 0),

  -- Settings
  is_default BOOLEAN DEFAULT false,
  is_public BOOLEAN DEFAULT false, -- If true, visible to all org members
  created_by UUID REFERENCES public.users(id) ON DELETE SET NULL,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_timer_presets_organization ON public.timer_presets(organization_id);
CREATE INDEX IF NOT EXISTS idx_timer_presets_default ON public.timer_presets(organization_id, is_default)
  WHERE is_default = true;

-- Enable Row Level Security
ALTER TABLE public.timer_presets ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.timer_presets IS 'Configurable timer presets for boxing rounds';
COMMENT ON COLUMN public.timer_presets.warning_seconds IS 'Seconds before round ends to play warning bell';
COMMENT ON COLUMN public.timer_presets.is_default IS 'Default preset for organization';
