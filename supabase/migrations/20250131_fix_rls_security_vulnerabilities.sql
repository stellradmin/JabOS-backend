-- Fix Critical RLS Security Vulnerabilities
-- This migration addresses SQL injection risks and overly permissive access policies

-- 1. Fix overly permissive profile viewing policy
-- OLD: USING (true) - Allows viewing ALL profiles
-- NEW: Implement proper access controls

DROP POLICY IF EXISTS "Authenticated users can view other profiles (limited)" ON public.profiles;

-- 2. Create blocks table for user safety (must exist before policies reference it)
CREATE TABLE IF NOT EXISTS public.blocks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    blocker_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    blocked_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    reason TEXT,
    UNIQUE(blocker_id, blocked_id)
);

-- Enable RLS on blocks table
ALTER TABLE public.blocks ENABLE ROW LEVEL SECURITY;

-- Users can only see their own blocks
CREATE POLICY "Users can manage their own blocks"
    ON public.blocks FOR ALL
    USING (auth.uid() = blocker_id)
    WITH CHECK (auth.uid() = blocker_id);

-- Create a secure profile visibility policy
-- Users can only view profiles if:
-- 1. It's their own profile
-- 2. They have an active match with the user
-- 3. The profile is marked as discoverable AND they haven't been blocked
CREATE POLICY "Users can view matched or discoverable profiles"
    ON public.profiles FOR SELECT
    TO authenticated
    USING (
        -- Own profile
        auth.uid() = id
        OR
        -- Has an active match
        EXISTS (
            SELECT 1 FROM public.matches m
            WHERE m.status = 'active'
            AND (
                (m.user1_id = auth.uid() AND m.user2_id = profiles.id) OR
                (m.user2_id = auth.uid() AND m.user1_id = profiles.id)
            )
        )
        OR
        -- Profile is discoverable and not blocked
        (
            profiles.onboarding_completed = true
            AND profiles.app_settings->>'is_discoverable' != 'false'
            AND NOT EXISTS (
                SELECT 1 FROM public.blocks b
                WHERE (b.blocker_id = auth.uid() AND b.blocked_id = profiles.id)
                OR (b.blocker_id = profiles.id AND b.blocked_id = auth.uid())
            )
        )
    );

-- 3. Add function to check if users can interact (not blocked)
CREATE OR REPLACE FUNCTION can_users_interact(user_a UUID, user_b UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT NOT EXISTS (
        SELECT 1 FROM public.blocks
        WHERE (blocker_id = user_a AND blocked_id = user_b)
        OR (blocker_id = user_b AND blocked_id = user_a)
    );
$$;

-- 4. Update swipes policy to prevent interaction with blocked users
DROP POLICY IF EXISTS "Users can insert their own swipes" ON public.swipes;
CREATE POLICY "Users can insert swipes on non-blocked users"
    ON public.swipes FOR INSERT
    WITH CHECK (
        swiper_id = auth.uid() 
        AND can_users_interact(auth.uid(), swiped_id)
    );

-- 5. Update messages policy to prevent messages to blocked users
-- Guard creation until is_conversation_participant function exists
DO $$
BEGIN
    -- Drop legacy policy if present
    IF EXISTS (
        SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'messages' AND policyname = 'Users can insert messages into their conversations'
    ) THEN
        EXECUTE 'DROP POLICY "Users can insert messages into their conversations" ON public.messages';
    END IF;

    -- Only create the new policy if the helper function is available
    IF to_regprocedure('public.is_conversation_participant(uuid,uuid)') IS NOT NULL THEN
        EXECUTE 'CREATE POLICY "Users can send messages in active conversations"\n'
            '    ON public.messages FOR INSERT\n'
            '    WITH CHECK (\n'
            '        sender_id = auth.uid() \n'
            '        AND is_conversation_participant(conversation_id, auth.uid())\n'
            '        AND EXISTS (\n'
            '            SELECT 1 FROM public.conversations c\n'
            '            WHERE c.id = conversation_id\n'
            '            AND can_users_interact(c.participant_1_id, c.participant_2_id)\n'
            '        )\n'
            '    );';
    END IF;
END$$;

-- 6. Add profile data masking for non-matched users
-- Create a view that masks sensitive data
CREATE OR REPLACE VIEW public.discoverable_profiles AS
SELECT 
    id,
    display_name,
    age,
    zodiac_sign,
    gender,
    looking_for,
    -- Mask exact location for privacy
    jsonb_build_object(
        'city', location->>'city',
        'state', location->>'state',
        'country', location->>'country'
    ) as location,
    -- Only show first photo for discovery
    CASE 
        WHEN avatar_url IS NOT NULL THEN 
            jsonb_build_array(avatar_url)
        ELSE 
            '[]'::jsonb
    END as photos,
    -- Limited bio preview
    CASE 
        WHEN length(bio) > 150 THEN 
            substring(bio, 1, 147) || '...'
        ELSE 
            bio
    END as bio_preview,
    created_at
FROM public.profiles
WHERE onboarding_completed = true
AND app_settings->>'is_discoverable' != 'false';

-- Grant access to the view
GRANT SELECT ON public.discoverable_profiles TO authenticated;

-- 7. Views do not support RLS policies. Grant is defined above and base table RLS applies through the view.
-- Skipping CREATE POLICY on view.

-- 8. Add function to get full profile data (only for matches)
CREATE OR REPLACE FUNCTION get_matched_profile(profile_id UUID)
RETURNS TABLE (
    id UUID,
    username TEXT,
    display_name TEXT,
    bio TEXT,
    avatar_url TEXT,
    zodiac_sign TEXT,
    age INTEGER,
    gender TEXT,
    looking_for TEXT,
    location JSONB,
    created_at TIMESTAMP WITH TIME ZONE,
    -- Additional match context
    match_id UUID,
    matched_at TIMESTAMP WITH TIME ZONE,
    compatibility_score INTEGER
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT 
        p.id,
        p.username,
        p.display_name,
        p.bio,
        p.avatar_url,
        p.zodiac_sign,
        p.age,
        p.gender,
        p.looking_for,
        p.location,
        p.created_at,
        m.id as match_id,
        m.matched_at,
        m.compatibility_score
    FROM public.profiles p
    JOIN public.matches m ON (
        (m.user1_id = auth.uid() AND m.user2_id = p.id) OR
        (m.user2_id = auth.uid() AND m.user1_id = p.id)
    )
    WHERE p.id = profile_id
    AND m.status = 'active';
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION get_matched_profile(UUID) TO authenticated;

-- 9. Add rate limiting metadata to profiles
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS last_swipe_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS daily_swipe_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS last_swipe_reset TIMESTAMP WITH TIME ZONE DEFAULT NOW();

-- 10. Create function to check and update swipe limits
CREATE OR REPLACE FUNCTION check_swipe_limit(user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_last_reset TIMESTAMP WITH TIME ZONE;
    v_daily_count INTEGER;
    v_is_premium BOOLEAN;
    v_daily_limit INTEGER;
BEGIN
    -- Get user's swipe data
    SELECT last_swipe_reset, daily_swipe_count
    INTO v_last_reset, v_daily_count
    FROM public.profiles
    WHERE id = user_id;

    -- Check if we need to reset the counter (new day)
    IF v_last_reset < CURRENT_DATE THEN
        UPDATE public.profiles
        SET daily_swipe_count = 0,
            last_swipe_reset = CURRENT_DATE
        WHERE id = user_id;
        v_daily_count := 0;
    END IF;

    -- Check subscription status
    SELECT COALESCE(u.subscription_tier = 'premium', false)
    INTO v_is_premium
    FROM public.users u
    WHERE u.auth_user_id = user_id;

    -- Set limits based on subscription
    v_daily_limit := CASE 
        WHEN v_is_premium THEN 100
        ELSE 30
    END;

    -- Return whether user can swipe
    RETURN v_daily_count < v_daily_limit;
END;
$$;

-- 11. Update swipes insert policy to include rate limiting
DROP POLICY IF EXISTS "Users can insert swipes on non-blocked users" ON public.swipes;
CREATE POLICY "Users can swipe within limits on non-blocked users"
    ON public.swipes FOR INSERT
    WITH CHECK (
        swiper_id = auth.uid() 
        AND can_users_interact(auth.uid(), swiped_id)
        AND check_swipe_limit(auth.uid())
    );

-- 12. Add trigger to update swipe count
CREATE OR REPLACE FUNCTION update_swipe_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.profiles
    SET daily_swipe_count = daily_swipe_count + 1,
        last_swipe_at = NOW()
    WHERE id = NEW.swiper_id;
    
    RETURN NEW;
END;
$$;

CREATE TRIGGER increment_swipe_count
    AFTER INSERT ON public.swipes
    FOR EACH ROW
    EXECUTE FUNCTION update_swipe_count();

-- 13. Create secure function for profile search with filters
CREATE OR REPLACE FUNCTION search_discoverable_profiles(
    p_min_age INTEGER DEFAULT NULL,
    p_max_age INTEGER DEFAULT NULL,
    p_gender TEXT DEFAULT NULL,
    p_looking_for TEXT DEFAULT NULL,
    p_zodiac_sign TEXT DEFAULT NULL,
    p_max_distance_km NUMERIC DEFAULT NULL,
    p_user_location JSONB DEFAULT NULL,
    p_limit INTEGER DEFAULT 20,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    display_name TEXT,
    age INTEGER,
    zodiac_sign TEXT,
    gender TEXT,
    location_display TEXT,
    bio_preview TEXT,
    photo_url TEXT,
    distance_km NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        p.id,
        p.display_name,
        p.age,
        p.zodiac_sign,
        p.gender,
        COALESCE(p.location->>'city', 'Unknown') || ', ' || 
        COALESCE(p.location->>'state', p.location->>'country', '') as location_display,
        CASE 
            WHEN length(p.bio) > 150 THEN 
                substring(p.bio, 1, 147) || '...'
            ELSE 
                p.bio
        END as bio_preview,
        p.avatar_url as photo_url,
        CASE 
            WHEN p_user_location IS NOT NULL AND p.location->>'latitude' IS NOT NULL THEN
                earth_distance(
                    ll_to_earth(
                        (p_user_location->>'latitude')::float,
                        (p_user_location->>'longitude')::float
                    ),
                    ll_to_earth(
                        (p.location->>'latitude')::float,
                        (p.location->>'longitude')::float
                    )
                ) / 1000 -- Convert to km
            ELSE NULL
        END as distance_km
    FROM public.profiles p
    WHERE p.id != auth.uid()
    AND p.onboarding_completed = true
    AND p.app_settings->>'is_discoverable' != 'false'
    -- Age filter
    AND (p_min_age IS NULL OR p.age >= p_min_age)
    AND (p_max_age IS NULL OR p.age <= p_max_age)
    -- Gender filter
    AND (p_gender IS NULL OR p.gender = p_gender)
    -- Looking for filter
    AND (p_looking_for IS NULL OR p.looking_for = p_looking_for)
    -- Zodiac filter
    AND (p_zodiac_sign IS NULL OR p.zodiac_sign = p_zodiac_sign)
    -- Not blocked
    AND NOT EXISTS (
        SELECT 1 FROM public.blocks b
        WHERE (b.blocker_id = auth.uid() AND b.blocked_id = p.id)
        OR (b.blocker_id = p.id AND b.blocked_id = auth.uid())
    )
    -- Not already swiped
    AND NOT EXISTS (
        SELECT 1 FROM public.swipes s
        WHERE s.swiper_id = auth.uid() AND s.swiped_id = p.id
    )
    -- Distance filter (if location provided)
    AND (
        p_max_distance_km IS NULL 
        OR p_user_location IS NULL 
        OR p.location->>'latitude' IS NULL
        OR earth_distance(
            ll_to_earth(
                (p_user_location->>'latitude')::float,
                (p_user_location->>'longitude')::float
            ),
            ll_to_earth(
                (p.location->>'latitude')::float,
                (p.location->>'longitude')::float
            )
        ) / 1000 <= p_max_distance_km
    )
    ORDER BY 
        CASE WHEN p_user_location IS NOT NULL THEN distance_km ELSE 0 END,
        p.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION search_discoverable_profiles TO authenticated;

-- 14. Add indexes for performance
CREATE INDEX IF NOT EXISTS idx_profiles_discoverable 
    ON public.profiles(onboarding_completed, created_at) 
    WHERE onboarding_completed = true;

CREATE INDEX IF NOT EXISTS idx_profiles_age 
    ON public.profiles(age) 
    WHERE onboarding_completed = true;

CREATE INDEX IF NOT EXISTS idx_profiles_gender 
    ON public.profiles(gender) 
    WHERE onboarding_completed = true;

CREATE INDEX IF NOT EXISTS idx_blocks_blocker 
    ON public.blocks(blocker_id);

CREATE INDEX IF NOT EXISTS idx_blocks_blocked 
    ON public.blocks(blocked_id);

CREATE INDEX IF NOT EXISTS idx_swipes_swiper_swiped 
    ON public.swipes(swiper_id, swiped_id);

-- Add comment explaining the security improvements
COMMENT ON POLICY "Users can view matched or discoverable profiles" ON public.profiles IS
'Secure profile visibility policy that prevents unauthorized access. Users can only view:
1. Their own profile
2. Profiles they have matched with
3. Discoverable profiles (if not blocked)
This replaces the previous overly permissive policy that allowed viewing all profiles.';