-- Add date night preferences field to users table
-- This migration adds the date_night_preferences JSONB field to store user preferences for matching

ALTER TABLE public.users 
ADD COLUMN IF NOT EXISTS date_night_preferences JSONB DEFAULT '{}';

-- Create index for performance on date night preferences queries
CREATE INDEX IF NOT EXISTS idx_users_date_night_preferences 
ON public.users USING GIN (date_night_preferences);

-- Add comment to document the expected structure
COMMENT ON COLUMN public.users.date_night_preferences IS 'User preferences for date night: zodiac signs and activities (preferred and avoided)';

-- Example structure for reference:
-- {
--   "preferredZodiacSigns": ["Leo", "Taurus", "Any"],
--   "avoidedZodiacSigns": ["Scorpio"],
--   "preferredActivities": ["Coffee Date", "Dinner", "Movies"],
--   "avoidedActivities": ["Hiking", "Sports Event"]
-- }