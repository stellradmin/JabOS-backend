-- Create Gym Metrics Table
-- Denormalized analytics for performance

CREATE TABLE IF NOT EXISTS public.gym_metrics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  date DATE NOT NULL,

  -- Member metrics
  total_members INTEGER DEFAULT 0,
  active_members INTEGER DEFAULT 0, -- Attended in last 30 days
  new_members INTEGER DEFAULT 0,
  churned_members INTEGER DEFAULT 0,
  trial_members INTEGER DEFAULT 0,

  -- Class metrics
  total_classes INTEGER DEFAULT 0,
  total_class_capacity INTEGER DEFAULT 0,
  total_bookings INTEGER DEFAULT 0,
  total_attendance INTEGER DEFAULT 0,
  total_no_shows INTEGER DEFAULT 0,
  total_cancellations INTEGER DEFAULT 0,
  avg_class_attendance DECIMAL(5,2),
  avg_capacity_utilization DECIMAL(5,2), -- Percentage

  -- Workout metrics
  total_workouts_logged INTEGER DEFAULT 0,
  total_sparring_sessions INTEGER DEFAULT 0,

  -- Revenue metrics (in cents)
  revenue_cents INTEGER DEFAULT 0,
  new_revenue_cents INTEGER DEFAULT 0,
  renewal_revenue_cents INTEGER DEFAULT 0,

  -- Retention metrics
  retention_rate_30d DECIMAL(5,2),
  retention_rate_60d DECIMAL(5,2),
  retention_rate_90d DECIMAL(5,2),

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  UNIQUE(organization_id, date)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_gym_metrics_organization_date ON public.gym_metrics(organization_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_gym_metrics_date ON public.gym_metrics(date);

-- Enable Row Level Security
ALTER TABLE public.gym_metrics ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.gym_metrics IS 'Daily aggregated metrics for analytics dashboard';
COMMENT ON COLUMN public.gym_metrics.active_members IS 'Members who attended at least once in last 30 days';
COMMENT ON COLUMN public.gym_metrics.avg_capacity_utilization IS 'Average class fill rate as percentage';
