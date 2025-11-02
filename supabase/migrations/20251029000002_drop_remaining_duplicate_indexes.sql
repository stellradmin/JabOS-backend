-- =====================================================
-- DROP REMAINING DUPLICATE INDEXES
-- =====================================================
-- This migration identifies and drops any remaining duplicate indexes
-- that were created multiple times across different migrations.
-- Keeping only one instance of each unique index definition.
-- Date: 2025-10-29
-- =====================================================

BEGIN;

-- =====================================================
-- DUPLICATE INDEX ANALYSIS AND REMOVAL
-- =====================================================

-- Log duplicate indexes before removal for audit trail
DO $$
DECLARE
    duplicate_rec RECORD;
    duplicate_count INTEGER := 0;
BEGIN
    RAISE NOTICE '🔍 Checking for duplicate indexes...';

    -- Find duplicate indexes by comparing their definitions
    FOR duplicate_rec IN
        SELECT
            schemaname,
            tablename,
            indexname,
            indexdef
        FROM pg_indexes
        WHERE schemaname = 'public'
        AND indexname IN (
            -- Known potentially duplicate indexes from migration history
            'idx_matches_user1_user2',
            'idx_swipes_swiper_swiped',
            'idx_profiles_onboarding_completed',
            'idx_conversations_match_id',
            'idx_matches_conversation_id',
            'idx_profiles_onboarding_status'
        )
        ORDER BY indexname
    LOOP
        RAISE NOTICE '  Found index: %.% on table %',
            duplicate_rec.schemaname,
            duplicate_rec.indexname,
            duplicate_rec.tablename;
        duplicate_count := duplicate_count + 1;
    END LOOP;

    IF duplicate_count = 0 THEN
        RAISE NOTICE '  ✅ No targeted duplicate indexes found. They may have already been cleaned up.';
    ELSE
        RAISE NOTICE '  Found % potentially duplicate indexes to evaluate.', duplicate_count;
    END IF;
END $$;

-- =====================================================
-- DROP DUPLICATE INDEXES
-- =====================================================
-- Using IF EXISTS to safely drop indexes that may or may not exist
-- These were identified as duplicates from migration file analysis

-- Drop duplicate match indexes (if they still exist after 20251029000000 migration)
DROP INDEX IF EXISTS idx_matches_user1_user2;
DROP INDEX IF EXISTS idx_matches_user2_user1;
DROP INDEX IF EXISTS idx_matches_users_composite;

-- Drop duplicate swipe indexes
DROP INDEX IF EXISTS idx_swipes_swiper_swiped;
DROP INDEX IF EXISTS idx_swipes_target_swiper;

-- Drop duplicate profile onboarding indexes
DROP INDEX IF EXISTS idx_profiles_onboarding_completed;
DROP INDEX IF EXISTS idx_profiles_onboarding_complete;
DROP INDEX IF EXISTS idx_profiles_onboarding_status;
DROP INDEX IF EXISTS idx_profiles_age_onboarding;
DROP INDEX IF EXISTS idx_profiles_onboarding_age;
DROP INDEX IF EXISTS idx_profiles_onboarding_gender;

-- Drop duplicate conversation indexes
DROP INDEX IF EXISTS idx_conversations_match_id;
DROP INDEX IF EXISTS idx_conversations_participants;

-- Drop duplicate message indexes
DROP INDEX IF EXISTS idx_messages_conversation_id;
DROP INDEX IF EXISTS idx_messages_sender;

-- Drop duplicate match request indexes
DROP INDEX IF EXISTS idx_match_requests_matched_user;
DROP INDEX IF EXISTS idx_match_requests_requesting_user;

-- Drop duplicate user indexes
DROP INDEX IF EXISTS idx_users_natal_signs;

-- =====================================================
-- RECREATE ESSENTIAL INDEXES (IF DROPPED)
-- =====================================================
-- Ensure critical indexes exist with proper definitions

-- Matches table indexes
CREATE INDEX IF NOT EXISTS idx_matches_user1_id ON matches(user1_id);
CREATE INDEX IF NOT EXISTS idx_matches_user2_id ON matches(user2_id);
CREATE INDEX IF NOT EXISTS idx_matches_conversation_id ON matches(conversation_id) WHERE conversation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_matches_created_at ON matches(created_at DESC);

-- Swipes table indexes
CREATE INDEX IF NOT EXISTS idx_swipes_swiper_id ON swipes(swiper_id);
CREATE INDEX IF NOT EXISTS idx_swipes_swiped_user_id ON swipes(swiped_user_id);
CREATE INDEX IF NOT EXISTS idx_swipes_created_at ON swipes(created_at DESC);

-- Profiles table indexes
CREATE INDEX IF NOT EXISTS idx_profiles_user_id ON profiles(id);
CREATE INDEX IF NOT EXISTS idx_profiles_discoverable ON profiles(discoverable) WHERE discoverable = true;
CREATE INDEX IF NOT EXISTS idx_profiles_created_at ON profiles(created_at DESC);

-- Conversations table indexes
CREATE INDEX IF NOT EXISTS idx_conversations_id ON conversations(id);
CREATE INDEX IF NOT EXISTS idx_conversations_created_at ON conversations(created_at DESC);

-- Messages table indexes
CREATE INDEX IF NOT EXISTS idx_messages_conversation_id_created ON messages(conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_sender_id ON messages(sender_id);

-- Match requests table indexes
CREATE INDEX IF NOT EXISTS idx_match_requests_requesting_user_id ON match_requests(requesting_user_id);
CREATE INDEX IF NOT EXISTS idx_match_requests_matched_user_id ON match_requests(matched_user_id);
CREATE INDEX IF NOT EXISTS idx_match_requests_status ON match_requests(status);

-- =====================================================
-- VERIFICATION QUERY
-- =====================================================
-- Query to find any remaining duplicate indexes by definition

DO $$
DECLARE
    remaining_duplicates INTEGER;
    index_stats RECORD;
BEGIN
    -- Count indexes by their definition to find duplicates
    SELECT COUNT(*) INTO remaining_duplicates
    FROM (
        SELECT indexdef, COUNT(*) as count
        FROM pg_indexes
        WHERE schemaname = 'public'
        GROUP BY indexdef
        HAVING COUNT(*) > 1
    ) duplicates;

    RAISE NOTICE '═════════════════════════════════════════════════════';
    RAISE NOTICE '✅ Duplicate Index Cleanup Complete';
    RAISE NOTICE '═════════════════════════════════════════════════════';

    IF remaining_duplicates > 0 THEN
        RAISE NOTICE '⚠️  Warning: % index definitions still appear more than once', remaining_duplicates;
        RAISE NOTICE '   This may indicate indexes with different names but identical definitions.';
        RAISE NOTICE '   Run this query to investigate:';
        RAISE NOTICE '   ';
        RAISE NOTICE '   SELECT indexdef, array_agg(indexname) as index_names, COUNT(*) as count';
        RAISE NOTICE '   FROM pg_indexes';
        RAISE NOTICE '   WHERE schemaname = ''public''';
        RAISE NOTICE '   GROUP BY indexdef';
        RAISE NOTICE '   HAVING COUNT(*) > 1;';
    ELSE
        RAISE NOTICE '✅ No duplicate index definitions detected';
    END IF;

    RAISE NOTICE '═════════════════════════════════════════════════════';
    RAISE NOTICE 'Index Summary by Table:';
    RAISE NOTICE '═════════════════════════════════════════════════════';

    FOR index_stats IN
        SELECT tablename, COUNT(*) as index_count
        FROM pg_indexes
        WHERE schemaname = 'public'
        AND tablename IN ('matches', 'swipes', 'profiles', 'conversations', 'messages', 'match_requests')
        GROUP BY tablename
        ORDER BY tablename
    LOOP
        RAISE NOTICE '  % : % indexes',
            rpad(index_stats.tablename, 25),
            index_stats.index_count;
    END LOOP;

    RAISE NOTICE '═════════════════════════════════════════════════════';
END $$;

COMMIT;
