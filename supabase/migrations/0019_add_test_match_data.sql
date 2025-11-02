-- Add test match data with compatibility information
-- Migration: 0019_add_test_match_data.sql

-- Note: This migration is commented out to avoid UUID conflicts
-- Uncomment and update with real UUIDs when needed for testing

/*
  '{
    "overallScore": 85,
    "AstrologicalGrade": "A",
    "QuestionnaireGrade": "B",
    "IsMatchRecommended": true,
    "MeetsScoreThreshold": true,
    "EligibleByPreferences": true,
    "astrologicalScore": 92,
    "questionnaireScore": 78,
    "compatibilityBreakdown": {
      "personalityMatch": 80,
      "lifestyleMatch": 75,
      "valuesAlignment": 85
    }
  }',
  85,
  'B',
  'A',
  NOW(),
  NOW()
),
(
  gen_random_uuid(),
  'mock-user-1',
  'mock-user-3',
  'pending', 
  '{
    "overallScore": 72,
    "AstrologicalGrade": "B",
    "QuestionnaireGrade": "C",
    "IsMatchRecommended": true,
    "MeetsScoreThreshold": true,
    "EligibleByPreferences": true,
    "astrologicalScore": 78,
    "questionnaireScore": 66,
    "compatibilityBreakdown": {
      "personalityMatch": 70,
      "lifestyleMatch": 68,
      "valuesAlignment": 76
    }
  }',
  72,
  'C',
  'B',
  NOW(),
  NOW()
),
(
  gen_random_uuid(),
  'mock-user-2',
  'mock-user-3',
  'pending',
  '{
    "overallScore": 91,
    "AstrologicalGrade": "A",
    "QuestionnaireGrade": "A",
    "IsMatchRecommended": true,
    "MeetsScoreThreshold": true,
    "EligibleByPreferences": true,
    "astrologicalScore": 94,
    "questionnaireScore": 88,
    "compatibilityBreakdown": {
      "personalityMatch": 90,
      "lifestyleMatch": 87,
      "valuesAlignment": 95
    }
  }',
  91,
  'A',
  'A',
  NOW(),
  NOW()
);

-- Add some test data for the current user (if they exist in profiles)
-- This will only insert if a profile with this ID actually exists
INSERT INTO public.matches (
  id,
  user1_id,
  user2_id,
  status,
  calculation_result,
  overall_score,
  questionnaire_grade,
  astrological_grade,
  created_at,
  updated_at
)
SELECT 
  gen_random_uuid(),
  '34675c00-bb6b-42be-8a45-af3827aa9925', -- The user ID from the logs
  'mock-user-1',
  'pending',
  '{
    "overallScore": 87,
    "AstrologicalGrade": "A", 
    "QuestionnaireGrade": "B",
    "IsMatchRecommended": true,
    "MeetsScoreThreshold": true,
    "EligibleByPreferences": true,
    "astrologicalScore": 93,
    "questionnaireScore": 81,
    "compatibilityBreakdown": {
      "personalityMatch": 85,
      "lifestyleMatch": 82,
      "valuesAlignment": 90
    }
  }',
  87,
  'B',
  'A',
  NOW(),
  NOW()
WHERE EXISTS (
  SELECT 1 FROM public.profiles WHERE id = '34675c00-bb6b-42be-8a45-af3827aa9925'
);

*/

-- Add indexes for better performance on user lookups
CREATE INDEX IF NOT EXISTS idx_matches_user1_user2 ON public.matches(user1_id, user2_id);
CREATE INDEX IF NOT EXISTS idx_matches_user2_user1 ON public.matches(user2_id, user1_id);