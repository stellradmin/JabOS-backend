-- Create essential base schema for JabOS gym platform
-- Note: This migration has been refactored from Stellr dating app to gym management

-- Create unified users table for gym staff and members
-- This table serves both web app (owners/coaches) and mobile app (members)
CREATE TABLE IF NOT EXISTS public.users (
    -- Direct reference to auth.users for authentication
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,

    -- Multi-tenant organization membership
    organization_id UUID NOT NULL,  -- FK added after organizations table exists

    -- Role within organization
    role TEXT NOT NULL CHECK (role IN ('owner', 'coach', 'member')),

    -- Basic profile information
    email TEXT NOT NULL,
    full_name TEXT NOT NULL,
    display_name TEXT,  -- Casual name for mobile app
    avatar_url TEXT,
    phone TEXT,
    bio TEXT,  -- Member bio for sparring matching

    -- User status
    is_active BOOLEAN DEFAULT true,
    last_login_at TIMESTAMP WITH TIME ZONE,
    onboarding_completed BOOLEAN DEFAULT FALSE,

    -- Mobile app features (repurposed from dating app)
    questionnaire_responses JSONB,  -- 25-question gym onboarding (1-5 scale)
    subscription_status TEXT DEFAULT 'inactive',  -- RevenueCat premium status
    subscription_tier TEXT DEFAULT 'free',  -- Premium features access

    -- Mobile app settings
    app_settings JSONB DEFAULT '{}',
    push_token TEXT,
    location JSONB,  -- Current location for cross-gym matching

    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- Ensure email uniqueness per organization (not globally)
    UNIQUE(organization_id, email)
);

-- Create conversations table (for sparring partner messaging)
CREATE TABLE IF NOT EXISTS public.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL,  -- Multi-tenant isolation
    participant_1_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    participant_2_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    match_id UUID,  -- References training match
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_message_at TIMESTAMP WITH TIME ZONE,
    last_message_content TEXT,
    UNIQUE(participant_1_id, participant_2_id)
);

-- Create messages table (for sparring partner chat)
CREATE TABLE IF NOT EXISTS public.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL,  -- Multi-tenant isolation
    conversation_id UUID REFERENCES public.conversations(id) ON DELETE CASCADE,
    sender_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    message_type TEXT DEFAULT 'text',
    is_read BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create swipes table (for sparring partner discovery - like/pass)
CREATE TABLE IF NOT EXISTS public.swipes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL,  -- Multi-tenant isolation
    swiper_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    swiped_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    swipe_type TEXT CHECK (swipe_type IN ('like', 'pass')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(swiper_id, swiped_id)
);

-- Create matches table (for confirmed sparring partner matches)
CREATE TABLE IF NOT EXISTS public.matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL,  -- Multi-tenant isolation
    user1_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    user2_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    match_request_id UUID,
    conversation_id UUID REFERENCES public.conversations(id),
    matched_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    status TEXT DEFAULT 'active',

    -- Compatibility scoring (repurposed for gym matching)
    compatibility_score INTEGER,  -- Overall compatibility (0-100)
    physical_grade TEXT,  -- Weight class + height + experience match (A-F)
    questionnaire_grade TEXT,  -- 25-question alignment (A-F)
    overall_score INTEGER,  -- Final match score

    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user1_id, user2_id)
);

-- Enable RLS for all tables
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.swipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;

-- RLS policies for multi-tenant gym platform

-- Users table policies
CREATE POLICY "Users can view members in their organization" ON public.users
    FOR SELECT USING (
        organization_id IN (
            SELECT organization_id FROM public.users WHERE id = auth.uid()
        )
    );

CREATE POLICY "Users can update their own profile" ON public.users
    FOR UPDATE USING (id = auth.uid());

-- Swipes policies (sparring partner discovery)
CREATE POLICY "Members can create swipes in their org" ON public.swipes
    FOR INSERT WITH CHECK (
        auth.uid() = swiper_id
        AND organization_id IN (
            SELECT organization_id FROM public.users WHERE id = auth.uid()
        )
    );

CREATE POLICY "Members can view swipes involving them" ON public.swipes
    FOR SELECT USING (
        auth.uid() = swiper_id OR auth.uid() = swiped_id
    );

-- Matches policies (confirmed sparring partners)
CREATE POLICY "Members can view their matches" ON public.matches
    FOR SELECT USING (
        auth.uid() = user1_id OR auth.uid() = user2_id
    );

-- Conversations policies
CREATE POLICY "Members can manage their conversations" ON public.conversations
    FOR ALL USING (
        auth.uid() = participant_1_id OR auth.uid() = participant_2_id
    );

-- Messages policies
CREATE POLICY "Members can view messages in their conversations" ON public.messages
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.conversations c
            WHERE c.id = conversation_id
            AND (c.participant_1_id = auth.uid() OR c.participant_2_id = auth.uid())
        )
    );

-- Create essential function for Edge Functions (sparring partner conversations)
CREATE OR REPLACE FUNCTION get_user_conversations(p_user_id UUID)
RETURNS TABLE(
    id UUID,
    participant_1_id UUID,
    participant_2_id UUID,
    created_at TIMESTAMP WITH TIME ZONE,
    updated_at TIMESTAMP WITH TIME ZONE,
    last_message_at TIMESTAMP WITH TIME ZONE,
    last_message_content TEXT,
    other_participant JSONB
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.id,
        c.participant_1_id,
        c.participant_2_id,
        c.created_at,
        c.updated_at,
        c.last_message_at,
        c.last_message_content,
        CASE
            WHEN c.participant_1_id = p_user_id THEN
                jsonb_build_object(
                    'id', u2.id,
                    'display_name', COALESCE(u2.display_name, u2.full_name, 'Unknown'),
                    'avatar_url', u2.avatar_url
                )
            ELSE
                jsonb_build_object(
                    'id', u1.id,
                    'display_name', COALESCE(u1.display_name, u1.full_name, 'Unknown'),
                    'avatar_url', u1.avatar_url
                )
        END as other_participant
    FROM conversations c
    LEFT JOIN users u1 ON c.participant_1_id = u1.id
    LEFT JOIN users u2 ON c.participant_2_id = u2.id
    WHERE c.participant_1_id = p_user_id OR c.participant_2_id = p_user_id
    ORDER BY c.last_message_at DESC NULLS LAST;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION get_user_conversations(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_conversations(UUID) TO service_role;