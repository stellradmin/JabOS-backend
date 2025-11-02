-- Create Workout Logs Table
-- Tracks member training sessions

CREATE TABLE IF NOT EXISTS public.workout_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Class association (optional - can log outside of class)
  class_instance_id UUID REFERENCES public.class_instances(id) ON DELETE SET NULL,

  -- Workout details
  workout_type TEXT CHECK (workout_type IN (
    'shadowbox', 'heavy_bag', 'speed_bag', 'double_end_bag',
    'sparring', 'mitt_work', 'conditioning', 'technique',
    'jump_rope', 'strength_training', 'cardio', 'other'
  )),
  duration_minutes INTEGER CHECK (duration_minutes > 0),
  rounds INTEGER,

  -- Timer preset used
  timer_preset_id UUID REFERENCES public.timer_presets(id) ON DELETE SET NULL,

  -- Notes and feedback
  notes TEXT,
  rating INTEGER CHECK (rating >= 1 AND rating <= 10), -- How they felt (1-10)

  -- Metrics (optional)
  calories_burned INTEGER,
  heart_rate_avg INTEGER,
  intensity_level TEXT CHECK (intensity_level IN ('light', 'moderate', 'vigorous')),

  -- Timestamp
  logged_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_workout_logs_user ON public.workout_logs(user_id, logged_at DESC);
CREATE INDEX IF NOT EXISTS idx_workout_logs_organization ON public.workout_logs(organization_id, logged_at DESC);
CREATE INDEX IF NOT EXISTS idx_workout_logs_type ON public.workout_logs(organization_id, workout_type);
CREATE INDEX IF NOT EXISTS idx_workout_logs_class ON public.workout_logs(class_instance_id);

-- Enable Row Level Security
ALTER TABLE public.workout_logs ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.workout_logs IS 'Member training session logs';
COMMENT ON COLUMN public.workout_logs.logged_at IS 'When the workout actually occurred (can be backdated)';
COMMENT ON COLUMN public.workout_logs.rating IS 'Self-reported workout quality/feeling (1-10)';
