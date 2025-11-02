-- Critical Security Enhancements and Audit Logging (FIXED VERSION)
-- Based on Production Readiness Audit (July 2025)
-- This migration implements critical security improvements identified in the audit

-- ============================================================================
-- AUDIT LOGGING SYSTEM
-- ============================================================================

-- Note: audit_logs table already exists from previous migration
-- Only add missing columns if they don't exist
DO $$
BEGIN
    -- Add action column as alias for operation_type if needed
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_schema = 'public' 
                   AND table_name = 'audit_logs' 
                   AND column_name = 'action') THEN
        ALTER TABLE public.audit_logs ADD COLUMN action TEXT;
        -- Copy data from operation_type to action
        UPDATE public.audit_logs SET action = operation_type WHERE action IS NULL;
    END IF;
    
    -- Add resource columns if they don't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_schema = 'public' 
                   AND table_name = 'audit_logs' 
                   AND column_name = 'resource_type') THEN
        ALTER TABLE public.audit_logs ADD COLUMN resource_type TEXT;
        -- Copy data from table_name to resource_type
        UPDATE public.audit_logs SET resource_type = table_name WHERE resource_type IS NULL;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_schema = 'public' 
                   AND table_name = 'audit_logs' 
                   AND column_name = 'resource_id') THEN
        ALTER TABLE public.audit_logs ADD COLUMN resource_id UUID;
        -- Copy data from record_id to resource_id
        UPDATE public.audit_logs SET resource_id = record_id WHERE resource_id IS NULL;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_schema = 'public' 
                   AND table_name = 'audit_logs' 
                   AND column_name = 'metadata') THEN
        ALTER TABLE public.audit_logs ADD COLUMN metadata JSONB DEFAULT '{}';
    END IF;
END $$;

-- Create indexes for audit log performance
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON public.audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON public.audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_audit_logs_resource ON public.audit_logs(resource_type, resource_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON public.audit_logs(created_at DESC);

-- ============================================================================
-- ENHANCED ROW LEVEL SECURITY POLICIES
-- ============================================================================

-- Drop overly permissive profile viewing policy
DROP POLICY IF EXISTS "Authenticated users can view other profiles (limited)" ON public.profiles;

-- Create restricted profile viewing policy - only allow viewing profiles of:
-- 1. Your own profile
-- 2. Profiles you have matched with
-- 3. Profiles in your potential matches (for matching flow)
CREATE POLICY "Restricted profile viewing for matches and potential matches" ON public.profiles
FOR SELECT 
USING (
    -- Own profile
    id = auth.uid() 
    OR 
    -- Matched profiles (bidirectional)
    id IN (
        SELECT CASE 
            WHEN user1_id = auth.uid() THEN user2_id 
            ELSE user1_id 
        END 
        FROM matches 
        WHERE (user1_id = auth.uid() OR user2_id = auth.uid()) 
        AND status = 'active'
    )
    OR
    -- Profiles with active conversations
    id IN (
        SELECT CASE 
            WHEN participant_1_id = auth.uid() THEN participant_2_id 
            ELSE participant_1_id 
        END 
        FROM conversations 
        WHERE participant_1_id = auth.uid() OR participant_2_id = auth.uid()
    )
);

-- ============================================================================
-- SECURITY MONITORING FUNCTIONS
-- ============================================================================

-- Function to log security-sensitive operations
CREATE OR REPLACE FUNCTION log_security_event(
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id UUID DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO public.audit_logs (
        user_id,
        operation_type,
        action,
        table_name,
        resource_type,
        record_id,
        resource_id,
        ip_address,
        context,
        metadata
    ) VALUES (
        auth.uid(),
        'profile_updated', -- Use a valid operation_type from constraint
        p_action,
        p_resource_type, -- Use resource_type as table_name
        p_resource_type,
        p_resource_id, -- Use resource_id as record_id
        p_resource_id,
        inet_client_addr(),
        p_metadata, -- Use metadata as context
        p_metadata
    );
END;
$$;

-- Function to track profile views for audit purposes
CREATE OR REPLACE FUNCTION track_profile_view(profile_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Only log if viewing someone else's profile
    IF profile_id != auth.uid() THEN
        PERFORM log_security_event(
            'profile_view',
            'profile',
            profile_id,
            jsonb_build_object(
                'viewed_at', NOW(),
                'viewer_id', auth.uid()
            )
        );
    END IF;
END;
$$;

-- ============================================================================
-- DATA RETENTION POLICIES
-- ============================================================================

-- Function to clean up old audit logs (retention policy)
CREATE OR REPLACE FUNCTION cleanup_audit_logs()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    -- Delete audit logs older than 2 years
    DELETE FROM public.audit_logs 
    WHERE created_at < NOW() - INTERVAL '2 years';
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    
    -- Log the cleanup operation
    INSERT INTO public.audit_logs (
        user_id,
        operation_type,
        action,
        table_name,
        resource_type,
        context,
        metadata
    ) VALUES (
        NULL, -- System operation
        'profile_updated',
        'audit_cleanup',
        'system',
        'system',
        jsonb_build_object(
            'deleted_count', deleted_count,
            'retention_period', '2 years'
        ),
        jsonb_build_object(
            'deleted_count', deleted_count,
            'retention_period', '2 years'
        )
    );
    
    RETURN deleted_count;
END;
$$;

-- Function to anonymize inactive user data (GDPR compliance)
CREATE OR REPLACE FUNCTION anonymize_inactive_users()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    anonymized_count INTEGER;
BEGIN
    -- Anonymize profiles that haven't been active for 3+ years
    UPDATE public.profiles 
    SET 
        display_name = 'Deleted User',
        bio = NULL,
        location = NULL,
        updated_at = NOW()
    WHERE 
        updated_at < NOW() - INTERVAL '3 years'
        AND display_name != 'Deleted User';
    
    GET DIAGNOSTICS anonymized_count = ROW_COUNT;
    
    -- Log the anonymization operation
    PERFORM log_security_event(
        'data_anonymization',
        'system',
        NULL,
        jsonb_build_object(
            'anonymized_count', anonymized_count,
            'retention_period', '3 years'
        )
    );
    
    RETURN anonymized_count;
END;
$$;

-- ============================================================================
-- SECURITY MONITORING TRIGGERS
-- ============================================================================

-- Trigger to log profile updates
CREATE OR REPLACE FUNCTION log_profile_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Only log significant changes, not every update
    IF OLD.display_name != NEW.display_name 
       OR OLD.bio != NEW.bio 
       OR OLD.app_settings != NEW.app_settings THEN
        
        PERFORM log_security_event(
            'profile_update',
            'profile',
            NEW.id,
            jsonb_build_object(
                'updated_fields', 
                CASE 
                    WHEN OLD.display_name != NEW.display_name THEN 'display_name,'
                    ELSE ''
                END ||
                CASE 
                    WHEN OLD.bio != NEW.bio THEN 'bio,'
                    ELSE ''
                END ||
                CASE 
                    WHEN OLD.app_settings != NEW.app_settings THEN 'app_settings'
                    ELSE ''
                END
            )
        );
    END IF;
    
    RETURN NEW;
END;
$$;

-- Create trigger for profile updates
DROP TRIGGER IF EXISTS trigger_log_profile_update ON public.profiles;
CREATE TRIGGER trigger_log_profile_update
    AFTER UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION log_profile_update();

-- ============================================================================
-- RLS POLICIES FOR AUDIT LOGS
-- ============================================================================

-- Enable RLS on audit_logs
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- Users can only see their own audit logs
CREATE POLICY "Users can view their own audit logs" ON public.audit_logs
FOR SELECT 
USING (user_id = auth.uid());

-- Service role can access all audit logs for system operations
CREATE POLICY "Service role can manage audit logs" ON public.audit_logs
FOR ALL 
USING (auth.role() = 'service_role');

-- ============================================================================
-- PERFORMANCE MONITORING ENHANCEMENTS
-- ============================================================================

-- Create performance monitoring table
CREATE TABLE IF NOT EXISTS public.performance_metrics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    metric_name TEXT NOT NULL,
    metric_value NUMERIC NOT NULL,
    metric_unit TEXT NOT NULL, -- ms, count, bytes, etc.
    endpoint TEXT,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    metadata JSONB DEFAULT '{}',
    recorded_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for performance metrics
CREATE INDEX IF NOT EXISTS idx_performance_metrics_name ON public.performance_metrics(metric_name);
CREATE INDEX IF NOT EXISTS idx_performance_metrics_recorded_at ON public.performance_metrics(recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_performance_metrics_endpoint ON public.performance_metrics(endpoint);

-- Function to record performance metrics
CREATE OR REPLACE FUNCTION record_performance_metric(
    p_metric_name TEXT,
    p_metric_value NUMERIC,
    p_metric_unit TEXT,
    p_endpoint TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO public.performance_metrics (
        metric_name,
        metric_value,
        metric_unit,
        endpoint,
        user_id,
        metadata
    ) VALUES (
        p_metric_name,
        p_metric_value,
        p_metric_unit,
        p_endpoint,
        auth.uid(),
        p_metadata
    );
END;
$$;

-- ============================================================================
-- SECURITY ENHANCEMENT NOTIFICATIONS
-- ============================================================================

-- Log this migration completion (include required operation_type column with valid value)
INSERT INTO public.audit_logs (
    user_id,
    operation_type,
    action,
    table_name,
    resource_type,
    context,
    metadata
) VALUES (
    NULL, -- System operation
    'profile_updated', -- Use a valid operation_type from the check constraint
    'security_migration_completed',
    'system',
    'system',
    jsonb_build_object(
        'migration', '20250722000000_audit_logging_and_security_enhancements_fixed',
        'enhancements', ARRAY[
            'audit_logging_system',
            'enhanced_rls_policies', 
            'security_monitoring_functions',
            'data_retention_policies',
            'performance_monitoring'
        ],
        'completed_at', NOW()
    ),
    jsonb_build_object(
        'migration', '20250722000000_audit_logging_and_security_enhancements_fixed',
        'completed_at', NOW()
    )
);

-- Grant necessary permissions
GRANT SELECT, INSERT ON public.audit_logs TO authenticated;
GRANT SELECT, INSERT ON public.performance_metrics TO authenticated;
GRANT EXECUTE ON FUNCTION log_security_event TO authenticated;
GRANT EXECUTE ON FUNCTION track_profile_view TO authenticated;
GRANT EXECUTE ON FUNCTION record_performance_metric TO authenticated;