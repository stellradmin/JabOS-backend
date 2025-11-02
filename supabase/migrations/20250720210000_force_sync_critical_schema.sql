-- Force sync critical database functions for Edge Functions

-- Ensure swipes table exists
CREATE TABLE IF NOT EXISTS public.swipes (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    swiper_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    swiped_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    swipe_type TEXT CHECK (swipe_type IN ('like', 'pass')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Ensure matches table has all columns
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS compatibility_score INTEGER;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS astrological_grade TEXT;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS questionnaire_grade TEXT;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS overall_score INTEGER;

-- Ensure profiles table has required columns
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS age INTEGER;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS gender TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS looking_for TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS location JSONB;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS app_settings JSONB DEFAULT '{}';

-- Add RLS policies
ALTER TABLE public.swipes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can insert their own swipes" ON public.swipes;
CREATE POLICY "Users can insert their own swipes" ON public.swipes
    FOR INSERT WITH CHECK (auth.uid() = swiper_id);

DROP POLICY IF EXISTS "Users can view their own swipes" ON public.swipes;
CREATE POLICY "Users can view their own swipes" ON public.swipes
    FOR SELECT USING (auth.uid() = swiper_id OR auth.uid() = swiped_id);

-- Create essential functions for Edge Functions
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
                    'display_name', p2.display_name,
                    'avatar_url', p2.avatar_url
                )
            ELSE 
                jsonb_build_object(
                    'id', p1.id,
                    'display_name', p1.display_name,
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

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION get_user_conversations(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_conversations(UUID) TO service_role;