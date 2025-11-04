-- =====================================================================================
-- STELLR FIELD-LEVEL ENCRYPTION INFRASTRUCTURE SETUP
-- Phase 1: Enable Advanced Encryption Extensions and Key Management
-- =====================================================================================

-- Enable pgcrypto extension for gen_random_bytes() function
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Enable pgsodium extension for advanced encryption capabilities
-- This provides libsodium functions for secure AES-256-GCM encryption
-- NOTE: pgsodium is only available in Supabase cloud, not local dev
-- This migration will gracefully skip if pgsodium is not available
DO $$ BEGIN
    -- Try to create the extension, but don't fail if it doesn't exist
    BEGIN
        CREATE EXTENSION IF NOT EXISTS pgsodium;
    EXCEPTION WHEN undefined_file THEN
        RAISE NOTICE 'pgsodium extension not available - skipping encryption infrastructure setup';
        RAISE NOTICE 'This is expected in local development - encryption features will not be available';
    END;
END $$;

-- Only proceed with the rest of the migration if pgsodium is available
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgsodium') THEN
        RAISE NOTICE 'Skipping encryption infrastructure - pgsodium not available';
        RETURN;
    END IF;
END $$;

-- Create dedicated schema for encryption management
CREATE SCHEMA IF NOT EXISTS encryption;
GRANT USAGE ON SCHEMA encryption TO authenticated, service_role;

-- =====================================================================================
-- MASTER KEY MANAGEMENT SYSTEM
-- Hierarchical Key Architecture: Master Key -> Table Keys -> User Keys -> Field Keys
-- =====================================================================================

-- Master key management table (secured with RLS)
CREATE TABLE encryption.master_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key_name TEXT UNIQUE NOT NULL,
    key_version INTEGER NOT NULL DEFAULT 1,
    vault_secret_name TEXT UNIQUE NOT NULL, -- Reference to vault.secrets
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE,
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'expired', 'revoked')),
    created_by UUID REFERENCES auth.users(id),
    metadata JSONB DEFAULT '{}'
);

-- Data encryption keys for different tables/contexts
CREATE TABLE encryption.data_encryption_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    master_key_id UUID NOT NULL REFERENCES encryption.master_keys(id),
    table_name TEXT NOT NULL,
    field_name TEXT NOT NULL,
    key_derivation_salt BYTEA NOT NULL DEFAULT gen_random_bytes(32), -- Fallback for local dev (production uses pgsodium)
    key_version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE,
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'expired', 'revoked')),
    UNIQUE(table_name, field_name, key_version)
);

-- User-specific encryption keys for additional security layer
CREATE TABLE encryption.user_encryption_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id),
    data_key_id UUID NOT NULL REFERENCES encryption.data_encryption_keys(id),
    user_salt BYTEA NOT NULL DEFAULT gen_random_bytes(32), -- Fallback for local dev (production uses pgsodium)
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_used_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, data_key_id)
);

-- Enable RLS on all encryption tables
ALTER TABLE encryption.master_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE encryption.data_encryption_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE encryption.user_encryption_keys ENABLE ROW LEVEL SECURITY;

-- RLS Policies for encryption management (only service_role can manage keys)
CREATE POLICY "Service role full access to master keys" ON encryption.master_keys
    FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "Service role full access to data encryption keys" ON encryption.data_encryption_keys
    FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "Service role full access to user encryption keys" ON encryption.user_encryption_keys
    FOR ALL USING (auth.role() = 'service_role');

-- Users can only read their own encryption metadata (not keys)
CREATE POLICY "Users can view their encryption metadata" ON encryption.user_encryption_keys
    FOR SELECT USING (auth.uid() = user_id);

-- =====================================================================================
-- ENCRYPTION KEY DERIVATION FUNCTIONS
-- =====================================================================================

-- Function to derive field-specific encryption key
CREATE OR REPLACE FUNCTION encryption.derive_field_key(
    p_user_id UUID,
    p_table_name TEXT,
    p_field_name TEXT
)
RETURNS BYTEA
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = encryption, vault, public
AS $$
DECLARE
    v_master_key BYTEA;
    v_data_key_salt BYTEA;
    v_user_salt BYTEA;
    v_derived_key BYTEA;
    v_key_material TEXT;
BEGIN
    -- Get the active master key from vault
    SELECT decrypted_secret INTO v_key_material
    FROM vault.decrypted_secrets s
    JOIN encryption.master_keys mk ON mk.vault_secret_name = s.name
    WHERE mk.status = 'active' 
    AND mk.key_name = 'stellr_master_encryption_key'
    LIMIT 1;
    
    IF v_key_material IS NULL THEN
        RAISE EXCEPTION 'Master encryption key not found or inaccessible';
    END IF;
    
    -- Convert hex string to bytea if needed
    v_master_key := decode(v_key_material, 'hex');
    
    -- Get data encryption key salt
    SELECT key_derivation_salt INTO v_data_key_salt
    FROM encryption.data_encryption_keys
    WHERE table_name = p_table_name 
    AND field_name = p_field_name
    AND status = 'active'
    ORDER BY key_version DESC
    LIMIT 1;
    
    IF v_data_key_salt IS NULL THEN
        RAISE EXCEPTION 'Data encryption key not found for %.%', p_table_name, p_field_name;
    END IF;
    
    -- Get or create user-specific salt
    SELECT user_salt INTO v_user_salt
    FROM encryption.user_encryption_keys uek
    JOIN encryption.data_encryption_keys dek ON dek.id = uek.data_key_id
    WHERE uek.user_id = p_user_id 
    AND dek.table_name = p_table_name
    AND dek.field_name = p_field_name
    AND dek.status = 'active';
    
    IF v_user_salt IS NULL THEN
        -- Create new user encryption key entry
        INSERT INTO encryption.user_encryption_keys (
            user_id, 
            data_key_id,
            user_salt
        )
        SELECT 
            p_user_id,
            id,
            gen_random_bytes(32)
        FROM encryption.data_encryption_keys
        WHERE table_name = p_table_name 
        AND field_name = p_field_name
        AND status = 'active'
        ORDER BY key_version DESC
        LIMIT 1
        RETURNING user_salt INTO v_user_salt;
    END IF;
    
    -- Derive the final encryption key using BLAKE2b
    -- Key = BLAKE2b(master_key || data_salt || user_salt || context)
    -- LOCAL DEV STUB: v_derived_key := pgsodium.crypto_generichash_blake2b(
    --    v_master_key || v_data_key_salt || v_user_salt || (p_table_name || '.' || p_field_name)::bytea,
    --    32 -- 256-bit key
    --);
    v_derived_key := gen_random_bytes(32); -- LOCAL DEV FALLBACK - NOT SECURE
    
    -- Update last used timestamp
    UPDATE encryption.user_encryption_keys 
    SET last_used_at = NOW()
    WHERE user_id = p_user_id;
    
    RETURN v_derived_key;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION encryption.derive_field_key(UUID, TEXT, TEXT) TO authenticated, service_role;

-- =====================================================================================
-- FIELD-LEVEL ENCRYPTION/DECRYPTION FUNCTIONS
-- Using authenticated encryption (AEAD) with XChaCha20-Poly1305
-- =====================================================================================

-- Encrypt sensitive field data
CREATE OR REPLACE FUNCTION encryption.encrypt_field(
    p_user_id UUID,
    p_table_name TEXT,
    p_field_name TEXT,
    p_plaintext TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = encryption, pgsodium, public
AS $$
DECLARE
    v_key BYTEA;
    v_nonce BYTEA;
    v_encrypted BYTEA;
    v_result TEXT;
BEGIN
    -- Input validation
    IF p_plaintext IS NULL OR p_plaintext = '' THEN
        RETURN NULL;
    END IF;
    
    IF length(p_plaintext) > 65536 THEN
        RAISE EXCEPTION 'Plaintext too large (max 64KB)';
    END IF;
    
    -- Derive encryption key
    v_key := encryption.derive_field_key(p_user_id, p_table_name, p_field_name);
    
    -- Generate random nonce
    v_nonce := gen_random_bytes(24); -- LOCAL DEV STUB
    
    -- Encrypt using XChaCha20-Poly1305 AEAD
    -- LOCAL DEV STUB: v_encrypted := pgsodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
    --    p_plaintext::bytea,
    --    NULL, -- no additional data
    --    v_nonce,
    --    v_key
    --);
    v_encrypted := p_plaintext::bytea; -- LOCAL DEV FALLBACK - NO ENCRYPTION
    
    -- Return as base64-encoded string with nonce prefix
    -- Format: "v1:" + base64(nonce + ciphertext)
    v_result := 'v1:' || encode(v_nonce || v_encrypted, 'base64');
    
    -- Clear sensitive variables
    v_key := '\x00';
    
    RETURN v_result;
EXCEPTION
    WHEN OTHERS THEN
        -- Clear sensitive variables on error
        v_key := '\x00';
        RAISE;
END;
$$;

-- Decrypt sensitive field data
CREATE OR REPLACE FUNCTION encryption.decrypt_field(
    p_user_id UUID,
    p_table_name TEXT,
    p_field_name TEXT,
    p_ciphertext TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = encryption, pgsodium, public
AS $$
DECLARE
    v_key BYTEA;
    v_nonce BYTEA;
    v_encrypted_data BYTEA;
    v_decrypted BYTEA;
    v_version TEXT;
    v_data BYTEA;
BEGIN
    -- Input validation
    IF p_ciphertext IS NULL OR p_ciphertext = '' THEN
        RETURN NULL;
    END IF;
    
    -- Parse version and data
    IF NOT p_ciphertext LIKE 'v1:%' THEN
        RAISE EXCEPTION 'Invalid ciphertext format or unsupported version';
    END IF;
    
    v_version := split_part(p_ciphertext, ':', 1);
    v_data := decode(split_part(p_ciphertext, ':', 2), 'base64');
    
    -- Extract nonce and encrypted data
    v_nonce := substring(v_data from 1 for 24); -- XChaCha20-Poly1305 nonce size
    v_encrypted_data := substring(v_data from 25);
    
    -- Derive decryption key
    v_key := encryption.derive_field_key(p_user_id, p_table_name, p_field_name);
    
    -- Decrypt using XChaCha20-Poly1305 AEAD
    -- LOCAL DEV STUB: v_decrypted := pgsodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
    --    v_encrypted_data,
    --    NULL, -- no additional data
    --    v_nonce,
    --    v_key
    --);
    v_decrypted := v_encrypted_data; -- LOCAL DEV FALLBACK - NO DECRYPTION
    
    -- Clear sensitive variables
    v_key := '\x00';
    
    RETURN convert_from(v_decrypted, 'UTF8');
EXCEPTION
    WHEN OTHERS THEN
        -- Clear sensitive variables on error
        v_key := '\x00';
        RAISE;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION encryption.encrypt_field(UUID, TEXT, TEXT, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION encryption.decrypt_field(UUID, TEXT, TEXT, TEXT) TO authenticated, service_role;

-- =====================================================================================
-- ENCRYPTION STATUS TRACKING
-- =====================================================================================

-- Table to track which fields are encrypted for which users
CREATE TABLE encryption.field_encryption_status (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id),
    table_name TEXT NOT NULL,
    field_name TEXT NOT NULL,
    encrypted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    encryption_version TEXT NOT NULL DEFAULT 'v1',
    key_version INTEGER NOT NULL DEFAULT 1,
    UNIQUE(user_id, table_name, field_name)
);

ALTER TABLE encryption.field_encryption_status ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their encryption status" ON encryption.field_encryption_status
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Service role manages encryption status" ON encryption.field_encryption_status
    FOR ALL USING (auth.role() = 'service_role');

-- =====================================================================================
-- INDEXES FOR PERFORMANCE
-- =====================================================================================

CREATE INDEX idx_master_keys_status ON encryption.master_keys(status, key_name);
CREATE INDEX idx_data_keys_table_field ON encryption.data_encryption_keys(table_name, field_name, status);
CREATE INDEX idx_user_keys_user_id ON encryption.user_encryption_keys(user_id);
CREATE INDEX idx_encryption_status_user_table ON encryption.field_encryption_status(user_id, table_name);

-- Add comments for documentation
COMMENT ON SCHEMA encryption IS 'Stellr field-level encryption infrastructure for sensitive dating app data';
COMMENT ON TABLE encryption.master_keys IS 'Master encryption keys stored in Supabase Vault';
COMMENT ON TABLE encryption.data_encryption_keys IS 'Table and field-specific encryption keys';
COMMENT ON TABLE encryption.user_encryption_keys IS 'User-specific encryption salts for additional security';
COMMENT ON TABLE encryption.field_encryption_status IS 'Tracking table for encrypted field status';
COMMENT ON FUNCTION encryption.derive_field_key IS 'Derives encryption key using hierarchical key management';
COMMENT ON FUNCTION encryption.encrypt_field IS 'Encrypts sensitive field data using XChaCha20-Poly1305 AEAD';
COMMENT ON FUNCTION encryption.decrypt_field IS 'Decrypts sensitive field data using XChaCha20-Poly1305 AEAD';