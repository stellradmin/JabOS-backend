-- =====================================================
-- STELLR NOTIFICATION PERSISTENCE SYSTEM
-- Comprehensive server-side notification tracking
-- Following industry best practices for dating apps
-- =====================================================

-- Create notification types enum for type safety
CREATE TYPE notification_type AS ENUM (
    'new_match',
    'new_message',
    'profile_view',
    'super_like',
    'date_reminder',
    'system_announcement',
    'security_alert'
);

-- Create notification priority enum
CREATE TYPE notification_priority AS ENUM (
    'low',
    'normal', 
    'high',
    'critical'
);

-- Create notification status enum
CREATE TYPE notification_status AS ENUM (
    'pending',
    'sent',
    'delivered',
    'read',
    'failed'
);

-- =====================================================
-- MAIN NOTIFICATIONS TABLE
-- =====================================================
CREATE TABLE IF NOT EXISTS public.user_notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    type notification_type NOT NULL,
    title TEXT NOT NULL CHECK (char_length(title) <= 100),
    body TEXT NOT NULL CHECK (char_length(body) <= 500),
    priority notification_priority NOT NULL DEFAULT 'normal',
    status notification_status NOT NULL DEFAULT 'pending',
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    scheduled_for TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    read_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    
    -- Type-specific data stored as JSONB for flexibility
    metadata JSONB DEFAULT '{}'::jsonb,
    
    -- Deep link information
    deep_link_url TEXT,
    
    -- Push notification specific data
    push_token TEXT,
    push_sent_at TIMESTAMPTZ,
    push_response JSONB,
    
    -- Analytics and tracking
    interaction_count INTEGER DEFAULT 0,
    last_interaction_at TIMESTAMPTZ,
    
    CONSTRAINT valid_schedule CHECK (scheduled_for IS NULL OR scheduled_for > created_at),
    CONSTRAINT valid_expiry CHECK (expires_at IS NULL OR expires_at > created_at),
    CONSTRAINT valid_read_time CHECK (read_at IS NULL OR read_at >= created_at)
);

-- =====================================================
-- NOTIFICATION READ STATUS TRACKING
-- =====================================================
CREATE TABLE IF NOT EXISTS public.notification_read_status (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    notification_id UUID NOT NULL REFERENCES public.user_notifications(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    read_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_from_device TEXT, -- 'mobile', 'web', 'tablet'
    read_location POINT, -- Geographic location if available
    session_id TEXT,
    
    UNIQUE(notification_id, user_id)
);

-- =====================================================
-- NOTIFICATION PREFERENCES INTEGRATION
-- =====================================================
-- Extend existing user_settings table if it doesn't have notification columns
DO $$
BEGIN
    -- Add notification delivery preferences if they don't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'user_settings' 
                   AND column_name = 'notification_delivery_hours') THEN
        ALTER TABLE public.user_settings 
        ADD COLUMN notification_delivery_hours JSONB DEFAULT '{"start": "08:00", "end": "22:00"}'::jsonb;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'user_settings' 
                   AND column_name = 'notification_frequency') THEN
        ALTER TABLE public.user_settings 
        ADD COLUMN notification_frequency TEXT DEFAULT 'real_time' 
        CHECK (notification_frequency IN ('real_time', 'daily_digest', 'weekly_digest', 'disabled'));
    END IF;
END $$;

-- =====================================================
-- PERFORMANCE INDEXES
-- =====================================================
-- Primary query patterns for notifications
CREATE INDEX IF NOT EXISTS idx_user_notifications_user_id_created
    ON public.user_notifications(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_notifications_user_id_status
    ON public.user_notifications(user_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_notifications_user_id_type
    ON public.user_notifications(user_id, type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_notifications_unread
    ON public.user_notifications(user_id, created_at DESC)
    WHERE status != 'read';

CREATE INDEX IF NOT EXISTS idx_user_notifications_scheduled
    ON public.user_notifications(scheduled_for)
    WHERE scheduled_for IS NOT NULL AND status = 'pending';

CREATE INDEX IF NOT EXISTS idx_user_notifications_expires
    ON public.user_notifications(expires_at)
    WHERE expires_at IS NOT NULL;

-- Metadata JSONB indexing for type-specific queries
CREATE INDEX IF NOT EXISTS idx_user_notifications_metadata_gin
    ON public.user_notifications USING GIN(metadata);

-- Read status tracking indexes
CREATE INDEX IF NOT EXISTS idx_notification_read_status_user_id
    ON public.notification_read_status(user_id, read_at DESC);

CREATE INDEX IF NOT EXISTS idx_notification_read_status_notification_id
    ON public.notification_read_status(notification_id);

-- =====================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- =====================================================
-- Enable RLS on both tables
ALTER TABLE public.user_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_read_status ENABLE ROW LEVEL SECURITY;

-- User notifications policies
CREATE POLICY "Users can view their own notifications" 
    ON public.user_notifications FOR SELECT 
    USING (auth.uid() = user_id);

CREATE POLICY "Users can update read status of their notifications" 
    ON public.user_notifications FOR UPDATE 
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- System can insert notifications for any user (for backend services)
CREATE POLICY "Service role can insert notifications" 
    ON public.user_notifications FOR INSERT 
    WITH CHECK (
        auth.jwt() ->> 'role' = 'service_role' OR
        auth.uid() = user_id
    );

-- System can update any notification (for delivery status updates)
CREATE POLICY "Service role can update notification status" 
    ON public.user_notifications FOR UPDATE 
    USING (auth.jwt() ->> 'role' = 'service_role');

-- Read status policies
CREATE POLICY "Users can view their own read status" 
    ON public.notification_read_status FOR SELECT 
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own read status" 
    ON public.notification_read_status FOR INSERT 
    WITH CHECK (auth.uid() = user_id);

-- Service role can manage read status
CREATE POLICY "Service role can manage read status" 
    ON public.notification_read_status FOR ALL 
    USING (auth.jwt() ->> 'role' = 'service_role');

-- =====================================================
-- UTILITY FUNCTIONS
-- =====================================================

-- Function to mark notification as read
CREATE OR REPLACE FUNCTION mark_notification_read(
    p_notification_id UUID,
    p_user_id UUID DEFAULT auth.uid(),
    p_device_type TEXT DEFAULT NULL,
    p_session_id TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    notification_exists BOOLEAN;
BEGIN
    -- Verify notification exists and belongs to user
    SELECT EXISTS(
        SELECT 1 FROM user_notifications 
        WHERE id = p_notification_id AND user_id = p_user_id
    ) INTO notification_exists;
    
    IF NOT notification_exists THEN
        RETURN FALSE;
    END IF;
    
    -- Update notification status
    UPDATE user_notifications 
    SET 
        status = 'read',
        read_at = NOW(),
        interaction_count = interaction_count + 1,
        last_interaction_at = NOW()
    WHERE id = p_notification_id AND user_id = p_user_id;
    
    -- Insert read status record
    INSERT INTO notification_read_status (
        notification_id, 
        user_id, 
        read_from_device, 
        session_id
    ) VALUES (
        p_notification_id, 
        p_user_id, 
        p_device_type, 
        p_session_id
    ) ON CONFLICT (notification_id, user_id) DO UPDATE SET
        read_at = NOW(),
        read_from_device = EXCLUDED.read_from_device,
        session_id = EXCLUDED.session_id;
    
    RETURN TRUE;
END;
$$;

-- Function to get unread notification count
CREATE OR REPLACE FUNCTION get_unread_notification_count(
    p_user_id UUID DEFAULT auth.uid()
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN (
        SELECT COUNT(*)::INTEGER
        FROM user_notifications 
        WHERE user_id = p_user_id 
        AND status != 'read'
        AND (expires_at IS NULL OR expires_at > NOW())
    );
END;
$$;

-- Function to cleanup expired notifications
CREATE OR REPLACE FUNCTION cleanup_expired_notifications()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    -- Delete notifications that have expired
    DELETE FROM user_notifications 
    WHERE expires_at IS NOT NULL AND expires_at < NOW();
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    
    -- Delete old read notifications (older than 30 days)
    DELETE FROM user_notifications 
    WHERE status = 'read' 
    AND read_at < NOW() - INTERVAL '30 days';
    
    RETURN deleted_count;
END;
$$;

-- Function to clear all notifications for a user
CREATE OR REPLACE FUNCTION clear_all_user_notifications(
    p_user_id UUID DEFAULT auth.uid()
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    updated_count INTEGER;
BEGIN
    -- Mark all unread notifications as read
    UPDATE user_notifications 
    SET 
        status = 'read',
        read_at = NOW(),
        last_interaction_at = NOW()
    WHERE user_id = p_user_id 
    AND status != 'read';
    
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    
    RETURN updated_count;
END;
$$;

-- =====================================================
-- TRIGGERS AND AUTOMATION
-- =====================================================

-- Function to automatically set expires_at based on notification type
CREATE OR REPLACE FUNCTION set_notification_expiry()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Set expiry based on notification type if not explicitly set
    IF NEW.expires_at IS NULL THEN
        CASE NEW.type
            WHEN 'new_message' THEN
                NEW.expires_at := NEW.created_at + INTERVAL '7 days';
            WHEN 'new_match' THEN
                NEW.expires_at := NEW.created_at + INTERVAL '30 days';
            WHEN 'profile_view' THEN
                NEW.expires_at := NEW.created_at + INTERVAL '3 days';
            WHEN 'super_like' THEN
                NEW.expires_at := NEW.created_at + INTERVAL '14 days';
            WHEN 'date_reminder' THEN
                NEW.expires_at := NEW.created_at + INTERVAL '1 day';
            WHEN 'system_announcement' THEN
                NEW.expires_at := NEW.created_at + INTERVAL '90 days';
            WHEN 'security_alert' THEN
                NEW.expires_at := NEW.created_at + INTERVAL '30 days';
        END CASE;
    END IF;
    
    RETURN NEW;
END;
$$;

-- Create trigger for automatic expiry setting
CREATE TRIGGER set_notification_expiry_trigger
    BEFORE INSERT ON public.user_notifications
    FOR EACH ROW
    EXECUTE FUNCTION set_notification_expiry();

-- =====================================================
-- COMMENTS AND DOCUMENTATION
-- =====================================================
COMMENT ON TABLE public.user_notifications IS 'Server-side persistent notification storage for Stellr dating app following industry best practices';
COMMENT ON TABLE public.notification_read_status IS 'Tracks read status and interaction details for notifications';

COMMENT ON COLUMN public.user_notifications.metadata IS 'Type-specific notification data stored as JSONB for flexibility';
COMMENT ON COLUMN public.user_notifications.priority IS 'Notification importance level affecting delivery timing and UI presentation';
COMMENT ON COLUMN public.user_notifications.deep_link_url IS 'App URL for notification tap navigation';

COMMENT ON FUNCTION mark_notification_read(UUID, UUID, TEXT, TEXT) IS 'Safely mark notification as read with audit trail';
COMMENT ON FUNCTION get_unread_notification_count(UUID) IS 'Get count of unread notifications for user';
COMMENT ON FUNCTION cleanup_expired_notifications() IS 'Background job function to clean up old notifications';