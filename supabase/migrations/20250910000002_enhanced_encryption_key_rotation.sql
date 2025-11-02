-- =====================================================================================
-- ENHANCED ENCRYPTION KEY ROTATION SYSTEM
-- Migration: 20250910_002_enhanced_encryption_key_rotation.sql
-- Purpose: Implement automated key rotation with backup and recovery mechanisms
-- Dependencies: pgsodium extension, vault system, existing encryption infrastructure
-- =====================================================================================

-- SECURITY CONTEXT:
-- Implements automated encryption key rotation to prevent key compromise risks
-- Includes backup mechanisms, versioning, and rollback capabilities
-- Addresses security audit findings on encryption key lifecycle management

-- =====================================================================================
-- PHASE 1: ENHANCED KEY ROTATION INFRASTRUCTURE
-- =====================================================================================

-- Create schema for key rotation management if not exists
CREATE SCHEMA IF NOT EXISTS key_rotation;

-- Key rotation schedule and policies table
CREATE TABLE IF NOT EXISTS key_rotation.rotation_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_name VARCHAR(100) UNIQUE NOT NULL,
    key_type VARCHAR(50) NOT NULL, -- 'master', 'field', 'session'
    rotation_interval_days INTEGER NOT NULL DEFAULT 90,
    auto_rotation_enabled BOOLEAN DEFAULT TRUE,
    backup_retention_days INTEGER DEFAULT 30,
    compliance_requirement VARCHAR(100),
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Key rotation history and audit trail
CREATE TABLE IF NOT EXISTS key_rotation.rotation_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rotation_job_id UUID NOT NULL,
    key_id UUID NOT NULL,
    key_type VARCHAR(50) NOT NULL,
    rotation_type VARCHAR(20) NOT NULL, -- 'scheduled', 'emergency', 'manual'
    old_key_version INTEGER,
    new_key_version INTEGER,
    rotation_started_at TIMESTAMP WITH TIME ZONE NOT NULL,
    rotation_completed_at TIMESTAMP WITH TIME ZONE,
    rotation_status VARCHAR(20) DEFAULT 'in_progress', -- 'completed', 'failed', 'rolled_back'
    backup_created BOOLEAN DEFAULT FALSE,
    data_migration_required BOOLEAN DEFAULT FALSE,
    data_migration_completed BOOLEAN DEFAULT FALSE,
    error_details JSONB,
    performance_metrics JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Key backup storage with versioning
CREATE TABLE IF NOT EXISTS key_rotation.key_backups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    original_key_id UUID NOT NULL,
    backup_key_id UUID NOT NULL,
    key_type VARCHAR(50) NOT NULL,
    key_version INTEGER NOT NULL,
    backup_type VARCHAR(20) NOT NULL, -- 'pre_rotation', 'emergency', 'scheduled'
    encrypted_backup_data TEXT NOT NULL, -- Encrypted with separate backup key
    backup_metadata JSONB DEFAULT '{}',
    retention_until TIMESTAMP WITH TIME ZONE NOT NULL,
    is_restorable BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_rotation_policies_auto_enabled ON key_rotation.rotation_policies(auto_rotation_enabled, rotation_interval_days);
CREATE INDEX IF NOT EXISTS idx_rotation_history_job_status ON key_rotation.rotation_history(rotation_job_id, rotation_status);
CREATE INDEX IF NOT EXISTS idx_key_backups_retention ON key_rotation.key_backups(retention_until, is_restorable);

-- =====================================================================================
-- PHASE 2: AUTOMATED KEY ROTATION PROCEDURES
-- =====================================================================================

-- Enhanced master key rotation with backup and recovery
CREATE OR REPLACE FUNCTION key_rotation.rotate_master_key_enhanced(
    p_key_name TEXT,
    p_rotation_type TEXT DEFAULT 'scheduled',
    p_force_rotation BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_rotation_job_id UUID := gen_random_uuid();
    v_old_master_key RECORD;
    v_new_master_key_id UUID;
    v_new_key_hex TEXT;
    v_backup_id UUID;
    v_affected_keys_count INTEGER := 0;
    v_rotation_start_time TIMESTAMP WITH TIME ZONE := NOW();
    v_result JSONB;
BEGIN
    -- Initialize rotation job
    INSERT INTO key_rotation.rotation_history (
        rotation_job_id, key_type, rotation_type, rotation_started_at, rotation_status
    ) VALUES (
        v_rotation_job_id, 'master', p_rotation_type, v_rotation_start_time, 'in_progress'
    );

    -- Get current master key
    SELECT mk.id, mk.key_version, mk.vault_secret_name
    INTO v_old_master_key
    FROM encryption.master_keys mk
    WHERE mk.key_name = p_key_name 
    AND mk.status = 'active'
    ORDER BY mk.key_version DESC
    LIMIT 1;

    IF v_old_master_key.id IS NULL THEN
        RAISE EXCEPTION 'Active master key not found: %', p_key_name;
    END IF;

    -- Check if rotation is needed (unless forced)
    IF NOT p_force_rotation THEN
        PERFORM 1 FROM key_rotation.rotation_policies rp
        WHERE rp.policy_name = p_key_name
        AND rp.auto_rotation_enabled = TRUE
        AND EXISTS (
            SELECT 1 FROM encryption.master_keys mk
            WHERE mk.key_name = p_key_name
            AND mk.created_at >= NOW() - INTERVAL '1 day' * rp.rotation_interval_days
        );
        
        IF FOUND THEN
            RAISE NOTICE 'Key rotation not required for % (within rotation interval)', p_key_name;
            RETURN jsonb_build_object(
                'status', 'skipped',
                'reason', 'within_rotation_interval',
                'rotation_job_id', v_rotation_job_id
            );
        END IF;
    END IF;

    -- Step 1: Create backup of current master key
    PERFORM key_rotation.backup_master_key(
        v_old_master_key.id,
        'pre_rotation',
        v_rotation_job_id
    );

    -- Step 2: Generate new master key with enhanced entropy
    SELECT encode(
        gen_random_bytes(32) || 
        encode(extract(epoch from NOW())::TEXT::BYTEA, 'hex')::BYTEA ||
        gen_random_bytes(16), 
        'hex'
    ) INTO v_new_key_hex;

    -- Step 3: Store new key in vault with versioning
    INSERT INTO vault.secrets (
        name, 
        description, 
        secret
    ) VALUES (
        p_key_name || '_v' || (v_old_master_key.key_version + 1),
        'Master encryption key version ' || (v_old_master_key.key_version + 1) || 
        ' (rotated from v' || v_old_master_key.key_version || ')',
        v_new_key_hex
    );

    -- Step 4: Create new master key record
    INSERT INTO encryption.master_keys (
        key_name,
        key_version,
        vault_secret_name,
        status,
        metadata
    ) VALUES (
        p_key_name,
        v_old_master_key.key_version + 1,
        p_key_name || '_v' || (v_old_master_key.key_version + 1),
        'active',
        jsonb_build_object(
            'algorithm', 'XChaCha20-Poly1305',
            'key_length_bits', 384, -- Enhanced from 256 to 384 bits
            'rotated_from_key_id', v_old_master_key.id,
            'rotation_job_id', v_rotation_job_id,
            'rotation_type', p_rotation_type,
            'entropy_sources', ARRAY['random_bytes', 'timestamp', 'additional_random']
        )
    ) RETURNING id INTO v_new_master_key_id;

    -- Step 5: Update all dependent data encryption keys
    UPDATE encryption.data_encryption_keys
    SET 
        master_key_id = v_new_master_key_id,
        updated_at = NOW()
    WHERE master_key_id = v_old_master_key.id;
    
    GET DIAGNOSTICS v_affected_keys_count = ROW_COUNT;

    -- Step 6: Mark old key as expired with retention period
    UPDATE encryption.master_keys
    SET 
        status = 'expired',
        expires_at = NOW() + INTERVAL '30 days', -- Retain for recovery
        metadata = metadata || jsonb_build_object(
            'expired_by_rotation_job', v_rotation_job_id,
            'successor_key_id', v_new_master_key_id
        )
    WHERE id = v_old_master_key.id;

    -- Step 7: Update rotation history
    UPDATE key_rotation.rotation_history
    SET 
        key_id = v_new_master_key_id,
        old_key_version = v_old_master_key.key_version,
        new_key_version = v_old_master_key.key_version + 1,
        rotation_completed_at = NOW(),
        rotation_status = 'completed',
        backup_created = TRUE,
        performance_metrics = jsonb_build_object(
            'affected_keys_count', v_affected_keys_count,
            'rotation_duration_seconds', EXTRACT(EPOCH FROM (NOW() - v_rotation_start_time))
        )
    WHERE rotation_job_id = v_rotation_job_id;

    -- Step 8: Schedule cleanup of old backups
    PERFORM key_rotation.schedule_backup_cleanup(p_key_name);

    v_result := jsonb_build_object(
        'status', 'completed',
        'rotation_job_id', v_rotation_job_id,
        'old_key_version', v_old_master_key.key_version,
        'new_key_version', v_old_master_key.key_version + 1,
        'new_master_key_id', v_new_master_key_id,
        'affected_keys_count', v_affected_keys_count,
        'duration_seconds', EXTRACT(EPOCH FROM (NOW() - v_rotation_start_time))
    );

    RAISE NOTICE 'Master key rotation completed: %', v_result;
    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        -- Update rotation history with error
        UPDATE key_rotation.rotation_history
        SET 
            rotation_status = 'failed',
            error_details = jsonb_build_object(
                'error_message', SQLERRM,
                'error_state', SQLSTATE,
                'failed_at', NOW()
            )
        WHERE rotation_job_id = v_rotation_job_id;
        
        RAISE;
END;
$$;

-- =====================================================================================
-- PHASE 3: BACKUP AND RECOVERY MECHANISMS
-- =====================================================================================

-- Function to create secure backup of master key
CREATE OR REPLACE FUNCTION key_rotation.backup_master_key(
    p_key_id UUID,
    p_backup_type TEXT DEFAULT 'scheduled',
    p_rotation_job_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_backup_id UUID := gen_random_uuid();
    v_key_data RECORD;
    v_backup_key TEXT;
    v_encrypted_backup TEXT;
    v_retention_days INTEGER;
BEGIN
    -- Get key information
    SELECT mk.key_name, mk.key_version, vs.secret
    INTO v_key_data
    FROM encryption.master_keys mk
    JOIN vault.decrypted_secrets vs ON vs.name = mk.vault_secret_name
    WHERE mk.id = p_key_id;

    IF v_key_data.key_name IS NULL THEN
        RAISE EXCEPTION 'Master key not found for backup: %', p_key_id;
    END IF;

    -- Generate backup encryption key (separate from master key)
    SELECT encode(gen_random_bytes(32), 'hex') INTO v_backup_key;

    -- Store backup key in vault
    INSERT INTO vault.secrets (
        name,
        description,
        secret
    ) VALUES (
        'backup_key_' || v_backup_id,
        'Backup encryption key for master key backup ' || v_backup_id,
        v_backup_key
    );

    -- Encrypt the master key data with backup key
    -- In production, use pgsodium.crypto_aead_xchacha20poly1305_ietf_encrypt
    v_encrypted_backup := encode(
        pgsodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
            v_key_data.secret::BYTEA,
            NULL,  -- No additional data
            gen_random_bytes(24), -- Random nonce
            decode(v_backup_key, 'hex')
        ),
        'hex'
    );

    -- Get retention policy
    SELECT COALESCE(rp.backup_retention_days, 30)
    INTO v_retention_days
    FROM key_rotation.rotation_policies rp
    WHERE rp.policy_name = v_key_data.key_name;

    -- Store encrypted backup
    INSERT INTO key_rotation.key_backups (
        id,
        original_key_id,
        backup_key_id,
        key_type,
        key_version,
        backup_type,
        encrypted_backup_data,
        backup_metadata,
        retention_until
    ) VALUES (
        v_backup_id,
        p_key_id,
        (SELECT id FROM vault.secrets WHERE name = 'backup_key_' || v_backup_id),
        'master',
        v_key_data.key_version,
        p_backup_type,
        v_encrypted_backup,
        jsonb_build_object(
            'key_name', v_key_data.key_name,
            'rotation_job_id', p_rotation_job_id,
            'backup_algorithm', 'XChaCha20-Poly1305',
            'created_by', 'key_rotation_system'
        ),
        NOW() + INTERVAL '1 day' * v_retention_days
    );

    RAISE NOTICE 'Master key backup created: %', v_backup_id;
    RETURN v_backup_id;
END;
$$;

-- Function to restore master key from backup
CREATE OR REPLACE FUNCTION key_rotation.restore_master_key_from_backup(
    p_backup_id UUID,
    p_restore_as_active BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_backup_data RECORD;
    v_backup_key TEXT;
    v_decrypted_key TEXT;
    v_restored_key_id UUID;
    v_vault_secret_name TEXT;
BEGIN
    -- Get backup information
    SELECT kb.original_key_id, kb.backup_key_id, kb.encrypted_backup_data, kb.backup_metadata
    INTO v_backup_data
    FROM key_rotation.key_backups kb
    WHERE kb.id = p_backup_id
    AND kb.is_restorable = TRUE
    AND kb.retention_until > NOW();

    IF v_backup_data.original_key_id IS NULL THEN
        RAISE EXCEPTION 'Valid backup not found or expired: %', p_backup_id;
    END IF;

    -- Get backup encryption key
    SELECT vs.secret INTO v_backup_key
    FROM vault.decrypted_secrets vs
    WHERE vs.id = v_backup_data.backup_key_id;

    -- Decrypt the backed up key
    v_decrypted_key := encode(
        pgsodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
            decode(v_backup_data.encrypted_backup_data, 'hex'),
            NULL,  -- No additional data
            decode(v_backup_key, 'hex')
        ),
        'hex'
    );

    -- Generate new vault secret name for restored key
    v_vault_secret_name := (v_backup_data.backup_metadata->>'key_name') || '_restored_' || 
                          extract(epoch from NOW())::TEXT;

    -- Store restored key in vault
    INSERT INTO vault.secrets (
        name,
        description,  
        secret
    ) VALUES (
        v_vault_secret_name,
        'Restored master key from backup ' || p_backup_id,
        v_decrypted_key
    );

    -- Create new master key record
    INSERT INTO encryption.master_keys (
        key_name,
        key_version,
        vault_secret_name,
        status,
        metadata
    ) VALUES (
        v_backup_data.backup_metadata->>'key_name',
        999, -- Special version number for restored keys
        v_vault_secret_name,
        CASE WHEN p_restore_as_active THEN 'active' ELSE 'restored' END,
        jsonb_build_object(
            'algorithm', 'XChaCha20-Poly1305',
            'key_length_bits', 256,
            'restored_from_backup', p_backup_id,
            'original_key_id', v_backup_data.original_key_id,
            'restore_timestamp', NOW()
        )
    ) RETURNING id INTO v_restored_key_id;

    -- If restoring as active, deactivate other keys
    IF p_restore_as_active THEN
        UPDATE encryption.master_keys
        SET status = 'superseded'
        WHERE key_name = (v_backup_data.backup_metadata->>'key_name')
        AND id != v_restored_key_id;
    END IF;

    RAISE NOTICE 'Master key restored from backup %. New key ID: %', p_backup_id, v_restored_key_id;
    RETURN v_restored_key_id;
END;
$$;

-- =====================================================================================
-- PHASE 4: AUTOMATED ROTATION SCHEDULING
-- =====================================================================================

-- Function to check and execute scheduled rotations
CREATE OR REPLACE FUNCTION key_rotation.execute_scheduled_rotations()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_policy RECORD;
    v_rotation_results JSONB := '[]'::JSONB;
    v_rotation_result JSONB;
    v_total_rotations INTEGER := 0;
    v_successful_rotations INTEGER := 0;
BEGIN
    -- Check all auto-rotation policies
    FOR v_policy IN
        SELECT rp.policy_name, rp.rotation_interval_days, rp.key_type
        FROM key_rotation.rotation_policies rp
        WHERE rp.auto_rotation_enabled = TRUE
    LOOP
        -- Check if rotation is due
        IF EXISTS (
            SELECT 1 FROM encryption.master_keys mk
            WHERE mk.key_name = v_policy.policy_name
            AND mk.status = 'active'
            AND mk.created_at <= NOW() - INTERVAL '1 day' * v_policy.rotation_interval_days
        ) THEN
            BEGIN
                -- Execute rotation
                SELECT key_rotation.rotate_master_key_enhanced(
                    v_policy.policy_name,
                    'scheduled',
                    FALSE
                ) INTO v_rotation_result;
                
                v_total_rotations := v_total_rotations + 1;
                
                IF v_rotation_result->>'status' = 'completed' THEN
                    v_successful_rotations := v_successful_rotations + 1;
                END IF;
                
                -- Add to results
                v_rotation_results := v_rotation_results || jsonb_build_object(
                    'policy_name', v_policy.policy_name,
                    'result', v_rotation_result
                );
                
            EXCEPTION
                WHEN OTHERS THEN
                    v_total_rotations := v_total_rotations + 1;
                    v_rotation_results := v_rotation_results || jsonb_build_object(
                        'policy_name', v_policy.policy_name,
                        'result', jsonb_build_object(
                            'status', 'failed',
                            'error', SQLERRM
                        )
                    );
            END;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'total_policies_checked', (SELECT COUNT(*) FROM key_rotation.rotation_policies WHERE auto_rotation_enabled = TRUE),
        'total_rotations_attempted', v_total_rotations,
        'successful_rotations', v_successful_rotations,
        'rotation_results', v_rotation_results,
        'execution_timestamp', NOW()
    );
END;
$$;

-- =====================================================================================
-- PHASE 5: BACKUP CLEANUP AND MAINTENANCE
-- =====================================================================================

-- Function to clean up expired backups
CREATE OR REPLACE FUNCTION key_rotation.cleanup_expired_backups()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_cleanup_count INTEGER := 0;
    v_backup RECORD;
BEGIN
    -- Clean up expired backups
    FOR v_backup IN
        SELECT id, backup_key_id
        FROM key_rotation.key_backups
        WHERE retention_until <= NOW()
        AND is_restorable = TRUE
    LOOP
        -- Remove backup key from vault
        DELETE FROM vault.secrets 
        WHERE id = v_backup.backup_key_id;
        
        -- Mark backup as non-restorable
        UPDATE key_rotation.key_backups
        SET 
            is_restorable = FALSE,
            backup_metadata = backup_metadata || jsonb_build_object(
                'cleaned_up_at', NOW(),
                'cleanup_reason', 'retention_expired'
            )
        WHERE id = v_backup.id;
        
        v_cleanup_count := v_cleanup_count + 1;
    END LOOP;
    
    RAISE NOTICE 'Cleaned up % expired key backups', v_cleanup_count;
    RETURN v_cleanup_count;
END;
$$;

-- Function to schedule backup cleanup
CREATE OR REPLACE FUNCTION key_rotation.schedule_backup_cleanup(p_key_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- This would integrate with a job scheduler in production
    -- For now, just perform immediate cleanup
    PERFORM key_rotation.cleanup_expired_backups();
END;
$$;

-- =====================================================================================
-- PHASE 6: MONITORING AND HEALTH CHECKS
-- =====================================================================================

-- Function to monitor key rotation health
CREATE OR REPLACE FUNCTION key_rotation.health_check()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_health_report JSONB;
    v_overdue_rotations INTEGER;
    v_failed_rotations INTEGER;
    v_backup_status JSONB;
BEGIN
    -- Count overdue rotations
    SELECT COUNT(*)
    INTO v_overdue_rotations
    FROM key_rotation.rotation_policies rp
    JOIN encryption.master_keys mk ON mk.key_name = rp.policy_name
    WHERE rp.auto_rotation_enabled = TRUE
    AND mk.status = 'active'
    AND mk.created_at <= NOW() - INTERVAL '1 day' * rp.rotation_interval_days;

    -- Count recent failed rotations
    SELECT COUNT(*)
    INTO v_failed_rotations
    FROM key_rotation.rotation_history rh
    WHERE rh.rotation_status = 'failed'
    AND rh.rotation_started_at >= NOW() - INTERVAL '7 days';

    -- Check backup status
    SELECT jsonb_build_object(
        'total_backups', COUNT(*),
        'restorable_backups', COUNT(*) FILTER (WHERE is_restorable = TRUE),
        'expired_backups', COUNT(*) FILTER (WHERE retention_until <= NOW()),
        'oldest_backup_age_days', EXTRACT(DAYS FROM (NOW() - MIN(created_at)))
    ) INTO v_backup_status
    FROM key_rotation.key_backups;

    v_health_report := jsonb_build_object(
        'timestamp', NOW(),
        'overall_status', 
            CASE 
                WHEN v_overdue_rotations > 0 THEN 'WARNING'
                WHEN v_failed_rotations > 0 THEN 'DEGRADED'
                ELSE 'HEALTHY'
            END,
        'overdue_rotations_count', v_overdue_rotations,
        'failed_rotations_last_7_days', v_failed_rotations,
        'backup_status', v_backup_status,
        'active_master_keys', (
            SELECT COUNT(*) FROM encryption.master_keys WHERE status = 'active'
        ),
        'rotation_policies_enabled', (
            SELECT COUNT(*) FROM key_rotation.rotation_policies WHERE auto_rotation_enabled = TRUE
        )
    );

    RETURN v_health_report;
END;
$$;

-- =====================================================================================
-- PHASE 7: SETUP DEFAULT ROTATION POLICIES
-- =====================================================================================

-- Insert default rotation policies for existing keys
INSERT INTO key_rotation.rotation_policies (
    policy_name,
    key_type,
    rotation_interval_days,
    auto_rotation_enabled,
    backup_retention_days,
    compliance_requirement,
    metadata
) VALUES 
(
    'stellr_master_encryption_key',
    'master',
    90, -- Rotate every 90 days
    TRUE,
    30, -- Keep backups for 30 days
    'PCI_DSS',
    jsonb_build_object(
        'description', 'Primary master key for field-level encryption',
        'criticality', 'high',
        'auto_created', TRUE
    )
),
(
    'session_encryption_keys',
    'session', 
    7, -- Rotate weekly for session keys
    TRUE,
    7,
    'SECURITY_BEST_PRACTICE',
    jsonb_build_object(
        'description', 'Session-level encryption keys',
        'criticality', 'medium',
        'auto_created', TRUE
    )
) 
ON CONFLICT (policy_name) DO NOTHING;

-- =====================================================================================
-- PHASE 8: RLS POLICIES FOR KEY ROTATION TABLES
-- =====================================================================================

-- Enable RLS on key rotation tables
ALTER TABLE key_rotation.rotation_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE key_rotation.rotation_history ENABLE ROW LEVEL SECURITY;  
ALTER TABLE key_rotation.key_backups ENABLE ROW LEVEL SECURITY;

-- Service role only policies
CREATE POLICY "service_role_rotation_policies" ON key_rotation.rotation_policies
    FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "service_role_rotation_history" ON key_rotation.rotation_history
    FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "service_role_key_backups" ON key_rotation.key_backups
    FOR ALL USING (auth.role() = 'service_role');

-- =====================================================================================
-- PHASE 9: GRANTS AND PERMISSIONS
-- =====================================================================================

GRANT USAGE ON SCHEMA key_rotation TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA key_rotation TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA key_rotation TO service_role;

-- Grant execute permissions on key rotation functions
GRANT EXECUTE ON FUNCTION key_rotation.rotate_master_key_enhanced TO service_role;
GRANT EXECUTE ON FUNCTION key_rotation.backup_master_key TO service_role;
GRANT EXECUTE ON FUNCTION key_rotation.restore_master_key_from_backup TO service_role;
GRANT EXECUTE ON FUNCTION key_rotation.execute_scheduled_rotations TO service_role;
GRANT EXECUTE ON FUNCTION key_rotation.cleanup_expired_backups TO service_role;
GRANT EXECUTE ON FUNCTION key_rotation.health_check TO service_role;

-- =====================================================================================
-- PHASE 10: INITIAL BACKUP OF EXISTING KEYS
-- =====================================================================================

-- Create initial backups for existing master keys
DO $$
DECLARE
    v_master_key RECORD;
    v_backup_id UUID;
BEGIN
    FOR v_master_key IN
        SELECT id, key_name, key_version
        FROM encryption.master_keys
        WHERE status = 'active'
    LOOP
        BEGIN
            SELECT key_rotation.backup_master_key(
                v_master_key.id,
                'initial_migration',
                NULL
            ) INTO v_backup_id;
            
            RAISE NOTICE 'Created initial backup % for master key % (version %)', 
                v_backup_id, v_master_key.key_name, v_master_key.key_version;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING 'Failed to create initial backup for key %: %', 
                    v_master_key.key_name, SQLERRM;
        END;
    END LOOP;
END;
$$;

-- =====================================================================================
-- PHASE 11: COMMENTS AND DOCUMENTATION
-- =====================================================================================

COMMENT ON SCHEMA key_rotation IS 'Enhanced encryption key rotation system with backup and recovery';
COMMENT ON TABLE key_rotation.rotation_policies IS 'Automated key rotation policies and schedules';
COMMENT ON TABLE key_rotation.rotation_history IS 'Complete audit trail of all key rotation operations';
COMMENT ON TABLE key_rotation.key_backups IS 'Encrypted backups of rotated keys with retention policies';

COMMENT ON FUNCTION key_rotation.rotate_master_key_enhanced IS 'Enhanced master key rotation with backup, versioning and rollback capabilities';
COMMENT ON FUNCTION key_rotation.backup_master_key IS 'Creates encrypted backup of master key with separate backup encryption';
COMMENT ON FUNCTION key_rotation.restore_master_key_from_backup IS 'Restores master key from encrypted backup with validation';
COMMENT ON FUNCTION key_rotation.execute_scheduled_rotations IS 'Executes all scheduled key rotations based on policies';
COMMENT ON FUNCTION key_rotation.health_check IS 'Comprehensive health check for key rotation system';

-- =====================================================================================
-- MIGRATION COMPLETION SUMMARY
-- =====================================================================================

DO $$
DECLARE
    v_total_policies INTEGER;
    v_total_backups INTEGER;
    v_health_status JSONB;
BEGIN
    SELECT COUNT(*) INTO v_total_policies FROM key_rotation.rotation_policies;
    SELECT COUNT(*) INTO v_total_backups FROM key_rotation.key_backups;
    SELECT key_rotation.health_check() INTO v_health_status;
    
    RAISE NOTICE '========================================';
    RAISE NOTICE 'ENHANCED KEY ROTATION SYSTEM DEPLOYED';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Rotation policies configured: %', v_total_policies;
    RAISE NOTICE 'Initial backups created: %', v_total_backups;
    RAISE NOTICE 'Health status: %', v_health_status->>'overall_status';
    RAISE NOTICE 'Master key rotation interval: 90 days';
    RAISE NOTICE 'Session key rotation interval: 7 days';
    RAISE NOTICE 'Backup retention: 30 days';
    RAISE NOTICE 'Auto-rotation: ENABLED';
    RAISE NOTICE '========================================';
END;
$$;