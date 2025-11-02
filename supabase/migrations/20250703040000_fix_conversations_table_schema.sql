-- Fix conversations table schema by adding missing columns
-- This fixes the "column match_id of relation conversations does not exist" error

-- Add columns only if they don't exist
DO $$
BEGIN
    -- Add match_id column if it doesn't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'conversations' AND column_name = 'match_id') THEN
        ALTER TABLE public.conversations ADD COLUMN match_id UUID REFERENCES public.matches(id) ON DELETE CASCADE;
    END IF;
    
    -- Add last_message_preview column if it doesn't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'conversations' AND column_name = 'last_message_preview') THEN
        ALTER TABLE public.conversations ADD COLUMN last_message_preview TEXT;
    END IF;
    
    -- Add last_message_at column if it doesn't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'conversations' AND column_name = 'last_message_at') THEN
        ALTER TABLE public.conversations ADD COLUMN last_message_at TIMESTAMPTZ;
    END IF;
END $$;

-- Add comments for the new columns
COMMENT ON COLUMN public.conversations.match_id IS 'Reference to the match that created this conversation';
COMMENT ON COLUMN public.conversations.last_message_preview IS 'Preview text of the last message in this conversation';
COMMENT ON COLUMN public.conversations.last_message_at IS 'Timestamp of when the last message was sent';

-- Create index for performance on match_id lookups
CREATE INDEX idx_conversations_match_id ON public.conversations(match_id);

-- Create index for performance on last_message_at for conversation ordering
CREATE INDEX idx_conversations_last_message_at ON public.conversations(last_message_at DESC);