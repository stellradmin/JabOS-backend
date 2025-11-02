-- Add missing columns to matches table that are needed for the matching system

-- Add conversation_id column if it doesn't exist
ALTER TABLE public.matches 
ADD COLUMN IF NOT EXISTS conversation_id UUID REFERENCES public.conversations(id) ON DELETE SET NULL;

-- Create index for performance
CREATE INDEX IF NOT EXISTS idx_matches_conversation_id ON public.matches(conversation_id);

-- Add comment
COMMENT ON COLUMN public.matches.conversation_id IS 'Reference to the conversation created when users match';