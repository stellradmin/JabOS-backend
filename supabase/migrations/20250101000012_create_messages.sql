-- Create Messages Table
-- Internal gym messaging system

CREATE TABLE IF NOT EXISTS public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Participants
  sender_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  recipient_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

  -- Content
  content TEXT NOT NULL CHECK (char_length(content) <= 5000),

  -- Attachments (future feature)
  attachment_url TEXT,
  attachment_type TEXT,

  -- Status
  read_at TIMESTAMP WITH TIME ZONE,
  deleted_by_sender BOOLEAN DEFAULT false,
  deleted_by_recipient BOOLEAN DEFAULT false,

  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  -- Prevent self-messaging
  CONSTRAINT different_users CHECK (sender_id != recipient_id)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_messages_sender ON public.messages(sender_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_recipient ON public.messages(recipient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_organization ON public.messages(organization_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_unread ON public.messages(recipient_id)
  WHERE read_at IS NULL AND deleted_by_recipient = false;

-- Composite index for conversation threads
CREATE INDEX IF NOT EXISTS idx_messages_conversation
  ON public.messages(sender_id, recipient_id, created_at DESC);

-- Enable Row Level Security
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

-- Comments
COMMENT ON TABLE public.messages IS 'Internal messaging between gym members and staff';
COMMENT ON COLUMN public.messages.read_at IS 'When recipient read the message';
