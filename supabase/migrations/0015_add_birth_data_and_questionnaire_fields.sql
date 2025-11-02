-- Add birth data and questionnaire fields to support complete onboarding flow

-- Add birth data fields to users table
ALTER TABLE users ADD COLUMN IF NOT EXISTS birth_date TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS birth_location TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS birth_time TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS questionnaire_responses JSONB;

-- Add comments for documentation
COMMENT ON COLUMN users.birth_date IS 'User birth date in format "Month Day, Year"';
COMMENT ON COLUMN users.birth_location IS 'User birth city/location';
COMMENT ON COLUMN users.birth_time IS 'User birth time (e.g., "2:30 PM")';
COMMENT ON COLUMN users.questionnaire_responses IS 'Array of questionnaire responses with questions and answers';