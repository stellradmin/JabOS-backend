-- Fix gender validation by temporarily bypassing the trigger
-- This resolves the production-blocking gender validation issue

-- Step 1: Drop the problematic trigger temporarily
DROP TRIGGER IF EXISTS validate_profile_data_trigger ON public.profiles;

-- Step 2: Update any invalid gender values without trigger interference
UPDATE public.profiles 
SET gender = CASE 
    WHEN LOWER(gender) = 'male' THEN 'Male'
    WHEN LOWER(gender) = 'female' THEN 'Female'
    WHEN LOWER(gender) = 'non-binary' THEN 'Non-binary'
    WHEN LOWER(gender) = 'other' THEN 'Other'
    WHEN gender IS NULL THEN 'Other'
    ELSE 'Other'
END
WHERE gender NOT IN ('Male', 'Female', 'Non-binary', 'Other', 'Prefer not to say') OR gender IS NULL;

-- Step 3: Add proper gender constraint to profiles table
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_gender_check;
ALTER TABLE public.profiles 
ADD CONSTRAINT profiles_gender_check 
CHECK (gender IN ('Male', 'Female', 'Non-binary', 'Other', 'Prefer not to say'));

-- Step 4: Update the validate_profile_data() function to accept correct gender values
CREATE OR REPLACE FUNCTION validate_profile_data()
RETURNS TRIGGER AS $$
BEGIN
    -- Validate gender (allow proper case-sensitive values)
    IF NEW.gender IS NOT NULL AND NEW.gender NOT IN ('Male', 'Female', 'Non-binary', 'Other', 'Prefer not to say') THEN
        RAISE EXCEPTION 'Invalid gender value. Must be: Male, Female, Non-binary, Other, or Prefer not to say';
    END IF;
    
    -- Add other validations as needed
    IF NEW.age IS NOT NULL AND (NEW.age < 18 OR NEW.age > 100) THEN
        RAISE EXCEPTION 'Age must be between 18 and 100';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Step 5: Re-create the trigger with the updated function
CREATE TRIGGER validate_profile_data_trigger
    BEFORE INSERT OR UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION validate_profile_data();

-- Step 6: Fix matches status constraint (using correct table name)
UPDATE public.matches 
SET status = CASE 
    WHEN status NOT IN ('pending', 'confirmed', 'rejected', 'expired', 'active', 'cancelled') THEN 'pending'
    ELSE status
END;

ALTER TABLE public.matches DROP CONSTRAINT IF EXISTS matches_status_check;
ALTER TABLE public.matches 
ADD CONSTRAINT matches_status_check 
CHECK (status IN ('pending', 'confirmed', 'rejected', 'expired', 'active', 'cancelled'));

-- Step 7: Add looking_for column to users table
ALTER TABLE public.users 
ADD COLUMN IF NOT EXISTS looking_for TEXT[] DEFAULT NULL;

-- Step 8: Add constraint for valid looking_for values
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.constraint_column_usage 
                   WHERE constraint_name = 'users_looking_for_check' AND table_name = 'users') THEN
        ALTER TABLE public.users 
        ADD CONSTRAINT users_looking_for_check 
        CHECK (looking_for IS NULL OR looking_for <@ ARRAY['Males', 'Females', 'Both', 'Non-Binary', 'Transgender']);
    END IF;
END $$;

-- Step 9: Update preferences structure to include looking_for
-- Commented out due to missing preferences column
/*
UPDATE public.users 
SET preferences = COALESCE(preferences, '{}'::jsonb) || 
    jsonb_build_object('looking_for', COALESCE(looking_for, ARRAY['Males', 'Females']))
WHERE looking_for IS NOT NULL;
*/

-- Add comments
COMMENT ON COLUMN public.users.looking_for IS 'Array of gender preferences the user is looking to match with: Males, Females, Both, Non-Binary, Transgender';
COMMENT ON FUNCTION validate_profile_data() IS 'Validates profile data including proper gender values and age constraints';