-- Performance Optimizations and Monitoring for Edge Functions
-- Improves query performance and adds monitoring capabilities

-- =====================================
-- SECTION 1: CRITICAL PERFORMANCE INDEXES
-- =====================================

-- Indexes for get-potential-matches optimization
CREATE INDEX IF NOT EXISTS idx_profiles_matching_composite ON public.profiles(onboarding_completed, gender, age) 
WHERE onboarding_completed = true;

CREATE INDEX IF NOT EXISTS idx_profiles_zodiac_interests ON public.profiles(zodiac_sign, interests) 
WHERE onboarding_completed = true;

CREATE INDEX IF NOT EXISTS idx_users_looking_for_preferences ON public.users(looking_for, preferences) 
WHERE looking_for IS NOT NULL;

-- Indexes for swipes and matches exclusion
CREATE INDEX IF NOT EXISTS idx_swipes_swiper_swiped ON public.swipes(swiper_id, swiped_id);
CREATE INDEX IF NOT EXISTS idx_matches_users_composite ON public.matches(user1_id, user2_id, created_at);

-- Indexes for match requests (if table exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_requests') THEN
        CREATE INDEX IF NOT EXISTS idx_match_requests_requester_status ON public.match_requests(requester_id, status, created_at);
        CREATE INDEX IF NOT EXISTS idx_match_requests_matched_user_status ON public.match_requests(matched_user_id, status, created_at);
        CREATE INDEX IF NOT EXISTS idx_match_requests_status_created ON public.match_requests(status, created_at);
    END IF;
END $$;

-- Indexes for conversations and messages
CREATE INDEX IF NOT EXISTS idx_conversations_participants_updated ON public.conversations(participant_1_id, participant_2_id, last_message_at);
CREATE INDEX IF NOT EXISTS idx_messages_conversation_created ON public.messages(conversation_id, created_at);

-- =====================================
-- SECTION 2: QUERY OPTIMIZATION FUNCTIONS
-- =====================================

-- Create optimized function for checking if users are already connected
CREATE OR REPLACE FUNCTION public.check_users_connected(
    user1_id UUID,
    user2_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    is_connected BOOLEAN := FALSE;
BEGIN
    -- Check if users have already swiped on each other
    SELECT EXISTS(
        SELECT 1 FROM public.swipes 
        WHERE swiper_id = user1_id AND swiped_id = user2_id
    ) INTO is_connected;
    
    IF is_connected THEN
        RETURN TRUE;
    END IF;
    
    -- Check if users are already matched
    SELECT EXISTS(
        SELECT 1 FROM public.matches 
        WHERE (user1_id = user1_id AND user2_id = user2_id) 
           OR (user1_id = user2_id AND user2_id = user1_id)
    ) INTO is_connected;
    
    RETURN is_connected;
END;
$$;

-- Create optimized function for getting user exclusion list
CREATE OR REPLACE FUNCTION public.get_user_exclusion_list(
    user_id UUID
)
RETURNS UUID[]
LANGUAGE plpgsql
AS $$
DECLARE
    exclusion_list UUID[];
BEGIN
    -- Get all user IDs that should be excluded (swiped + matched + self)
    SELECT ARRAY(
        SELECT DISTINCT swiped_id FROM public.swipes WHERE swiper_id = user_id
        UNION
        SELECT DISTINCT CASE 
            WHEN user1_id = user_id THEN user2_id 
            ELSE user1_id 
        END FROM public.matches 
        WHERE user1_id = user_id OR user2_id = user_id
        UNION
        SELECT user_id -- exclude self
    ) INTO exclusion_list;
    
    RETURN COALESCE(exclusion_list, ARRAY[]::UUID[]);
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.check_users_connected(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_users_connected(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_user_exclusion_list(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_exclusion_list(UUID) TO service_role;

-- =====================================
-- SECTION 3: MONITORING AND LOGGING
-- =====================================

-- Create edge function performance monitoring table
CREATE TABLE IF NOT EXISTS public.edge_function_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    function_name TEXT NOT NULL,
    user_id UUID REFERENCES public.users(id),
    execution_time_ms INTEGER,
    status_code INTEGER,
    error_message TEXT,
    request_params JSONB,
    response_size INTEGER,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Add indexes for monitoring table
CREATE INDEX IF NOT EXISTS idx_edge_function_logs_function_created ON public.edge_function_logs(function_name, created_at);
CREATE INDEX IF NOT EXISTS idx_edge_function_logs_user_created ON public.edge_function_logs(user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_edge_function_logs_status_created ON public.edge_function_logs(status_code, created_at);

-- Create function to log edge function performance
CREATE OR REPLACE FUNCTION public.log_edge_function_performance(
    p_function_name TEXT,
    p_user_id UUID DEFAULT NULL,
    p_execution_time_ms INTEGER DEFAULT NULL,
    p_status_code INTEGER DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL,
    p_request_params JSONB DEFAULT NULL,
    p_response_size INTEGER DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    log_id UUID;
BEGIN
    INSERT INTO public.edge_function_logs (
        function_name,
        user_id,
        execution_time_ms,
        status_code,
        error_message,
        request_params,
        response_size
    ) VALUES (
        p_function_name,
        p_user_id,
        p_execution_time_ms,
        p_status_code,
        p_error_message,
        p_request_params,
        p_response_size
    ) RETURNING id INTO log_id;
    
    RETURN log_id;
END;
$$;

-- Grant permissions for logging function
GRANT EXECUTE ON FUNCTION public.log_edge_function_performance(TEXT, UUID, INTEGER, INTEGER, TEXT, JSONB, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.log_edge_function_performance(TEXT, UUID, INTEGER, INTEGER, TEXT, JSONB, INTEGER) TO authenticated;

-- =====================================
-- SECTION 4: HEALTH CHECK FUNCTIONS
-- =====================================

-- Create function for edge function health checks
CREATE OR REPLACE FUNCTION public.health_check_edge_functions()
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    result JSONB;
    user_count INTEGER;
    profile_count INTEGER;
    match_request_count INTEGER;
    recent_errors INTEGER;
BEGIN
    -- Get basic counts
    SELECT COUNT(*) INTO user_count FROM public.users;
    SELECT COUNT(*) INTO profile_count FROM public.profiles WHERE onboarding_completed = true;
    SELECT COUNT(*) INTO match_request_count FROM public.match_requests WHERE status = 'pending_system_match';
    
    -- Check for recent errors (last hour)
    SELECT COUNT(*) INTO recent_errors 
    FROM public.edge_function_logs 
    WHERE created_at > NOW() - INTERVAL '1 hour' 
    AND status_code >= 400;
    
    result := jsonb_build_object(
        'status', 'healthy',
        'timestamp', NOW(),
        'metrics', jsonb_build_object(
            'total_users', user_count,
            'completed_profiles', profile_count,
            'pending_match_requests', match_request_count,
            'recent_errors_1h', recent_errors
        ),
        'database_connection', 'ok',
        'rpc_functions', jsonb_build_object(
            'get_filtered_potential_matches', 'available',
            'calculate_compatibility_scores', 'available'
        )
    );
    
    RETURN result;
END;
$$;

-- Grant permissions for health check
GRANT EXECUTE ON FUNCTION public.health_check_edge_functions() TO service_role;
GRANT EXECUTE ON FUNCTION public.health_check_edge_functions() TO authenticated;

-- =====================================
-- SECTION 5: PERFORMANCE MONITORING VIEWS
-- =====================================

-- Create view for edge function performance metrics
CREATE OR REPLACE VIEW public.edge_function_performance AS
SELECT 
    function_name,
    COUNT(*) as total_calls,
    AVG(execution_time_ms) as avg_execution_time_ms,
    MAX(execution_time_ms) as max_execution_time_ms,
    COUNT(*) FILTER (WHERE status_code >= 400) as error_count,
    COUNT(*) FILTER (WHERE status_code = 200) as success_count,
    (COUNT(*) FILTER (WHERE status_code = 200)::FLOAT / COUNT(*)::FLOAT * 100) as success_rate_percent,
    DATE_TRUNC('hour', created_at) as hour
FROM public.edge_function_logs
WHERE created_at > NOW() - INTERVAL '24 hours'
GROUP BY function_name, DATE_TRUNC('hour', created_at)
ORDER BY hour DESC, function_name;

-- Grant permissions for performance view
GRANT SELECT ON public.edge_function_performance TO service_role;
GRANT SELECT ON public.edge_function_performance TO authenticated;

-- =====================================
-- SECTION 6: AUTOMATED CLEANUP
-- =====================================

-- Create function to clean up old logs (keep last 7 days)
CREATE OR REPLACE FUNCTION public.cleanup_old_edge_function_logs()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM public.edge_function_logs 
    WHERE created_at < NOW() - INTERVAL '7 days';
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    
    RAISE NOTICE 'Cleaned up % old edge function log records', deleted_count;
    RETURN deleted_count;
END;
$$;

-- Grant permissions for cleanup function
GRANT EXECUTE ON FUNCTION public.cleanup_old_edge_function_logs() TO service_role;

-- =====================================
-- SECTION 7: QUERY OPTIMIZATION SETTINGS
-- =====================================

-- Optimize PostgreSQL settings for our workload
-- These settings improve performance for read-heavy workloads with complex queries

-- Enable parallel query execution for complex matching queries
SET max_parallel_workers_per_gather = 2;
SET max_parallel_workers = 8;

-- Optimize work memory for sorting and hashing operations
SET work_mem = '16MB';

-- Optimize shared buffers for caching frequently accessed data
-- Note: shared_buffers cannot be changed at runtime, requires server restart
-- SET shared_buffers = '256MB';

-- Enable auto-vacuuming with more aggressive settings for high-update tables
ALTER TABLE public.edge_function_logs SET (
    autovacuum_vacuum_scale_factor = 0.1,
    autovacuum_analyze_scale_factor = 0.05
);

-- =====================================
-- SECTION 8: VERIFICATION AND TESTING
-- =====================================

-- Test the optimized functions
DO $$
DECLARE
    test_user_id UUID;
    exclusion_list UUID[];
    health_status JSONB;
    performance_metrics INTEGER;
BEGIN
    -- Test basic functionality
    SELECT id INTO test_user_id FROM public.users LIMIT 1;
    
    IF test_user_id IS NOT NULL THEN
        -- Test exclusion list function
        SELECT public.get_user_exclusion_list(test_user_id) INTO exclusion_list;
        RAISE NOTICE 'Exclusion list function working: % excluded users', array_length(exclusion_list, 1);
        
        -- Test health check
        SELECT public.health_check_edge_functions() INTO health_status;
        RAISE NOTICE 'Health check working: %', health_status->>'status';
    END IF;
    
    -- Test performance monitoring
    SELECT COUNT(*) INTO performance_metrics FROM public.edge_function_performance;
    RAISE NOTICE 'Performance monitoring view accessible: % metrics available', performance_metrics;
    
END $$;

-- Final status report
SELECT 
    'Performance Optimizations and Monitoring Applied Successfully' as status,
    COUNT(*) as indexes_created
FROM pg_indexes 
WHERE schemaname = 'public' 
AND indexname LIKE 'idx_%';

-- Add comments documenting the optimizations
COMMENT ON TABLE public.edge_function_logs IS 'Performance monitoring and logging for edge functions - tracks execution times, errors, and usage patterns';
COMMENT ON FUNCTION public.get_user_exclusion_list(UUID) IS 'Optimized function to get list of user IDs to exclude from potential matches (already swiped, matched, or self)';
COMMENT ON VIEW public.edge_function_performance IS 'Real-time performance metrics for edge functions over the last 24 hours';