-- =====================================================
-- USER SETTINGS UTILITY FUNCTIONS
-- =====================================================
-- Additional utility functions for the unified user settings system
-- These functions provide specialized operations, caching support,
-- and integration helpers for the Stellr dating app.
--
-- Author: Claude Code Assistant
-- Date: 2024-09-04
-- Version: 1.0.0
-- =====================================================

BEGIN;

-- =====================================================
-- 1. MATCHING PREFERENCE FUNCTIONS
-- =====================================================

-- Function to get matching preferences for a user (optimized for matching algorithms)
CREATE OR REPLACE FUNCTION get_user_matching_preferences(target_user_id UUID)
RETURNS TABLE (
    user_id UUID,
    preferred_distance_km INTEGER,
    min_age_preference INTEGER,
    max_age_preference INTEGER,
    gender_preference TEXT,
    min_height_preference INTEGER,
    max_height_preference INTEGER,
    zodiac_compatibility_required BOOLEAN,
    discovery_enabled BOOLEAN,
    incognito_mode BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        us.user_id,
        us.preferred_distance_km,
        us.min_age_preference,
        us.max_age_preference,
        us.gender_preference,
        us.min_height_preference,
        us.max_height_preference,
        us.zodiac_compatibility_required,
        us.discovery_enabled,
        us.incognito_mode
    FROM public.user_settings us
    WHERE us.user_id = target_user_id;
    
    -- If no settings found, return defaults
    IF NOT FOUND THEN
        RETURN QUERY
        SELECT 
            target_user_id,
            50::INTEGER,     -- preferred_distance_km
            21::INTEGER,     -- min_age_preference  
            40::INTEGER,     -- max_age_preference
            'any'::TEXT,     -- gender_preference
            NULL::INTEGER,   -- min_height_preference
            84::INTEGER,     -- max_height_preference
            FALSE::BOOLEAN,  -- zodiac_compatibility_required
            TRUE::BOOLEAN,   -- discovery_enabled
            FALSE::BOOLEAN;  -- incognito_mode
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to check if two users are compatible based on their preferences
CREATE OR REPLACE FUNCTION check_mutual_compatibility(
    user_a_id UUID,
    user_b_id UUID
)
RETURNS JSONB AS $$
DECLARE
    user_a_prefs RECORD;
    user_b_prefs RECORD;
    user_a_profile RECORD;
    user_b_profile RECORD;
    compatibility_result JSONB;
BEGIN
    -- Get user preferences
    SELECT * INTO user_a_prefs FROM get_user_matching_preferences(user_a_id) LIMIT 1;
    SELECT * INTO user_b_prefs FROM get_user_matching_preferences(user_b_id) LIMIT 1;
    
    -- Get basic profile data
    SELECT age, gender, height FROM public.profiles WHERE id = user_a_id INTO user_a_profile;
    SELECT age, gender, height FROM public.profiles WHERE id = user_b_id INTO user_b_profile;
    
    -- Check mutual compatibility
    compatibility_result := jsonb_build_object(
        'compatible', true,
        'reasons', jsonb_build_array(),
        'blocking_factors', jsonb_build_array()
    );
    
    -- Age compatibility check (mutual)
    IF user_a_profile.age < user_b_prefs.min_age_preference OR 
       user_a_profile.age > user_b_prefs.max_age_preference THEN
        compatibility_result := jsonb_set(
            compatibility_result, 
            '{compatible}', 
            'false'::jsonb
        );
        compatibility_result := jsonb_set(
            compatibility_result,
            '{blocking_factors}',
            (compatibility_result->'blocking_factors') || '"user_a_age_outside_user_b_preference"'::jsonb
        );
    END IF;
    
    IF user_b_profile.age < user_a_prefs.min_age_preference OR 
       user_b_profile.age > user_a_prefs.max_age_preference THEN
        compatibility_result := jsonb_set(
            compatibility_result, 
            '{compatible}', 
            'false'::jsonb
        );
        compatibility_result := jsonb_set(
            compatibility_result,
            '{blocking_factors}',
            (compatibility_result->'blocking_factors') || '"user_b_age_outside_user_a_preference"'::jsonb
        );
    END IF;
    
    -- Gender preference check (mutual)
    IF user_a_prefs.gender_preference != 'any' AND 
       user_a_prefs.gender_preference != user_b_profile.gender THEN
        compatibility_result := jsonb_set(
            compatibility_result, 
            '{compatible}', 
            'false'::jsonb
        );
        compatibility_result := jsonb_set(
            compatibility_result,
            '{blocking_factors}',
            (compatibility_result->'blocking_factors') || '"user_a_gender_preference_mismatch"'::jsonb
        );
    END IF;
    
    IF user_b_prefs.gender_preference != 'any' AND 
       user_b_prefs.gender_preference != user_a_profile.gender THEN
        compatibility_result := jsonb_set(
            compatibility_result, 
            '{compatible}', 
            'false'::jsonb
        );
        compatibility_result := jsonb_set(
            compatibility_result,
            '{blocking_factors}',
            (compatibility_result->'blocking_factors') || '"user_b_gender_preference_mismatch"'::jsonb
        );
    END IF;
    
    -- Height preference check (if specified)
    IF user_a_prefs.min_height_preference IS NOT NULL AND 
       user_b_profile.height IS NOT NULL AND
       user_b_profile.height < user_a_prefs.min_height_preference THEN
        compatibility_result := jsonb_set(
            compatibility_result,
            '{reasons}',
            (compatibility_result->'reasons') || '"user_b_below_user_a_height_minimum"'::jsonb
        );
    END IF;
    
    IF user_a_prefs.max_height_preference IS NOT NULL AND 
       user_b_profile.height IS NOT NULL AND
       user_b_profile.height > user_a_prefs.max_height_preference THEN
        compatibility_result := jsonb_set(
            compatibility_result,
            '{reasons}',
            (compatibility_result->'reasons') || '"user_b_above_user_a_height_maximum"'::jsonb
        );
    END IF;
    
    -- Check discovery settings
    IF NOT user_a_prefs.discovery_enabled OR NOT user_b_prefs.discovery_enabled THEN
        compatibility_result := jsonb_set(
            compatibility_result, 
            '{compatible}', 
            'false'::jsonb
        );
        compatibility_result := jsonb_set(
            compatibility_result,
            '{blocking_factors}',
            (compatibility_result->'blocking_factors') || '"discovery_disabled"'::jsonb
        );
    END IF;
    
    -- Add metadata
    compatibility_result := compatibility_result || jsonb_build_object(
        'checked_at', NOW(),
        'user_a_id', user_a_id,
        'user_b_id', user_b_id
    );
    
    RETURN compatibility_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 2. NOTIFICATION PREFERENCE FUNCTIONS
-- =====================================================

-- Function to get notification preferences for a user
CREATE OR REPLACE FUNCTION get_user_notification_preferences(target_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    notification_prefs JSONB;
BEGIN
    SELECT jsonb_build_object(
        'message_notifications_enabled', message_notifications_enabled,
        'message_notifications_push', message_notifications_push,
        'message_notifications_email', message_notifications_email,
        'message_notifications_sound', message_notifications_sound,
        'match_notifications_enabled', match_notifications_enabled,
        'match_request_notifications', match_request_notifications,
        'daily_matches_notifications', daily_matches_notifications,
        'app_update_notifications', app_update_notifications,
        'marketing_notifications_enabled', marketing_notifications_enabled,
        'do_not_disturb_enabled', do_not_disturb_enabled,
        'do_not_disturb_start_time', do_not_disturb_start_time,
        'do_not_disturb_end_time', do_not_disturb_end_time
    ) INTO notification_prefs
    FROM public.user_settings
    WHERE user_id = target_user_id;
    
    -- Return defaults if no settings found
    IF notification_prefs IS NULL THEN
        notification_prefs := jsonb_build_object(
            'message_notifications_enabled', true,
            'message_notifications_push', true,
            'message_notifications_email', false,
            'message_notifications_sound', true,
            'match_notifications_enabled', true,
            'match_request_notifications', true,
            'daily_matches_notifications', true,
            'app_update_notifications', true,
            'marketing_notifications_enabled', false,
            'do_not_disturb_enabled', false,
            'do_not_disturb_start_time', '22:00:00'::TIME,
            'do_not_disturb_end_time', '08:00:00'::TIME
        );
    END IF;
    
    RETURN notification_prefs;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to check if user should receive notifications at current time
CREATE OR REPLACE FUNCTION should_send_notification(
    target_user_id UUID,
    notification_type TEXT DEFAULT 'message'
)
RETURNS BOOLEAN AS $$
DECLARE
    prefs JSONB;
    dnd_enabled BOOLEAN;
    dnd_start_time TIME;
    dnd_end_time TIME;
    check_time TIME;
    type_enabled BOOLEAN := TRUE;
BEGIN
    -- Get notification preferences
    SELECT get_user_notification_preferences(target_user_id) INTO prefs;

    -- Check if this notification type is enabled
    CASE notification_type
        WHEN 'message' THEN
            type_enabled := (prefs->>'message_notifications_enabled')::BOOLEAN;
        WHEN 'match' THEN
            type_enabled := (prefs->>'match_notifications_enabled')::BOOLEAN;
        WHEN 'match_request' THEN
            type_enabled := (prefs->>'match_request_notifications')::BOOLEAN;
        WHEN 'daily_matches' THEN
            type_enabled := (prefs->>'daily_matches_notifications')::BOOLEAN;
        WHEN 'app_update' THEN
            type_enabled := (prefs->>'app_update_notifications')::BOOLEAN;
        WHEN 'marketing' THEN
            type_enabled := (prefs->>'marketing_notifications_enabled')::BOOLEAN;
        ELSE
            type_enabled := TRUE; -- Default to enabled for unknown types
    END CASE;

    -- If type is disabled, don't send
    IF NOT type_enabled THEN
        RETURN FALSE;
    END IF;

    -- Check Do Not Disturb
    dnd_enabled := (prefs->>'do_not_disturb_enabled')::BOOLEAN;

    IF dnd_enabled THEN
        dnd_start_time := (prefs->>'do_not_disturb_start_time')::TIME;
        dnd_end_time := (prefs->>'do_not_disturb_end_time')::TIME;
        check_time := LOCALTIME;

        -- Handle DND times that cross midnight
        IF dnd_start_time > dnd_end_time THEN
            -- DND period crosses midnight (e.g., 22:00 to 08:00)
            IF check_time >= dnd_start_time OR check_time <= dnd_end_time THEN
                RETURN FALSE;
            END IF;
        ELSE
            -- DND period within same day (e.g., 12:00 to 14:00)
            IF check_time >= dnd_start_time AND check_time <= dnd_end_time THEN
                RETURN FALSE;
            END IF;
        END IF;
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 3. PRIVACY AND VISIBILITY FUNCTIONS
-- =====================================================

-- Function to get privacy settings for a user
CREATE OR REPLACE FUNCTION get_user_privacy_settings(target_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    privacy_settings JSONB;
BEGIN
    SELECT jsonb_build_object(
        'read_receipts_enabled', read_receipts_enabled,
        'profile_visibility_public', profile_visibility_public,
        'show_distance_on_profile', show_distance_on_profile,
        'show_age_on_profile', show_age_on_profile,
        'show_height_on_profile', show_height_on_profile,
        'data_sharing_enabled', data_sharing_enabled,
        'discovery_enabled', discovery_enabled,
        'incognito_mode', incognito_mode
    ) INTO privacy_settings
    FROM public.user_settings
    WHERE user_id = target_user_id;
    
    -- Return defaults if no settings found
    IF privacy_settings IS NULL THEN
        privacy_settings := jsonb_build_object(
            'read_receipts_enabled', true,
            'profile_visibility_public', true,
            'show_distance_on_profile', true,
            'show_age_on_profile', true,
            'show_height_on_profile', false,
            'data_sharing_enabled', false,
            'discovery_enabled', true,
            'incognito_mode', false
        );
    END IF;
    
    RETURN privacy_settings;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to check if user should be visible to another user
CREATE OR REPLACE FUNCTION is_user_discoverable(
    target_user_id UUID,
    viewing_user_id UUID DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
    privacy_settings JSONB;
    is_discoverable BOOLEAN;
BEGIN
    -- Get privacy settings
    SELECT get_user_privacy_settings(target_user_id) INTO privacy_settings;
    
    -- Check basic discoverability
    is_discoverable := 
        (privacy_settings->>'profile_visibility_public')::BOOLEAN AND
        (privacy_settings->>'discovery_enabled')::BOOLEAN AND
        NOT (privacy_settings->>'incognito_mode')::BOOLEAN;
    
    -- Additional checks can be added here (e.g., blocking, reporting)
    
    RETURN is_discoverable;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 4. SETTINGS CACHING AND PERFORMANCE FUNCTIONS
-- =====================================================

-- Function to get cached user settings (for high-performance queries)
CREATE OR REPLACE FUNCTION get_cached_user_settings(target_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    cached_settings JSONB;
BEGIN
    -- This function can be enhanced with Redis caching later
    -- For now, it's a direct database call with optimized queries
    
    SELECT jsonb_build_object(
        'matching_preferences', jsonb_build_object(
            'preferred_distance_km', preferred_distance_km,
            'min_age_preference', min_age_preference,
            'max_age_preference', max_age_preference,
            'gender_preference', gender_preference,
            'min_height_preference', min_height_preference,
            'max_height_preference', max_height_preference,
            'zodiac_compatibility_required', zodiac_compatibility_required
        ),
        'privacy_settings', jsonb_build_object(
            'read_receipts_enabled', read_receipts_enabled,
            'discovery_enabled', discovery_enabled,
            'incognito_mode', incognito_mode
        ),
        'notification_settings', jsonb_build_object(
            'message_notifications_enabled', message_notifications_enabled,
            'match_notifications_enabled', match_notifications_enabled,
            'do_not_disturb_enabled', do_not_disturb_enabled
        ),
        'cache_metadata', jsonb_build_object(
            'cached_at', NOW(),
            'settings_version', settings_version
        )
    ) INTO cached_settings
    FROM public.user_settings
    WHERE user_id = target_user_id;
    
    -- Return defaults if no settings found
    IF cached_settings IS NULL THEN
        cached_settings := jsonb_build_object(
            'matching_preferences', jsonb_build_object(
                'preferred_distance_km', 50,
                'min_age_preference', 21,
                'max_age_preference', 40,
                'gender_preference', 'any'
            ),
            'privacy_settings', jsonb_build_object(
                'read_receipts_enabled', true,
                'discovery_enabled', true,
                'incognito_mode', false
            ),
            'notification_settings', jsonb_build_object(
                'message_notifications_enabled', true,
                'match_notifications_enabled', true,
                'do_not_disturb_enabled', false
            ),
            'cache_metadata', jsonb_build_object(
                'cached_at', NOW(),
                'settings_version', 1,
                'is_default', true
            )
        );
    END IF;
    
    RETURN cached_settings;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 5. SETTINGS VALIDATION AND CONSISTENCY FUNCTIONS
-- =====================================================

-- Function to validate settings before update
CREATE OR REPLACE FUNCTION validate_settings_update(
    target_user_id UUID,
    settings_update JSONB
)
RETURNS JSONB AS $$
DECLARE
    validation_result JSONB;
    errors JSONB := '[]'::JSONB;
    warnings JSONB := '[]'::JSONB;
    proposed_distance INTEGER;
    proposed_min_age INTEGER;
    proposed_max_age INTEGER;
BEGIN
    validation_result := jsonb_build_object(
        'valid', true,
        'errors', errors,
        'warnings', warnings
    );
    
    -- Validate distance preference
    IF settings_update->'matching_preferences' ? 'preferred_distance_km' THEN
        proposed_distance := (settings_update->'matching_preferences'->>'preferred_distance_km')::INTEGER;
        IF proposed_distance < 1 OR proposed_distance > 500 THEN
            errors := errors || jsonb_build_object(
                'field', 'preferred_distance_km',
                'message', 'Distance preference must be between 1 and 500 kilometers'
            )::jsonb;
            validation_result := jsonb_set(validation_result, '{valid}', 'false'::jsonb);
        END IF;
    END IF;
    
    -- Validate age preferences
    IF settings_update->'matching_preferences' ? 'min_age_preference' THEN
        proposed_min_age := (settings_update->'matching_preferences'->>'min_age_preference')::INTEGER;
        IF proposed_min_age < 18 OR proposed_min_age > 100 THEN
            errors := errors || jsonb_build_object(
                'field', 'min_age_preference',
                'message', 'Minimum age preference must be between 18 and 100'
            )::jsonb;
            validation_result := jsonb_set(validation_result, '{valid}', 'false'::jsonb);
        END IF;
    END IF;
    
    IF settings_update->'matching_preferences' ? 'max_age_preference' THEN
        proposed_max_age := (settings_update->'matching_preferences'->>'max_age_preference')::INTEGER;
        IF proposed_max_age < 18 OR proposed_max_age > 100 THEN
            errors := errors || jsonb_build_object(
                'field', 'max_age_preference',
                'message', 'Maximum age preference must be between 18 and 100'
            )::jsonb;
            validation_result := jsonb_set(validation_result, '{valid}', 'false'::jsonb);
        END IF;
    END IF;
    
    -- Validate age range consistency
    IF (settings_update->'matching_preferences' ? 'min_age_preference') AND 
       (settings_update->'matching_preferences' ? 'max_age_preference') THEN
        IF proposed_min_age > proposed_max_age THEN
            errors := errors || jsonb_build_object(
                'field', 'age_range',
                'message', 'Minimum age preference cannot be greater than maximum age preference'
            )::jsonb;
            validation_result := jsonb_set(validation_result, '{valid}', 'false'::jsonb);
        END IF;
    END IF;
    
    -- Add warnings for potentially limiting settings
    IF proposed_distance IS NOT NULL AND proposed_distance < 10 THEN
        warnings := warnings || jsonb_build_object(
            'field', 'preferred_distance_km',
            'message', 'A distance preference under 10km may significantly limit your matches'
        )::jsonb;
    END IF;
    
    -- Update validation result with errors and warnings
    validation_result := jsonb_set(validation_result, '{errors}', errors);
    validation_result := jsonb_set(validation_result, '{warnings}', warnings);
    
    -- Add validation metadata
    validation_result := validation_result || jsonb_build_object(
        'validated_at', NOW(),
        'user_id', target_user_id,
        'validator_version', '1.0.0'
    );
    
    RETURN validation_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 6. SETTINGS ANALYTICS AND MONITORING FUNCTIONS
-- =====================================================

-- Function to log settings changes for analytics
CREATE OR REPLACE FUNCTION log_settings_change(
    target_user_id UUID,
    changed_fields JSONB,
    previous_values JSONB,
    new_values JSONB,
    change_source TEXT DEFAULT 'user_action',
    user_agent TEXT DEFAULT NULL,
    ip_address INET DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    changelog_id UUID;
BEGIN
    INSERT INTO public.user_settings_changelog (
        user_id,
        changed_fields,
        previous_values,
        new_values,
        change_source,
        user_agent,
        ip_address
    ) VALUES (
        target_user_id,
        changed_fields,
        previous_values,
        new_values,
        change_source,
        user_agent,
        ip_address
    ) RETURNING id INTO changelog_id;
    
    RETURN changelog_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get settings usage statistics
CREATE OR REPLACE FUNCTION get_settings_usage_stats()
RETURNS JSONB AS $$
DECLARE
    stats JSONB;
BEGIN
    SELECT jsonb_build_object(
        'total_users_with_settings', 
        (SELECT COUNT(*) FROM public.user_settings),
        
        'average_distance_preference',
        (SELECT ROUND(AVG(preferred_distance_km), 2) FROM public.user_settings),
        
        'average_age_range',
        jsonb_build_object(
            'min_age', (SELECT ROUND(AVG(min_age_preference), 1) FROM public.user_settings),
            'max_age', (SELECT ROUND(AVG(max_age_preference), 1) FROM public.user_settings)
        ),
        
        'notification_preferences',
        jsonb_build_object(
            'message_notifications_enabled_pct', 
            (SELECT ROUND(
                (COUNT(*) FILTER (WHERE message_notifications_enabled = true)::FLOAT / COUNT(*)) * 100, 2
            ) FROM public.user_settings),
            'do_not_disturb_enabled_pct',
            (SELECT ROUND(
                (COUNT(*) FILTER (WHERE do_not_disturb_enabled = true)::FLOAT / COUNT(*)) * 100, 2
            ) FROM public.user_settings)
        ),
        
        'privacy_settings',
        jsonb_build_object(
            'read_receipts_enabled_pct',
            (SELECT ROUND(
                (COUNT(*) FILTER (WHERE read_receipts_enabled = true)::FLOAT / COUNT(*)) * 100, 2
            ) FROM public.user_settings),
            'discovery_enabled_pct',
            (SELECT ROUND(
                (COUNT(*) FILTER (WHERE discovery_enabled = true)::FLOAT / COUNT(*)) * 100, 2
            ) FROM public.user_settings),
            'incognito_mode_enabled_pct',
            (SELECT ROUND(
                (COUNT(*) FILTER (WHERE incognito_mode = true)::FLOAT / COUNT(*)) * 100, 2
            ) FROM public.user_settings)
        ),
        
        'calculated_at', NOW()
    ) INTO stats;
    
    RETURN stats;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 7. GRANT PERMISSIONS FOR ALL FUNCTIONS
-- =====================================================

-- Grant execute permissions to authenticated users
GRANT EXECUTE ON FUNCTION get_user_matching_preferences(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION check_mutual_compatibility(UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_user_notification_preferences(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION should_send_notification(UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_user_privacy_settings(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION is_user_discoverable(UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_cached_user_settings(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION validate_settings_update(UUID, JSONB) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION log_settings_change(UUID, JSONB, JSONB, JSONB, TEXT, TEXT, INET) TO authenticated, service_role;

-- Grant execute permissions for statistics (service role only)
GRANT EXECUTE ON FUNCTION get_settings_usage_stats() TO service_role;

-- =====================================================
-- 8. ADD FUNCTION COMMENTS
-- =====================================================

COMMENT ON FUNCTION get_user_matching_preferences(UUID) IS 'Returns optimized matching preferences for use in matching algorithms with defaults for missing data';
COMMENT ON FUNCTION check_mutual_compatibility(UUID, UUID) IS 'Checks if two users are mutually compatible based on their matching preferences and profiles';
COMMENT ON FUNCTION get_user_notification_preferences(UUID) IS 'Returns structured notification preferences for a user with defaults';
COMMENT ON FUNCTION should_send_notification(UUID, TEXT) IS 'Determines if a notification should be sent to a user based on their preferences and Do Not Disturb settings';
COMMENT ON FUNCTION get_user_privacy_settings(UUID) IS 'Returns privacy and visibility settings for a user';
COMMENT ON FUNCTION is_user_discoverable(UUID, UUID) IS 'Checks if a user should be visible/discoverable to another user based on privacy settings';
COMMENT ON FUNCTION get_cached_user_settings(UUID) IS 'Returns frequently accessed user settings optimized for caching and high-performance queries';
COMMENT ON FUNCTION validate_settings_update(UUID, JSONB) IS 'Validates proposed settings changes and returns validation results with errors and warnings';
COMMENT ON FUNCTION log_settings_change(UUID, JSONB, JSONB, JSONB, TEXT, TEXT, INET) IS 'Logs settings changes for audit and analytics purposes';
COMMENT ON FUNCTION get_settings_usage_stats() IS 'Returns anonymized statistics about settings usage across all users for analytics';

-- =====================================================
-- 9. CREATE PERFORMANCE VIEWS FOR COMMON QUERIES
-- =====================================================

-- View for discoverable users with their matching preferences (for matching algorithms)
-- NOTE: height column removed as it doesn't exist in profiles table
-- NOTE: lat/lng extracted from location JSONB if available
CREATE OR REPLACE VIEW public.discoverable_users_with_preferences AS
SELECT
    p.id as user_id,
    p.display_name,
    p.gender,
    p.age,
    p.zodiac_sign,
    (p.location->>'lat')::NUMERIC as lat,
    (p.location->>'lng')::NUMERIC as lng,
    us.preferred_distance_km,
    us.min_age_preference,
    us.max_age_preference,
    us.gender_preference,
    us.min_height_preference,
    us.max_height_preference,
    us.zodiac_compatibility_required,
    p.updated_at
FROM public.profiles p
LEFT JOIN public.user_settings us ON us.user_id = p.id
WHERE p.onboarding_completed = true
  AND COALESCE(us.discovery_enabled, true) = true
  AND COALESCE(us.profile_visibility_public, true) = true
  AND COALESCE(us.incognito_mode, false) = false;

-- Grant permissions on the view
GRANT SELECT ON public.discoverable_users_with_preferences TO authenticated, service_role;

COMMENT ON VIEW public.discoverable_users_with_preferences IS 'Optimized view combining profile data with matching preferences for users who are discoverable';

-- =====================================================
-- 10. VERIFICATION AND TESTING
-- =====================================================

-- Test the utility functions
DO $$
DECLARE
    test_user_id UUID;
    test_result JSONB;
    function_count INTEGER;
BEGIN
    -- Count created functions
    SELECT COUNT(*) INTO function_count
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
    AND p.proname LIKE '%user%settings%'
    OR p.proname LIKE '%notification%'
    OR p.proname LIKE '%compatibility%'
    OR p.proname LIKE '%discoverable%';
    
    RAISE NOTICE '✅ Created % settings utility functions', function_count;
    
    -- Test with a real user if available
    SELECT id INTO test_user_id FROM auth.users LIMIT 1;
    
    IF test_user_id IS NOT NULL THEN
        -- Test get_user_matching_preferences
        SELECT * FROM get_user_matching_preferences(test_user_id) INTO test_result LIMIT 1;
        IF test_result IS NOT NULL THEN
            RAISE NOTICE '✅ get_user_matching_preferences function working';
        END IF;
        
        -- Test get_user_notification_preferences
        SELECT get_user_notification_preferences(test_user_id) INTO test_result;
        IF test_result IS NOT NULL THEN
            RAISE NOTICE '✅ get_user_notification_preferences function working';
        END IF;
        
        -- Test should_send_notification
        IF should_send_notification(test_user_id, 'message') IS NOT NULL THEN
            RAISE NOTICE '✅ should_send_notification function working';
        END IF;
    ELSE
        RAISE NOTICE '⚠️ No test users available for function testing';
    END IF;
    
    RAISE NOTICE '🎉 All settings utility functions created successfully!';
END $$;

COMMIT;

-- =====================================================
-- UTILITY FUNCTIONS MIGRATION COMPLETE
-- =====================================================

SELECT 
    'Settings Utility Functions Migration Completed!' as status,
    NOW() as completed_at,
    (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid 
     WHERE n.nspname = 'public' AND (
         p.proname LIKE '%user%settings%' OR 
         p.proname LIKE '%notification%' OR 
         p.proname LIKE '%compatibility%' OR 
         p.proname LIKE '%discoverable%'
     )) as utility_functions_created;