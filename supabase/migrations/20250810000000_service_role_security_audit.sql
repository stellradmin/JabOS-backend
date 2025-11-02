-- Service Role Security Audit and Restriction Migration
-- Implements least-privilege access patterns and audits service role usage  
-- Created: 2025-08-10
-- Purpose: Critical security fix for service role over-privileging

-- SECURITY ISSUE: Service role key being used inappropriately in Edge Functions
-- Service role has unrestricted access - should only be used for specific admin operations

-- 1. Create function to validate legitimate service role usage

CREATE OR REPLACE FUNCTION is_legitimate_service_role_operation(
  operation_type TEXT,
  table_name TEXT,
  user_context UUID DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Define legitimate service role operations
  CASE operation_type
    -- Account deletion requires service role (deletes across multiple tables)
    WHEN 'DELETE_USER_ACCOUNT' THEN
      RETURN table_name IN ('users', 'profiles', 'conversations', 'messages', 'matches', 'swipes', 'auth.users');
      
    -- System maintenance operations
    WHEN 'SYSTEM_MAINTENANCE' THEN
      RETURN table_name IN ('processed_stripe_webhooks', 'photo_verification_logs', 'security_audit_log');
      
    -- Webhook processing (payment updates)
    WHEN 'WEBHOOK_PROCESSING' THEN
      RETURN table_name IN ('users', 'processed_stripe_webhooks');
      
    -- Photo verification (ML analysis results)  
    WHEN 'PHOTO_VERIFICATION' THEN
      RETURN table_name IN ('photo_verification_logs', 'profiles');
      
    -- Security monitoring
    WHEN 'SECURITY_MONITORING' THEN
      RETURN table_name IN ('security_audit_log', 'rate_limit_log');
      
    ELSE
      -- All other operations should use user context, not service role
      RETURN false;
  END CASE;
END;
$$;

-- 2. Create service role usage audit log

CREATE TABLE IF NOT EXISTS service_role_usage_audit (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  function_name VARCHAR(100) NOT NULL,
  operation_type VARCHAR(50) NOT NULL,
  table_accessed VARCHAR(100),
  user_context UUID,
  is_legitimate BOOLEAN NOT NULL DEFAULT false,
  justification TEXT,
  client_ip INET,
  request_id VARCHAR(100),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Add indexes for performance and monitoring
CREATE INDEX IF NOT EXISTS idx_service_role_audit_function ON service_role_usage_audit(function_name, created_at);
CREATE INDEX IF NOT EXISTS idx_service_role_audit_legitimate ON service_role_usage_audit(is_legitimate, created_at);
CREATE INDEX IF NOT EXISTS idx_service_role_audit_operation ON service_role_usage_audit(operation_type, table_accessed);

-- 3. Create function to log service role usage (called from Edge Functions)

CREATE OR REPLACE FUNCTION log_service_role_usage(
  function_name TEXT,
  operation_type TEXT,
  table_accessed TEXT DEFAULT NULL,
  user_context UUID DEFAULT NULL,
  justification TEXT DEFAULT NULL,
  client_ip TEXT DEFAULT NULL,
  request_id TEXT DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  is_legitimate_usage BOOLEAN;
BEGIN
  -- Check if this is a legitimate service role operation
  is_legitimate_usage := is_legitimate_service_role_operation(
    operation_type, 
    table_accessed, 
    user_context
  );

  -- Log the usage
  INSERT INTO service_role_usage_audit (
    function_name,
    operation_type,
    table_accessed,
    user_context,
    is_legitimate,
    justification,
    client_ip,
    request_id,
    created_at
  ) VALUES (
    function_name,
    operation_type,
    table_accessed,
    user_context,
    is_legitimate_usage,
    justification,
    client_ip::INET,
    request_id,
    NOW()
  );

  -- Alert if illegitimate usage detected
  IF NOT is_legitimate_usage THEN
    INSERT INTO security_audit_log (
      user_id,
      action,
      resource_type,
      resource_id,
      details,
      severity,
      ip_address,
      created_at
    ) VALUES (
      user_context,
      'ILLEGITIMATE_SERVICE_ROLE_USAGE',
      'edge_function',
      function_name,
      jsonb_build_object(
        'operation_type', operation_type,
        'table_accessed', table_accessed,
        'justification', justification,
        'request_id', request_id
      ),
      'CRITICAL',
      client_ip::INET,
      NOW()
    );
  END IF;
END;
$$;

-- 4. Create monitoring views for service role usage

-- View to identify potentially problematic service role usage
CREATE OR REPLACE VIEW service_role_security_violations AS
SELECT 
  function_name,
  operation_type,
  table_accessed,
  COUNT(*) as violation_count,
  array_agg(DISTINCT user_context) as affected_users,
  MIN(created_at) as first_violation,
  MAX(created_at) as last_violation,
  array_agg(DISTINCT justification) as justifications_given
FROM service_role_usage_audit
WHERE is_legitimate = false
AND created_at >= NOW() - INTERVAL '7 days'
GROUP BY function_name, operation_type, table_accessed
ORDER BY violation_count DESC, last_violation DESC;

-- View for legitimate service role usage patterns
CREATE OR REPLACE VIEW service_role_usage_summary AS
SELECT 
  function_name,
  operation_type,
  COUNT(*) as total_usage,
  COUNT(*) FILTER (WHERE is_legitimate = true) as legitimate_usage,
  COUNT(*) FILTER (WHERE is_legitimate = false) as illegitimate_usage,
  ROUND(
    (COUNT(*) FILTER (WHERE is_legitimate = true)::decimal / COUNT(*)) * 100, 
    2
  ) as legitimacy_percentage,
  DATE_TRUNC('hour', created_at) as hour_bucket
FROM service_role_usage_audit
WHERE created_at >= NOW() - INTERVAL '24 hours'
GROUP BY function_name, operation_type, DATE_TRUNC('hour', created_at)
ORDER BY hour_bucket DESC, illegitimate_usage DESC;

-- 5. Set up RLS policies for service role audit tables

ALTER TABLE service_role_usage_audit ENABLE ROW LEVEL SECURITY;

-- Service role can manage its own audit logs
CREATE POLICY "Service role can manage usage audit" ON service_role_usage_audit
FOR ALL TO service_role USING (true);

-- Authenticated users can read audit logs for transparency
CREATE POLICY "Users can read service role audit" ON service_role_usage_audit  
FOR SELECT TO authenticated USING (true);

-- 6. Grant appropriate permissions

GRANT EXECUTE ON FUNCTION log_service_role_usage(TEXT, TEXT, TEXT, UUID, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION is_legitimate_service_role_operation(TEXT, TEXT, UUID) TO service_role;

GRANT SELECT ON service_role_security_violations TO service_role;
GRANT SELECT ON service_role_usage_summary TO service_role;

-- 7. Create cleanup function for audit logs

CREATE OR REPLACE FUNCTION cleanup_service_role_audit()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Delete audit logs older than 30 days
  DELETE FROM service_role_usage_audit
  WHERE created_at < NOW() - INTERVAL '30 days';

  -- Log cleanup action
  INSERT INTO service_role_usage_audit (
    function_name,
    operation_type,
    is_legitimate,
    justification,
    created_at
  ) VALUES (
    'system_cleanup',
    'AUDIT_CLEANUP',
    true,
    'Automated cleanup of old service role audit logs',
    NOW()
  );
END;
$$;

-- 8. Create validation function for current service role usage

CREATE OR REPLACE FUNCTION validate_current_service_role_usage()
RETURNS TABLE(
  function_name TEXT,
  issue_severity TEXT,
  issue_description TEXT,
  recommendation TEXT
) AS $$
BEGIN
  -- Check for functions with high illegitimate usage
  RETURN QUERY
  SELECT 
    sra.function_name::TEXT,
    'HIGH'::TEXT as issue_severity,
    'High rate of illegitimate service role usage detected'::TEXT as issue_description,
    'Review function implementation and migrate to user-context pattern'::TEXT as recommendation
  FROM service_role_usage_audit sra
  WHERE sra.created_at >= NOW() - INTERVAL '24 hours'
  AND sra.is_legitimate = false
  GROUP BY sra.function_name
  HAVING COUNT(*) > 10;

  -- Check for functions without proper justification
  RETURN QUERY  
  SELECT 
    sra.function_name::TEXT,
    'MEDIUM'::TEXT as issue_severity,
    'Service role usage without proper justification'::TEXT as issue_description,
    'Add proper justification and audit logging to function'::TEXT as recommendation
  FROM service_role_usage_audit sra
  WHERE sra.created_at >= NOW() - INTERVAL '24 hours'
  AND (sra.justification IS NULL OR length(sra.justification) < 10)
  GROUP BY sra.function_name
  HAVING COUNT(*) > 5;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant access to validation function
GRANT EXECUTE ON FUNCTION validate_current_service_role_usage() TO service_role;
GRANT EXECUTE ON FUNCTION cleanup_service_role_audit() TO service_role;

-- 9. Add comments for documentation
COMMENT ON TABLE service_role_usage_audit IS 'Audit log for Edge Function service role usage to identify over-privileged operations';
COMMENT ON FUNCTION log_service_role_usage(TEXT, TEXT, TEXT, UUID, TEXT, TEXT, TEXT) IS 'Function to log service role usage from Edge Functions for security monitoring';
COMMENT ON FUNCTION is_legitimate_service_role_operation(TEXT, TEXT, UUID) IS 'Validates whether a service role operation is legitimate based on defined security policies';
COMMENT ON VIEW service_role_security_violations IS 'Monitoring view for illegitimate service role usage patterns';

-- Migration complete - service role audit system deployed