-- STELLR PRODUCTION FIX: Database Schema Column Alignment
-- Fixes column name mismatches between code and database schema
-- Ensures consistency between TypeScript types and actual database structure

-- =============================================================================
-- MATCHES TABLE: Fix column naming inconsistencies
-- =============================================================================

-- The code expects compatibility_score (INTEGER) but some places expect overall_score
-- Ensure we have both for backward compatibility during transition
DO $$
BEGIN
    -- Check if overall_score column exists and rename/standardize
    IF EXISTS (SELECT 1 FROM information_schema.columns 
               WHERE table_schema = 'public' 
               AND table_name = 'matches' 
               AND column_name = 'overall_score') THEN
        
        -- If compatibility_score doesn't exist, rename overall_score
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                      WHERE table_schema = 'public' 
                      AND table_name = 'matches' 
                      AND column_name = 'compatibility_score') THEN
            ALTER TABLE public.matches RENAME COLUMN overall_score TO compatibility_score;
        ELSE
            -- Both exist, copy data and drop duplicate
            UPDATE public.matches
            SET compatibility_score = COALESCE(compatibility_score, overall_score)
            WHERE compatibility_score IS NULL AND overall_score IS NOT NULL;

            -- Drop the duplicate column with CASCADE to handle dependencies
            BEGIN
                ALTER TABLE public.matches DROP COLUMN IF EXISTS overall_score CASCADE;
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'Could not drop overall_score column: %. Keeping both columns for compatibility.', SQLERRM;
            END;
        END IF;
    END IF;

    -- Ensure compatibility_score column exists with proper type
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'matches' 
                  AND column_name = 'compatibility_score') THEN
        ALTER TABLE public.matches ADD COLUMN compatibility_score INTEGER;
    END IF;

    -- Ensure proper JSONB columns exist for compatibility data
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'matches' 
                  AND column_name = 'astro_compatibility') THEN
        ALTER TABLE public.matches ADD COLUMN astro_compatibility JSONB DEFAULT '{}'::jsonb;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'matches' 
                  AND column_name = 'questionnaire_compatibility') THEN
        ALTER TABLE public.matches ADD COLUMN questionnaire_compatibility JSONB DEFAULT '{}'::jsonb;
    END IF;
END $$;

-- =============================================================================
-- SWIPES TABLE: Ensure proper structure aligns with code expectations
-- =============================================================================

DO $$
BEGIN
    -- Ensure swipes table has location_context column for mobile app support
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'swipes' 
                  AND column_name = 'location_context') THEN
        ALTER TABLE public.swipes ADD COLUMN location_context JSONB;
    END IF;
END $$;

-- =============================================================================
-- MATCH_REQUESTS TABLE: Ensure compatibility with code expectations
-- =============================================================================

DO $$
BEGIN
    -- Ensure expires_at column exists (critical for request expiration)
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'match_requests' 
                  AND column_name = 'expires_at') THEN
        ALTER TABLE public.match_requests ADD COLUMN expires_at TIMESTAMP WITH TIME ZONE 
            DEFAULT (NOW() + INTERVAL '7 days');
    END IF;

    -- Ensure response_message column exists for custom rejection messages
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'match_requests' 
                  AND column_name = 'response_message') THEN
        ALTER TABLE public.match_requests ADD COLUMN response_message TEXT;
    END IF;

    -- Fix compatibility_details column type consistency
    IF EXISTS (SELECT 1 FROM information_schema.columns 
              WHERE table_schema = 'public' 
              AND table_name = 'match_requests' 
              AND column_name = 'compatibility_details'
              AND data_type != 'jsonb') THEN
        -- Convert to JSONB if it's not already
        ALTER TABLE public.match_requests 
        ALTER COLUMN compatibility_details TYPE JSONB USING compatibility_details::jsonb;
    END IF;
END $$;

-- =============================================================================
-- PROFILES TABLE: Ensure encrypted data columns exist
-- =============================================================================

DO $$
BEGIN
    -- Ensure birth_data_encrypted column exists for encrypted birth info
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'profiles' 
                  AND column_name = 'birth_data_encrypted') THEN
        ALTER TABLE public.profiles ADD COLUMN birth_data_encrypted BOOLEAN DEFAULT FALSE;
    END IF;

    -- Ensure interests column is properly typed as array
    IF EXISTS (SELECT 1 FROM information_schema.columns 
              WHERE table_schema = 'public' 
              AND table_name = 'profiles' 
              AND column_name = 'interests'
              AND data_type != 'ARRAY') THEN
        -- Convert interests to text array if not already
        ALTER TABLE public.profiles 
        ALTER COLUMN interests TYPE TEXT[] USING 
            CASE 
                WHEN interests IS NULL THEN NULL
                WHEN jsonb_typeof(interests::jsonb) = 'array' THEN 
                    ARRAY(SELECT jsonb_array_elements_text(interests::jsonb))
                ELSE ARRAY[interests::text]
            END;
    END IF;
END $$;

-- =============================================================================
-- CONVERSATIONS TABLE: Ensure proper structure
-- =============================================================================

DO $$
BEGIN
    -- Ensure user1_id and user2_id columns exist (consistent with matches table naming)
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'conversations' 
                  AND column_name = 'user1_id') THEN
        
        -- Check if old column names exist and rename them
        IF EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'conversations' 
                  AND column_name = 'participant_1_id') THEN
            ALTER TABLE public.conversations RENAME COLUMN participant_1_id TO user1_id;
        ELSE
            ALTER TABLE public.conversations ADD COLUMN user1_id UUID REFERENCES auth.users(id);
        END IF;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'conversations' 
                  AND column_name = 'user2_id') THEN
        
        -- Check if old column names exist and rename them
        IF EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'conversations' 
                  AND column_name = 'participant_2_id') THEN
            ALTER TABLE public.conversations RENAME COLUMN participant_2_id TO user2_id;
        ELSE
            ALTER TABLE public.conversations ADD COLUMN user2_id UUID REFERENCES auth.users(id);
        END IF;
    END IF;
END $$;

-- =============================================================================
-- MESSAGES TABLE: Ensure proper sender_id column
-- =============================================================================

DO $$
BEGIN
    -- Ensure sender_id column exists and is properly typed
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'messages' 
                  AND column_name = 'sender_id') THEN
        ALTER TABLE public.messages ADD COLUMN sender_id UUID REFERENCES auth.users(id);
    END IF;

    -- Ensure content column exists for message text
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                  WHERE table_schema = 'public' 
                  AND table_name = 'messages' 
                  AND column_name = 'content') THEN
        ALTER TABLE public.messages ADD COLUMN content TEXT NOT NULL;
    END IF;
END $$;

-- =============================================================================
-- ENCRYPTED_BIRTH_DATA TABLE: Ensure proper structure for encryption
-- =============================================================================

DO $$
BEGIN
    -- Create table if it doesn't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables 
                  WHERE table_schema = 'public' 
                  AND table_name = 'encrypted_birth_data') THEN
        CREATE TABLE public.encrypted_birth_data (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
            encrypted_data BYTEA NOT NULL,
            encryption_key_id TEXT NOT NULL,
            salt TEXT NOT NULL,
            iv TEXT NOT NULL,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
            updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
            
            UNIQUE(user_id)
        );

        -- Add RLS
        ALTER TABLE public.encrypted_birth_data ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

-- =============================================================================
-- DATE_PROPOSALS TABLE: Ensure proper structure
-- =============================================================================

DO $$
BEGIN
    -- Ensure proper column types for date proposals
    IF EXISTS (SELECT 1 FROM information_schema.tables 
              WHERE table_schema = 'public' 
              AND table_name = 'date_proposals') THEN
        
        -- Ensure proposed_date is properly typed
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                      WHERE table_schema = 'public' 
                      AND table_name = 'date_proposals' 
                      AND column_name = 'proposed_date'
                      AND data_type = 'timestamp with time zone') THEN
            ALTER TABLE public.date_proposals 
            ALTER COLUMN proposed_date TYPE TIMESTAMP WITH TIME ZONE;
        END IF;

        -- Ensure location column exists
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                      WHERE table_schema = 'public' 
                      AND table_name = 'date_proposals' 
                      AND column_name = 'location') THEN
            ALTER TABLE public.date_proposals ADD COLUMN location TEXT;
        END IF;
    END IF;
END $$;

-- =============================================================================
-- AUDIT_LOGS TABLE: Ensure proper logging structure
-- =============================================================================

DO $$
BEGIN
    -- Create audit_logs table if it doesn't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables 
                  WHERE table_schema = 'public' 
                  AND table_name = 'audit_logs') THEN
        CREATE TABLE public.audit_logs (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id UUID REFERENCES auth.users(id),
            action TEXT NOT NULL,
            table_name TEXT,
            record_id UUID,
            old_values JSONB,
            new_values JSONB,
            ip_address INET,
            user_agent TEXT,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
        );

        -- Add indexes for performance
        CREATE INDEX idx_audit_logs_user_id ON public.audit_logs(user_id);
        CREATE INDEX idx_audit_logs_action ON public.audit_logs(action);
        CREATE INDEX idx_audit_logs_created_at ON public.audit_logs(created_at);
        
        -- Add RLS
        ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

-- =============================================================================
-- CONSTRAINTS AND INDEXES: Ensure proper relationships
-- =============================================================================

-- Add missing constraints that code expects
DO $$
BEGIN
    -- Ensure matches table has proper constraints
    IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints 
                  WHERE table_schema = 'public' 
                  AND table_name = 'matches'
                  AND constraint_name = 'matches_users_unique') THEN
        ALTER TABLE public.matches 
        ADD CONSTRAINT matches_users_unique UNIQUE (user1_id, user2_id);
    END IF;

    -- Ensure swipes table has proper constraint to prevent duplicate swipes
    IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints 
                  WHERE table_schema = 'public' 
                  AND table_name = 'swipes'
                  AND constraint_name = 'swipes_unique_pair') THEN
        ALTER TABLE public.swipes 
        ADD CONSTRAINT swipes_unique_pair UNIQUE (swiper_id, swiped_id);
    END IF;

    -- Ensure match_requests has proper constraints
    IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints 
                  WHERE table_schema = 'public' 
                  AND table_name = 'match_requests'
                  AND constraint_name = 'match_requests_unique_pair') THEN
        ALTER TABLE public.match_requests 
        ADD CONSTRAINT match_requests_unique_pair UNIQUE (requester_id, matched_user_id);
    END IF;
END $$;

-- =============================================================================
-- PERFORMANCE INDEXES: Ensure proper query performance
-- =============================================================================

-- Add performance indexes that the code expects
CREATE INDEX IF NOT EXISTS idx_matches_user1_user2 ON public.matches(user1_id, user2_id);
CREATE INDEX IF NOT EXISTS idx_swipes_swiper_swiped ON public.swipes(swiper_id, swiped_id);
CREATE INDEX IF NOT EXISTS idx_match_requests_matched_user ON public.match_requests(matched_user_id);
CREATE INDEX IF NOT EXISTS idx_conversations_users ON public.conversations(user1_id, user2_id);
CREATE INDEX IF NOT EXISTS idx_messages_conversation ON public.messages(conversation_id);

-- =============================================================================
-- DATA TYPE CONSISTENCY: Ensure all columns match code expectations
-- =============================================================================

-- Ensure all ID columns are UUID type
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT table_name, column_name 
        FROM information_schema.columns 
        WHERE table_schema = 'public' 
        AND column_name LIKE '%_id' 
        AND data_type != 'uuid'
        AND table_name IN ('matches', 'swipes', 'match_requests', 'conversations', 'messages')
    ) LOOP
        BEGIN
            EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I TYPE UUID USING %I::uuid', 
                          r.table_name, r.column_name, r.column_name);
        EXCEPTION WHEN OTHERS THEN
            -- Log error but continue
            RAISE NOTICE 'Could not convert column %.% to UUID: %', r.table_name, r.column_name, SQLERRM;
        END;
    END LOOP;
END $$;

-- =============================================================================
-- VALIDATION: Check schema consistency
-- =============================================================================

-- Create a view to validate schema consistency
CREATE OR REPLACE VIEW public.schema_validation AS
SELECT 
    table_name,
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns 
WHERE table_schema = 'public'
AND table_name IN ('matches', 'swipes', 'match_requests', 'conversations', 'messages', 'profiles')
ORDER BY table_name, ordinal_position;

-- Add comment documenting this migration
COMMENT ON VIEW public.schema_validation IS 
'Validation view to ensure database schema matches TypeScript type definitions. Use this to verify column types and constraints.';

-- =============================================================================
-- COMPLETION LOG
-- =============================================================================

-- Log migration completion (fail gracefully if audit_logs structure differs)
DO $$
BEGIN
    INSERT INTO public.audit_logs (action, table_name, new_values, created_at)
    VALUES (
        'schema_migration_completed',
        'system',
        jsonb_build_object(
            'migration', '20250905000002_fix_schema_column_mismatches',
            'description', 'Fixed column naming inconsistencies between code and database',
            'tables_affected', ARRAY['matches', 'swipes', 'match_requests', 'conversations', 'messages', 'profiles'],
            'completion_time', NOW()
        ),
        NOW()
    );
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not log migration completion to audit_logs: %. Continuing migration.', SQLERRM;
END $$;

-- End of schema column mismatch fixes