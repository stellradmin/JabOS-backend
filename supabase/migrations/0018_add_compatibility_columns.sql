-- Add missing compatibility columns to matches table
-- Migration: 0018_add_compatibility_columns.sql

-- Add compatibility columns to matches table
ALTER TABLE public.matches 
ADD COLUMN IF NOT EXISTS calculation_result JSONB,
ADD COLUMN IF NOT EXISTS overall_score INTEGER,
ADD COLUMN IF NOT EXISTS questionnaire_grade TEXT,
ADD COLUMN IF NOT EXISTS astrological_grade TEXT;

-- Add indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_matches_overall_score ON public.matches(overall_score);
CREATE INDEX IF NOT EXISTS idx_matches_questionnaire_grade ON public.matches(questionnaire_grade);
CREATE INDEX IF NOT EXISTS idx_matches_astrological_grade ON public.matches(astrological_grade);

-- Add comments for documentation
COMMENT ON COLUMN public.matches.calculation_result IS 'JSON object containing detailed compatibility calculation results';
COMMENT ON COLUMN public.matches.overall_score IS 'Overall compatibility score as integer (0-100)';
COMMENT ON COLUMN public.matches.questionnaire_grade IS 'Letter grade (A-F) for questionnaire-based compatibility';
COMMENT ON COLUMN public.matches.astrological_grade IS 'Letter grade (A-F) for astrological compatibility';