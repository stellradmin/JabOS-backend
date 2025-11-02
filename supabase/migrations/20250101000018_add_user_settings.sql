-- Add user settings column for notification preferences and other user-specific settings
-- This migration adds a JSONB column to store flexible user settings

ALTER TABLE users
ADD COLUMN IF NOT EXISTS settings JSONB DEFAULT '{
  "notifications": {
    "email_notifications": true,
    "class_reminders": true,
    "sparring_requests": true,
    "announcements": true,
    "messages": true
  }
}'::jsonb;

-- Add index for efficient JSONB querying
CREATE INDEX IF NOT EXISTS users_settings_idx ON users USING gin(settings);

-- Add comment explaining the settings structure
COMMENT ON COLUMN users.settings IS 'User settings stored as JSONB. Structure: {
  "notifications": {
    "email_notifications": boolean,
    "class_reminders": boolean,
    "sparring_requests": boolean,
    "announcements": boolean,
    "messages": boolean
  }
}';
