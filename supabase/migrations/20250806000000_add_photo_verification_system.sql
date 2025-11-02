-- Photo Verification System Database Schema
-- This migration adds support for photo verification and authenticity tracking

-- Add photo verification columns to profiles table
ALTER TABLE profiles 
ADD COLUMN IF NOT EXISTS photo_verification_status VARCHAR(20) DEFAULT 'unverified' CHECK (
  photo_verification_status IN ('unverified', 'verified', 'rejected', 'pending_review')
),
ADD COLUMN IF NOT EXISTS photo_verification_date TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS photo_verification_confidence DECIMAL(3,2) CHECK (
  photo_verification_confidence >= 0 AND photo_verification_confidence <= 1
);

-- Create index for verification status queries
CREATE INDEX IF NOT EXISTS idx_profiles_verification_status 
ON profiles(photo_verification_status);

-- Create photo verification logs table for audit trail
CREATE TABLE IF NOT EXISTS photo_verification_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  image_url TEXT NOT NULL,
  image_uri TEXT, -- Original URI from device
  verification_result JSONB NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for photo verification logs
CREATE INDEX IF NOT EXISTS idx_photo_verification_logs_user_id 
ON photo_verification_logs(user_id);

CREATE INDEX IF NOT EXISTS idx_photo_verification_logs_created_at 
ON photo_verification_logs(created_at);

-- Create manual review queue table
CREATE TABLE IF NOT EXISTS photo_manual_review_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  image_url TEXT NOT NULL,
  verification_log_id UUID REFERENCES photo_verification_logs(id),
  review_status VARCHAR(20) DEFAULT 'pending' CHECK (
    review_status IN ('pending', 'approved', 'rejected', 'escalated')
  ),
  reviewer_id UUID REFERENCES auth.users(id),
  review_notes TEXT,
  priority INTEGER DEFAULT 1 CHECK (priority BETWEEN 1 AND 5),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  reviewed_at TIMESTAMP WITH TIME ZONE,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for manual review queue
CREATE INDEX IF NOT EXISTS idx_photo_manual_review_queue_status 
ON photo_manual_review_queue(review_status);

CREATE INDEX IF NOT EXISTS idx_photo_manual_review_queue_priority 
ON photo_manual_review_queue(priority, created_at);

CREATE INDEX IF NOT EXISTS idx_photo_manual_review_queue_user_id 
ON photo_manual_review_queue(user_id);

-- Create photo verification settings table for admin configuration
CREATE TABLE IF NOT EXISTS photo_verification_settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  setting_key VARCHAR(100) NOT NULL UNIQUE,
  setting_value JSONB NOT NULL,
  description TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Insert default verification settings
INSERT INTO photo_verification_settings (setting_key, setting_value, description) VALUES
('face_detection_enabled', 'true', 'Enable face detection for photo verification'),
('blur_detection_enabled', 'true', 'Enable blur detection for photo verification'),
('liveness_check_enabled', 'true', 'Enable liveness detection for photo verification'),
('min_quality_score', '0.6', 'Minimum quality score for photo verification (0.0 - 1.0)'),
('max_faces_allowed', '1', 'Maximum number of faces allowed in profile photos'),
('manual_review_threshold', '0.4', 'Confidence threshold below which photos go to manual review'),
('auto_approve_threshold', '0.6', 'Confidence threshold above which photos are auto-approved')
ON CONFLICT (setting_key) DO NOTHING;

-- Create function to automatically add photos to manual review queue
CREATE OR REPLACE FUNCTION add_to_manual_review_queue()
RETURNS TRIGGER AS $$
BEGIN
  -- If verification status is pending_review, add to manual review queue
  IF NEW.photo_verification_status = 'pending_review' AND 
     (OLD IS NULL OR OLD.photo_verification_status != 'pending_review') THEN
    
    INSERT INTO photo_manual_review_queue (
      user_id,
      profile_id,
      image_url,
      priority
    ) VALUES (
      NEW.id,
      NEW.id,
      NEW.avatar_url,
      CASE 
        WHEN NEW.photo_verification_confidence < 0.3 THEN 5 -- High priority
        WHEN NEW.photo_verification_confidence < 0.5 THEN 3 -- Medium priority
        ELSE 1 -- Low priority
      END
    );
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger for automatic manual review queue addition
DROP TRIGGER IF EXISTS trigger_add_to_manual_review_queue ON profiles;
CREATE TRIGGER trigger_add_to_manual_review_queue
  AFTER UPDATE OF photo_verification_status ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION add_to_manual_review_queue();

-- Create function to get verification statistics
CREATE OR REPLACE FUNCTION get_verification_statistics()
RETURNS TABLE (
  total_profiles BIGINT,
  verified_profiles BIGINT,
  unverified_profiles BIGINT,
  pending_review BIGINT,
  rejected_profiles BIGINT,
  manual_review_queue_size BIGINT,
  avg_confidence DECIMAL(3,2),
  verification_rate DECIMAL(5,2)
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COUNT(*) as total_profiles,
    COUNT(*) FILTER (WHERE photo_verification_status = 'verified') as verified_profiles,
    COUNT(*) FILTER (WHERE photo_verification_status = 'unverified') as unverified_profiles,
    COUNT(*) FILTER (WHERE photo_verification_status = 'pending_review') as pending_review,
    COUNT(*) FILTER (WHERE photo_verification_status = 'rejected') as rejected_profiles,
    (SELECT COUNT(*) FROM photo_manual_review_queue WHERE review_status = 'pending') as manual_review_queue_size,
    AVG(photo_verification_confidence) as avg_confidence,
    CASE 
      WHEN COUNT(*) > 0 THEN 
        ROUND((COUNT(*) FILTER (WHERE photo_verification_status = 'verified')::DECIMAL / COUNT(*)) * 100, 2)
      ELSE 0
    END as verification_rate
  FROM profiles 
  WHERE avatar_url IS NOT NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create RLS policies for photo verification logs
ALTER TABLE photo_verification_logs ENABLE ROW LEVEL SECURITY;

-- Users can only see their own verification logs
CREATE POLICY "Users can view their own verification logs" 
ON photo_verification_logs FOR SELECT 
USING (auth.uid() = user_id);

-- Users can insert their own verification logs
CREATE POLICY "Users can insert their own verification logs" 
ON photo_verification_logs FOR INSERT 
WITH CHECK (auth.uid() = user_id);

-- Create RLS policies for manual review queue
ALTER TABLE photo_manual_review_queue ENABLE ROW LEVEL SECURITY;

-- Only admins can view manual review queue (would need admin role system)
CREATE POLICY "Service role can manage manual review queue" 
ON photo_manual_review_queue FOR ALL 
USING (auth.role() = 'service_role');

-- Create RLS policies for verification settings
ALTER TABLE photo_verification_settings ENABLE ROW LEVEL SECURITY;

-- Only service role can manage verification settings
CREATE POLICY "Service role can manage verification settings" 
ON photo_verification_settings FOR ALL 
USING (auth.role() = 'service_role');

-- Create function to clean up old verification logs (for maintenance)
CREATE OR REPLACE FUNCTION cleanup_old_verification_logs(days_to_keep INTEGER DEFAULT 90)
RETURNS INTEGER AS $$
DECLARE
  deleted_count INTEGER;
BEGIN
  DELETE FROM photo_verification_logs 
  WHERE created_at < CURRENT_TIMESTAMP - INTERVAL '1 day' * days_to_keep;
  
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  
  RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Add comments for documentation
COMMENT ON TABLE photo_verification_logs IS 'Audit trail for all photo verification attempts';
COMMENT ON TABLE photo_manual_review_queue IS 'Queue for photos that require manual review by moderators';
COMMENT ON TABLE photo_verification_settings IS 'Configuration settings for the photo verification system';

COMMENT ON COLUMN profiles.photo_verification_status IS 'Current verification status of the user profile photo';
COMMENT ON COLUMN profiles.photo_verification_date IS 'Date when the photo was last verified';
COMMENT ON COLUMN profiles.photo_verification_confidence IS 'AI confidence score for the verification (0.0-1.0)';

COMMENT ON FUNCTION get_verification_statistics() IS 'Returns comprehensive statistics about photo verification system';
COMMENT ON FUNCTION cleanup_old_verification_logs(INTEGER) IS 'Maintenance function to clean up old verification logs';

-- Grant necessary permissions
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT ALL ON TABLE photo_verification_logs TO authenticated;
GRANT ALL ON TABLE photo_manual_review_queue TO service_role;
GRANT ALL ON TABLE photo_verification_settings TO service_role;
GRANT EXECUTE ON FUNCTION get_verification_statistics() TO service_role;
GRANT EXECUTE ON FUNCTION cleanup_old_verification_logs(INTEGER) TO service_role;