-- Distributed Rate Limiting Infrastructure
-- Creates table and functions for database-backed rate limiting in production environments

-- Rate limiting entries table
CREATE TABLE IF NOT EXISTS public.rate_limit_entries (
    id BIGSERIAL PRIMARY KEY,
    identifier TEXT NOT NULL,
    window_start TIMESTAMPTZ NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 1,
    limit_value INTEGER NOT NULL,
    reset_time TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for efficient lookups and cleanup
CREATE INDEX IF NOT EXISTS idx_rate_limit_identifier_window 
ON public.rate_limit_entries (identifier, window_start);

CREATE INDEX IF NOT EXISTS idx_rate_limit_reset_time 
ON public.rate_limit_entries (reset_time);

-- RLS policies for rate limiting table
ALTER TABLE public.rate_limit_entries ENABLE ROW LEVEL SECURITY;

-- Only service role can manage rate limiting entries
CREATE POLICY "Service role can manage rate limit entries" ON public.rate_limit_entries
FOR ALL USING (auth.role() = 'service_role');

-- RPC function to check and update rate limits atomically
CREATE OR REPLACE FUNCTION public.check_and_update_rate_limit(
    p_identifier TEXT,
    p_window_start TIMESTAMPTZ,
    p_limit INTEGER,
    p_reset_time TIMESTAMPTZ
) RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    current_count INTEGER := 0;
    result_json JSON;
BEGIN
    -- Upsert the rate limit entry
    INSERT INTO public.rate_limit_entries (
        identifier,
        window_start,
        request_count,
        limit_value,
        reset_time,
        updated_at
    ) VALUES (
        p_identifier,
        p_window_start,
        1,
        p_limit,
        p_reset_time,
        NOW()
    )
    ON CONFLICT (identifier, window_start)
    DO UPDATE SET
        request_count = rate_limit_entries.request_count + 1,
        updated_at = NOW()
    RETURNING request_count INTO current_count;

    -- Return the current count and limit information
    result_json := json_build_object(
        'count', current_count,
        'limit', p_limit,
        'reset_time', EXTRACT(EPOCH FROM p_reset_time) * 1000,
        'allowed', current_count <= p_limit
    );

    RETURN result_json;
END;
$$;

-- Function to clean up expired rate limit entries
CREATE OR REPLACE FUNCTION public.cleanup_expired_rate_limits()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM public.rate_limit_entries
    WHERE reset_time < NOW() - INTERVAL '1 hour';
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    
    RETURN deleted_count;
END;
$$;

-- Grant execute permissions to authenticated and service roles
GRANT EXECUTE ON FUNCTION public.check_and_update_rate_limit(TEXT, TIMESTAMPTZ, INTEGER, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_and_update_rate_limit(TEXT, TIMESTAMPTZ, INTEGER, TIMESTAMPTZ) TO service_role;

GRANT EXECUTE ON FUNCTION public.cleanup_expired_rate_limits() TO service_role;

-- Create a unique constraint to prevent duplicate entries
ALTER TABLE public.rate_limit_entries 
ADD CONSTRAINT unique_identifier_window 
UNIQUE (identifier, window_start);

-- Add a comment explaining the table purpose
COMMENT ON TABLE public.rate_limit_entries IS 'Stores rate limiting data for distributed environments. Each entry tracks request counts within specific time windows for different identifiers (user IDs, IP addresses, etc.)';

COMMENT ON FUNCTION public.check_and_update_rate_limit(TEXT, TIMESTAMPTZ, INTEGER, TIMESTAMPTZ) IS 'Atomically checks current rate limit status and increments the counter. Returns JSON with current count, limit, and whether the request should be allowed.';

COMMENT ON FUNCTION public.cleanup_expired_rate_limits() IS 'Removes expired rate limit entries to prevent table bloat. Should be called periodically via cron or scheduled job.';