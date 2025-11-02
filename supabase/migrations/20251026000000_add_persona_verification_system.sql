-- Persona Identity Verification System Migration
-- Adds Persona-specific verification schema for selfie + liveness detection
-- This replaces/extends the legacy photo_verification system

-- Add Persona-specific columns to profiles table
ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS persona_inquiry_id TEXT,
ADD COLUMN IF NOT EXISTS persona_verification_status TEXT DEFAULT 'not_started' CHECK (
  persona_verification_status IN ('not_started', 'in_progress', 'pending', 'approved', 'declined', 'failed', 'requires_retry')
),
ADD COLUMN IF NOT EXISTS persona_verified_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS persona_liveness_score DECIMAL(3,2) CHECK (
  persona_liveness_score IS NULL OR (persona_liveness_score >= 0 AND persona_liveness_score <= 1)
);

-- Create index for Persona verification status queries
CREATE INDEX IF NOT EXISTS idx_profiles_persona_verification_status
ON profiles(persona_verification_status);

CREATE INDEX IF NOT EXISTS idx_profiles_persona_inquiry_id
ON profiles(persona_inquiry_id);

-- Create Persona verification logs table for audit trail
CREATE TABLE IF NOT EXISTS persona_verification_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  inquiry_id TEXT NOT NULL,
  status TEXT NOT NULL,
  session_token TEXT,
  error_message TEXT,
  liveness_score DECIMAL(3,2),
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for Persona verification logs
CREATE INDEX IF NOT EXISTS idx_persona_verification_logs_user_id
ON persona_verification_logs(user_id);

CREATE INDEX IF NOT EXISTS idx_persona_verification_logs_inquiry_id
ON persona_verification_logs(inquiry_id);

CREATE INDEX IF NOT EXISTS idx_persona_verification_logs_status
ON persona_verification_logs(status);

CREATE INDEX IF NOT EXISTS idx_persona_verification_logs_created_at
ON persona_verification_logs(created_at DESC);

-- Create Persona webhook events table for tracking all webhooks
CREATE TABLE IF NOT EXISTS persona_webhook_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  inquiry_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  event_data JSONB NOT NULL,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  processed BOOLEAN DEFAULT FALSE,
  processed_at TIMESTAMP WITH TIME ZONE,
  error_message TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for webhook events
CREATE INDEX IF NOT EXISTS idx_persona_webhook_events_inquiry_id
ON persona_webhook_events(inquiry_id);

CREATE INDEX IF NOT EXISTS idx_persona_webhook_events_processed
ON persona_webhook_events(processed, created_at);

CREATE INDEX IF NOT EXISTS idx_persona_webhook_events_user_id
ON persona_webhook_events(user_id);

-- Create function to get Persona verification statistics
CREATE OR REPLACE FUNCTION get_persona_verification_statistics()
RETURNS TABLE (
  total_users BIGINT,
  verified_users BIGINT,
  pending_verifications BIGINT,
  failed_verifications BIGINT,
  in_progress BIGINT,
  not_started BIGINT,
  avg_liveness_score DECIMAL(3,2),
  verification_rate DECIMAL(5,2),
  last_24h_verifications BIGINT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    COUNT(*) as total_users,
    COUNT(*) FILTER (WHERE persona_verification_status = 'approved') as verified_users,
    COUNT(*) FILTER (WHERE persona_verification_status = 'pending') as pending_verifications,
    COUNT(*) FILTER (WHERE persona_verification_status IN ('failed', 'declined')) as failed_verifications,
    COUNT(*) FILTER (WHERE persona_verification_status = 'in_progress') as in_progress,
    COUNT(*) FILTER (WHERE persona_verification_status = 'not_started') as not_started,
    AVG(persona_liveness_score) as avg_liveness_score,
    CASE
      WHEN COUNT(*) > 0 THEN
        ROUND((COUNT(*) FILTER (WHERE persona_verification_status = 'approved')::DECIMAL / COUNT(*)) * 100, 2)
      ELSE 0
    END as verification_rate,
    (SELECT COUNT(*) FROM persona_verification_logs
     WHERE created_at >= NOW() - INTERVAL '24 hours') as last_24h_verifications
  FROM profiles;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create function to handle verification status updates
CREATE OR REPLACE FUNCTION update_persona_verification_status(
  p_user_id UUID,
  p_inquiry_id TEXT,
  p_status TEXT,
  p_liveness_score DECIMAL DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
  UPDATE profiles
  SET
    persona_inquiry_id = p_inquiry_id,
    persona_verification_status = p_status,
    persona_liveness_score = p_liveness_score,
    persona_verified_at = CASE
      WHEN p_status = 'approved' THEN NOW()
      ELSE persona_verified_at
    END,
    updated_at = NOW()
  WHERE id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create function to clean up old verification logs (for maintenance)
CREATE OR REPLACE FUNCTION cleanup_old_persona_logs(days_to_keep INTEGER DEFAULT 90)
RETURNS INTEGER AS $$
DECLARE
  deleted_count INTEGER;
BEGIN
  -- Clean up old verification logs
  DELETE FROM persona_verification_logs
  WHERE created_at < CURRENT_TIMESTAMP - INTERVAL '1 day' * days_to_keep
  AND status IN ('failed', 'requires_retry');

  GET DIAGNOSTICS deleted_count = ROW_COUNT;

  -- Clean up processed webhook events older than retention period
  DELETE FROM persona_webhook_events
  WHERE created_at < CURRENT_TIMESTAMP - INTERVAL '1 day' * days_to_keep
  AND processed = TRUE;

  RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger to log verification status changes
CREATE OR REPLACE FUNCTION log_persona_status_change()
RETURNS TRIGGER AS $$
BEGIN
  -- Only log if status actually changed
  IF OLD.persona_verification_status IS DISTINCT FROM NEW.persona_verification_status THEN
    INSERT INTO persona_verification_logs (
      user_id,
      inquiry_id,
      status,
      liveness_score
    ) VALUES (
      NEW.id,
      COALESCE(NEW.persona_inquiry_id, 'unknown'),
      NEW.persona_verification_status,
      NEW.persona_liveness_score
    );
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_log_persona_status_change ON profiles;
CREATE TRIGGER trigger_log_persona_status_change
  AFTER UPDATE OF persona_verification_status ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION log_persona_status_change();

-- Enable RLS on new tables
ALTER TABLE persona_verification_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE persona_webhook_events ENABLE ROW LEVEL SECURITY;

-- Create RLS policies for verification logs
-- Users can only see their own verification logs
CREATE POLICY "Users can view their own Persona verification logs"
ON persona_verification_logs FOR SELECT
USING (auth.uid() = user_id);

-- Users can insert their own verification logs
CREATE POLICY "Users can insert their own Persona verification logs"
ON persona_verification_logs FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Service role can manage all verification logs
CREATE POLICY "Service role can manage Persona verification logs"
ON persona_verification_logs FOR ALL
USING (auth.role() = 'service_role');

-- Create RLS policies for webhook events
-- Only service role can access webhook events
CREATE POLICY "Service role can manage Persona webhook events"
ON persona_webhook_events FOR ALL
USING (auth.role() = 'service_role');

-- Grant necessary permissions
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT ALL ON TABLE persona_verification_logs TO authenticated;
GRANT ALL ON TABLE persona_webhook_events TO service_role;
GRANT EXECUTE ON FUNCTION get_persona_verification_statistics() TO service_role;
GRANT EXECUTE ON FUNCTION update_persona_verification_status(UUID, TEXT, TEXT, DECIMAL) TO service_role;
GRANT EXECUTE ON FUNCTION cleanup_old_persona_logs(INTEGER) TO service_role;

-- Add comments for documentation
COMMENT ON TABLE persona_verification_logs IS 'Audit trail for all Persona identity verification attempts';
COMMENT ON TABLE persona_webhook_events IS 'Log of all webhook events received from Persona';
COMMENT ON COLUMN profiles.persona_inquiry_id IS 'Persona Inquiry ID for this user''s verification';
COMMENT ON COLUMN profiles.persona_verification_status IS 'Current Persona verification status';
COMMENT ON COLUMN profiles.persona_verified_at IS 'Timestamp when user was successfully verified';
COMMENT ON COLUMN profiles.persona_liveness_score IS 'Liveness detection score from Persona (0.0-1.0)';
COMMENT ON FUNCTION get_persona_verification_statistics() IS 'Returns comprehensive statistics about Persona verification system';
COMMENT ON FUNCTION cleanup_old_persona_logs(INTEGER) IS 'Maintenance function to clean up old verification logs and webhook events';

-- Create view for admin dashboard
CREATE OR REPLACE VIEW persona_verification_summary AS
SELECT
  p.id,
  p.display_name,
  p.persona_inquiry_id,
  p.persona_verification_status,
  p.persona_verified_at,
  p.persona_liveness_score,
  p.created_at as profile_created_at,
  (SELECT COUNT(*) FROM persona_verification_logs WHERE user_id = p.id) as total_attempts
FROM profiles p
WHERE p.persona_inquiry_id IS NOT NULL
ORDER BY p.updated_at DESC;

COMMENT ON VIEW persona_verification_summary IS 'Admin dashboard view of all Persona verifications';

-- Grant access to the view
GRANT SELECT ON persona_verification_summary TO service_role;
