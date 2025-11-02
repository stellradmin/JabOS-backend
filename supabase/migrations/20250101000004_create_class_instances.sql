-- Create Class Instances Table
-- Represents individual class sessions (e.g., "Monday Sparring on Jan 15, 2025 at 6pm")

CREATE TABLE IF NOT EXISTS public.class_instances (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  class_id UUID NOT NULL REFERENCES public.classes(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Schedule
  start_time TIMESTAMP WITH TIME ZONE NOT NULL,
  end_time TIMESTAMP WITH TIME ZONE NOT NULL,

  -- Override settings (can differ from parent class)
  coach_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  max_capacity INTEGER,

  -- Status
  status TEXT DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'in_progress', 'completed', 'canceled')),

  -- Notes
  notes TEXT,
  canceled_reason TEXT,
  canceled_at TIMESTAMP WITH TIME ZONE,

  -- Stats (denormalized)
  total_bookings INTEGER DEFAULT 0,
  total_attended INTEGER DEFAULT 0,
  total_no_shows INTEGER DEFAULT 0,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  CONSTRAINT valid_time_range CHECK (end_time > start_time)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_class_instances_class_id ON public.class_instances(class_id);
CREATE INDEX IF NOT EXISTS idx_class_instances_organization_id ON public.class_instances(organization_id);
CREATE INDEX IF NOT EXISTS idx_class_instances_start_time ON public.class_instances(organization_id, start_time);
CREATE INDEX IF NOT EXISTS idx_class_instances_status ON public.class_instances(organization_id, status);
CREATE INDEX IF NOT EXISTS idx_class_instances_coach ON public.class_instances(coach_id, start_time);

-- Index for calendar queries (find classes in a date range)
CREATE INDEX IF NOT EXISTS idx_class_instances_date_range ON public.class_instances(organization_id, start_time, end_time);

-- Enable Row Level Security
ALTER TABLE public.class_instances ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.class_instances IS 'Individual class sessions scheduled from class templates';
COMMENT ON COLUMN public.class_instances.status IS 'Current status of the class session';
COMMENT ON COLUMN public.class_instances.total_attended IS 'Number of members who attended (checked in)';
COMMENT ON COLUMN public.class_instances.total_no_shows IS 'Number of members who booked but did not show up';
