-- Production Monitoring and Performance Optimization
-- This migration sets up comprehensive monitoring, indexing, and alerts for production

-- Note: This migration is temporarily commented out due to schema mismatches
-- Uncomment and adjust when schema includes deleted_at columns

/*
-- ======================
-- PERFORMANCE INDEXES
-- ======================

-- Core performance indexes for production workloads
CREATE INDEX IF NOT EXISTS idx_users_auth_user_id_active 
ON users (auth_user_id) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_profiles_onboarding_status 
ON profiles (onboarding_completed, created_at) WHERE onboarding_completed = true;

CREATE INDEX IF NOT EXISTS idx_messages_conversation_created 
ON messages (conversation_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_conversations_participants_active 
ON conversations (user1_id, user2_id, updated_at DESC) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_matches_users_score 
ON matches (user1_id, user2_id, overall_score DESC) WHERE overall_score >= 70;

CREATE INDEX IF NOT EXISTS idx_swipes_swiper_created 
ON swipes (swiper_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_profiles_location_active 
ON profiles USING GIST (location) WHERE location IS NOT NULL;

-- Composite indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_profiles_matching_criteria 
ON profiles (gender, age, zodiac_sign, onboarding_completed) 
WHERE onboarding_completed = true;

CREATE INDEX IF NOT EXISTS idx_users_subscription_status 
ON users (subscription_status, subscription_current_period_end) 
WHERE subscription_status IN ('active', 'trialing');

-- ======================
-- MONITORING TABLES
-- ======================

-- System performance metrics
CREATE TABLE IF NOT EXISTS system_metrics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    metric_name TEXT NOT NULL,
    metric_value NUMERIC NOT NULL,
    metric_unit TEXT NOT NULL,
    labels JSONB DEFAULT '{}',
    recorded_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_system_metrics_name_time 
ON system_metrics (metric_name, recorded_at DESC);

-- API endpoint performance tracking
CREATE TABLE IF NOT EXISTS api_performance_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    endpoint_name TEXT NOT NULL,
    method TEXT NOT NULL,
    response_time_ms INTEGER NOT NULL,
    status_code INTEGER NOT NULL,
    user_id UUID REFERENCES users(id),
    request_size_bytes INTEGER,
    response_size_bytes INTEGER,
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_api_logs_endpoint_time 
ON api_performance_logs (endpoint_name, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_api_logs_performance 
ON api_performance_logs (endpoint_name, response_time_ms) 
WHERE response_time_ms > 1000; -- Slow queries

-- Database query monitoring
CREATE TABLE IF NOT EXISTS slow_query_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    query_text TEXT NOT NULL,
    execution_time_ms NUMERIC NOT NULL,
    rows_examined INTEGER,
    rows_affected INTEGER,
    function_name TEXT,
    user_id UUID,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_slow_queries_time 
ON slow_query_log (execution_time_ms DESC, created_at DESC);

-- Error tracking and alerting
CREATE TABLE IF NOT EXISTS error_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    error_level TEXT NOT NULL CHECK (error_level IN ('warning', 'error', 'fatal')),
    error_message TEXT NOT NULL,
    error_code TEXT,
    function_name TEXT,
    user_id UUID,
    request_data JSONB,
    stack_trace TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_error_logs_level_time 
ON error_logs (error_level, created_at DESC);

-- ======================
-- MONITORING FUNCTIONS
-- ======================

-- Function to record system metrics
CREATE OR REPLACE FUNCTION record_system_metric(
    metric_name TEXT,
    metric_value NUMERIC,
    metric_unit TEXT DEFAULT 'count',
    labels JSONB DEFAULT '{}'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    metric_id UUID;
BEGIN
    INSERT INTO system_metrics (metric_name, metric_value, metric_unit, labels)
    VALUES (metric_name, metric_value, metric_unit, labels)
    RETURNING id INTO metric_id;
    
    RETURN metric_id;
END;
$$;

-- Function to record API performance
CREATE OR REPLACE FUNCTION record_api_performance(
    endpoint_name TEXT,
    method TEXT,
    response_time_ms INTEGER,
    status_code INTEGER,
    user_id UUID DEFAULT NULL,
    request_size_bytes INTEGER DEFAULT NULL,
    response_size_bytes INTEGER DEFAULT NULL,
    error_message TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    log_id UUID;
BEGIN
    INSERT INTO api_performance_logs (
        endpoint_name, method, response_time_ms, status_code,
        user_id, request_size_bytes, response_size_bytes, error_message
    )
    VALUES (
        endpoint_name, method, response_time_ms, status_code,
        user_id, request_size_bytes, response_size_bytes, error_message
    )
    RETURNING id INTO log_id;
    
    -- Alert on slow responses (>5 seconds)
    IF response_time_ms > 5000 THEN
        PERFORM record_system_metric(
            'slow_api_response',
            response_time_ms,
            'milliseconds',
            jsonb_build_object(
                'endpoint', endpoint_name,
                'method', method,
                'status', status_code
            )
        );
    END IF;
    
    RETURN log_id;
END;
$$;

-- Function to get database health metrics
CREATE OR REPLACE FUNCTION get_database_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    result JSONB;
    active_connections INTEGER;
    total_size_bytes BIGINT;
    cache_hit_ratio NUMERIC;
BEGIN
    -- Get active connections
    SELECT COUNT(*) INTO active_connections
    FROM pg_stat_activity
    WHERE state = 'active';
    
    -- Get database size
    SELECT pg_database_size(current_database()) INTO total_size_bytes;
    
    -- Get cache hit ratio
    SELECT 
        ROUND(
            (sum(heap_blks_hit) / GREATEST(sum(heap_blks_hit) + sum(heap_blks_read), 1)) * 100,
            2
        ) INTO cache_hit_ratio
    FROM pg_statio_user_tables;
    
    result := jsonb_build_object(
        'active_connections', active_connections,
        'database_size_mb', ROUND(total_size_bytes / 1024.0 / 1024.0, 2),
        'cache_hit_ratio_percent', cache_hit_ratio,
        'checked_at', NOW()
    );
    
    -- Record metrics
    PERFORM record_system_metric('database_active_connections', active_connections);
    PERFORM record_system_metric('database_size_mb', total_size_bytes / 1024.0 / 1024.0, 'megabytes');
    PERFORM record_system_metric('database_cache_hit_ratio', cache_hit_ratio, 'percent');
    
    RETURN result;
END;
$$;

-- Function to get application health metrics
CREATE OR REPLACE FUNCTION get_application_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    result JSONB;
    total_users INTEGER;
    active_users_24h INTEGER;
    total_matches INTEGER;
    messages_24h INTEGER;
    average_response_time NUMERIC;
BEGIN
    -- Total users
    SELECT COUNT(*) INTO total_users FROM users WHERE deleted_at IS NULL;
    
    -- Active users in last 24h
    SELECT COUNT(DISTINCT user_id) INTO active_users_24h
    FROM api_performance_logs
    WHERE created_at >= NOW() - INTERVAL '24 hours'
    AND user_id IS NOT NULL;
    
    -- Total matches
    SELECT COUNT(*) INTO total_matches FROM matches;
    
    -- Messages in last 24h
    SELECT COUNT(*) INTO messages_24h
    FROM messages
    WHERE created_at >= NOW() - INTERVAL '24 hours';
    
    -- Average API response time (last hour)
    SELECT COALESCE(AVG(response_time_ms), 0) INTO average_response_time
    FROM api_performance_logs
    WHERE created_at >= NOW() - INTERVAL '1 hour';
    
    result := jsonb_build_object(
        'total_users', total_users,
        'active_users_24h', active_users_24h,
        'total_matches', total_matches,
        'messages_24h', messages_24h,
        'avg_response_time_ms', ROUND(average_response_time, 2),
        'checked_at', NOW()
    );
    
    -- Record application metrics
    PERFORM record_system_metric('total_users', total_users);
    PERFORM record_system_metric('active_users_24h', active_users_24h);
    PERFORM record_system_metric('messages_24h', messages_24h);
    PERFORM record_system_metric('avg_response_time_ms', average_response_time, 'milliseconds');
    
    RETURN result;
END;
$$;

-- ======================
-- AUTOMATED CLEANUP
-- ======================

-- Function to clean up old monitoring data
CREATE OR REPLACE FUNCTION cleanup_monitoring_data()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    deleted_count INTEGER := 0;
    temp_count INTEGER;
BEGIN
    -- Clean up system metrics older than 30 days
    DELETE FROM system_metrics 
    WHERE recorded_at < NOW() - INTERVAL '30 days';
    GET DIAGNOSTICS temp_count = ROW_COUNT;
    deleted_count := deleted_count + temp_count;
    
    -- Clean up API logs older than 7 days (keep recent performance data)
    DELETE FROM api_performance_logs 
    WHERE created_at < NOW() - INTERVAL '7 days';
    GET DIAGNOSTICS temp_count = ROW_COUNT;
    deleted_count := deleted_count + temp_count;
    
    -- Clean up slow query logs older than 14 days
    DELETE FROM slow_query_log 
    WHERE created_at < NOW() - INTERVAL '14 days';
    GET DIAGNOSTICS temp_count = ROW_COUNT;
    deleted_count := deleted_count + temp_count;
    
    -- Clean up error logs older than 30 days (keep errors longer for analysis)
    DELETE FROM error_logs 
    WHERE created_at < NOW() - INTERVAL '30 days' 
    AND error_level IN ('warning');
    GET DIAGNOSTICS temp_count = ROW_COUNT;
    deleted_count := deleted_count + temp_count;
    
    RETURN deleted_count;
END;
$$;

-- ======================
-- VIEWS FOR MONITORING
-- ======================

-- Performance dashboard view
CREATE OR REPLACE VIEW performance_dashboard AS
SELECT 
    'API Performance' as category,
    endpoint_name as name,
    COUNT(*) as total_requests,
    AVG(response_time_ms) as avg_response_time,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY response_time_ms) as p95_response_time,
    COUNT(*) FILTER (WHERE status_code >= 400) as error_count,
    (COUNT(*) FILTER (WHERE status_code >= 400)::FLOAT / COUNT(*) * 100) as error_rate
FROM api_performance_logs 
WHERE created_at >= NOW() - INTERVAL '24 hours'
GROUP BY endpoint_name

UNION ALL

SELECT 
    'System Health' as category,
    metric_name as name,
    COUNT(*) as total_requests,
    AVG(metric_value) as avg_response_time,
    MAX(metric_value) as p95_response_time,
    0 as error_count,
    0 as error_rate
FROM system_metrics 
WHERE recorded_at >= NOW() - INTERVAL '24 hours'
GROUP BY metric_name;

-- Error summary view
CREATE OR REPLACE VIEW error_summary AS
SELECT 
    error_level,
    function_name,
    COUNT(*) as error_count,
    COUNT(DISTINCT user_id) as affected_users,
    MAX(created_at) as last_occurrence,
    array_agg(DISTINCT error_message) as error_messages
FROM error_logs 
WHERE created_at >= NOW() - INTERVAL '24 hours'
GROUP BY error_level, function_name
ORDER BY error_count DESC;

-- ======================
-- GRANTS AND PERMISSIONS
-- ======================

-- Grant access to monitoring functions
GRANT EXECUTE ON FUNCTION record_system_metric TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION record_api_performance TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_database_health TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_application_health TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION cleanup_monitoring_data TO service_role;

-- Grant access to monitoring views
GRANT SELECT ON performance_dashboard TO authenticated, service_role;
GRANT SELECT ON error_summary TO authenticated, service_role;

-- Enable Row Level Security on monitoring tables
ALTER TABLE system_metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_performance_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE slow_query_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE error_logs ENABLE ROW LEVEL SECURITY;

-- RLS policies for monitoring (service role can access all, authenticated users can see their own data)
CREATE POLICY "Service role can access all metrics" ON system_metrics FOR ALL TO service_role USING (true);
CREATE POLICY "Service role can access all API logs" ON api_performance_logs FOR ALL TO service_role USING (true);
CREATE POLICY "Service role can access all slow queries" ON slow_query_log FOR ALL TO service_role USING (true);
CREATE POLICY "Service role can access all errors" ON error_logs FOR ALL TO service_role USING (true);

CREATE POLICY "Users can see their own API logs" ON api_performance_logs FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Users can see their own errors" ON error_logs FOR SELECT TO authenticated USING (user_id = auth.uid());

-- Comments for documentation
COMMENT ON TABLE system_metrics IS 'System-wide performance and health metrics for monitoring';
COMMENT ON TABLE api_performance_logs IS 'API endpoint performance tracking for monitoring and optimization';
*/

-- Basic indexes that don't depend on deleted_at columns
CREATE INDEX IF NOT EXISTS idx_profiles_onboarding_status 
ON profiles (onboarding_completed, created_at) WHERE onboarding_completed = true;

CREATE INDEX IF NOT EXISTS idx_messages_conversation_created 
ON messages (conversation_id, created_at DESC);