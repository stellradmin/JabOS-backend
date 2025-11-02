-- =====================================================================================
-- STELLR DATA MIGRATION TO ENCRYPTED STORAGE
-- Phase 4: Safely migrate existing unencrypted data to encrypted format
-- =====================================================================================

-- =====================================================================================
-- MIGRATION SAFETY PROCEDURES
-- Create backup and staging procedures for safe migration
-- =====================================================================================

-- Create backup table for existing birth data before migration
CREATE TABLE IF NOT EXISTS encryption.birth_data_migration_backup AS
SELECT 
    id,
    auth_user_id,
    birth_date,
    birth_time,
    birth_location,
    birth_lat,
    birth_lng,
    questionnaire_responses,
    created_at,
    updated_at
FROM public.users
WHERE (
    birth_date IS NOT NULL OR 
    birth_time IS NOT NULL OR 
    birth_location IS NOT NULL OR 
    birth_lat IS NOT NULL OR 
    birth_lng IS NOT NULL OR 
    questionnaire_responses IS NOT NULL
)
AND encryption_enabled = FALSE;

-- Add migration tracking table
CREATE TABLE IF NOT EXISTS encryption.migration_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    migration_batch TEXT NOT NULL,
    user_id UUID NOT NULL,
    operation TEXT NOT NULL,
    status TEXT NOT NULL, -- 'success', 'failed', 'skipped'
    error_message TEXT,
    fields_migrated TEXT[],
    started_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    duration_ms INTEGER
);

-- Enable RLS on migration log
ALTER TABLE encryption.migration_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Service role manages migration log" ON encryption.migration_log
    FOR ALL USING (auth.role() = 'service_role');

-- =====================================================================================
-- BATCH MIGRATION FUNCTION
-- Process data in safe batches to avoid timeouts and memory issues
-- =====================================================================================

CREATE OR REPLACE FUNCTION encryption.migrate_batch_to_encrypted(
    p_batch_size INTEGER DEFAULT 100,
    p_batch_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_record RECORD;
    v_migration_batch TEXT;
    v_processed_count INTEGER := 0;
    v_success_count INTEGER := 0;
    v_error_count INTEGER := 0;
    v_skipped_count INTEGER := 0;
    v_batch_start TIMESTAMP WITH TIME ZONE;
    v_operation_start TIMESTAMP WITH TIME ZONE;
    v_operation_duration INTEGER;
    v_fields_migrated TEXT[];
    v_error_message TEXT;
BEGIN
    -- Generate unique batch ID
    v_migration_batch := 'batch_' || p_batch_offset || '_' || extract(epoch from now())::bigint;
    v_batch_start := NOW();
    
    RAISE NOTICE 'Starting migration batch: % (size: %, offset: %)', v_migration_batch, p_batch_size, p_batch_offset;
    
    -- Process users in batch
    FOR v_user_record IN 
        SELECT 
            id, 
            auth_user_id,
            birth_date,
            birth_time, 
            birth_location,
            birth_lat,
            birth_lng,
            questionnaire_responses,
            encryption_enabled
        FROM public.users
        WHERE (
            birth_date IS NOT NULL OR 
            birth_time IS NOT NULL OR 
            birth_location IS NOT NULL OR
            birth_lat IS NOT NULL OR
            birth_lng IS NOT NULL OR
            questionnaire_responses IS NOT NULL
        )
        AND COALESCE(encryption_enabled, FALSE) = FALSE
        ORDER BY created_at
        LIMIT p_batch_size
        OFFSET p_batch_offset
    LOOP
        v_processed_count := v_processed_count + 1;
        v_operation_start := NOW();
        v_fields_migrated := ARRAY[]::TEXT[];
        v_error_message := NULL;
        
        BEGIN
            -- Determine which fields need migration
            IF v_user_record.birth_date IS NOT NULL THEN
                v_fields_migrated := v_fields_migrated || 'birth_date';
            END IF;
            IF v_user_record.birth_time IS NOT NULL THEN
                v_fields_migrated := v_fields_migrated || 'birth_time';
            END IF;
            IF v_user_record.birth_location IS NOT NULL THEN
                v_fields_migrated := v_fields_migrated || 'birth_location';
            END IF;
            IF v_user_record.birth_lat IS NOT NULL THEN
                v_fields_migrated := v_fields_migrated || 'birth_lat';
            END IF;
            IF v_user_record.birth_lng IS NOT NULL THEN
                v_fields_migrated := v_fields_migrated || 'birth_lng';
            END IF;
            IF v_user_record.questionnaire_responses IS NOT NULL THEN
                v_fields_migrated := v_fields_migrated || 'questionnaire_responses';
            END IF;
            
            -- Skip if no fields to migrate
            IF array_length(v_fields_migrated, 1) IS NULL THEN
                v_skipped_count := v_skipped_count + 1;
                
                -- Log skipped operation
                INSERT INTO encryption.migration_log (
                    migration_batch, user_id, operation, status, 
                    fields_migrated, started_at, completed_at, duration_ms
                )
                VALUES (
                    v_migration_batch,
                    COALESCE(v_user_record.auth_user_id, v_user_record.id),
                    'encrypt_birth_data',
                    'skipped',
                    v_fields_migrated,
                    v_operation_start,
                    NOW(),
                    extract(milliseconds from NOW() - v_operation_start)::integer
                );
                
                CONTINUE;
            END IF;
            
            -- Encrypt the user's birth data
            PERFORM public.encrypt_user_birth_data(
                COALESCE(v_user_record.auth_user_id, v_user_record.id)
            );
            
            v_success_count := v_success_count + 1;
            v_operation_duration := extract(milliseconds from NOW() - v_operation_start)::integer;
            
            -- Log successful operation
            INSERT INTO encryption.migration_log (
                migration_batch, user_id, operation, status, 
                fields_migrated, started_at, completed_at, duration_ms
            )
            VALUES (
                v_migration_batch,
                COALESCE(v_user_record.auth_user_id, v_user_record.id),
                'encrypt_birth_data',
                'success',
                v_fields_migrated,
                v_operation_start,
                NOW(),
                v_operation_duration
            );
            
            -- Progress logging every 10 users
            IF v_processed_count % 10 = 0 THEN
                RAISE NOTICE 'Migrated % users in batch %', v_processed_count, v_migration_batch;
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                v_error_count := v_error_count + 1;
                v_error_message := SQLERRM;
                v_operation_duration := extract(milliseconds from NOW() - v_operation_start)::integer;
                
                -- Log failed operation
                INSERT INTO encryption.migration_log (
                    migration_batch, user_id, operation, status, error_message,
                    fields_migrated, started_at, completed_at, duration_ms
                )
                VALUES (
                    v_migration_batch,
                    COALESCE(v_user_record.auth_user_id, v_user_record.id),
                    'encrypt_birth_data',
                    'failed',
                    v_error_message,
                    v_fields_migrated,
                    v_operation_start,
                    NOW(),
                    v_operation_duration
                );
                
                RAISE WARNING 'Migration failed for user %: %', 
                    COALESCE(v_user_record.auth_user_id, v_user_record.id), 
                    v_error_message;
        END;
    END LOOP;
    
    RAISE NOTICE 'Batch % completed: Processed: %, Success: %, Errors: %, Skipped: %, Duration: %ms',
        v_migration_batch, v_processed_count, v_success_count, v_error_count, v_skipped_count,
        extract(milliseconds from NOW() - v_batch_start)::integer;
    
    -- Return batch summary
    RETURN jsonb_build_object(
        'migration_batch', v_migration_batch,
        'processed_count', v_processed_count,
        'success_count', v_success_count,
        'error_count', v_error_count,
        'skipped_count', v_skipped_count,
        'batch_duration_ms', extract(milliseconds from NOW() - v_batch_start)::integer,
        'timestamp', NOW()
    );
END;
$$;

-- =====================================================================================
-- FULL MIGRATION ORCHESTRATOR
-- Orchestrates complete migration of all unencrypted data
-- =====================================================================================

CREATE OR REPLACE FUNCTION encryption.migrate_all_to_encrypted(
    p_batch_size INTEGER DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_total_users_to_migrate INTEGER;
    v_total_batches INTEGER;
    v_current_batch INTEGER := 0;
    v_batch_result JSONB;
    v_migration_summary JSONB := '{}'::JSONB;
    v_overall_start TIMESTAMP WITH TIME ZONE;
    v_total_processed INTEGER := 0;
    v_total_success INTEGER := 0;
    v_total_errors INTEGER := 0;
    v_total_skipped INTEGER := 0;
BEGIN
    v_overall_start := NOW();
    
    -- Count total users needing migration
    SELECT COUNT(*) INTO v_total_users_to_migrate
    FROM public.users
    WHERE (
        birth_date IS NOT NULL OR 
        birth_time IS NOT NULL OR 
        birth_location IS NOT NULL OR
        birth_lat IS NOT NULL OR
        birth_lng IS NOT NULL OR
        questionnaire_responses IS NOT NULL
    )
    AND COALESCE(encryption_enabled, FALSE) = FALSE;
    
    v_total_batches := CEIL(v_total_users_to_migrate::NUMERIC / p_batch_size::NUMERIC);
    
    RAISE NOTICE 'Starting full migration: % users in % batches of % users each',
        v_total_users_to_migrate, v_total_batches, p_batch_size;
    
    -- Process all batches
    WHILE v_current_batch < v_total_batches LOOP
        -- Process current batch
        SELECT encryption.migrate_batch_to_encrypted(
            p_batch_size, 
            v_current_batch * p_batch_size
        ) INTO v_batch_result;
        
        -- Accumulate totals
        v_total_processed := v_total_processed + (v_batch_result->>'processed_count')::INTEGER;
        v_total_success := v_total_success + (v_batch_result->>'success_count')::INTEGER;
        v_total_errors := v_total_errors + (v_batch_result->>'error_count')::INTEGER;
        v_total_skipped := v_total_skipped + (v_batch_result->>'skipped_count')::INTEGER;
        
        -- Store batch result
        v_migration_summary := v_migration_summary || 
            jsonb_build_object('batch_' || v_current_batch, v_batch_result);
        
        v_current_batch := v_current_batch + 1;
        
        -- Brief pause between batches to avoid overwhelming the system
        PERFORM pg_sleep(0.1);
    END LOOP;
    
    -- Final summary
    v_migration_summary := v_migration_summary || jsonb_build_object(
        'migration_summary', jsonb_build_object(
            'total_users_targeted', v_total_users_to_migrate,
            'total_batches', v_total_batches,
            'batch_size', p_batch_size,
            'total_processed', v_total_processed,
            'total_success', v_total_success,
            'total_errors', v_total_errors,
            'total_skipped', v_total_skipped,
            'success_rate_percent', 
                CASE 
                    WHEN v_total_processed > 0 
                    THEN round((v_total_success::NUMERIC / v_total_processed::NUMERIC) * 100, 2)
                    ELSE 0
                END,
            'overall_duration_ms', extract(milliseconds from NOW() - v_overall_start)::integer,
            'completed_at', NOW()
        )
    );
    
    RAISE NOTICE 'Migration completed: %/%% success rate (%/% users)',
        CASE 
            WHEN v_total_processed > 0 
            THEN round((v_total_success::NUMERIC / v_total_processed::NUMERIC) * 100, 2)
            ELSE 0
        END,
        v_total_success, v_total_processed;
    
    RETURN v_migration_summary;
END;
$$;

-- =====================================================================================
-- MIGRATION VERIFICATION FUNCTIONS
-- =====================================================================================

-- Function to verify migration completeness
CREATE OR REPLACE FUNCTION encryption.verify_migration_completeness()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_unencrypted_count INTEGER;
    v_encrypted_count INTEGER;
    v_total_sensitive_users INTEGER;
    v_coverage_percent NUMERIC;
    v_verification_details JSONB;
BEGIN
    -- Count users with unencrypted sensitive data
    SELECT COUNT(*) INTO v_unencrypted_count
    FROM public.users
    WHERE (
        birth_date IS NOT NULL OR 
        birth_time IS NOT NULL OR 
        birth_location IS NOT NULL OR
        birth_lat IS NOT NULL OR
        birth_lng IS NOT NULL OR
        questionnaire_responses IS NOT NULL
    )
    AND COALESCE(encryption_enabled, FALSE) = FALSE;
    
    -- Count users with encrypted data
    SELECT COUNT(*) INTO v_encrypted_count
    FROM public.users
    WHERE encryption_enabled = TRUE;
    
    -- Count total users with sensitive data
    SELECT COUNT(*) INTO v_total_sensitive_users
    FROM public.users
    WHERE (
        birth_date IS NOT NULL OR 
        birth_time IS NOT NULL OR 
        birth_location IS NOT NULL OR
        birth_lat IS NOT NULL OR
        birth_lng IS NOT NULL OR
        questionnaire_responses IS NOT NULL
    );
    
    -- Calculate coverage percentage
    v_coverage_percent := CASE 
        WHEN v_total_sensitive_users > 0 
        THEN round((v_encrypted_count::NUMERIC / v_total_sensitive_users::NUMERIC) * 100, 2)
        ELSE 0
    END;
    
    -- Get detailed breakdown
    SELECT jsonb_agg(
        jsonb_build_object(
            'field', field_name,
            'encrypted_users', encrypted_count
        )
    ) INTO v_verification_details
    FROM (
        SELECT 
            field_name,
            COUNT(*) as encrypted_count
        FROM encryption.field_encryption_status
        WHERE table_name = 'users'
        GROUP BY field_name
    ) details;
    
    RETURN jsonb_build_object(
        'verification_timestamp', NOW(),
        'total_users_with_sensitive_data', v_total_sensitive_users,
        'encrypted_users', v_encrypted_count,
        'unencrypted_users', v_unencrypted_count,
        'encryption_coverage_percent', v_coverage_percent,
        'is_migration_complete', v_unencrypted_count = 0,
        'field_encryption_breakdown', v_verification_details
    );
END;
$$;

-- Function to get migration statistics
CREATE OR REPLACE FUNCTION encryption.get_migration_statistics()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_migration_stats JSONB;
    v_recent_migrations JSONB;
    v_error_summary JSONB;
BEGIN
    -- Get overall migration statistics
    SELECT jsonb_build_object(
        'total_migration_operations', COUNT(*),
        'successful_operations', COUNT(*) FILTER (WHERE status = 'success'),
        'failed_operations', COUNT(*) FILTER (WHERE status = 'failed'),
        'skipped_operations', COUNT(*) FILTER (WHERE status = 'skipped'),
        'average_operation_duration_ms', AVG(duration_ms),
        'total_users_migrated', COUNT(DISTINCT user_id) FILTER (WHERE status = 'success'),
        'migration_date_range', jsonb_build_object(
            'earliest', MIN(started_at),
            'latest', MAX(completed_at)
        )
    ) INTO v_migration_stats
    FROM encryption.migration_log;
    
    -- Get recent migration batches
    SELECT jsonb_agg(
        jsonb_build_object(
            'batch', migration_batch,
            'total_operations', batch_total,
            'success_rate', round((success_count::NUMERIC / batch_total::NUMERIC) * 100, 2),
            'completed_at', latest_completion
        )
    ) INTO v_recent_migrations
    FROM (
        SELECT 
            migration_batch,
            COUNT(*) as batch_total,
            COUNT(*) FILTER (WHERE status = 'success') as success_count,
            MAX(completed_at) as latest_completion
        FROM encryption.migration_log
        GROUP BY migration_batch
        ORDER BY MAX(completed_at) DESC
        LIMIT 10
    ) recent_batches;
    
    -- Get error summary
    SELECT jsonb_agg(
        jsonb_build_object(
            'error_message', error_message,
            'occurrence_count', error_count,
            'affected_users', user_count
        )
    ) INTO v_error_summary
    FROM (
        SELECT 
            error_message,
            COUNT(*) as error_count,
            COUNT(DISTINCT user_id) as user_count
        FROM encryption.migration_log
        WHERE status = 'failed'
        AND error_message IS NOT NULL
        GROUP BY error_message
        ORDER BY COUNT(*) DESC
        LIMIT 5
    ) error_breakdown;
    
    RETURN jsonb_build_object(
        'migration_statistics', v_migration_stats,
        'recent_migration_batches', v_recent_migrations,
        'error_summary', v_error_summary,
        'report_generated_at', NOW()
    );
END;
$$;

-- Grant permissions for migration functions
GRANT EXECUTE ON FUNCTION encryption.migrate_batch_to_encrypted(INTEGER, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION encryption.migrate_all_to_encrypted(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION encryption.verify_migration_completeness() TO service_role, authenticated;
GRANT EXECUTE ON FUNCTION encryption.get_migration_statistics() TO service_role, authenticated;

-- =====================================================================================
-- ROLLBACK AND RECOVERY PROCEDURES
-- =====================================================================================

-- Function to rollback migration for specific users (emergency use)
CREATE OR REPLACE FUNCTION encryption.rollback_user_encryption(
    p_user_id UUID,
    p_force BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_backup_record RECORD;
    v_user_record RECORD;
BEGIN
    -- Only allow rollback if forced or in development
    IF NOT p_force AND current_setting('app.environment', true) = 'production' THEN
        RAISE EXCEPTION 'Rollback not allowed in production without force flag';
    END IF;
    
    -- Get backup data
    SELECT * INTO v_backup_record
    FROM encryption.birth_data_migration_backup
    WHERE id = p_user_id OR auth_user_id = p_user_id
    LIMIT 1;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No backup data found for user %', p_user_id;
    END IF;
    
    -- Get current user record
    SELECT * INTO v_user_record
    FROM public.users
    WHERE id = p_user_id OR auth_user_id = p_user_id
    LIMIT 1;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;
    
    -- Restore original data
    UPDATE public.users
    SET 
        birth_date = v_backup_record.birth_date,
        birth_time = v_backup_record.birth_time,
        birth_location = v_backup_record.birth_location,
        birth_lat = v_backup_record.birth_lat,
        birth_lng = v_backup_record.birth_lng,
        questionnaire_responses = v_backup_record.questionnaire_responses,
        -- Clear encrypted columns
        birth_date_encrypted = NULL,
        birth_time_encrypted = NULL,
        birth_location_encrypted = NULL,
        birth_lat_encrypted = NULL,
        birth_lng_encrypted = NULL,
        questionnaire_responses_encrypted = NULL,
        encryption_enabled = FALSE,
        encrypted_at = NULL,
        updated_at = NOW()
    WHERE id = v_user_record.id;
    
    -- Remove encryption status records
    DELETE FROM encryption.field_encryption_status
    WHERE user_id = p_user_id AND table_name = 'users';
    
    -- Remove user encryption keys
    DELETE FROM encryption.user_encryption_keys
    WHERE user_id = p_user_id;
    
    RAISE NOTICE 'Encryption rollback completed for user %', p_user_id;
    
    RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION encryption.rollback_user_encryption(UUID, BOOLEAN) TO service_role;

-- =====================================================================================
-- INDEXES FOR MIGRATION PERFORMANCE
-- =====================================================================================

CREATE INDEX IF NOT EXISTS idx_users_encryption_migration ON public.users(encryption_enabled, created_at) 
    WHERE encryption_enabled = FALSE;
CREATE INDEX IF NOT EXISTS idx_migration_log_batch ON encryption.migration_log(migration_batch, status);
CREATE INDEX IF NOT EXISTS idx_migration_log_user ON encryption.migration_log(user_id, operation);

-- =====================================================================================
-- FINAL SETUP AND COMMENTS
-- =====================================================================================

-- Add comments for documentation
COMMENT ON FUNCTION encryption.migrate_batch_to_encrypted IS 'Safely migrates a batch of users to encrypted storage';
COMMENT ON FUNCTION encryption.migrate_all_to_encrypted IS 'Orchestrates complete migration of all unencrypted data';
COMMENT ON FUNCTION encryption.verify_migration_completeness IS 'Verifies that all sensitive data has been properly encrypted';
COMMENT ON FUNCTION encryption.get_migration_statistics IS 'Returns comprehensive migration statistics and reports';
COMMENT ON FUNCTION encryption.rollback_user_encryption IS 'Emergency rollback function for encryption (use with caution)';
COMMENT ON TABLE encryption.migration_log IS 'Tracks all encryption migration operations for audit and troubleshooting';
COMMENT ON TABLE encryption.birth_data_migration_backup IS 'Backup of original birth data before encryption migration';

-- Final migration readiness check
DO $$
DECLARE
    v_health_check JSONB;
    v_unencrypted_count INTEGER;
BEGIN
    -- Check system health before declaring ready
    SELECT encryption.health_check() INTO v_health_check;
    
    IF (v_health_check->>'status') != 'healthy' THEN
        RAISE WARNING 'Encryption system not healthy: %', v_health_check;
    END IF;
    
    -- Count users ready for migration
    SELECT COUNT(*) INTO v_unencrypted_count
    FROM public.users
    WHERE (
        birth_date IS NOT NULL OR 
        birth_time IS NOT NULL OR 
        birth_location IS NOT NULL OR
        birth_lat IS NOT NULL OR
        birth_lng IS NOT NULL OR
        questionnaire_responses IS NOT NULL
    )
    AND COALESCE(encryption_enabled, FALSE) = FALSE;
    
    RAISE NOTICE '========================================';
    RAISE NOTICE 'STELLR ENCRYPTION MIGRATION READY';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'System Status: %', v_health_check->>'status';
    RAISE NOTICE 'Users ready for migration: %', v_unencrypted_count;
    RAISE NOTICE 'Backup table created: encryption.birth_data_migration_backup';
    RAISE NOTICE 'Migration functions available:';
    RAISE NOTICE '  - encryption.migrate_all_to_encrypted() -- Full migration';
    RAISE NOTICE '  - encryption.migrate_batch_to_encrypted(batch_size, offset) -- Batch migration';
    RAISE NOTICE '  - encryption.verify_migration_completeness() -- Verify migration';
    RAISE NOTICE '  - encryption.get_migration_statistics() -- Get migration stats';
    RAISE NOTICE '========================================';
    
    IF v_unencrypted_count > 0 THEN
        RAISE NOTICE 'TO START MIGRATION: SELECT encryption.migrate_all_to_encrypted(50);';
    ELSE
        RAISE NOTICE 'No users require migration - system ready!';
    END IF;
END;
$$;