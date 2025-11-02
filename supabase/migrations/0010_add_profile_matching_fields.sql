-- Add zodiac_sign to profiles table if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
        AND table_name = 'profiles'
        AND column_name = 'zodiac_sign'
    ) THEN
        ALTER TABLE public.profiles
        ADD COLUMN zodiac_sign TEXT;
        RAISE NOTICE 'Column zodiac_sign added to profiles.';
    ELSE
        RAISE NOTICE 'Column zodiac_sign already exists in profiles.';
    END IF;
END $$;

-- Add activity_preferences to profiles table if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
        AND table_name = 'profiles'
        AND column_name = 'activity_preferences'
    ) THEN
        ALTER TABLE public.profiles
        ADD COLUMN activity_preferences JSONB; -- Or TEXT[] if preferred and handled by app logic
        RAISE NOTICE 'Column activity_preferences added to profiles.';
    ELSE
        RAISE NOTICE 'Column activity_preferences already exists in profiles.';
    END IF;
END $$;

-- Regarding match_requests.status:
-- If it's currently TEXT, you might want to add a CHECK constraint
-- or convert it to an ENUM type for better data integrity.
-- Example for CHECK constraint (if status is TEXT):
/*
ALTER TABLE public.match_requests
ADD CONSTRAINT check_match_requests_status
CHECK (status IN ('pending_system_match', 'fulfilled', 'pending_user_confirmation', 'cancelled', 'expired'));
-- Add other relevant statuses to the IN clause.
*/

-- Example for creating an ENUM type and altering column (more involved, especially if data exists):
/*
CREATE TYPE public.match_request_status_enum AS ENUM (
    'pending_system_match',
    'pending_user_confirmation', -- If system proposes and waits for user
    'fulfilled',
    'cancelled',
    'expired'
);

ALTER TABLE public.match_requests
ALTER COLUMN status TYPE public.match_request_status_enum
USING status::public.match_request_status_enum;
*/

-- For now, this migration focuses on adding the profile fields.
-- Status field changes should be considered carefully based on existing data and application logic.

COMMENT ON COLUMN public.profiles.zodiac_sign IS 'User''s own zodiac sign, derived from natal chart data.';
COMMENT ON COLUMN public.profiles.activity_preferences IS 'User''s own preferred activities for matching, e.g., as a JSONB array of strings.';
