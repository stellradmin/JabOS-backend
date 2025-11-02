-- Create essential base schema that Edge Functions depend on

-- Create profiles table (referenced by many other tables)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    username TEXT UNIQUE,
    display_name TEXT,
    bio TEXT,
    avatar_url TEXT,
    zodiac_sign TEXT,
    age INTEGER,
    gender TEXT,
    looking_for TEXT,
    location JSONB,
    app_settings JSONB DEFAULT '{}',
    push_token TEXT,
    onboarding_completed BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create users table if needed
CREATE TABLE IF NOT EXISTS public.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT UNIQUE NOT NULL,
    stripe_customer_id TEXT UNIQUE,
    subscription_status TEXT DEFAULT 'inactive',
    subscription_tier TEXT DEFAULT 'free',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create conversations table
CREATE TABLE IF NOT EXISTS public.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    participant_1_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    participant_2_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    match_id UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_message_at TIMESTAMP WITH TIME ZONE,
    last_message_content TEXT,
    UNIQUE(participant_1_id, participant_2_id)
);

-- Create messages table
CREATE TABLE IF NOT EXISTS public.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID REFERENCES public.conversations(id) ON DELETE CASCADE,
    sender_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    message_type TEXT DEFAULT 'text',
    is_read BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create swipes table
CREATE TABLE IF NOT EXISTS public.swipes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    swiper_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    swiped_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    swipe_type TEXT CHECK (swipe_type IN ('like', 'pass')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(swiper_id, swiped_id)
);

-- Create matches table
CREATE TABLE IF NOT EXISTS public.matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user1_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    user2_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    match_request_id UUID,
    conversation_id UUID REFERENCES public.conversations(id),
    matched_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    status TEXT DEFAULT 'active',
    compatibility_score INTEGER,
    astrological_grade TEXT,
    questionnaire_grade TEXT,
    overall_score INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user1_id, user2_id)
);

-- Enable RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.swipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;

-- Basic RLS policies for Edge Functions to work
CREATE POLICY "Users can view their own profile" ON public.profiles
    FOR ALL USING (auth.uid() = id);

CREATE POLICY "Users can view discoverable profiles" ON public.profiles
    FOR SELECT USING (onboarding_completed = true);

CREATE POLICY "Users can insert their own swipes" ON public.swipes
    FOR INSERT WITH CHECK (auth.uid() = swiper_id);

CREATE POLICY "Users can view their own swipes" ON public.swipes
    FOR SELECT USING (auth.uid() = swiper_id OR auth.uid() = swiped_id);

CREATE POLICY "Users can view their conversations" ON public.conversations
    FOR ALL USING (auth.uid() = participant_1_id OR auth.uid() = participant_2_id);

CREATE POLICY "Users can view messages in their conversations" ON public.messages
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.conversations c
            WHERE c.id = conversation_id
            AND (c.participant_1_id = auth.uid() OR c.participant_2_id = auth.uid())
        )
    );

-- Create essential function for Edge Functions
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
                    'id', p2.id,
                    'display_name', COALESCE(p2.display_name, 'Unknown'),
                    'avatar_url', p2.avatar_url
                )
            ELSE 
                jsonb_build_object(
                    'id', p1.id,
                    'display_name', COALESCE(p1.display_name, 'Unknown'),
                    'avatar_url', p1.avatar_url
                )
        END as other_participant
    FROM conversations c
    LEFT JOIN profiles p1 ON c.participant_1_id = p1.id
    LEFT JOIN profiles p2 ON c.participant_2_id = p2.id
    WHERE c.participant_1_id = p_user_id OR c.participant_2_id = p_user_id
    ORDER BY c.last_message_at DESC NULLS LAST;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION get_user_conversations(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_conversations(UUID) TO service_role;