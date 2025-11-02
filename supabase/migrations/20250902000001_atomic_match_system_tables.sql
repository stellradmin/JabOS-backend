-- Migration: Atomic Match System Support Tables
-- Description: Creates tables needed for comprehensive error handling, logging, and audit trails

-- Create error logs table for comprehensive error tracking
CREATE TABLE IF NOT EXISTS public.error_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    error_code TEXT NOT NULL,
    message TEXT NOT NULL,
    severity TEXT NOT NULL CHECK (severity IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
    context JSONB DEFAULT '{}',
    details JSONB DEFAULT '{}',
    correlation_id TEXT,
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create match logs table for structured logging
CREATE TABLE IF NOT EXISTS public.match_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    level TEXT NOT NULL CHECK (level IN ('DEBUG', 'INFO', 'WARN', 'ERROR', 'CRITICAL')),
    category TEXT NOT NULL CHECK (category IN ('SWIPE', 'MATCH_CREATION', 'MATCH_STATUS', 'CONVERSATION', 'TRANSACTION', 'VALIDATION', 'NOTIFICATION', 'COMPATIBILITY', 'ANALYTICS', 'SECURITY', 'PERFORMANCE')),
    operation TEXT NOT NULL,
    message TEXT NOT NULL,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    match_id UUID,
    conversation_id UUID,
    swipe_id UUID,
    correlation_id TEXT,
    session_id TEXT,
    request_id TEXT,
    context JSONB DEFAULT '{}',
    metadata JSONB DEFAULT '{}',
    duration INTEGER, -- in milliseconds
    error_details JSONB,
    tags TEXT[] DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create match status audit table for tracking status changes
CREATE TABLE IF NOT EXISTS public.match_status_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id UUID REFERENCES public.matches(id) ON DELETE CASCADE,
    from_status TEXT NOT NULL,
    to_status TEXT NOT NULL,
    reason TEXT,
    triggered_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    metadata JSONB DEFAULT '{}',
    transition_timestamp TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create match creation logs table for audit trail
CREATE TABLE IF NOT EXISTS public.match_creation_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL DEFAULT 'match_created',
    match_id UUID REFERENCES public.matches(id) ON DELETE CASCADE,
    source_type TEXT NOT NULL CHECK (source_type IN ('mutual_swipe', 'match_request', 'admin_created')),
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    match_request_id UUID,
    conversation_id UUID,
    metadata JSONB DEFAULT '{}',
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_error_logs_correlation_id ON public.error_logs(correlation_id);
CREATE INDEX IF NOT EXISTS idx_error_logs_timestamp ON public.error_logs(timestamp);
CREATE INDEX IF NOT EXISTS idx_error_logs_severity ON public.error_logs(severity);

CREATE INDEX IF NOT EXISTS idx_match_logs_correlation_id ON public.match_logs(correlation_id);
CREATE INDEX IF NOT EXISTS idx_match_logs_timestamp ON public.match_logs(timestamp);
CREATE INDEX IF NOT EXISTS idx_match_logs_level ON public.match_logs(level);
CREATE INDEX IF NOT EXISTS idx_match_logs_category ON public.match_logs(category);
CREATE INDEX IF NOT EXISTS idx_match_logs_user_id ON public.match_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_match_logs_match_id ON public.match_logs(match_id);

CREATE INDEX IF NOT EXISTS idx_match_status_audit_match_id ON public.match_status_audit(match_id);
CREATE INDEX IF NOT EXISTS idx_match_status_audit_timestamp ON public.match_status_audit(transition_timestamp);
CREATE INDEX IF NOT EXISTS idx_match_status_audit_triggered_by ON public.match_status_audit(triggered_by);

CREATE INDEX IF NOT EXISTS idx_match_creation_logs_match_id ON public.match_creation_logs(match_id);
CREATE INDEX IF NOT EXISTS idx_match_creation_logs_timestamp ON public.match_creation_logs(timestamp);
CREATE INDEX IF NOT EXISTS idx_match_creation_logs_source_type ON public.match_creation_logs(source_type);

-- Enable RLS on all tables
ALTER TABLE public.error_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.match_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.match_status_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.match_creation_logs ENABLE ROW LEVEL SECURITY;

-- RLS policies for error_logs (admin access only)
CREATE POLICY "Service role can manage error logs" ON public.error_logs
    FOR ALL USING (auth.role() = 'service_role');

-- RLS policies for match_logs (users can view their own logs, service role can manage all)
CREATE POLICY "Users can view their own match logs" ON public.match_logs
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Service role can manage all match logs" ON public.match_logs
    FOR ALL USING (auth.role() = 'service_role');

-- RLS policies for match_status_audit (users can view audit for their matches)
CREATE POLICY "Users can view status audit for their matches" ON public.match_status_audit
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.matches m
            WHERE m.id = match_id
            AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
        )
    );

CREATE POLICY "Service role can manage match status audit" ON public.match_status_audit
    FOR ALL USING (auth.role() = 'service_role');

-- RLS policies for match_creation_logs (users can view logs for their matches)
CREATE POLICY "Users can view creation logs for their matches" ON public.match_creation_logs
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.matches m
            WHERE m.id = match_id
            AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
        )
    );

CREATE POLICY "Service role can manage match creation logs" ON public.match_creation_logs
    FOR ALL USING (auth.role() = 'service_role');

-- Add updated_at triggers for audit tables
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add comments for documentation
COMMENT ON TABLE public.error_logs IS 'Comprehensive error logging for match operations';
COMMENT ON TABLE public.match_logs IS 'Structured logging for all match system operations';
COMMENT ON TABLE public.match_status_audit IS 'Audit trail for match status changes';
COMMENT ON TABLE public.match_creation_logs IS 'Audit trail for match creation events';

COMMENT ON COLUMN public.error_logs.correlation_id IS 'Links related errors across operations';
COMMENT ON COLUMN public.match_logs.correlation_id IS 'Links related log entries across operations';
COMMENT ON COLUMN public.match_logs.duration IS 'Operation duration in milliseconds';
COMMENT ON COLUMN public.match_status_audit.metadata IS 'Additional context for status change';
COMMENT ON COLUMN public.match_creation_logs.source_type IS 'How the match was created: mutual_swipe, match_request, or admin_created';

-- Grant necessary permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON public.error_logs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.match_logs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.match_status_audit TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.match_creation_logs TO service_role;

GRANT SELECT ON public.match_logs TO authenticated;
GRANT SELECT ON public.match_status_audit TO authenticated;
GRANT SELECT ON public.match_creation_logs TO authenticated;