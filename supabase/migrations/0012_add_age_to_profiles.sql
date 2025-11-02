-- Add age column if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'profiles' AND column_name = 'age') THEN
        ALTER TABLE public.profiles ADD COLUMN age INT;
    END IF;
END $$;
