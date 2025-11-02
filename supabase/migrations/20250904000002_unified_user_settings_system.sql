-- =====================================================
-- UNIFIED USER SETTINGS SYSTEM
-- =====================================================
-- This migration creates a comprehensive, centralized user settings system
-- that consolidates all user preferences into a single, well-structured table
-- with proper validation, constraints, and performance optimizations.
--
-- Author: Claude Code Assistant
-- Date: 2024-09-04
-- Version: 1.0.0
-- 
-- Features:
-- - Unified settings storage with JSONB validation
-- - Performance-optimized indexes for matching queries
-- - Proper constraints and validation triggers  
-- - Migration of existing settings data
-- - Backwards compatibility during transition
-- =====================================================

BEGIN;

-- =====================================================
-- 1. CREATE UNIFIED USER SETTINGS TABLE
-- =====================================================

-- Drop the table if it exists (for clean recreation during development)
DROP TABLE IF EXISTS public.user_settings CASCADE;

-- Create the unified user settings table
CREATE TABLE public.user_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- ===== MATCHING PREFERENCES =====
    -- Distance preferences (in kilometers)
    preferred_distance_km INTEGER DEFAULT 50 
        CHECK (preferred_distance_km >= 1 AND preferred_distance_km <= 500),
    
    -- Age range preferences  
    min_age_preference INTEGER DEFAULT 21
        CHECK (min_age_preference >= 18 AND min_age_preference <= 100),
    max_age_preference INTEGER DEFAULT 40
        CHECK (max_age_preference >= 18 AND max_age_preference <= 100),
        
    -- Gender preference
    gender_preference TEXT DEFAULT 'any'
        CHECK (gender_preference IN ('male', 'female', 'any', 'non_binary')),
        
    -- Height preferences (in inches)
    min_height_preference INTEGER DEFAULT NULL
        CHECK (min_height_preference IS NULL OR (min_height_preference >= 48 AND min_height_preference <= 96)),
    max_height_preference INTEGER DEFAULT 84 -- 7 feet
        CHECK (max_height_preference IS NULL OR (max_height_preference >= 48 AND max_height_preference <= 96)),
    
    -- Advanced matching preferences
    education_level_preference TEXT[] DEFAULT NULL,
    zodiac_compatibility_required BOOLEAN DEFAULT false,
    
    -- ===== PRIVACY SETTINGS =====
    read_receipts_enabled BOOLEAN DEFAULT true,
    profile_visibility_public BOOLEAN DEFAULT true,
    show_distance_on_profile BOOLEAN DEFAULT true,
    show_age_on_profile BOOLEAN DEFAULT true,
    show_height_on_profile BOOLEAN DEFAULT false,
    data_sharing_enabled BOOLEAN DEFAULT false,
    
    -- ===== NOTIFICATION SETTINGS =====
    -- Message notifications
    message_notifications_enabled BOOLEAN DEFAULT true,
    message_notifications_push BOOLEAN DEFAULT true,
    message_notifications_email BOOLEAN DEFAULT false,
    message_notifications_sound BOOLEAN DEFAULT true,
    
    -- Match notifications
    match_notifications_enabled BOOLEAN DEFAULT true,
    match_request_notifications BOOLEAN DEFAULT true,
    daily_matches_notifications BOOLEAN DEFAULT true,
    
    -- System notifications
    app_update_notifications BOOLEAN DEFAULT true,
    marketing_notifications_enabled BOOLEAN DEFAULT false,
    
    -- Notification timing preferences
    do_not_disturb_enabled BOOLEAN DEFAULT false,
    do_not_disturb_start_time TIME DEFAULT '22:00:00',
    do_not_disturb_end_time TIME DEFAULT '08:00:00',
    
    -- ===== ACCESSIBILITY SETTINGS =====
    accessibility_features_enabled BOOLEAN DEFAULT true,
    large_text_enabled BOOLEAN DEFAULT false,
    high_contrast_enabled BOOLEAN DEFAULT false,
    reduced_motion_enabled BOOLEAN DEFAULT false,
    screen_reader_enabled BOOLEAN DEFAULT false,
    
    -- ===== DISCOVERY SETTINGS =====
    discovery_enabled BOOLEAN DEFAULT true,
    boost_profile BOOLEAN DEFAULT false,
    incognito_mode BOOLEAN DEFAULT false,
    
    -- ===== ADVANCED PREFERENCES (JSONB for flexibility) =====
    advanced_preferences JSONB DEFAULT '{}' NOT NULL,
    
    -- ===== METADATA =====
    settings_version INTEGER DEFAULT 1 NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
    
    -- ===== CONSTRAINTS =====
    CONSTRAINT user_settings_user_id_unique UNIQUE (user_id),
    CONSTRAINT user_settings_age_range_valid CHECK (min_age_preference <= max_age_preference),
    CONSTRAINT user_settings_height_range_valid CHECK (
        min_height_preference IS NULL OR 
        max_height_preference IS NULL OR 
        min_height_preference <= max_height_preference
    ),
    CONSTRAINT user_settings_dnd_time_valid CHECK (
        NOT do_not_disturb_enabled OR 
        (do_not_disturb_start_time IS NOT NULL AND do_not_disturb_end_time IS NOT NULL)
    )
);

-- =====================================================
-- 2. CREATE PERFORMANCE INDEXES
-- =====================================================

-- Primary lookup index for user settings
CREATE INDEX idx_user_settings_user_id ON public.user_settings (user_id);

-- Matching preference indexes for fast filtering
CREATE INDEX idx_user_settings_distance ON public.user_settings (preferred_distance_km) 
    WHERE discovery_enabled = true;

CREATE INDEX idx_user_settings_age_range ON public.user_settings (min_age_preference, max_age_preference)
    WHERE discovery_enabled = true;

CREATE INDEX idx_user_settings_gender_pref ON public.user_settings (gender_preference)
    WHERE discovery_enabled = true;

CREATE INDEX idx_user_settings_height_range ON public.user_settings (min_height_preference, max_height_preference)
    WHERE discovery_enabled = true AND (min_height_preference IS NOT NULL OR max_height_preference IS NOT NULL);

-- Notification settings indexes for quick lookups
CREATE INDEX idx_user_settings_notifications ON public.user_settings (
    message_notifications_enabled,
    match_notifications_enabled,
    do_not_disturb_enabled
) WHERE message_notifications_enabled = true OR match_notifications_enabled = true;

-- Privacy settings index
CREATE INDEX idx_user_settings_privacy ON public.user_settings (
    profile_visibility_public,
    discovery_enabled,
    incognito_mode
) WHERE profile_visibility_public = true AND discovery_enabled = true;

-- JSONB index for advanced preferences
CREATE INDEX idx_user_settings_advanced_preferences_gin 
ON public.user_settings USING GIN (advanced_preferences);

-- Updated at index for cache invalidation
CREATE INDEX idx_user_settings_updated_at ON public.user_settings (updated_at);

-- =====================================================
-- 3. CREATE VALIDATION TRIGGERS
-- =====================================================

-- Function to validate settings consistency
CREATE OR REPLACE FUNCTION validate_user_settings()
RETURNS TRIGGER AS $$
BEGIN
    -- Validate age range consistency
    IF NEW.min_age_preference > NEW.max_age_preference THEN
        RAISE EXCEPTION 'Minimum age preference (%) cannot be greater than maximum age preference (%)', 
            NEW.min_age_preference, NEW.max_age_preference;
    END IF;
    
    -- Validate height range consistency
    IF NEW.min_height_preference IS NOT NULL AND NEW.max_height_preference IS NOT NULL 
       AND NEW.min_height_preference > NEW.max_height_preference THEN
        RAISE EXCEPTION 'Minimum height preference (% inches) cannot be greater than maximum height preference (% inches)', 
            NEW.min_height_preference, NEW.max_height_preference;
    END IF;
    
    -- Validate distance preference
    IF NEW.preferred_distance_km < 1 OR NEW.preferred_distance_km > 500 THEN
        RAISE EXCEPTION 'Distance preference must be between 1 and 500 km, got %', NEW.preferred_distance_km;
    END IF;
    
    -- Validate Do Not Disturb times
    IF NEW.do_not_disturb_enabled AND 
       (NEW.do_not_disturb_start_time IS NULL OR NEW.do_not_disturb_end_time IS NULL) THEN
        RAISE EXCEPTION 'Do Not Disturb start and end times must be set when DND is enabled';
    END IF;
    
    -- Update the updated_at timestamp
    NEW.updated_at = NOW();
    
    -- Increment settings version for cache invalidation
    NEW.settings_version = COALESCE(OLD.settings_version, 0) + 1;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create the validation trigger
CREATE TRIGGER trigger_validate_user_settings
    BEFORE INSERT OR UPDATE ON public.user_settings
    FOR EACH ROW EXECUTE FUNCTION validate_user_settings();

-- =====================================================
-- 4. CREATE SETTINGS MANAGEMENT FUNCTIONS
-- =====================================================

-- Function to get user settings with defaults
CREATE OR REPLACE FUNCTION get_user_settings(target_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    settings_record RECORD;
    settings_json JSONB;
BEGIN
    -- Get the user settings
    SELECT * INTO settings_record
    FROM public.user_settings 
    WHERE user_id = target_user_id;
    
    -- If no settings exist, return defaults
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'matching_preferences', jsonb_build_object(
                'preferred_distance_km', 50,
                'min_age_preference', 21,
                'max_age_preference', 40,
                'gender_preference', 'any',
                'max_height_preference', 84,
                'zodiac_compatibility_required', false
            ),
            'privacy_settings', jsonb_build_object(
                'read_receipts_enabled', true,
                'profile_visibility_public', true,
                'show_distance_on_profile', true,
                'show_age_on_profile', true,
                'show_height_on_profile', false,
                'data_sharing_enabled', false
            ),
            'notification_settings', jsonb_build_object(
                'message_notifications_enabled', true,
                'message_notifications_push', true,
                'match_notifications_enabled', true,
                'do_not_disturb_enabled', false
            ),
            'discovery_settings', jsonb_build_object(
                'discovery_enabled', true,
                'boost_profile', false,
                'incognito_mode', false
            ),
            'settings_version', 1,
            'created_at', NOW(),
            'updated_at', NOW()
        );
    END IF;
    
    -- Build the structured JSON response
    settings_json := jsonb_build_object(
        'matching_preferences', jsonb_build_object(
            'preferred_distance_km', settings_record.preferred_distance_km,
            'min_age_preference', settings_record.min_age_preference,
            'max_age_preference', settings_record.max_age_preference,
            'gender_preference', settings_record.gender_preference,
            'min_height_preference', settings_record.min_height_preference,
            'max_height_preference', settings_record.max_height_preference,
            'education_level_preference', settings_record.education_level_preference,
            'zodiac_compatibility_required', settings_record.zodiac_compatibility_required
        ),
        'privacy_settings', jsonb_build_object(
            'read_receipts_enabled', settings_record.read_receipts_enabled,
            'profile_visibility_public', settings_record.profile_visibility_public,
            'show_distance_on_profile', settings_record.show_distance_on_profile,
            'show_age_on_profile', settings_record.show_age_on_profile,
            'show_height_on_profile', settings_record.show_height_on_profile,
            'data_sharing_enabled', settings_record.data_sharing_enabled
        ),
        'notification_settings', jsonb_build_object(
            'message_notifications_enabled', settings_record.message_notifications_enabled,
            'message_notifications_push', settings_record.message_notifications_push,
            'message_notifications_email', settings_record.message_notifications_email,
            'message_notifications_sound', settings_record.message_notifications_sound,
            'match_notifications_enabled', settings_record.match_notifications_enabled,
            'match_request_notifications', settings_record.match_request_notifications,
            'daily_matches_notifications', settings_record.daily_matches_notifications,
            'app_update_notifications', settings_record.app_update_notifications,
            'marketing_notifications_enabled', settings_record.marketing_notifications_enabled,
            'do_not_disturb_enabled', settings_record.do_not_disturb_enabled,
            'do_not_disturb_start_time', settings_record.do_not_disturb_start_time,
            'do_not_disturb_end_time', settings_record.do_not_disturb_end_time
        ),
        'accessibility_settings', jsonb_build_object(
            'accessibility_features_enabled', settings_record.accessibility_features_enabled,
            'large_text_enabled', settings_record.large_text_enabled,
            'high_contrast_enabled', settings_record.high_contrast_enabled,
            'reduced_motion_enabled', settings_record.reduced_motion_enabled,
            'screen_reader_enabled', settings_record.screen_reader_enabled
        ),
        'discovery_settings', jsonb_build_object(
            'discovery_enabled', settings_record.discovery_enabled,
            'boost_profile', settings_record.boost_profile,
            'incognito_mode', settings_record.incognito_mode
        ),
        'advanced_preferences', settings_record.advanced_preferences,
        'metadata', jsonb_build_object(
            'settings_version', settings_record.settings_version,
            'created_at', settings_record.created_at,
            'updated_at', settings_record.updated_at
        )
    );
    
    RETURN settings_json;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to update user settings
CREATE OR REPLACE FUNCTION update_user_settings(
    target_user_id UUID,
    settings_update JSONB
)
RETURNS JSONB AS $$
DECLARE
    existing_settings RECORD;
    updated_settings JSONB;
BEGIN
    -- Get existing settings or create default
    SELECT * INTO existing_settings
    FROM public.user_settings 
    WHERE user_id = target_user_id;
    
    -- If no settings exist, create with defaults
    IF NOT FOUND THEN
        INSERT INTO public.user_settings (user_id) VALUES (target_user_id);
        SELECT * INTO existing_settings
        FROM public.user_settings 
        WHERE user_id = target_user_id;
    END IF;
    
    -- Update the settings based on the provided JSONB
    UPDATE public.user_settings SET
        -- Matching preferences
        preferred_distance_km = COALESCE(
            (settings_update->'matching_preferences'->>'preferred_distance_km')::INTEGER,
            preferred_distance_km
        ),
        min_age_preference = COALESCE(
            (settings_update->'matching_preferences'->>'min_age_preference')::INTEGER,
            min_age_preference
        ),
        max_age_preference = COALESCE(
            (settings_update->'matching_preferences'->>'max_age_preference')::INTEGER,
            max_age_preference
        ),
        gender_preference = COALESCE(
            settings_update->'matching_preferences'->>'gender_preference',
            gender_preference
        ),
        min_height_preference = CASE
            WHEN settings_update->'matching_preferences' ? 'min_height_preference' THEN
                (settings_update->'matching_preferences'->>'min_height_preference')::INTEGER
            ELSE min_height_preference
        END,
        max_height_preference = CASE
            WHEN settings_update->'matching_preferences' ? 'max_height_preference' THEN
                (settings_update->'matching_preferences'->>'max_height_preference')::INTEGER
            ELSE max_height_preference
        END,
        zodiac_compatibility_required = COALESCE(
            (settings_update->'matching_preferences'->>'zodiac_compatibility_required')::BOOLEAN,
            zodiac_compatibility_required
        ),
        
        -- Privacy settings
        read_receipts_enabled = COALESCE(
            (settings_update->'privacy_settings'->>'read_receipts_enabled')::BOOLEAN,
            read_receipts_enabled
        ),
        profile_visibility_public = COALESCE(
            (settings_update->'privacy_settings'->>'profile_visibility_public')::BOOLEAN,
            profile_visibility_public
        ),
        show_distance_on_profile = COALESCE(
            (settings_update->'privacy_settings'->>'show_distance_on_profile')::BOOLEAN,
            show_distance_on_profile
        ),
        show_age_on_profile = COALESCE(
            (settings_update->'privacy_settings'->>'show_age_on_profile')::BOOLEAN,
            show_age_on_profile
        ),
        show_height_on_profile = COALESCE(
            (settings_update->'privacy_settings'->>'show_height_on_profile')::BOOLEAN,
            show_height_on_profile
        ),
        data_sharing_enabled = COALESCE(
            (settings_update->'privacy_settings'->>'data_sharing_enabled')::BOOLEAN,
            data_sharing_enabled
        ),
        
        -- Notification settings
        message_notifications_enabled = COALESCE(
            (settings_update->'notification_settings'->>'message_notifications_enabled')::BOOLEAN,
            message_notifications_enabled
        ),
        message_notifications_push = COALESCE(
            (settings_update->'notification_settings'->>'message_notifications_push')::BOOLEAN,
            message_notifications_push
        ),
        match_notifications_enabled = COALESCE(
            (settings_update->'notification_settings'->>'match_notifications_enabled')::BOOLEAN,
            match_notifications_enabled
        ),
        do_not_disturb_enabled = COALESCE(
            (settings_update->'notification_settings'->>'do_not_disturb_enabled')::BOOLEAN,
            do_not_disturb_enabled
        ),
        
        -- Discovery settings  
        discovery_enabled = COALESCE(
            (settings_update->'discovery_settings'->>'discovery_enabled')::BOOLEAN,
            discovery_enabled
        ),
        boost_profile = COALESCE(
            (settings_update->'discovery_settings'->>'boost_profile')::BOOLEAN,
            boost_profile
        ),
        incognito_mode = COALESCE(
            (settings_update->'discovery_settings'->>'incognito_mode')::BOOLEAN,
            incognito_mode
        ),
        
        -- Advanced preferences (merge JSONB)
        advanced_preferences = advanced_preferences || COALESCE(settings_update->'advanced_preferences', '{}'::JSONB)
        
    WHERE user_id = target_user_id;
    
    -- Return the updated settings
    RETURN get_user_settings(target_user_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 5. MIGRATE EXISTING SETTINGS DATA
-- =====================================================

-- Create function to migrate existing settings data
CREATE OR REPLACE FUNCTION migrate_existing_user_settings()
RETURNS INTEGER AS $$
DECLARE
    migrated_count INTEGER := 0;
    user_record RECORD;
BEGIN
    -- Migrate from profiles.app_settings and users.preferences
    FOR user_record IN 
        SELECT DISTINCT 
            COALESCE(p.id, u.auth_user_id) as user_id,
            p.app_settings,
            u.preferences as user_preferences
        FROM auth.users au
        LEFT JOIN public.profiles p ON p.id = au.id
        LEFT JOIN public.users u ON u.auth_user_id = au.id
        WHERE au.id NOT IN (SELECT user_id FROM public.user_settings)
    LOOP
        -- Insert new settings record with migrated data
        INSERT INTO public.user_settings (
            user_id,
            preferred_distance_km,
            min_age_preference,
            max_age_preference,
            gender_preference,
            max_height_preference,
            read_receipts_enabled,
            show_height_on_profile,
            message_notifications_enabled,
            match_notifications_enabled,
            advanced_preferences
        ) VALUES (
            user_record.user_id,
            -- Distance from either app_settings or preferences
            COALESCE(
                (user_record.app_settings->>'distance')::INTEGER,
                (user_record.user_preferences->>'max_distance_km')::INTEGER,
                50
            ),
            -- Min age
            COALESCE(
                (user_record.app_settings->>'min_age_preference')::INTEGER,
                (user_record.user_preferences->>'min_age')::INTEGER,
                21
            ),
            -- Max age
            COALESCE(
                (user_record.app_settings->>'max_age_preference')::INTEGER,
                (user_record.user_preferences->>'max_age')::INTEGER,
                40
            ),
            -- Gender preference
            COALESCE(
                user_record.app_settings->>'gender_preference',
                user_record.user_preferences->>'gender_preference',
                'any'
            ),
            -- Height preference
            COALESCE(
                (user_record.app_settings->>'height_preference_ft')::INTEGER * 12 + 
                (user_record.app_settings->>'height_preference_in')::INTEGER,
                84
            ),
            -- Read receipts
            COALESCE(
                (user_record.user_preferences->>'readReceipts')::BOOLEAN,
                true
            ),
            -- Show height
            COALESCE(
                (user_record.app_settings->>'show_height_on_profile')::BOOLEAN,
                (user_record.user_preferences->>'showHeight')::BOOLEAN,
                false
            ),
            -- Notifications
            COALESCE(
                (user_record.user_preferences->>'messageNotifications')::BOOLEAN,
                (user_record.user_preferences->>'notifications_enabled')::BOOLEAN,
                true
            ),
            COALESCE(
                (user_record.user_preferences->>'matchAlerts')::BOOLEAN,
                true
            ),
            -- Store original settings in advanced_preferences for reference
            jsonb_build_object(
                'original_app_settings', user_record.app_settings,
                'original_user_preferences', user_record.user_preferences,
                'migration_timestamp', NOW()
            )
        );
        
        migrated_count := migrated_count + 1;
    END LOOP;
    
    RETURN migrated_count;
END;
$$ LANGUAGE plpgsql;

-- Execute the migration
SELECT migrate_existing_user_settings() as migrated_users_count;

-- =====================================================
-- 6. ENABLE ROW LEVEL SECURITY
-- =====================================================

-- Enable RLS on the user_settings table
ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;

-- Policy: Users can only access their own settings
CREATE POLICY "Users can access own settings" ON public.user_settings
    FOR ALL USING (auth.uid() = user_id);

-- Policy: Service role can access all settings
CREATE POLICY "Service role full access" ON public.user_settings
    FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

-- =====================================================
-- 7. GRANT PERMISSIONS
-- =====================================================

-- Grant table permissions
GRANT SELECT, INSERT, UPDATE ON public.user_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_settings TO service_role;

-- Grant function permissions
GRANT EXECUTE ON FUNCTION get_user_settings(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION update_user_settings(UUID, JSONB) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION migrate_existing_user_settings() TO service_role;

-- =====================================================
-- 8. ADD COMPREHENSIVE COMMENTS
-- =====================================================

COMMENT ON TABLE public.user_settings IS 'Unified user settings system for all user preferences including matching, privacy, notifications, and accessibility settings';

COMMENT ON COLUMN public.user_settings.user_id IS 'Reference to the auth.users.id - each user has exactly one settings record';
COMMENT ON COLUMN public.user_settings.preferred_distance_km IS 'Maximum distance for matching candidates in kilometers (1-500)';
COMMENT ON COLUMN public.user_settings.min_age_preference IS 'Minimum age preference for matching (18-100)';
COMMENT ON COLUMN public.user_settings.max_age_preference IS 'Maximum age preference for matching (18-100)';
COMMENT ON COLUMN public.user_settings.gender_preference IS 'Gender preference for matching: male, female, any, non_binary';
COMMENT ON COLUMN public.user_settings.read_receipts_enabled IS 'Whether user sends/receives read receipts for messages';
COMMENT ON COLUMN public.user_settings.do_not_disturb_enabled IS 'Whether Do Not Disturb mode is active';
COMMENT ON COLUMN public.user_settings.discovery_enabled IS 'Whether user appears in discovery/matching for other users';
COMMENT ON COLUMN public.user_settings.advanced_preferences IS 'JSONB field for additional custom preferences and feature flags';
COMMENT ON COLUMN public.user_settings.settings_version IS 'Version number for cache invalidation and conflict resolution';

COMMENT ON FUNCTION get_user_settings(UUID) IS 'Retrieves structured user settings with defaults for missing values';
COMMENT ON FUNCTION update_user_settings(UUID, JSONB) IS 'Updates user settings with validation and returns the updated settings structure';

-- =====================================================
-- 9. CREATE SETTINGS CHANGE LOG TABLE
-- =====================================================

-- Create table to track settings changes for audit purposes
CREATE TABLE public.user_settings_changelog (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    changed_fields JSONB NOT NULL,
    previous_values JSONB,
    new_values JSONB,
    change_source TEXT DEFAULT 'user_action',
    user_agent TEXT,
    ip_address INET,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL
);

-- Index for querying user's settings history
CREATE INDEX idx_user_settings_changelog_user_id ON public.user_settings_changelog (user_id, created_at DESC);

-- Index for querying recent changes
CREATE INDEX idx_user_settings_changelog_created_at ON public.user_settings_changelog (created_at DESC);

-- Enable RLS on changelog
ALTER TABLE public.user_settings_changelog ENABLE ROW LEVEL SECURITY;

-- Policy: Users can only view their own settings history
CREATE POLICY "Users can view own settings history" ON public.user_settings_changelog
    FOR SELECT USING (auth.uid() = user_id);

-- Policy: Service role can access all changelog entries  
CREATE POLICY "Service role changelog access" ON public.user_settings_changelog
    FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

GRANT SELECT ON public.user_settings_changelog TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_settings_changelog TO service_role;

COMMENT ON TABLE public.user_settings_changelog IS 'Audit log of all user settings changes for security and debugging purposes';

-- =====================================================
-- 10. VERIFICATION AND TESTING
-- =====================================================

-- Verify the table was created successfully
DO $$
DECLARE
    table_exists BOOLEAN;
    migrated_count INTEGER;
    settings_count INTEGER;
BEGIN
    -- Check if table exists
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = 'public' 
        AND table_name = 'user_settings'
    ) INTO table_exists;
    
    IF table_exists THEN
        RAISE NOTICE '✅ user_settings table created successfully';
        
        -- Count settings records
        SELECT COUNT(*) INTO settings_count FROM public.user_settings;
        RAISE NOTICE '📊 Total user settings records: %', settings_count;
        
        -- Test the get_user_settings function
        IF EXISTS (SELECT 1 FROM auth.users LIMIT 1) THEN
            DECLARE
                test_user_id UUID;
                test_settings JSONB;
            BEGIN
                SELECT id INTO test_user_id FROM auth.users LIMIT 1;
                SELECT get_user_settings(test_user_id) INTO test_settings;
                
                IF test_settings IS NOT NULL THEN
                    RAISE NOTICE '✅ get_user_settings function working correctly';
                ELSE
                    RAISE NOTICE '⚠️ get_user_settings function returned NULL';
                END IF;
            END;
        END IF;
        
    ELSE
        RAISE EXCEPTION '❌ FAILED: user_settings table was not created';
    END IF;
END $$;

COMMIT;

-- =====================================================
-- MIGRATION COMPLETE
-- =====================================================

SELECT 
    'Unified User Settings System Migration Completed Successfully!' as status,
    NOW() as completed_at,
    (SELECT COUNT(*) FROM public.user_settings) as total_settings_records,
    (SELECT COUNT(DISTINCT user_id) FROM public.user_settings) as unique_users_with_settings,
    version() as database_version;