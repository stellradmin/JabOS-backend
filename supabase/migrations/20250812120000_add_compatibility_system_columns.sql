-- Compatibility System Migration - Add missing columns
-- This migration adds missing columns for enhanced compatibility system
-- Safe to run - includes proper constraints and IF NOT EXISTS clauses

-- Add missing columns for comprehensive natal chart data storage to users table
ALTER TABLE users ADD COLUMN IF NOT EXISTS sun_sign TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS moon_sign TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS rising_sign TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS birth_lat DECIMAL(10,8);
ALTER TABLE users ADD COLUMN IF NOT EXISTS birth_lng DECIMAL(11,8);
ALTER TABLE users ADD COLUMN IF NOT EXISTS birth_city TEXT;

-- Add compatibility scoring columns to matches table
ALTER TABLE matches ADD COLUMN IF NOT EXISTS astrological_score DECIMAL(5,2);
ALTER TABLE matches ADD COLUMN IF NOT EXISTS questionnaire_score DECIMAL(5,2);
ALTER TABLE matches ADD COLUMN IF NOT EXISTS combined_score DECIMAL(5,2);
ALTER TABLE matches ADD COLUMN IF NOT EXISTS meets_threshold BOOLEAN DEFAULT FALSE;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS priority_score DECIMAL(5,2);
ALTER TABLE matches ADD COLUMN IF NOT EXISTS is_recommended BOOLEAN DEFAULT FALSE;

-- Add constraints for data quality
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'valid_birth_coordinates') THEN
    ALTER TABLE users ADD CONSTRAINT valid_birth_coordinates
      CHECK (birth_lat IS NULL OR (birth_lat BETWEEN -90 AND 90));
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'valid_birth_lng') THEN
    ALTER TABLE users ADD CONSTRAINT valid_birth_lng
      CHECK (birth_lng IS NULL OR (birth_lng BETWEEN -180 AND 180));
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'valid_zodiac_signs') THEN
    ALTER TABLE users ADD CONSTRAINT valid_zodiac_signs
      CHECK (sun_sign IS NULL OR sun_sign IN ('Aries', 'Taurus', 'Gemini', 'Cancer', 'Leo', 'Virgo',
                         'Libra', 'Scorpio', 'Sagittarius', 'Capricorn', 'Aquarius', 'Pisces'));
  END IF;
END $$;

-- Add constraints for compatibility scores
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'valid_astrological_score') THEN
    ALTER TABLE matches ADD CONSTRAINT valid_astrological_score
      CHECK (astrological_score IS NULL OR (astrological_score >= 0 AND astrological_score <= 100));
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'valid_questionnaire_score') THEN
    ALTER TABLE matches ADD CONSTRAINT valid_questionnaire_score
      CHECK (questionnaire_score IS NULL OR (questionnaire_score >= 0 AND questionnaire_score <= 100));
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'valid_combined_score') THEN
    ALTER TABLE matches ADD CONSTRAINT valid_combined_score
      CHECK (combined_score IS NULL OR (combined_score >= 0 AND combined_score <= 100));
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'valid_priority_score') THEN
    ALTER TABLE matches ADD CONSTRAINT valid_priority_score
      CHECK (priority_score IS NULL OR (priority_score >= 0 AND priority_score <= 100));
  END IF;
END $$;

-- Add indexes for compatibility queries
CREATE INDEX IF NOT EXISTS idx_users_natal_signs ON users(sun_sign, moon_sign, rising_sign);
CREATE INDEX IF NOT EXISTS idx_users_birth_coordinates ON users(birth_lat, birth_lng);
CREATE INDEX IF NOT EXISTS idx_users_birth_city ON users(birth_city) WHERE birth_city IS NOT NULL;

-- Add indexes for matches table
CREATE INDEX IF NOT EXISTS idx_matches_compatibility_scores ON matches(astrological_score, questionnaire_score, combined_score);
CREATE INDEX IF NOT EXISTS idx_matches_recommended ON matches(is_recommended, meets_threshold) WHERE is_recommended = true;
CREATE INDEX IF NOT EXISTS idx_matches_priority_score ON matches(priority_score DESC) WHERE meets_threshold = true;

-- Performance indexes for compatibility matching
CREATE INDEX IF NOT EXISTS idx_users_complete_birth_data ON users(birth_date, birth_lat, birth_lng) WHERE birth_date IS NOT NULL AND birth_lat IS NOT NULL AND birth_lng IS NOT NULL;