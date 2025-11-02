-- Comprehensive Security Monitoring and Logging System
-- Real-time security monitoring, anomaly detection, and threat analysis
-- Created: 2025-08-10
-- Purpose: Production-ready security monitoring for photo upload system

-- 1. Alter existing security events table to add missing columns
DO $$ BEGIN
    -- Add event_category column if it doesn't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'event_category') THEN
        ALTER TABLE security_events ADD COLUMN event_category VARCHAR(30);
    END IF;

    -- Add investigation_status column if it doesn't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'investigation_status') THEN
        ALTER TABLE security_events ADD COLUMN investigation_status VARCHAR(20) DEFAULT 'OPEN'
            CHECK (investigation_status IN ('OPEN', 'INVESTIGATING', 'RESOLVED', 'FALSE_POSITIVE', 'ESCALATED'));
    END IF;

    -- Add other missing columns that may not exist in earlier version
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'session_id') THEN
        ALTER TABLE security_events ADD COLUMN session_id TEXT;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'request_method') THEN
        ALTER TABLE security_events ADD COLUMN request_method VARCHAR(10);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'request_path') THEN
        ALTER TABLE security_events ADD COLUMN request_path TEXT;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'request_headers') THEN
        ALTER TABLE security_events ADD COLUMN request_headers JSONB;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'request_body_hash') THEN
        ALTER TABLE security_events ADD COLUMN request_body_hash TEXT;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'response_code') THEN
        ALTER TABLE security_events ADD COLUMN response_code INTEGER;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'geolocation') THEN
        ALTER TABLE security_events ADD COLUMN geolocation JSONB;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'flagged_by') THEN
        ALTER TABLE security_events ADD COLUMN flagged_by TEXT[];
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'analyst_notes') THEN
        ALTER TABLE security_events ADD COLUMN analyst_notes TEXT;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                   AND table_name = 'security_events'
                   AND column_name = 'resolved_at') THEN
        ALTER TABLE security_events ADD COLUMN resolved_at TIMESTAMP WITH TIME ZONE;
    END IF;

    -- Rename columns if they have different names in earlier migration
    IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public'
              AND table_name = 'security_events'
              AND column_name = 'timestamp')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public'
                      AND table_name = 'security_events'
                      AND column_name = 'created_at') THEN
        -- Note: created_at already exists from July migration, so skip this
        NULL;
    END IF;
END $$;

-- Create security events table if it doesn't exist (for fresh installations)
CREATE TABLE IF NOT EXISTS security_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type VARCHAR(50) NOT NULL,
  event_category VARCHAR(30) NOT NULL,
  severity VARCHAR(20) NOT NULL DEFAULT 'INFO',
  user_id UUID,
  session_id TEXT,
  ip_address INET,
  user_agent TEXT,
  request_method VARCHAR(10),
  request_path TEXT,
  request_headers JSONB,
  request_body_hash TEXT,
  response_code INTEGER,
  event_details JSONB NOT NULL DEFAULT '{}'::jsonb,
  geolocation JSONB,
  threat_score INTEGER DEFAULT 0,
  flagged_by TEXT[],
  investigation_status VARCHAR(20) DEFAULT 'OPEN',
  analyst_notes TEXT,
  resolved_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  -- Constraints
  CONSTRAINT valid_severity CHECK (severity IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL', 'INFO', 'WARNING')),
  CONSTRAINT valid_investigation_status CHECK (investigation_status IN ('OPEN', 'INVESTIGATING', 'RESOLVED', 'FALSE_POSITIVE', 'ESCALATED')),
  CONSTRAINT valid_threat_score CHECK (threat_score BETWEEN 0 AND 100)
);

-- Create indexes for performance and monitoring
CREATE INDEX IF NOT EXISTS idx_security_events_type ON security_events(event_type);
CREATE INDEX IF NOT EXISTS idx_security_events_category ON security_events(event_category);
CREATE INDEX IF NOT EXISTS idx_security_events_severity ON security_events(severity);
CREATE INDEX IF NOT EXISTS idx_security_events_user_id ON security_events(user_id);
CREATE INDEX IF NOT EXISTS idx_security_events_created_at ON security_events(created_at);
CREATE INDEX IF NOT EXISTS idx_security_events_ip_address ON security_events(ip_address);
CREATE INDEX IF NOT EXISTS idx_security_events_threat_score ON security_events(threat_score) WHERE threat_score > 50;
CREATE INDEX IF NOT EXISTS idx_security_events_unresolved ON security_events(created_at) WHERE investigation_status = 'OPEN';

-- 2. Create comprehensive security event logging function
CREATE OR REPLACE FUNCTION log_security_event(
  p_event_type TEXT,
  p_event_category TEXT,
  p_severity TEXT DEFAULT 'INFO',
  p_user_id UUID DEFAULT NULL,
  p_session_id TEXT DEFAULT NULL,
  p_ip_address INET DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL,
  p_request_method TEXT DEFAULT NULL,
  p_request_path TEXT DEFAULT NULL,
  p_request_headers JSONB DEFAULT '{}'::jsonb,
  p_response_code INTEGER DEFAULT NULL,
  p_event_details JSONB DEFAULT '{}'::jsonb,
  p_threat_score INTEGER DEFAULT 0
) RETURNS UUID AS $$
DECLARE
  v_event_id UUID;
  v_geolocation JSONB := '{}'::jsonb;
BEGIN
  -- Basic geolocation info (simplified - in production use proper IP geolocation service)
  IF p_ip_address IS NOT NULL THEN
    v_geolocation := jsonb_build_object(
      'ip', p_ip_address::text,
      'type', CASE 
        WHEN host(p_ip_address) ~ '^(10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.)' THEN 'private'
        WHEN host(p_ip_address) ~ '^(127\.|0\.|169\.254\.)' THEN 'local'
        ELSE 'public'
      END
    );
  END IF;
  
  -- Calculate request body hash if present
  DECLARE
    v_request_body_hash TEXT := NULL;
  BEGIN
    IF p_event_details ? 'request_body' THEN
      v_request_body_hash := encode(digest(p_event_details->>'request_body', 'sha256'), 'hex');
    END IF;
  END;
  
  -- Insert security event
  INSERT INTO security_events (
    event_type,
    event_category,
    severity,
    user_id,
    session_id,
    ip_address,
    user_agent,
    request_method,
    request_path,
    request_headers,
    request_body_hash,
    response_code,
    event_details,
    geolocation,
    threat_score,
    created_at
  ) VALUES (
    p_event_type,
    p_event_category,
    p_severity,
    p_user_id,
    p_session_id,
    p_ip_address,
    p_user_agent,
    p_request_method,
    p_request_path,
    p_request_headers,
    v_request_body_hash,
    p_response_code,
    p_event_details,
    v_geolocation,
    p_threat_score,
    NOW()
  ) RETURNING id INTO v_event_id;
  
  -- Auto-flag high threat score events
  IF p_threat_score > 70 THEN
    UPDATE security_events SET
      flagged_by = ARRAY['automated_threat_detection'],
      investigation_status = 'INVESTIGATING'
    WHERE id = v_event_id;
  END IF;
  
  -- Also log to security audit log for critical events
  IF p_severity IN ('CRITICAL', 'HIGH') THEN
    INSERT INTO security_audit_log (
      user_id,
      action,
      resource_type,
      resource_id,
      details,
      severity,
      created_at
    ) VALUES (
      p_user_id,
      'SECURITY_EVENT',
      'security_monitoring',
      v_event_id::text,
      jsonb_build_object(
        'event_type', p_event_type,
        'threat_score', p_threat_score,
        'event_category', p_event_category
      ),
      p_severity,
      NOW()
    );
  END IF;
  
  RETURN v_event_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Enable RLS
ALTER TABLE security_events ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist (from July migration)
DROP POLICY IF EXISTS "Users can view own security events" ON security_events;
DROP POLICY IF EXISTS "Service role can manage security events" ON security_events;

-- Users can see their own security events
CREATE POLICY "Users can view own security events" ON security_events
FOR SELECT TO authenticated USING (user_id = auth.uid());

-- Service role can manage all security data
CREATE POLICY "Service role can manage security events" ON security_events
FOR ALL TO service_role USING (true);

-- Grant table access
GRANT SELECT ON security_events TO authenticated;
GRANT ALL ON security_events TO service_role;

-- Grant function permissions
GRANT EXECUTE ON FUNCTION log_security_event(TEXT, TEXT, TEXT, UUID, TEXT, INET, TEXT, TEXT, TEXT, JSONB, INTEGER, JSONB, INTEGER) TO authenticated, service_role;

-- Security monitoring system migration complete - Part 1