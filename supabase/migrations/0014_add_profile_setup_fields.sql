-- Add profile setup fields to the profiles table
-- This migration adds columns needed for the profile setup flow

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS education_level TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS politics TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS is_single BOOLEAN DEFAULT true;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS has_kids BOOLEAN DEFAULT false;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS wants_kids TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS traits TEXT[] DEFAULT '{}';
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS interests TEXT[] DEFAULT '{}';
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS onboarding_completed BOOLEAN DEFAULT false;

-- Add comments for documentation
COMMENT ON COLUMN profiles.education_level IS 'User education level (e.g., High School, Bachelor''s Degree, etc.)';
COMMENT ON COLUMN profiles.politics IS 'User political views (e.g., Liberal, Conservative, Not Political, etc.)';
COMMENT ON COLUMN profiles.is_single IS 'Whether the user is currently single';
COMMENT ON COLUMN profiles.has_kids IS 'Whether the user has children';
COMMENT ON COLUMN profiles.wants_kids IS 'User preference for having kids (Yes, No, Maybe)';
COMMENT ON COLUMN profiles.traits IS 'Array of personality traits selected by user';
COMMENT ON COLUMN profiles.interests IS 'Array of interests/hobbies selected by user';
COMMENT ON COLUMN profiles.onboarding_completed IS 'Whether the user has completed the onboarding process';