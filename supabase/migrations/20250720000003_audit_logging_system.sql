-- AUDIT LOGGING SYSTEM FOR SENSITIVE OPERATIONS
-- Track all critical operations for security and debugging

-- =====================================
-- SECTION 1: CREATE AUDIT LOG TABLE
-- =====================================

CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- User and session info
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    session_id TEXT,
    ip_address INET,
    user_agent TEXT,
    -- Operation details
    operation_type TEXT NOT NULL,
    table_name TEXT,
    record_id UUID,
    -- Data snapshots
    old_data JSONB,
    new_data JSONB,
    -- Additional context
    context JSONB DEFAULT '{}'::jsonb,
    error_message TEXT,
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Indexes for common queries
    CHECK (operation_type IN (
        'match_request_created',
        'match_request_updated',
        'match_created',
        'match_updated',
        'swipe_recorded',
        'conversation_created',
        'message_sent',
        'profile_updated',
        'auth_login',
        'auth_logout',
        'subscription_changed',
        'error_occurred'
    ))
);

-- Create indexes for performance
CREATE INDEX idx_audit_logs_user_id ON public.audit_logs(user_id);
CREATE INDEX idx_audit_logs_operation_type ON public.audit_logs(operation_type);
CREATE INDEX idx_audit_logs_table_name ON public.audit_logs(table_name);
CREATE INDEX idx_audit_logs_created_at ON public.audit_logs(created_at DESC);
CREATE INDEX idx_audit_logs_record_id ON public.audit_logs(record_id);

-- =====================================
-- SECTION 2: AUDIT TRIGGER FUNCTION
-- =====================================

CREATE OR REPLACE FUNCTION public.audit_trigger_function()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID;
    v_operation_type TEXT;
    v_old_data JSONB;
    v_new_data JSONB;
BEGIN
    -- Get current user ID
    v_user_id := COALESCE(auth.uid(), (current_setting('app.current_user_id', true))::UUID);
    
    -- Determine operation type
    CASE TG_OP
        WHEN 'INSERT' THEN
            v_operation_type := TG_TABLE_NAME || '_created';
            v_new_data := to_jsonb(NEW);
            v_old_data := NULL;
        WHEN 'UPDATE' THEN
            v_operation_type := TG_TABLE_NAME || '_updated';
            v_new_data := to_jsonb(NEW);
            v_old_data := to_jsonb(OLD);
        WHEN 'DELETE' THEN
            v_operation_type := TG_TABLE_NAME || '_deleted';
            v_new_data := NULL;
            v_old_data := to_jsonb(OLD);
    END CASE;
    
    -- Insert audit log
    INSERT INTO public.audit_logs (
        user_id,
        operation_type,
        table_name,
        record_id,
        old_data,
        new_data,
        context
    ) VALUES (
        v_user_id,
        v_operation_type,
        TG_TABLE_NAME,
        COALESCE(NEW.id, OLD.id),
        v_old_data,
        v_new_data,
        jsonb_build_object(
            'trigger_op', TG_OP,
            'trigger_name', TG_NAME,
            'schema_name', TG_TABLE_SCHEMA
        )
    );
    
    -- Return appropriate value
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

-- =====================================
-- SECTION 3: CREATE AUDIT TRIGGERS
-- =====================================

-- Audit match_requests
CREATE TRIGGER audit_match_requests
    AFTER INSERT OR UPDATE OR DELETE ON public.match_requests
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_trigger_function();

-- Audit matches
CREATE TRIGGER audit_matches
    AFTER INSERT OR UPDATE OR DELETE ON public.matches
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_trigger_function();

-- Audit swipes
CREATE TRIGGER audit_swipes
    AFTER INSERT ON public.swipes
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_trigger_function();

-- Audit conversations
CREATE TRIGGER audit_conversations
    AFTER INSERT OR UPDATE ON public.conversations
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_trigger_function();

-- Audit messages (be careful with performance)
CREATE TRIGGER audit_messages
    AFTER INSERT ON public.messages
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_trigger_function();

-- =====================================
-- SECTION 4: MANUAL AUDIT FUNCTION
-- =====================================

CREATE OR REPLACE FUNCTION public.log_audit_event(
    p_operation_type TEXT,
    p_table_name TEXT DEFAULT NULL,
    p_record_id UUID DEFAULT NULL,
    p_context JSONB DEFAULT '{}'::jsonb,
    p_error_message TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_audit_id UUID;
BEGIN
    INSERT INTO public.audit_logs (
        user_id,
        operation_type,
        table_name,
        record_id,
        context,
        error_message
    ) VALUES (
        auth.uid(),
        p_operation_type,
        p_table_name,
        p_record_id,
        p_context,
        p_error_message
    ) RETURNING id INTO v_audit_id;
    
    RETURN v_audit_id;
END;
$$;

-- =====================================
-- SECTION 5: AUDIT LOG RLS POLICIES
-- =====================================

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- Users can only view their own audit logs
CREATE POLICY "Users can view own audit logs"
    ON public.audit_logs
    FOR SELECT
    USING (auth.uid() = user_id);

-- Service role has full access
CREATE POLICY "Service role has full audit access"
    ON public.audit_logs
    FOR ALL
    USING (auth.jwt()->>'role' = 'service_role')
    WITH CHECK (auth.jwt()->>'role' = 'service_role');

-- =====================================
-- SECTION 6: CLEANUP FUNCTION
-- =====================================

CREATE OR REPLACE FUNCTION public.cleanup_old_audit_logs()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_deleted_count INTEGER;
BEGIN
    -- Delete audit logs older than 90 days
    DELETE FROM public.audit_logs
    WHERE created_at < NOW() - INTERVAL '90 days';
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    
    -- Log the cleanup operation
    PERFORM public.log_audit_event(
        'audit_cleanup',
        'audit_logs',
        NULL,
        jsonb_build_object('deleted_count', v_deleted_count)
    );
    
    RETURN v_deleted_count;
END;
$$;

-- =====================================
-- SECTION 7: PERMISSIONS
-- =====================================

GRANT SELECT ON public.audit_logs TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_audit_event TO authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_old_audit_logs TO service_role;

-- =====================================
-- SECTION 8: COMMENTS
-- =====================================

COMMENT ON TABLE public.audit_logs IS 'Comprehensive audit trail for all sensitive operations';
COMMENT ON FUNCTION public.audit_trigger_function IS 'Generic trigger function for audit logging';
COMMENT ON FUNCTION public.log_audit_event IS 'Manual audit logging for custom events';
COMMENT ON FUNCTION public.cleanup_old_audit_logs IS 'Removes audit logs older than 90 days';