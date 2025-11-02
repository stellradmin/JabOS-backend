-- =====================================================================================
-- STELLR ENCRYPTED BIRTH DATA STORAGE
-- Phase 2: Add encrypted columns for sensitive birth data and natal chart information
-- =====================================================================================

-- Add encrypted columns to users table for birth data
-- Keep original columns during transition period

-- Encrypted birth data columns
ALTER TABLE public.users 
ADD COLUMN IF NOT EXISTS birth_date_encrypted TEXT,
ADD COLUMN IF NOT EXISTS birth_time_encrypted TEXT,
ADD COLUMN IF NOT EXISTS birth_location_encrypted TEXT,
ADD COLUMN IF NOT EXISTS birth_lat_encrypted TEXT,
ADD COLUMN IF NOT EXISTS birth_lng_encrypted TEXT,
ADD COLUMN IF NOT EXISTS questionnaire_responses_encrypted TEXT;

-- Add metadata columns for encryption tracking
ALTER TABLE public.users
ADD COLUMN IF NOT EXISTS encryption_enabled BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS encrypted_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS encryption_version TEXT DEFAULT 'v1';

-- =====================================================================================
-- ENCRYPTED NATAL CHART STORAGE
-- Create dedicated table for encrypted natal chart data
-- =====================================================================================

CREATE TABLE IF NOT EXISTS public.natal_charts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- Encrypted natal chart data
    chart_data_encrypted TEXT NOT NULL, -- Full natal chart JSON encrypted
    calculation_metadata_encrypted TEXT, -- Calculation parameters encrypted
    
    -- Public metadata (not encrypted)
    calculated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    chart_version TEXT DEFAULT 'v1',
    encryption_version TEXT DEFAULT 'v1',
    
    -- Performance and caching
    chart_hash TEXT, -- Hash for change detection
    last_accessed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    access_count INTEGER DEFAULT 0,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(user_id) -- One chart per user
);

-- Enable RLS on natal_charts
ALTER TABLE public.natal_charts ENABLE ROW LEVEL SECURITY;

-- RLS policies for natal charts
CREATE POLICY "Users can manage their natal chart" ON public.natal_charts
    FOR ALL USING (auth.uid() = user_id);

CREATE POLICY "Service role full access to natal charts" ON public.natal_charts
    FOR ALL USING (auth.role() = 'service_role');

-- =====================================================================================
-- ENCRYPTED COMPATIBILITY CALCULATIONS STORAGE
-- Update matches table to support encrypted compatibility data
-- =====================================================================================

-- Add encrypted compatibility data column to matches table
ALTER TABLE public.matches 
ADD COLUMN IF NOT EXISTS calculation_result_encrypted TEXT,
ADD COLUMN IF NOT EXISTS compatibility_encryption_version TEXT DEFAULT 'v1';

-- =====================================================================================
-- BIRTH DATA ENCRYPTION/DECRYPTION WRAPPER FUNCTIONS
-- High-level functions for birth data operations
-- =====================================================================================

-- Encrypt user's birth data
CREATE OR REPLACE FUNCTION public.encrypt_user_birth_data(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_record RECORD;
    v_encrypted_date TEXT;
    v_encrypted_time TEXT;
    v_encrypted_location TEXT;
    v_encrypted_lat TEXT;
    v_encrypted_lng TEXT;
    v_encrypted_questionnaire TEXT;
BEGIN
    -- Get current user data
    SELECT * INTO v_user_record
    FROM public.users
    WHERE id = p_user_id OR auth_user_id = p_user_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;
    
    -- Skip if already encrypted
    IF v_user_record.encryption_enabled THEN
        RETURN TRUE;
    END IF;
    
    -- Encrypt birth_date
    IF v_user_record.birth_date IS NOT NULL THEN
        v_encrypted_date := encryption.encrypt_field(
            p_user_id, 'users', 'birth_date', v_user_record.birth_date
        );
    END IF;
    
    -- Encrypt birth_time
    IF v_user_record.birth_time IS NOT NULL THEN
        v_encrypted_time := encryption.encrypt_field(
            p_user_id, 'users', 'birth_time', v_user_record.birth_time
        );
    END IF;
    
    -- Encrypt birth_location
    IF v_user_record.birth_location IS NOT NULL THEN
        v_encrypted_location := encryption.encrypt_field(
            p_user_id, 'users', 'birth_location', v_user_record.birth_location
        );
    END IF;
    
    -- Encrypt birth_lat
    IF v_user_record.birth_lat IS NOT NULL THEN
        v_encrypted_lat := encryption.encrypt_field(
            p_user_id, 'users', 'birth_lat', v_user_record.birth_lat::TEXT
        );
    END IF;
    
    -- Encrypt birth_lng
    IF v_user_record.birth_lng IS NOT NULL THEN
        v_encrypted_lng := encryption.encrypt_field(
            p_user_id, 'users', 'birth_lng', v_user_record.birth_lng::TEXT
        );
    END IF;
    
    -- Encrypt questionnaire_responses
    IF v_user_record.questionnaire_responses IS NOT NULL THEN
        v_encrypted_questionnaire := encryption.encrypt_field(
            p_user_id, 'users', 'questionnaire_responses', v_user_record.questionnaire_responses::TEXT
        );
    END IF;
    
    -- Update user record with encrypted data
    UPDATE public.users
    SET 
        birth_date_encrypted = v_encrypted_date,
        birth_time_encrypted = v_encrypted_time,
        birth_location_encrypted = v_encrypted_location,
        birth_lat_encrypted = v_encrypted_lat,
        birth_lng_encrypted = v_encrypted_lng,
        questionnaire_responses_encrypted = v_encrypted_questionnaire,
        encryption_enabled = TRUE,
        encrypted_at = NOW(),
        encryption_version = 'v1'
    WHERE id = v_user_record.id;
    
    -- Record encryption status
    INSERT INTO encryption.field_encryption_status (user_id, table_name, field_name, encryption_version)
    SELECT p_user_id, 'users', field_name, 'v1'
    FROM unnest(ARRAY['birth_date', 'birth_time', 'birth_location', 'birth_lat', 'birth_lng', 'questionnaire_responses']) AS field_name
    ON CONFLICT (user_id, table_name, field_name) DO NOTHING;
    
    RETURN TRUE;
END;
$$;

-- Decrypt user's birth data for application use
CREATE OR REPLACE FUNCTION public.get_decrypted_birth_data(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_record RECORD;
    v_result JSONB := '{}'::JSONB;
    v_decrypted_value TEXT;
BEGIN
    -- Get user record
    SELECT * INTO v_user_record
    FROM public.users
    WHERE id = p_user_id OR auth_user_id = p_user_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;
    
    -- If encryption is not enabled, return original data
    IF NOT v_user_record.encryption_enabled THEN
        RETURN jsonb_build_object(
            'birth_date', v_user_record.birth_date,
            'birth_time', v_user_record.birth_time,
            'birth_location', v_user_record.birth_location,
            'birth_lat', v_user_record.birth_lat,
            'birth_lng', v_user_record.birth_lng,
            'questionnaire_responses', v_user_record.questionnaire_responses,
            'encrypted', false
        );
    END IF;
    
    -- Decrypt birth_date
    IF v_user_record.birth_date_encrypted IS NOT NULL THEN
        v_decrypted_value := encryption.decrypt_field(
            p_user_id, 'users', 'birth_date', v_user_record.birth_date_encrypted
        );
        v_result := v_result || jsonb_build_object('birth_date', v_decrypted_value);
    END IF;
    
    -- Decrypt birth_time
    IF v_user_record.birth_time_encrypted IS NOT NULL THEN
        v_decrypted_value := encryption.decrypt_field(
            p_user_id, 'users', 'birth_time', v_user_record.birth_time_encrypted
        );
        v_result := v_result || jsonb_build_object('birth_time', v_decrypted_value);
    END IF;
    
    -- Decrypt birth_location
    IF v_user_record.birth_location_encrypted IS NOT NULL THEN
        v_decrypted_value := encryption.decrypt_field(
            p_user_id, 'users', 'birth_location', v_user_record.birth_location_encrypted
        );
        v_result := v_result || jsonb_build_object('birth_location', v_decrypted_value);
    END IF;
    
    -- Decrypt birth_lat
    IF v_user_record.birth_lat_encrypted IS NOT NULL THEN
        v_decrypted_value := encryption.decrypt_field(
            p_user_id, 'users', 'birth_lat', v_user_record.birth_lat_encrypted
        );
        v_result := v_result || jsonb_build_object('birth_lat', v_decrypted_value::NUMERIC);
    END IF;
    
    -- Decrypt birth_lng
    IF v_user_record.birth_lng_encrypted IS NOT NULL THEN
        v_decrypted_value := encryption.decrypt_field(
            p_user_id, 'users', 'birth_lng', v_user_record.birth_lng_encrypted
        );
        v_result := v_result || jsonb_build_object('birth_lng', v_decrypted_value::NUMERIC);
    END IF;
    
    -- Decrypt questionnaire_responses
    IF v_user_record.questionnaire_responses_encrypted IS NOT NULL THEN
        v_decrypted_value := encryption.decrypt_field(
            p_user_id, 'users', 'questionnaire_responses', v_user_record.questionnaire_responses_encrypted
        );
        v_result := v_result || jsonb_build_object('questionnaire_responses', v_decrypted_value::JSONB);
    END IF;
    
    v_result := v_result || jsonb_build_object('encrypted', true, 'encryption_version', v_user_record.encryption_version);
    
    RETURN v_result;
END;
$$;

-- =====================================================================================
-- NATAL CHART ENCRYPTION FUNCTIONS
-- =====================================================================================

-- Store encrypted natal chart
CREATE OR REPLACE FUNCTION public.store_encrypted_natal_chart(
    p_user_id UUID,
    p_chart_data JSONB,
    p_calculation_metadata JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_chart_id UUID;
    v_encrypted_chart TEXT;
    v_encrypted_metadata TEXT;
    v_chart_hash TEXT;
BEGIN
    -- Encrypt chart data
    v_encrypted_chart := encryption.encrypt_field(
        p_user_id, 'natal_charts', 'chart_data', p_chart_data::TEXT
    );
    
    -- Encrypt metadata if provided
    IF p_calculation_metadata IS NOT NULL THEN
        v_encrypted_metadata := encryption.encrypt_field(
            p_user_id, 'natal_charts', 'calculation_metadata', p_calculation_metadata::TEXT
        );
    END IF;
    
    -- Generate hash for change detection
    v_chart_hash := encode(
        digest(p_chart_data::TEXT || COALESCE(p_calculation_metadata::TEXT, ''), 'sha256'), 
        'hex'
    );
    
    -- Insert or update natal chart
    INSERT INTO public.natal_charts (
        user_id,
        chart_data_encrypted,
        calculation_metadata_encrypted,
        chart_hash
    ) VALUES (
        p_user_id,
        v_encrypted_chart,
        v_encrypted_metadata,
        v_chart_hash
    )
    ON CONFLICT (user_id) DO UPDATE SET
        chart_data_encrypted = EXCLUDED.chart_data_encrypted,
        calculation_metadata_encrypted = EXCLUDED.calculation_metadata_encrypted,
        chart_hash = EXCLUDED.chart_hash,
        updated_at = NOW()
    RETURNING id INTO v_chart_id;
    
    -- Record encryption status
    INSERT INTO encryption.field_encryption_status (user_id, table_name, field_name, encryption_version)
    VALUES 
        (p_user_id, 'natal_charts', 'chart_data', 'v1'),
        (p_user_id, 'natal_charts', 'calculation_metadata', 'v1')
    ON CONFLICT (user_id, table_name, field_name) DO NOTHING;
    
    RETURN v_chart_id;
END;
$$;

-- Retrieve decrypted natal chart
CREATE OR REPLACE FUNCTION public.get_decrypted_natal_chart(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_chart_record RECORD;
    v_decrypted_chart JSONB;
    v_decrypted_metadata JSONB;
BEGIN
    -- Get chart record
    SELECT * INTO v_chart_record
    FROM public.natal_charts
    WHERE user_id = p_user_id;
    
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    
    -- Decrypt chart data
    v_decrypted_chart := encryption.decrypt_field(
        p_user_id, 'natal_charts', 'chart_data', v_chart_record.chart_data_encrypted
    )::JSONB;
    
    -- Decrypt metadata if exists
    IF v_chart_record.calculation_metadata_encrypted IS NOT NULL THEN
        v_decrypted_metadata := encryption.decrypt_field(
            p_user_id, 'natal_charts', 'calculation_metadata', v_chart_record.calculation_metadata_encrypted
        )::JSONB;
    END IF;
    
    -- Update access tracking
    UPDATE public.natal_charts
    SET 
        last_accessed_at = NOW(),
        access_count = access_count + 1
    WHERE user_id = p_user_id;
    
    RETURN jsonb_build_object(
        'id', v_chart_record.id,
        'chart_data', v_decrypted_chart,
        'calculation_metadata', v_decrypted_metadata,
        'calculated_at', v_chart_record.calculated_at,
        'chart_version', v_chart_record.chart_version,
        'chart_hash', v_chart_record.chart_hash
    );
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.encrypt_user_birth_data(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_decrypted_birth_data(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.store_encrypted_natal_chart(UUID, JSONB, JSONB) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_decrypted_natal_chart(UUID) TO authenticated, service_role;

-- =====================================================================================
-- INDEXES FOR PERFORMANCE
-- =====================================================================================

CREATE INDEX IF NOT EXISTS idx_users_encryption_enabled ON public.users(encryption_enabled) WHERE encryption_enabled = TRUE;
CREATE INDEX IF NOT EXISTS idx_natal_charts_user_id ON public.natal_charts(user_id);
CREATE INDEX IF NOT EXISTS idx_natal_charts_calculated_at ON public.natal_charts(calculated_at);
CREATE INDEX IF NOT EXISTS idx_natal_charts_chart_hash ON public.natal_charts(chart_hash);

-- =====================================================================================
-- COMMENTS FOR DOCUMENTATION
-- =====================================================================================

COMMENT ON COLUMN public.users.birth_date_encrypted IS 'Encrypted birth date using XChaCha20-Poly1305 AEAD';
COMMENT ON COLUMN public.users.birth_time_encrypted IS 'Encrypted birth time using XChaCha20-Poly1305 AEAD';
COMMENT ON COLUMN public.users.birth_location_encrypted IS 'Encrypted birth location using XChaCha20-Poly1305 AEAD';
COMMENT ON COLUMN public.users.birth_lat_encrypted IS 'Encrypted birth latitude using XChaCha20-Poly1305 AEAD';
COMMENT ON COLUMN public.users.birth_lng_encrypted IS 'Encrypted birth longitude using XChaCha20-Poly1305 AEAD';
COMMENT ON COLUMN public.users.questionnaire_responses_encrypted IS 'Encrypted questionnaire responses using XChaCha20-Poly1305 AEAD';
COMMENT ON COLUMN public.users.encryption_enabled IS 'Flag indicating if user data is encrypted';
COMMENT ON COLUMN public.users.encrypted_at IS 'Timestamp when data was first encrypted';
COMMENT ON COLUMN public.users.encryption_version IS 'Version of encryption scheme used';

COMMENT ON TABLE public.natal_charts IS 'Encrypted natal chart storage for astrological compatibility calculations';
COMMENT ON COLUMN public.natal_charts.chart_data_encrypted IS 'Encrypted natal chart calculation results';
COMMENT ON COLUMN public.natal_charts.calculation_metadata_encrypted IS 'Encrypted metadata about chart calculation parameters';
COMMENT ON COLUMN public.natal_charts.chart_hash IS 'SHA-256 hash of chart data for change detection';

COMMENT ON FUNCTION public.encrypt_user_birth_data IS 'Encrypts all birth data fields for a user';
COMMENT ON FUNCTION public.get_decrypted_birth_data IS 'Returns decrypted birth data for authorized access';
COMMENT ON FUNCTION public.store_encrypted_natal_chart IS 'Stores encrypted natal chart with metadata';
COMMENT ON FUNCTION public.get_decrypted_natal_chart IS 'Retrieves and decrypts natal chart data';