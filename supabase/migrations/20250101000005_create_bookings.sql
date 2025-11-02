-- Create Bookings Table
-- Represents member reservations for class instances

CREATE TABLE IF NOT EXISTS public.bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  class_instance_id UUID NOT NULL REFERENCES public.class_instances(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Status
  status TEXT DEFAULT 'confirmed' CHECK (status IN ('confirmed', 'waitlist', 'canceled', 'attended', 'no_show')),

  -- Timestamps
  checked_in_at TIMESTAMP WITH TIME ZONE,
  canceled_at TIMESTAMP WITH TIME ZONE,
  cancellation_reason TEXT,

  -- Waitlist
  waitlist_position INTEGER,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  -- Prevent duplicate bookings
  UNIQUE(class_instance_id, user_id)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_bookings_class_instance ON public.bookings(class_instance_id);
CREATE INDEX IF NOT EXISTS idx_bookings_user ON public.bookings(user_id);
CREATE INDEX IF NOT EXISTS idx_bookings_organization ON public.bookings(organization_id);
CREATE INDEX IF NOT EXISTS idx_bookings_status ON public.bookings(class_instance_id, status);
CREATE INDEX IF NOT EXISTS idx_bookings_user_upcoming ON public.bookings(user_id, status)
  WHERE status IN ('confirmed', 'waitlist');

-- Enable Row Level Security
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.bookings IS 'Member reservations for class instances';
COMMENT ON COLUMN public.bookings.status IS 'Booking status: confirmed, waitlist, canceled, attended, no_show';
COMMENT ON COLUMN public.bookings.waitlist_position IS 'Position in waitlist if class is full';
