-- Add compatibility columns to matches table
-- These columns are required by the get-compatibility-details Edge Function

ALTER TABLE public.matches 
ADD COLUMN IF NOT EXISTS calculation_result JSONB,
ADD COLUMN IF NOT EXISTS overall_score INTEGER,
ADD COLUMN IF NOT EXISTS questionnaire_grade TEXT,
ADD COLUMN IF NOT EXISTS astrological_grade TEXT;

-- Add comments for clarity
COMMENT ON COLUMN public.matches.calculation_result IS 'JSON object containing full compatibility calculation results';
COMMENT ON COLUMN public.matches.overall_score IS 'Numeric overall compatibility score (0-100)';
COMMENT ON COLUMN public.matches.questionnaire_grade IS 'Letter grade (A-F) for questionnaire compatibility';
COMMENT ON COLUMN public.matches.astrological_grade IS 'Letter grade (A-F) for astrological compatibility';

-- Create an index on overall_score for performance
CREATE INDEX IF NOT EXISTS idx_matches_overall_score ON public.matches(overall_score);