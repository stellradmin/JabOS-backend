-- Critical Constraints Only - Simplified for Launch
-- This migration adds only the most essential constraints and indexes

-- Remove duplicate RLS policies first
DROP POLICY IF EXISTS "Service role bypass RLS" ON public.profiles;
DROP POLICY IF EXISTS "Service role bypass RLS" ON public.users;  
DROP POLICY IF EXISTS "Service role bypass RLS" ON public.matches;
DROP POLICY IF EXISTS "Service role bypass RLS" ON public.swipes;
DROP POLICY IF EXISTS "Service role bypass RLS" ON public.conversations;
DROP POLICY IF EXISTS "Service role bypass RLS" ON public.messages;

-- Add unique constraint to prevent duplicate matches
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'unique_user_pair') THEN
        ALTER TABLE public.matches ADD CONSTRAINT unique_user_pair UNIQUE (user1_id, user2_id);
    END IF;
END $$;

-- Add unique constraint to prevent duplicate swipes
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'unique_swipe_pair') THEN
        ALTER TABLE public.swipes ADD CONSTRAINT unique_swipe_pair UNIQUE (swiper_id, swiped_id);
    END IF;
END $$;

-- Add critical performance index for user discovery
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_profiles_discovery') THEN
        CREATE INDEX idx_profiles_discovery ON public.profiles (onboarding_completed, gender, age) WHERE onboarding_completed = true;
    END IF;
END $$;

-- Add index for mutual match checking
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_swipes_mutual_check') THEN
        CREATE INDEX idx_swipes_mutual_check ON public.swipes (swiped_id, swiper_id, swipe_type);
    END IF;
END $$;

-- Add index for message retrieval
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_messages_conversation_time') THEN
        CREATE INDEX idx_messages_conversation_time ON public.messages (conversation_id, created_at DESC);
    END IF;
END $$;

-- Clean up any existing duplicate matches
WITH duplicate_matches AS (
    SELECT id, ROW_NUMBER() OVER (
        PARTITION BY LEAST(user1_id, user2_id), GREATEST(user1_id, user2_id) 
        ORDER BY created_at
    ) as row_num
    FROM public.matches
)
DELETE FROM public.matches 
WHERE id IN (
    SELECT id FROM duplicate_matches WHERE row_num > 1
);

-- Verification
DO $$
BEGIN
    RAISE NOTICE 'Critical fixes applied successfully';
    RAISE NOTICE 'Unique constraints: matches=%, swipes=%', 
        (SELECT COUNT(*) FROM pg_constraint WHERE conname = 'unique_user_pair'),
        (SELECT COUNT(*) FROM pg_constraint WHERE conname = 'unique_swipe_pair');
    RAISE NOTICE 'Performance indexes: discovery=%, mutual_check=%, messages=%',
        (SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'idx_profiles_discovery'),
        (SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'idx_swipes_mutual_check'),
        (SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'idx_messages_conversation_time');
END $$;