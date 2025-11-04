-- Create Attendance Table
-- Tracks member check-ins to gym and classes

CREATE TABLE IF NOT EXISTS public.attendance (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Class association (optional - can check in without class)
  class_instance_id UUID REFERENCES public.class_instances(id) ON DELETE SET NULL,

  -- Check-in/out times
  check_in_time TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  check_out_time TIMESTAMP WITH TIME ZONE,

  -- Method
  method TEXT DEFAULT 'manual' CHECK (method IN ('manual', 'qr_code', 'app', 'kiosk')),

  -- Location (future: multiple gym locations)
  location TEXT,

  -- Notes
  notes TEXT,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_attendance_user ON public.attendance(user_id, check_in_time DESC);
CREATE INDEX IF NOT EXISTS idx_attendance_organization ON public.attendance(organization_id, check_in_time DESC);
CREATE INDEX IF NOT EXISTS idx_attendance_class ON public.attendance(class_instance_id);
-- Date-based queries can use the organization+check_in_time index above

-- Index for active check-ins (not checked out yet)
CREATE INDEX IF NOT EXISTS idx_attendance_active ON public.attendance(organization_id, user_id)
  WHERE check_out_time IS NULL;

-- Enable Row Level Security
ALTER TABLE public.attendance ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.attendance IS 'Member check-in/check-out records';
COMMENT ON COLUMN public.attendance.method IS 'How member checked in: manual, qr_code, app, kiosk';
COMMENT ON COLUMN public.attendance.class_instance_id IS 'Optional class association';
