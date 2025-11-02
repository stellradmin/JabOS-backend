-- Add children preference fields to users table for dating preferences

-- Add has_kids column (boolean to indicate if user has children)
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS has_kids BOOLEAN DEFAULT NULL;

-- Add wants_kids column (text for preference: 'Yes', 'No', 'Maybe', 'Open to it')
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS wants_kids TEXT DEFAULT NULL;

-- Add check constraint to ensure wants_kids has valid values
ALTER TABLE public.users
  ADD CONSTRAINT check_wants_kids_values
  CHECK (wants_kids IS NULL OR wants_kids IN ('Yes', 'No', 'Maybe', 'Open to it'));

-- Add comment for documentation
COMMENT ON COLUMN public.users.has_kids IS 'Indicates whether the user has children';
COMMENT ON COLUMN public.users.wants_kids IS 'User preference for having children: Yes, No, Maybe, or Open to it';

-- Grant permissions
GRANT SELECT, UPDATE ON public.users TO authenticated;
GRANT SELECT ON public.users TO service_role;
