-- Backfill zodiac signs for existing users with birth data but NULL zodiac_sign
-- This migration calculates zodiac signs from existing birth_details JSONB data

-- Create a temporary function to calculate zodiac signs
CREATE OR REPLACE FUNCTION temp_calculate_zodiac_sign(birth_date TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    parsed_date DATE;
    month_num INT;
    day_num INT;
BEGIN
    -- Parse the date string
    BEGIN
        parsed_date := birth_date::DATE;
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL; -- Return NULL for invalid dates
    END;
    
    -- Extract month and day
    month_num := EXTRACT(MONTH FROM parsed_date);
    day_num := EXTRACT(DAY FROM parsed_date);
    
    -- Calculate zodiac sign based on date ranges (tropical zodiac)
    IF (month_num = 3 AND day_num >= 21) OR (month_num = 4 AND day_num <= 19) THEN
        RETURN 'Aries';
    ELSIF (month_num = 4 AND day_num >= 20) OR (month_num = 5 AND day_num <= 20) THEN
        RETURN 'Taurus';
    ELSIF (month_num = 5 AND day_num >= 21) OR (month_num = 6 AND day_num <= 20) THEN
        RETURN 'Gemini';
    ELSIF (month_num = 6 AND day_num >= 21) OR (month_num = 7 AND day_num <= 22) THEN
        RETURN 'Cancer';
    ELSIF (month_num = 7 AND day_num >= 23) OR (month_num = 8 AND day_num <= 22) THEN
        RETURN 'Leo';
    ELSIF (month_num = 8 AND day_num >= 23) OR (month_num = 9 AND day_num <= 22) THEN
        RETURN 'Virgo';
    ELSIF (month_num = 9 AND day_num >= 23) OR (month_num = 10 AND day_num <= 22) THEN
        RETURN 'Libra';
    ELSIF (month_num = 10 AND day_num >= 23) OR (month_num = 11 AND day_num <= 21) THEN
        RETURN 'Scorpio';
    ELSIF (month_num = 11 AND day_num >= 22) OR (month_num = 12 AND day_num <= 21) THEN
        RETURN 'Sagittarius';
    ELSIF (month_num = 12 AND day_num >= 22) OR (month_num = 1 AND day_num <= 19) THEN
        RETURN 'Capricorn';
    ELSIF (month_num = 1 AND day_num >= 20) OR (month_num = 2 AND day_num <= 18) THEN
        RETURN 'Aquarius';
    ELSIF (month_num = 2 AND day_num >= 19) OR (month_num = 3 AND day_num <= 20) THEN
        RETURN 'Pisces';
    ELSE
        RETURN NULL; -- Fallback for edge cases
    END IF;
END;
$$;

-- Update profiles with calculated zodiac signs using birth_date from users table
UPDATE public.profiles 
SET 
    zodiac_sign = temp_calculate_zodiac_sign(u.birth_date),
    updated_at = NOW()
FROM public.users u
WHERE 
    profiles.id = u.id
    AND profiles.zodiac_sign IS NULL 
    AND u.birth_date IS NOT NULL 
    AND u.birth_date != '';

-- Log the results
DO $$
DECLARE
    updated_count INT;
BEGIN
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RAISE NOTICE 'Updated zodiac_sign for % profiles using birth_date from users table', updated_count;
END
$$;


-- Drop the temporary function
DROP FUNCTION temp_calculate_zodiac_sign(TEXT);

-- Add comment documenting the migration
COMMENT ON COLUMN public.profiles.zodiac_sign IS 
'Zodiac sign calculated from birth date. Updated by migration 20250725120001_backfill_zodiac_signs.sql to fix NULL values that were showing as hardcoded "Aries" fallback.';