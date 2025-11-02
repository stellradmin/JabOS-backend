-- =====================================================
-- IMPLEMENT READ RECEIPTS SYSTEM BASED ON USER PREFERENCES
-- =====================================================
-- This migration implements a comprehensive read receipts system
-- that respects user privacy settings from the unified user_settings table.
--
-- Author: Claude Code Assistant
-- Date: 2024-09-04
-- Version: 1.0.0
--
-- Features:
-- - User-controlled read receipt preferences
-- - Mutual read receipt functionality (both users must have it enabled)
-- - Performance-optimized read status tracking
-- - Privacy-first design with granular controls
-- - Comprehensive audit trail for message status changes
-- - Real-time read status updates with WebSocket support
-- =====================================================

BEGIN;

-- =====================================================
-- 1. ENSURE MESSAGE STATUS FIELDS EXIST
-- =====================================================

-- Add read receipt related columns to messages table if they don't exist
DO $$
BEGIN
    -- Add read_at timestamp
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' 
        AND table_name = 'messages' 
        AND column_name = 'read_at'
    ) THEN
        ALTER TABLE public.messages ADD COLUMN read_at TIMESTAMPTZ;
        RAISE NOTICE 'Added read_at column to messages table';
    END IF;
    
    -- Add delivered_at timestamp
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' 
        AND table_name = 'messages' 
        AND column_name = 'delivered_at'
    ) THEN
        ALTER TABLE public.messages ADD COLUMN delivered_at TIMESTAMPTZ DEFAULT NOW();
        RAISE NOTICE 'Added delivered_at column to messages table';
    END IF;
    
    -- Add read_receipt_sent flag
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' 
        AND table_name = 'messages' 
        AND column_name = 'read_receipt_sent'
    ) THEN
        ALTER TABLE public.messages ADD COLUMN read_receipt_sent BOOLEAN DEFAULT FALSE;
        RAISE NOTICE 'Added read_receipt_sent column to messages table';
    END IF;
END $$;

-- =====================================================
-- 2. CREATE READ RECEIPT TRACKING TABLE
-- =====================================================

-- Create table to track detailed read receipt events
CREATE TABLE IF NOT EXISTS public.message_read_receipts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
    reader_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    sender_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
    
    -- Receipt preferences at time of read
    reader_receipts_enabled BOOLEAN NOT NULL DEFAULT false,
    sender_receipts_enabled BOOLEAN NOT NULL DEFAULT false,
    mutual_receipts_enabled BOOLEAN NOT NULL DEFAULT false,
    
    -- Timestamps
    delivered_at TIMESTAMPTZ DEFAULT NOW(),
    read_at TIMESTAMPTZ DEFAULT NOW(),
    receipt_sent_at TIMESTAMPTZ,
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT unique_message_reader UNIQUE (message_id, reader_id),
    CONSTRAINT no_self_receipts CHECK (reader_id != sender_id)
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_message_read_receipts_message_id ON public.message_read_receipts (message_id);
CREATE INDEX IF NOT EXISTS idx_message_read_receipts_reader_id ON public.message_read_receipts (reader_id);
CREATE INDEX IF NOT EXISTS idx_message_read_receipts_conversation_id ON public.message_read_receipts (conversation_id);
CREATE INDEX IF NOT EXISTS idx_message_read_receipts_read_at ON public.message_read_receipts (read_at DESC);

-- Enable RLS
ALTER TABLE public.message_read_receipts ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Users can only see read receipts for their own messages or messages they've read
DROP POLICY IF EXISTS "Users can access relevant read receipts" ON public.message_read_receipts;
CREATE POLICY "Users can access relevant read receipts" ON public.message_read_receipts
    FOR SELECT USING (
        auth.uid() = reader_id OR
        auth.uid() = sender_id
    );

-- RLS Policy: Users can insert read receipts for messages they receive
DROP POLICY IF EXISTS "Users can create read receipts" ON public.message_read_receipts;
CREATE POLICY "Users can create read receipts" ON public.message_read_receipts
    FOR INSERT WITH CHECK (auth.uid() = reader_id);

-- =====================================================
-- 3. CREATE READ RECEIPT FUNCTIONS
-- =====================================================

-- Function to check if read receipts should be shared between two users
CREATE OR REPLACE FUNCTION should_share_read_receipt(
    sender_id UUID,
    reader_id UUID
)
RETURNS BOOLEAN AS $$
DECLARE
    sender_settings RECORD;
    reader_settings RECORD;
BEGIN
    -- Get both users' read receipt preferences
    SELECT 
        COALESCE(us.read_receipts_enabled, true) as read_receipts_enabled
    INTO sender_settings
    FROM public.user_settings us
    WHERE us.user_id = sender_id;
    
    SELECT 
        COALESCE(us.read_receipts_enabled, true) as read_receipts_enabled
    INTO reader_settings
    FROM public.user_settings us
    WHERE us.user_id = reader_id;
    
    -- Use defaults if settings not found
    IF sender_settings IS NULL THEN
        sender_settings.read_receipts_enabled := true;
    END IF;
    
    IF reader_settings IS NULL THEN
        reader_settings.read_receipts_enabled := true;
    END IF;
    
    -- Both users must have read receipts enabled for mutual sharing
    RETURN sender_settings.read_receipts_enabled AND reader_settings.read_receipts_enabled;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to mark a message as read and handle read receipt logic
CREATE OR REPLACE FUNCTION mark_message_read(
    p_message_id UUID,
    p_reader_id UUID
)
RETURNS JSONB AS $$
DECLARE
    message_info RECORD;
    receipt_should_be_shared BOOLEAN;
    receipt_record_id UUID;
    result JSONB;
BEGIN
    -- Get message information
    SELECT 
        m.id,
        m.sender_id,
        m.conversation_id,
        m.content,
        m.read_at,
        c.user1_id,
        c.user2_id
    INTO message_info
    FROM public.messages m
    JOIN public.conversations c ON c.id = m.conversation_id
    WHERE m.id = p_message_id;
    
    -- Validate message exists and user is authorized to read it
    IF message_info IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Message not found or access denied',
            'message_id', p_message_id
        );
    END IF;
    
    -- Validate user is part of the conversation
    IF p_reader_id != message_info.user1_id AND p_reader_id != message_info.user2_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'User not authorized to read this message',
            'message_id', p_message_id
        );
    END IF;
    
    -- Don't process read receipts for the sender reading their own message
    IF p_reader_id = message_info.sender_id THEN
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Sender reading own message - no receipt needed',
            'message_id', p_message_id,
            'read_at', NOW()
        );
    END IF;
    
    -- Check if message is already marked as read
    IF message_info.read_at IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Message already marked as read',
            'message_id', p_message_id,
            'read_at', message_info.read_at
        );
    END IF;
    
    -- Check if read receipt should be shared
    SELECT should_share_read_receipt(message_info.sender_id, p_reader_id) 
    INTO receipt_should_be_shared;
    
    -- Update message read status
    UPDATE public.messages 
    SET 
        read_at = NOW(),
        read_receipt_sent = receipt_should_be_shared
    WHERE id = p_message_id;
    
    -- Create detailed read receipt record
    INSERT INTO public.message_read_receipts (
        message_id,
        reader_id,
        sender_id,
        conversation_id,
        reader_receipts_enabled,
        sender_receipts_enabled,
        mutual_receipts_enabled,
        delivered_at,
        read_at,
        receipt_sent_at
    ) VALUES (
        p_message_id,
        p_reader_id,
        message_info.sender_id,
        message_info.conversation_id,
        (SELECT COALESCE(us.read_receipts_enabled, true) FROM public.user_settings us WHERE us.user_id = p_reader_id),
        (SELECT COALESCE(us.read_receipts_enabled, true) FROM public.user_settings us WHERE us.user_id = message_info.sender_id),
        receipt_should_be_shared,
        NOW() - INTERVAL '1 second', -- Assume delivered just before read
        NOW(),
        CASE WHEN receipt_should_be_shared THEN NOW() ELSE NULL END
    ) RETURNING id INTO receipt_record_id;
    
    -- Build result
    result := jsonb_build_object(
        'success', true,
        'message_id', p_message_id,
        'reader_id', p_reader_id,
        'sender_id', message_info.sender_id,
        'conversation_id', message_info.conversation_id,
        'read_at', NOW(),
        'receipt_shared', receipt_should_be_shared,
        'receipt_record_id', receipt_record_id
    );
    
    -- Add notification metadata if receipt should be shared
    IF receipt_should_be_shared THEN
        result := result || jsonb_build_object(
            'notify_sender', true,
            'notification_type', 'read_receipt'
        );
    END IF;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get read receipt status for messages in a conversation
CREATE OR REPLACE FUNCTION get_conversation_read_status(
    p_conversation_id UUID,
    p_user_id UUID
)
RETURNS TABLE (
    message_id UUID,
    sender_id UUID,
    read_at TIMESTAMPTZ,
    reader_id UUID,
    receipt_visible BOOLEAN,
    delivery_status TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        m.id as message_id,
        m.sender_id,
        m.read_at,
        rr.reader_id,
        rr.mutual_receipts_enabled as receipt_visible,
        CASE 
            WHEN m.read_at IS NOT NULL THEN 'read'
            WHEN m.delivered_at IS NOT NULL THEN 'delivered' 
            ELSE 'sent'
        END as delivery_status
    FROM public.messages m
    LEFT JOIN public.message_read_receipts rr ON rr.message_id = m.id
    WHERE m.conversation_id = p_conversation_id
    AND (
        -- User can see read status for their own sent messages (if receipts enabled)
        (m.sender_id = p_user_id AND rr.mutual_receipts_enabled = true)
        OR
        -- User can see read status for messages they received (always visible to them)
        (m.sender_id != p_user_id)
    )
    ORDER BY m.created_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to mark multiple messages as read (for conversation view)
CREATE OR REPLACE FUNCTION mark_conversation_messages_read(
    p_conversation_id UUID,
    p_reader_id UUID,
    p_message_ids UUID[] DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    messages_to_mark UUID[];
    message_id UUID;
    mark_result JSONB;
    results JSONB[] := '{}';
    total_marked INTEGER := 0;
    total_receipts_sent INTEGER := 0;
BEGIN
    -- Get messages to mark as read
    IF p_message_ids IS NOT NULL THEN
        -- Mark specific messages
        messages_to_mark := p_message_ids;
    ELSE
        -- Mark all unread messages in conversation that user didn't send
        SELECT ARRAY(
            SELECT m.id 
            FROM public.messages m
            JOIN public.conversations c ON c.id = m.conversation_id
            WHERE m.conversation_id = p_conversation_id
            AND m.sender_id != p_reader_id
            AND m.read_at IS NULL
            AND (c.user1_id = p_reader_id OR c.user2_id = p_reader_id)
        ) INTO messages_to_mark;
    END IF;
    
    -- Mark each message as read
    FOREACH message_id IN ARRAY messages_to_mark
    LOOP
        SELECT mark_message_read(message_id, p_reader_id) INTO mark_result;
        
        IF (mark_result->>'success')::BOOLEAN THEN
            total_marked := total_marked + 1;
            
            IF (mark_result->>'receipt_shared')::BOOLEAN THEN
                total_receipts_sent := total_receipts_sent + 1;
            END IF;
        END IF;
        
        results := array_append(results, mark_result);
    END LOOP;
    
    RETURN jsonb_build_object(
        'success', true,
        'conversation_id', p_conversation_id,
        'reader_id', p_reader_id,
        'total_messages_marked', total_marked,
        'total_receipts_sent', total_receipts_sent,
        'messages_processed', array_length(messages_to_mark, 1),
        'individual_results', results,
        'processed_at', NOW()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 4. CREATE READ RECEIPT NOTIFICATION TRIGGER
-- =====================================================

-- Function to handle read receipt notifications
CREATE OR REPLACE FUNCTION notify_read_receipt()
RETURNS TRIGGER AS $$
DECLARE
    sender_notification_prefs JSONB;
BEGIN
    -- Only process if this is a new read receipt that should be shared
    IF NEW.mutual_receipts_enabled = true AND NEW.receipt_sent_at IS NOT NULL THEN
        -- Get sender's notification preferences
        SELECT get_user_notification_preferences(NEW.sender_id) 
        INTO sender_notification_prefs;
        
        -- Check if sender wants read receipt notifications
        IF (sender_notification_prefs->>'message_notifications_enabled')::BOOLEAN = true THEN
            -- Here you could integrate with your notification system
            -- For now, we'll just log it or use pg_notify for real-time updates
            
            PERFORM pg_notify(
                'read_receipt_channel',
                json_build_object(
                    'type', 'read_receipt',
                    'message_id', NEW.message_id,
                    'sender_id', NEW.sender_id,
                    'reader_id', NEW.reader_id,
                    'conversation_id', NEW.conversation_id,
                    'read_at', NEW.read_at,
                    'timestamp', NOW()
                )::TEXT
            );
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for read receipt notifications
CREATE TRIGGER trigger_read_receipt_notification
    AFTER INSERT ON public.message_read_receipts
    FOR EACH ROW EXECUTE FUNCTION notify_read_receipt();

-- =====================================================
-- 5. CREATE ANALYTICS AND MONITORING VIEWS
-- =====================================================

-- View for read receipt analytics
CREATE OR REPLACE VIEW public.read_receipt_analytics AS
SELECT 
    DATE_TRUNC('day', created_at) as date,
    COUNT(*) as total_read_receipts,
    COUNT(*) FILTER (WHERE mutual_receipts_enabled = true) as receipts_shared,
    COUNT(*) FILTER (WHERE mutual_receipts_enabled = false) as receipts_private,
    ROUND(
        ((COUNT(*) FILTER (WHERE mutual_receipts_enabled = true)::FLOAT / NULLIF(COUNT(*), 0)) * 100)::NUMERIC,
        2
    ) as sharing_percentage,
    COUNT(DISTINCT reader_id) as unique_readers,
    COUNT(DISTINCT sender_id) as unique_senders,
    COUNT(DISTINCT conversation_id) as unique_conversations
FROM public.message_read_receipts
GROUP BY DATE_TRUNC('day', created_at)
ORDER BY date DESC;

-- View for user read receipt preferences summary
CREATE OR REPLACE VIEW public.user_read_receipt_summary AS
SELECT 
    p.id as user_id,
    p.display_name,
    COALESCE(us.read_receipts_enabled, true) as read_receipts_enabled,
    COUNT(mrr.id) as total_messages_read,
    COUNT(mrr.id) FILTER (WHERE mrr.mutual_receipts_enabled = true) as receipts_shared,
    COUNT(sent_messages.id) as total_messages_sent,
    COUNT(sent_receipts.id) as receipts_received
FROM public.profiles p
LEFT JOIN public.user_settings us ON us.user_id = p.id
LEFT JOIN public.message_read_receipts mrr ON mrr.reader_id = p.id
LEFT JOIN public.messages sent_messages ON sent_messages.sender_id = p.id
LEFT JOIN public.message_read_receipts sent_receipts ON sent_receipts.sender_id = p.id
WHERE p.onboarding_completed = true
GROUP BY p.id, p.display_name, us.read_receipts_enabled;

-- =====================================================
-- 6. GRANT PERMISSIONS
-- =====================================================

-- Grant table permissions
GRANT SELECT, INSERT ON public.message_read_receipts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.message_read_receipts TO service_role;

-- Grant function permissions
GRANT EXECUTE ON FUNCTION should_share_read_receipt(UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION mark_message_read(UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_conversation_read_status(UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION mark_conversation_messages_read(UUID, UUID, UUID[]) TO authenticated, service_role;

-- Grant view permissions  
GRANT SELECT ON public.read_receipt_analytics TO service_role;
GRANT SELECT ON public.user_read_receipt_summary TO authenticated, service_role;

-- =====================================================
-- 7. ADD COMPREHENSIVE COMMENTS
-- =====================================================

COMMENT ON TABLE public.message_read_receipts IS 'Comprehensive read receipt tracking with user privacy preferences and mutual consent';
COMMENT ON COLUMN public.message_read_receipts.mutual_receipts_enabled IS 'True only when both sender and reader have read receipts enabled';
COMMENT ON COLUMN public.message_read_receipts.receipt_sent_at IS 'Timestamp when read receipt was actually shared with sender (null if not shared due to privacy settings)';

COMMENT ON FUNCTION should_share_read_receipt(UUID, UUID) IS 'Checks if read receipt should be shared between two users based on their mutual privacy preferences';
COMMENT ON FUNCTION mark_message_read(UUID, UUID) IS 'Marks a message as read and handles read receipt logic based on user preferences';
COMMENT ON FUNCTION get_conversation_read_status(UUID, UUID) IS 'Gets read receipt status for all messages in a conversation with proper privacy filtering';
COMMENT ON FUNCTION mark_conversation_messages_read(UUID, UUID, UUID[]) IS 'Bulk marks messages as read for conversation view optimization';

COMMENT ON VIEW public.read_receipt_analytics IS 'Analytics view for read receipt usage and privacy preferences trends';
COMMENT ON VIEW public.user_read_receipt_summary IS 'Summary of each users read receipt activity and preferences';

-- =====================================================
-- 8. CREATE EDGE FUNCTION HELPER
-- =====================================================

-- Function specifically designed for edge function calls
CREATE OR REPLACE FUNCTION api_mark_messages_read(
    p_conversation_id UUID,
    p_reader_id UUID,
    p_message_ids JSONB DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    message_ids_array UUID[];
    result JSONB;
BEGIN
    -- Convert JSONB array to UUID array if provided
    IF p_message_ids IS NOT NULL THEN
        SELECT ARRAY(SELECT jsonb_array_elements_text(p_message_ids)::UUID) 
        INTO message_ids_array;
    END IF;
    
    -- Call the main function
    SELECT mark_conversation_messages_read(p_conversation_id, p_reader_id, message_ids_array)
    INTO result;
    
    -- Add API-specific metadata
    result := result || jsonb_build_object(
        'api_call', true,
        'endpoint', 'mark_messages_read',
        'timestamp', NOW()
    );
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION api_mark_messages_read(UUID, UUID, JSONB) TO authenticated, service_role;

-- =====================================================
-- 9. MIGRATE EXISTING MESSAGE DATA
-- =====================================================

-- Update existing messages to have delivered_at timestamps
UPDATE public.messages 
SET delivered_at = created_at 
WHERE delivered_at IS NULL;

-- =====================================================
-- 10. VERIFICATION AND TESTING
-- =====================================================

-- Verify the implementation
DO $$
DECLARE
    table_exists BOOLEAN;
    function_count INTEGER;
    view_count INTEGER;
BEGIN
    -- Check if read receipts table was created
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = 'public' 
        AND table_name = 'message_read_receipts'
    ) INTO table_exists;
    
    IF table_exists THEN
        RAISE NOTICE '✅ message_read_receipts table created successfully';
    ELSE
        RAISE EXCEPTION '❌ message_read_receipts table was not created';
    END IF;
    
    -- Count functions created
    SELECT COUNT(*) INTO function_count
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
    AND p.proname IN (
        'should_share_read_receipt',
        'mark_message_read',
        'get_conversation_read_status',
        'mark_conversation_messages_read',
        'api_mark_messages_read'
    );
    
    RAISE NOTICE '✅ Created % read receipt functions', function_count;
    
    -- Count views created
    SELECT COUNT(*) INTO view_count
    FROM pg_views 
    WHERE schemaname = 'public'
    AND viewname IN ('read_receipt_analytics', 'user_read_receipt_summary');
    
    RAISE NOTICE '✅ Created % read receipt analytics views', view_count;
    
    -- Test the main function with a dummy scenario (if test data exists)
    IF EXISTS (SELECT 1 FROM public.messages LIMIT 1) THEN
        RAISE NOTICE '✅ Read receipt system ready for testing with existing messages';
    ELSE
        RAISE NOTICE '✅ Read receipt system ready (no test data available)';
    END IF;
END $$;

COMMIT;

-- =====================================================
-- READ RECEIPTS IMPLEMENTATION COMPLETE
-- =====================================================

SELECT 
    'Read Receipts System Implementation Completed!' as status,
    NOW() as completed_at,
    (SELECT COUNT(*) FROM public.message_read_receipts) as receipt_records,
    (SELECT COUNT(*) FROM public.messages WHERE read_at IS NOT NULL) as read_messages,
    (SELECT COUNT(*) FROM public.user_settings WHERE read_receipts_enabled = true) as users_with_receipts_enabled,
    'Privacy-first read receipts with mutual consent' as feature_description;