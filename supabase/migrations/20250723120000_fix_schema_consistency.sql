-- Comprehensive schema consistency fixes
-- This migration addresses the database schema issues causing the log errors

-- 1. Add foreign key constraints to conversations table for proper relationships
ALTER TABLE conversations 
DROP CONSTRAINT IF EXISTS conversations_user1_id_fkey,
DROP CONSTRAINT IF EXISTS conversations_user2_id_fkey;

-- Add proper foreign key constraints
ALTER TABLE conversations 
ADD CONSTRAINT conversations_user1_id_fkey 
FOREIGN KEY (user1_id) REFERENCES profiles(id) ON DELETE CASCADE;

ALTER TABLE conversations 
ADD CONSTRAINT conversations_user2_id_fkey 
FOREIGN KEY (user2_id) REFERENCES profiles(id) ON DELETE CASCADE;

-- 2. Add performance indexes
CREATE INDEX IF NOT EXISTS idx_conversations_user1_id ON conversations(user1_id);
CREATE INDEX IF NOT EXISTS idx_conversations_user2_id ON conversations(user2_id);
CREATE INDEX IF NOT EXISTS idx_conversations_last_message_at ON conversations(last_message_at);

-- Also add indexes on messages table for better performance
CREATE INDEX IF NOT EXISTS idx_messages_conversation_id ON messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender_id ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);

-- 3. Ensure all RPC functions use correct table references
-- The existing RPC functions already correctly reference profiles.display_name
-- No changes needed for RPC functions

-- 4. Add helpful comments
COMMENT ON TABLE conversations IS 'Stores conversation records between matched users';
COMMENT ON COLUMN conversations.user1_id IS 'Foreign key to profiles.id for first participant';
COMMENT ON COLUMN conversations.user2_id IS 'Foreign key to profiles.id for second participant';

COMMENT ON TABLE profiles IS 'Stores user profile information including display_name and avatar_url';
COMMENT ON TABLE users IS 'Stores user authentication and personal data (birth data, questionnaire responses)';

-- 5. Grant necessary permissions
GRANT SELECT ON conversations TO authenticated;
GRANT INSERT ON conversations TO authenticated;
GRANT UPDATE ON conversations TO authenticated;

-- Verify constraints were added correctly
DO $$
BEGIN
    -- Check if foreign key constraints exist
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'conversations_user1_id_fkey'
    ) THEN
        RAISE NOTICE 'Warning: conversations_user1_id_fkey constraint was not created';
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'conversations_user2_id_fkey'
    ) THEN
        RAISE NOTICE 'Warning: conversations_user2_id_fkey constraint was not created';
    END IF;
    
    RAISE NOTICE 'Schema consistency migration completed successfully';
END $$;