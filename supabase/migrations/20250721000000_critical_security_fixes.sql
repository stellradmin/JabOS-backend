-- ========================================
-- CRITICAL SECURITY FIXES FOR PRODUCTION
-- ========================================

-- This migration addresses critical security vulnerabilities identified in the production readiness audit
-- Priority: IMMEDIATE - These fixes are required before production deployment

-- 1. Fix RLS Policy Security Bypass Issues
-- Remove any dangerous "WITH CHECK (true)" policies and replace with proper authorization

-- Drop any existing dangerous policies that might exist (conditional for non-existent tables)
DO $$
BEGIN
    -- Only drop policies for tables that exist
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'user_match_presentations') THEN
        DROP POLICY IF EXISTS "System can manage match presentations" ON public.user_match_presentations;
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'user_interaction_history') THEN
        DROP POLICY IF EXISTS "System can manage interaction history" ON public.user_interaction_history;
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'compatibility_matches') THEN
        DROP POLICY IF EXISTS "System can create compatibility matches" ON public.compatibility_matches;
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'compatibility_match_history') THEN
        DROP POLICY IF EXISTS "System can create compatibility match history" ON public.compatibility_match_history;
    END IF;
END $$;

-- 2. Ensure all critical tables have RLS enabled
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.swipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;

-- 3. Create secure RLS policies for core tables if they don't exist

-- Profiles table policies
DROP POLICY IF EXISTS "Users can view their own profile" ON public.profiles;
CREATE POLICY "Users can view their own profile" ON public.profiles
    FOR ALL USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can view discoverable profiles" ON public.profiles;
CREATE POLICY "Users can view discoverable profiles" ON public.profiles
    FOR SELECT USING (onboarding_completed = true AND auth.uid() != id);

DROP POLICY IF EXISTS "Service role can manage all profiles" ON public.profiles;
CREATE POLICY "Service role can manage all profiles" ON public.profiles
    FOR ALL USING (auth.role() = 'service_role');

-- Users table policies
DROP POLICY IF EXISTS "Users can view their own user record" ON public.users;
CREATE POLICY "Users can view their own user record" ON public.users
    FOR ALL USING (auth.uid() = id OR auth.uid() = auth_user_id);

DROP POLICY IF EXISTS "Service role can manage all users" ON public.users;
CREATE POLICY "Service role can manage all users" ON public.users
    FOR ALL USING (auth.role() = 'service_role');

-- Conversations table policies
DROP POLICY IF EXISTS "Users can view their conversations" ON public.conversations;
CREATE POLICY "Users can view their conversations" ON public.conversations
    FOR ALL USING (auth.uid() = participant_1_id OR auth.uid() = participant_2_id);

DROP POLICY IF EXISTS "Service role can manage conversations" ON public.conversations;
CREATE POLICY "Service role can manage conversations" ON public.conversations
    FOR ALL USING (auth.role() = 'service_role');

-- Messages table policies
DROP POLICY IF EXISTS "Users can view messages in their conversations" ON public.messages;
CREATE POLICY "Users can view messages in their conversations" ON public.messages
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.conversations c
            WHERE c.id = conversation_id
            AND (c.participant_1_id = auth.uid() OR c.participant_2_id = auth.uid())
        )
    );

DROP POLICY IF EXISTS "Users can send messages to their conversations" ON public.messages;
CREATE POLICY "Users can send messages to their conversations" ON public.messages
    FOR INSERT WITH CHECK (
        auth.uid() = sender_id AND
        EXISTS (
            SELECT 1 FROM public.conversations c
            WHERE c.id = conversation_id
            AND (c.participant_1_id = auth.uid() OR c.participant_2_id = auth.uid())
        )
    );

DROP POLICY IF EXISTS "Service role can manage messages" ON public.messages;
CREATE POLICY "Service role can manage messages" ON public.messages
    FOR ALL USING (auth.role() = 'service_role');

-- Swipes table policies
DROP POLICY IF EXISTS "Users can insert their own swipes" ON public.swipes;
CREATE POLICY "Users can insert their own swipes" ON public.swipes
    FOR INSERT WITH CHECK (auth.uid() = swiper_id);

DROP POLICY IF EXISTS "Users can view their own swipes" ON public.swipes;
CREATE POLICY "Users can view their own swipes" ON public.swipes
    FOR SELECT USING (auth.uid() = swiper_id);

DROP POLICY IF EXISTS "Service role can manage swipes" ON public.swipes;
CREATE POLICY "Service role can manage swipes" ON public.swipes
    FOR ALL USING (auth.role() = 'service_role');

-- Matches table policies
DROP POLICY IF EXISTS "Users can view their matches" ON public.matches;
CREATE POLICY "Users can view their matches" ON public.matches
    FOR SELECT USING (auth.uid() = user1_id OR auth.uid() = user2_id);

DROP POLICY IF EXISTS "Service role can manage matches" ON public.matches;
CREATE POLICY "Service role can manage matches" ON public.matches
    FOR ALL USING (auth.role() = 'service_role');

-- 4. Create secure policies for extended tables if they exist

-- Match presentations table (if exists)
DO $$
BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'user_match_presentations') THEN
        ALTER TABLE public.user_match_presentations ENABLE ROW LEVEL SECURITY;
        
        DROP POLICY IF EXISTS "Users can view their match presentations" ON public.user_match_presentations;
        CREATE POLICY "Users can view their match presentations" ON public.user_match_presentations
            FOR SELECT USING (auth.uid() = presenter_user_id OR auth.uid() = presented_user_id);
        
        DROP POLICY IF EXISTS "Users can insert match presentations" ON public.user_match_presentations;
        CREATE POLICY "Users can insert match presentations" ON public.user_match_presentations
            FOR INSERT WITH CHECK (auth.uid() = presenter_user_id);
        
        DROP POLICY IF EXISTS "Users can update match responses" ON public.user_match_presentations;
        CREATE POLICY "Users can update match responses" ON public.user_match_presentations
            FOR UPDATE USING (auth.uid() = presenter_user_id OR auth.uid() = presented_user_id)
            WITH CHECK (auth.uid() = presenter_user_id OR auth.uid() = presented_user_id);
        
        DROP POLICY IF EXISTS "Service role can manage match presentations" ON public.user_match_presentations;
        CREATE POLICY "Service role can manage match presentations" ON public.user_match_presentations
            FOR ALL USING (auth.role() = 'service_role');
    END IF;
END
$$;

-- User interaction history table (if exists)
DO $$
BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'user_interaction_history') THEN
        ALTER TABLE public.user_interaction_history ENABLE ROW LEVEL SECURITY;
        
        DROP POLICY IF EXISTS "Users can view their interaction history" ON public.user_interaction_history;
        CREATE POLICY "Users can view their interaction history" ON public.user_interaction_history
            FOR SELECT USING (auth.uid() = user1_id OR auth.uid() = user2_id);
        
        DROP POLICY IF EXISTS "Service role can manage interaction history" ON public.user_interaction_history;
        CREATE POLICY "Service role can manage interaction history" ON public.user_interaction_history
            FOR ALL USING (auth.role() = 'service_role');
    END IF;
END
$$;

-- Compatibility matches table (if exists)
DO $$
BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'compatibility_matches') THEN
        ALTER TABLE public.compatibility_matches ENABLE ROW LEVEL SECURITY;
        
        DROP POLICY IF EXISTS "Users can view their compatibility matches" ON public.compatibility_matches;
        CREATE POLICY "Users can view their compatibility matches" ON public.compatibility_matches
            FOR SELECT USING (auth.uid() = user1_id OR auth.uid() = user2_id);
        
        DROP POLICY IF EXISTS "Users can update their compatibility match response" ON public.compatibility_matches;
        CREATE POLICY "Users can update their compatibility match response" ON public.compatibility_matches
            FOR UPDATE USING (auth.uid() = user1_id OR auth.uid() = user2_id)
            WITH CHECK (auth.uid() = user1_id OR auth.uid() = user2_id);
        
        DROP POLICY IF EXISTS "Service role can create compatibility matches" ON public.compatibility_matches;
        CREATE POLICY "Service role can create compatibility matches" ON public.compatibility_matches
            FOR INSERT USING (auth.role() = 'service_role');
        
        DROP POLICY IF EXISTS "Service role can manage compatibility matches" ON public.compatibility_matches;
        CREATE POLICY "Service role can manage compatibility matches" ON public.compatibility_matches
            FOR ALL USING (auth.role() = 'service_role');
    END IF;
END
$$;

-- Compatibility match history table (if exists)
DO $$
BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'compatibility_match_history') THEN
        ALTER TABLE public.compatibility_match_history ENABLE ROW LEVEL SECURITY;
        
        DROP POLICY IF EXISTS "Users can view their compatibility match history" ON public.compatibility_match_history;
        CREATE POLICY "Users can view their compatibility match history" ON public.compatibility_match_history
            FOR SELECT USING (auth.uid() = user_id);
        
        DROP POLICY IF EXISTS "Service role can create compatibility match history" ON public.compatibility_match_history;
        CREATE POLICY "Service role can create compatibility match history" ON public.compatibility_match_history
            FOR INSERT USING (auth.role() = 'service_role');
    END IF;
END
$$;

-- 5. Create audit logging for security events
CREATE TABLE IF NOT EXISTS public.security_audit_log (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    event_type VARCHAR(100) NOT NULL,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    session_id TEXT,
    ip_address INET,
    user_agent TEXT,
    event_data JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Enable RLS for audit log (only service role can access)
ALTER TABLE public.security_audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role can manage security audit log" ON public.security_audit_log
    FOR ALL USING (auth.role() = 'service_role');

-- 6. Create function to validate RLS policy coverage
CREATE OR REPLACE FUNCTION public.validate_rls_coverage()
RETURNS TABLE(
    table_name TEXT,
    rls_enabled BOOLEAN,
    policy_count INTEGER,
    has_select_policy BOOLEAN,
    has_insert_policy BOOLEAN,
    has_update_policy BOOLEAN,
    has_delete_policy BOOLEAN,
    security_status TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.table_name::TEXT,
        COALESCE(rls.rls_enabled, false) as rls_enabled,
        COALESCE(p.policy_count, 0) as policy_count,
        COALESCE(p.has_select, false) as has_select_policy,
        COALESCE(p.has_insert, false) as has_insert_policy,
        COALESCE(p.has_update, false) as has_update_policy,
        COALESCE(p.has_delete, false) as has_delete_policy,
        CASE 
            WHEN NOT COALESCE(rls.rls_enabled, false) THEN 'CRITICAL: RLS Disabled'
            WHEN COALESCE(p.policy_count, 0) = 0 THEN 'CRITICAL: No Policies'
            WHEN NOT (COALESCE(p.has_select, false) AND COALESCE(p.has_insert, false)) THEN 'WARNING: Missing Core Policies'
            ELSE 'OK'
        END as security_status
    FROM information_schema.tables t
    LEFT JOIN (
        SELECT 
            schemaname || '.' || tablename as full_name,
            rowsecurity as rls_enabled
        FROM pg_tables 
        WHERE schemaname = 'public'
    ) rls ON t.table_schema || '.' || t.table_name = rls.full_name
    LEFT JOIN (
        SELECT 
            pol.schemaname || '.' || pol.tablename as full_name,
            COUNT(*) as policy_count,
            BOOL_OR(pol.cmd = 'SELECT') as has_select,
            BOOL_OR(pol.cmd = 'INSERT') as has_insert,
            BOOL_OR(pol.cmd = 'UPDATE') as has_update,
            BOOL_OR(pol.cmd = 'DELETE') as has_delete
        FROM pg_policies pol
        WHERE pol.schemaname = 'public'
        GROUP BY pol.schemaname, pol.tablename
    ) p ON t.table_schema || '.' || t.table_name = p.full_name
    WHERE t.table_schema = 'public'
    AND t.table_type = 'BASE TABLE'
    ORDER BY 
        CASE 
            WHEN NOT COALESCE(rls.rls_enabled, false) THEN 1
            WHEN COALESCE(p.policy_count, 0) = 0 THEN 2
            ELSE 3
        END,
        t.table_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute permission to service role only
GRANT EXECUTE ON FUNCTION public.validate_rls_coverage() TO service_role;

-- 7. Add comments for security documentation
COMMENT ON TABLE public.security_audit_log IS 'Audit log for security events and policy violations';
COMMENT ON FUNCTION public.validate_rls_coverage() IS 'Validates RLS policy coverage across all public tables';

-- 8. Create security verification report (simplified)
DO $$
DECLARE
    total_tables INTEGER;
    rls_enabled_tables INTEGER;
BEGIN
    -- Get basic statistics
    SELECT COUNT(*) INTO total_tables 
    FROM information_schema.tables 
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE';
    
    SELECT COUNT(*) INTO rls_enabled_tables
    FROM pg_tables 
    WHERE schemaname = 'public' AND rowsecurity = true;
    
    RAISE NOTICE '========================================';
    RAISE NOTICE 'SECURITY MIGRATION COMPLETED';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Total tables: %', total_tables;
    RAISE NOTICE 'Tables with RLS enabled: %', rls_enabled_tables;
    RAISE NOTICE 'RLS coverage: %%%', ROUND((rls_enabled_tables::DECIMAL / total_tables::DECIMAL) * 100);
    RAISE NOTICE '========================================';
END
$$;