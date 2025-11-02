-- Create Classes Table
-- Defines class templates (e.g., "Morning Sparring", "Technique Tuesday")

CREATE TABLE IF NOT EXISTS public.classes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Class details
  title TEXT NOT NULL,
  description TEXT,
  class_type TEXT CHECK (class_type IN ('technique', 'sparring', 'conditioning', 'open_gym', 'beginners', 'advanced', 'private')),

  -- Coach assignment
  coach_id UUID REFERENCES public.users(id) ON DELETE SET NULL,

  -- Capacity
  max_capacity INTEGER DEFAULT 20 CHECK (max_capacity > 0),
  duration_minutes INTEGER DEFAULT 60 CHECK (duration_minutes > 0),

  -- Recurrence settings
  is_recurring BOOLEAN DEFAULT false,
  recurrence_rule TEXT, -- RRULE format (e.g., "FREQ=WEEKLY;BYDAY=MO,WE,FR")

  -- Settings
  allow_waitlist BOOLEAN DEFAULT true,
  require_membership BOOLEAN DEFAULT false,
  cancellation_hours INTEGER DEFAULT 24, -- Hours before class to allow cancellation

  -- Metadata
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_classes_organization_id ON public.classes(organization_id);
CREATE INDEX IF NOT EXISTS idx_classes_coach_id ON public.classes(coach_id);
CREATE INDEX IF NOT EXISTS idx_classes_type ON public.classes(organization_id, class_type);
CREATE INDEX IF NOT EXISTS idx_classes_active ON public.classes(organization_id, is_active);

-- Enable Row Level Security
ALTER TABLE public.classes ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.classes IS 'Class templates for recurring and one-time classes';
COMMENT ON COLUMN public.classes.recurrence_rule IS 'iCalendar RRULE format for recurring classes';
COMMENT ON COLUMN public.classes.cancellation_hours IS 'Number of hours before class when member can cancel';
