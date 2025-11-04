-- PHASE 3 SECURITY: Security Monitoring and Intrusion Detection Schema
-- Creates tables for comprehensive security event logging and monitoring

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";

-- Security events table for comprehensive logging
CREATE TABLE IF NOT EXISTS security_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type VARCHAR(100) NOT NULL,
    severity VARCHAR(20) NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    ip_address INET,
    user_agent TEXT,
    endpoint VARCHAR(200),
    method VARCHAR(10),
    request_id VARCHAR(100),
    details JSONB NOT NULL DEFAULT '{}',
    context JSONB DEFAULT '{}',
    threat_score INTEGER DEFAULT 0 CHECK (threat_score >= 0 AND threat_score <= 100),
    blocked BOOLEAN DEFAULT FALSE,
    action_taken VARCHAR(100),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Security alerts table for triggered incidents
CREATE TABLE IF NOT EXISTS security_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_type VARCHAR(100) NOT NULL,
    severity VARCHAR(20) NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    title VARCHAR(200),
    description TEXT,
    data JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    resolved BOOLEAN DEFAULT FALSE,
    resolved_at TIMESTAMPTZ,
    resolved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    resolution_notes TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Blocked IPs table for IP reputation management
CREATE TABLE IF NOT EXISTS blocked_ips (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ip_address INET NOT NULL UNIQUE,
    blocked_at TIMESTAMPTZ DEFAULT NOW(),
    blocked_until TIMESTAMPTZ,
    threat_score INTEGER DEFAULT 0 CHECK (threat_score >= 0 AND threat_score <= 100),
    reasons TEXT[] DEFAULT '{}',
    blocked_by VARCHAR(50) DEFAULT 'system',
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- User behavior analytics table
CREATE TABLE IF NOT EXISTS user_behavior_analytics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    total_events INTEGER DEFAULT 0,
    risk_score INTEGER DEFAULT 0 CHECK (risk_score >= 0 AND risk_score <= 100),
    anomalies TEXT[] DEFAULT '{}',
    event_types JSONB DEFAULT '{}',
    ip_addresses INET[] DEFAULT '{}',
    user_agents TEXT[] DEFAULT '{}',
    last_activity TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, date)
);

-- Security metrics aggregation table
CREATE TABLE IF NOT EXISTS security_metrics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    metric_type VARCHAR(100) NOT NULL,
    metric_name VARCHAR(100) NOT NULL,
    metric_value DECIMAL(10,2) NOT NULL,
    metric_unit VARCHAR(20),
    tags JSONB DEFAULT '{}',
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Password policy violations table
CREATE TABLE IF NOT EXISTS password_policy_violations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    email VARCHAR(255),
    violation_type VARCHAR(100) NOT NULL,
    password_strength_score INTEGER,
    violation_details JSONB DEFAULT '{}',
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- API version usage tracking
CREATE TABLE IF NOT EXISTS api_version_usage (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requested_version VARCHAR(20) NOT NULL,
    resolved_version VARCHAR(20) NOT NULL,
    endpoint VARCHAR(200) NOT NULL,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    ip_address INET,
    is_deprecated BOOLEAN DEFAULT FALSE,
    compatibility_mode TEXT[] DEFAULT '{}',
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_security_events_timestamp ON security_events(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_security_events_user_id ON security_events(user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_security_events_ip ON security_events(ip_address) WHERE ip_address IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_security_events_type ON security_events(event_type);
CREATE INDEX IF NOT EXISTS idx_security_events_severity ON security_events(severity);
CREATE INDEX IF NOT EXISTS idx_security_events_threat_score ON security_events(threat_score DESC);
CREATE INDEX IF NOT EXISTS idx_security_events_blocked ON security_events(blocked) WHERE blocked = TRUE;
CREATE INDEX IF NOT EXISTS idx_security_events_composite ON security_events(event_type, severity, timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_security_alerts_severity ON security_alerts(severity);
CREATE INDEX IF NOT EXISTS idx_security_alerts_resolved ON security_alerts(resolved) WHERE resolved = FALSE;
CREATE INDEX IF NOT EXISTS idx_security_alerts_created_at ON security_alerts(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_blocked_ips_ip ON blocked_ips(ip_address);
CREATE INDEX IF NOT EXISTS idx_blocked_ips_blocked_until ON blocked_ips(blocked_until);
CREATE INDEX IF NOT EXISTS idx_blocked_ips_threat_score ON blocked_ips(threat_score DESC);

CREATE INDEX IF NOT EXISTS idx_user_behavior_user_date ON user_behavior_analytics(user_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_user_behavior_risk_score ON user_behavior_analytics(risk_score DESC);
CREATE INDEX IF NOT EXISTS idx_user_behavior_last_activity ON user_behavior_analytics(last_activity DESC);

CREATE INDEX IF NOT EXISTS idx_security_metrics_type_name ON security_metrics(metric_type, metric_name);
CREATE INDEX IF NOT EXISTS idx_security_metrics_timestamp ON security_metrics(timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_password_violations_user ON password_policy_violations(user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_password_violations_email ON password_policy_violations(email);
CREATE INDEX IF NOT EXISTS idx_password_violations_type ON password_policy_violations(violation_type);
CREATE INDEX IF NOT EXISTS idx_password_violations_created_at ON password_policy_violations(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_api_version_usage_version ON api_version_usage(requested_version, resolved_version);
CREATE INDEX IF NOT EXISTS idx_api_version_usage_endpoint ON api_version_usage(endpoint);
CREATE INDEX IF NOT EXISTS idx_api_version_usage_deprecated ON api_version_usage(is_deprecated) WHERE is_deprecated = TRUE;
CREATE INDEX IF NOT EXISTS idx_api_version_usage_timestamp ON api_version_usage(timestamp DESC);

-- Partial indexes for efficient queries
-- Use a function that is immutable by avoiding NOW() in predicate; use age comparison instead is still STABLE. Replace partial with non-partial index for compatibility in migrations.
CREATE INDEX IF NOT EXISTS idx_security_events_recent_critical 
ON security_events(severity, timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_security_events_recent_high_threat 
ON security_events(threat_score DESC, timestamp DESC);

-- Row Level Security (RLS) policies
ALTER TABLE security_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE blocked_ips ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_behavior_analytics ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE password_policy_violations ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_version_usage ENABLE ROW LEVEL SECURITY;

-- Service role policies (for system operations)
CREATE POLICY "Service role can manage security events" ON security_events
FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY "Service role can manage security alerts" ON security_alerts
FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY "Service role can manage blocked IPs" ON blocked_ips
FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY "Service role can manage user behavior analytics" ON user_behavior_analytics
FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY "Service role can manage security metrics" ON security_metrics
FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY "Service role can manage password violations" ON password_policy_violations
FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY "Service role can manage API version usage" ON api_version_usage
FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Ensure admin flag exists on profiles for admin policy checks
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS is_admin BOOLEAN DEFAULT false;

-- Admin access policies (for security dashboard)
CREATE POLICY "Admins can read security events" ON security_events
FOR SELECT TO authenticated USING (
    EXISTS (
        SELECT 1 FROM profiles 
        WHERE profiles.id = auth.uid() 
        AND profiles.is_admin = true
    )
);

CREATE POLICY "Admins can read security alerts" ON security_alerts
FOR SELECT TO authenticated USING (
    EXISTS (
        SELECT 1 FROM profiles 
        WHERE profiles.id = auth.uid() 
        AND profiles.is_admin = true
    )
);

CREATE POLICY "Admins can manage security alerts" ON security_alerts
FOR UPDATE TO authenticated USING (
    EXISTS (
        SELECT 1 FROM profiles 
        WHERE profiles.id = auth.uid() 
        AND profiles.is_admin = true
    )
) WITH CHECK (
    EXISTS (
        SELECT 1 FROM profiles 
        WHERE profiles.id = auth.uid() 
        AND profiles.is_admin = true
    )
);

-- User access policies (users can see their own events)
CREATE POLICY "Users can read their security events" ON security_events
FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY "Users can read their behavior analytics" ON user_behavior_analytics
FOR SELECT TO authenticated USING (user_id = auth.uid());

-- Trigger function to update timestamps
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Triggers for updating timestamps
CREATE TRIGGER update_security_events_updated_at 
    BEFORE UPDATE ON security_events 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_security_alerts_updated_at 
    BEFORE UPDATE ON security_alerts 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_blocked_ips_updated_at 
    BEFORE UPDATE ON blocked_ips 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_user_behavior_analytics_updated_at 
    BEFORE UPDATE ON user_behavior_analytics 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Function to clean up old security events (retention policy)
CREATE OR REPLACE FUNCTION cleanup_old_security_events()
RETURNS void AS $$
BEGIN
    -- Delete security events older than 90 days
    DELETE FROM security_events 
    WHERE created_at < NOW() - INTERVAL '90 days';
    
    -- Delete resolved security alerts older than 30 days
    DELETE FROM security_alerts 
    WHERE resolved = true AND resolved_at < NOW() - INTERVAL '30 days';
    
    -- Delete expired blocked IPs
    DELETE FROM blocked_ips 
    WHERE blocked_until IS NOT NULL AND blocked_until < NOW();
    
    -- Delete old security metrics (keep 30 days)
    DELETE FROM security_metrics 
    WHERE created_at < NOW() - INTERVAL '30 days';
    
    -- Delete old API version usage data (keep 60 days)
    DELETE FROM api_version_usage 
    WHERE created_at < NOW() - INTERVAL '60 days';
    
    -- Aggregate old user behavior data (keep daily aggregates for 1 year)
    DELETE FROM user_behavior_analytics 
    WHERE created_at < NOW() - INTERVAL '1 year';
END;
$$ LANGUAGE plpgsql;

-- Function to get security dashboard metrics
CREATE OR REPLACE FUNCTION get_security_dashboard_metrics(
    time_range INTERVAL DEFAULT '24 hours'
)
RETURNS JSON AS $$
DECLARE
    result JSON;
BEGIN
    WITH recent_events AS (
        SELECT * FROM security_events 
        WHERE timestamp > NOW() - time_range
    ),
    event_summary AS (
        SELECT 
            COUNT(*) as total_events,
            COUNT(*) FILTER (WHERE severity = 'critical') as critical_events,
            COUNT(*) FILTER (WHERE severity = 'high') as high_events,
            COUNT(*) FILTER (WHERE severity = 'medium') as medium_events,
            COUNT(*) FILTER (WHERE severity = 'low') as low_events,
            COUNT(*) FILTER (WHERE blocked = true) as blocked_events,
            AVG(threat_score)::DECIMAL(5,2) as avg_threat_score,
            COUNT(DISTINCT user_id) as affected_users,
            COUNT(DISTINCT ip_address) as unique_ips
        FROM recent_events
    ),
    top_threats AS (
        SELECT 
            event_type,
            COUNT(*) as count,
            AVG(threat_score)::DECIMAL(5,2) as avg_score
        FROM recent_events 
        GROUP BY event_type 
        ORDER BY count DESC 
        LIMIT 10
    ),
    blocked_ips_count AS (
        SELECT COUNT(*) as active_blocked_ips
        FROM blocked_ips 
        WHERE blocked_until IS NULL OR blocked_until > NOW()
    ),
    unresolved_alerts AS (
        SELECT COUNT(*) as unresolved_alerts
        FROM security_alerts 
        WHERE resolved = false
    )
    SELECT json_build_object(
        'summary', (SELECT row_to_json(event_summary) FROM event_summary),
        'top_threats', (SELECT json_agg(row_to_json(top_threats)) FROM top_threats),
        'blocked_ips', (SELECT active_blocked_ips FROM blocked_ips_count),
        'unresolved_alerts', (SELECT unresolved_alerts FROM unresolved_alerts),
        'generated_at', NOW()
    ) INTO result;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get user risk assessment
CREATE OR REPLACE FUNCTION get_user_risk_assessment(target_user_id UUID)
RETURNS JSON AS $$
DECLARE
    result JSON;
BEGIN
    WITH user_events AS (
        SELECT * FROM security_events 
        WHERE user_id = target_user_id 
        AND timestamp > NOW() - INTERVAL '7 days'
    ),
    risk_summary AS (
        SELECT 
            COUNT(*) as total_events,
            AVG(threat_score)::DECIMAL(5,2) as avg_threat_score,
            MAX(threat_score) as max_threat_score,
            COUNT(*) FILTER (WHERE severity IN ('high', 'critical')) as high_risk_events,
            COUNT(*) FILTER (WHERE blocked = true) as blocked_events,
            COUNT(DISTINCT ip_address) as unique_ips,
            COUNT(DISTINCT DATE(timestamp)) as active_days
        FROM user_events
    ),
    recent_behavior AS (
        SELECT * FROM user_behavior_analytics 
        WHERE user_id = target_user_id 
        ORDER BY date DESC 
        LIMIT 7
    )
    SELECT json_build_object(
        'user_id', target_user_id,
        'risk_summary', (SELECT row_to_json(risk_summary) FROM risk_summary),
        'recent_behavior', (SELECT json_agg(row_to_json(recent_behavior)) FROM recent_behavior),
        'assessment_date', NOW()
    ) INTO result;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant necessary permissions
GRANT USAGE ON SCHEMA public TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role;

-- Create a scheduled job to cleanup old data (if pg_cron is available)
-- SELECT cron.schedule('cleanup-security-data', '0 2 * * *', 'SELECT cleanup_old_security_events();');

COMMENT ON TABLE security_events IS 'Comprehensive security event logging for intrusion detection and monitoring';
COMMENT ON TABLE security_alerts IS 'Security incidents and alerts triggered by the monitoring system';
COMMENT ON TABLE blocked_ips IS 'IP reputation and blocking system for threat mitigation';
COMMENT ON TABLE user_behavior_analytics IS 'User behavior analysis and anomaly detection data';
COMMENT ON TABLE security_metrics IS 'Aggregated security metrics for dashboard and reporting';
COMMENT ON TABLE password_policy_violations IS 'Password policy violation tracking';
COMMENT ON TABLE api_version_usage IS 'API version usage tracking and deprecation monitoring';