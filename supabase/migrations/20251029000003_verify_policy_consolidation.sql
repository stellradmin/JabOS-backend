-- =====================================================
-- VERIFY RLS POLICY CONSOLIDATION
-- =====================================================
-- This migration verifies that RLS policies have been properly
-- consolidated and identifies any remaining issues with multiple
-- permissive policies for the same table/role/action combination.
-- Date: 2025-10-29
-- =====================================================

-- Note: This is a verification migration, not a fix migration.
-- It reports on the state of RLS policies but does not modify them.

BEGIN;

-- =====================================================
-- CHECK FOR MULTIPLE PERMISSIVE POLICIES
-- =====================================================

DO $$
DECLARE
    policy_rec RECORD;
    duplicate_policy_groups INTEGER := 0;
    total_policies INTEGER;
    tables_with_issues TEXT[] := ARRAY[]::TEXT[];
BEGIN
    RAISE NOTICE '═════════════════════════════════════════════════════';
    RAISE NOTICE '🔍 RLS POLICY CONSOLIDATION VERIFICATION REPORT';
    RAISE NOTICE '═════════════════════════════════════════════════════';
    RAISE NOTICE '';

    -- Get total policy count
    SELECT COUNT(*) INTO total_policies
    FROM pg_policies
    WHERE schemaname = 'public';

    RAISE NOTICE 'Total RLS policies in public schema: %', total_policies;
    RAISE NOTICE '';
    RAISE NOTICE '─────────────────────────────────────────────────────';
    RAISE NOTICE 'Checking for Multiple Permissive Policies...';
    RAISE NOTICE '─────────────────────────────────────────────────────';

    -- Find tables with multiple permissive policies for same role/action
    FOR policy_rec IN
        SELECT
            tablename,
            cmd,
            roles,
            COUNT(*) as policy_count,
            array_agg(policyname) as policy_names
        FROM pg_policies
        WHERE schemaname = 'public'
        AND permissive = 'PERMISSIVE'  -- Only check permissive policies
        GROUP BY tablename, cmd, roles
        HAVING COUNT(*) > 1
        ORDER BY tablename, cmd
    LOOP
        duplicate_policy_groups := duplicate_policy_groups + 1;
        tables_with_issues := array_append(tables_with_issues, policy_rec.tablename);

        RAISE NOTICE '';
        RAISE NOTICE '⚠️  Table: %', policy_rec.tablename;
        RAISE NOTICE '   Command: %', policy_rec.cmd;
        RAISE NOTICE '   Roles: %', policy_rec.roles;
        RAISE NOTICE '   Number of policies: %', policy_rec.policy_count;
        RAISE NOTICE '   Policy names: %', array_to_string(policy_rec.policy_names, ', ');
        RAISE NOTICE '   ⚡ Impact: All % policies are evaluated, causing performance overhead', policy_rec.policy_count;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '─────────────────────────────────────────────────────';

    IF duplicate_policy_groups = 0 THEN
        RAISE NOTICE '✅ EXCELLENT: No multiple permissive policy issues found!';
        RAISE NOTICE '   All tables have properly consolidated policies.';
    ELSE
        RAISE NOTICE '⚠️  ATTENTION: Found % cases of multiple permissive policies', duplicate_policy_groups;
        RAISE NOTICE '   Tables affected: %', array_to_string(array_agg(DISTINCT t), ', ')
        FROM unnest(tables_with_issues) AS t;
        RAISE NOTICE '';
        RAISE NOTICE '   Recommendation: Consider consolidating these policies using OR logic';
        RAISE NOTICE '   Example:';
        RAISE NOTICE '   Instead of:';
        RAISE NOTICE '     POLICY "policy1" FOR SELECT USING (condition1)';
        RAISE NOTICE '     POLICY "policy2" FOR SELECT USING (condition2)';
        RAISE NOTICE '   Use:';
        RAISE NOTICE '     POLICY "combined_policy" FOR SELECT USING (condition1 OR condition2)';
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE '═════════════════════════════════════════════════════';
    RAISE NOTICE 'DETAILED POLICY BREAKDOWN BY TABLE';
    RAISE NOTICE '═════════════════════════════════════════════════════';
END $$;

-- =====================================================
-- DETAILED POLICY REPORT FOR CRITICAL TABLES
-- =====================================================

DO $$
DECLARE
    table_rec RECORD;
    policy_rec RECORD;
    critical_tables TEXT[] := ARRAY[
        'profiles',
        'users',
        'matches',
        'match_requests',
        'conversations',
        'messages',
        'swipes',
        'blocks',
        'user_settings',
        'user_notifications'
    ];
    table_name TEXT;
BEGIN
    FOREACH table_name IN ARRAY critical_tables
    LOOP
        -- Check if table has policies
        IF EXISTS (
            SELECT 1 FROM pg_policies
            WHERE schemaname = 'public'
            AND tablename = table_name
        ) THEN
            RAISE NOTICE '';
            RAISE NOTICE '─────────────────────────────────────────────────────';
            RAISE NOTICE 'Table: %', table_name;
            RAISE NOTICE '─────────────────────────────────────────────────────';

            -- Get policy summary for this table
            FOR policy_rec IN
                SELECT
                    cmd,
                    permissive,
                    COUNT(*) as count
                FROM pg_policies
                WHERE schemaname = 'public'
                AND tablename = table_name
                GROUP BY cmd, permissive
                ORDER BY cmd, permissive
            LOOP
                RAISE NOTICE '  % %: % policies',
                    rpad(policy_rec.cmd::TEXT, 10),
                    rpad(policy_rec.permissive::TEXT, 12),
                    policy_rec.count;
            END LOOP;

            -- Show actual policy names
            RAISE NOTICE '  ';
            RAISE NOTICE '  Policies:';
            FOR policy_rec IN
                SELECT policyname, cmd, roles
                FROM pg_policies
                WHERE schemaname = 'public'
                AND tablename = table_name
                ORDER BY cmd, policyname
            LOOP
                RAISE NOTICE '    • % (%, roles: %)',
                    policy_rec.policyname,
                    policy_rec.cmd,
                    policy_rec.roles;
            END LOOP;
        ELSE
            RAISE NOTICE '';
            RAISE NOTICE '⚠️  Table: % - NO POLICIES FOUND (RLS may not be enabled)', table_name;
        END IF;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '═════════════════════════════════════════════════════';
END $$;

-- =====================================================
-- CHECK FOR TABLES WITH RLS ENABLED BUT NO POLICIES
-- =====================================================

DO $$
DECLARE
    orphan_rec RECORD;
    orphan_count INTEGER := 0;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '─────────────────────────────────────────────────────';
    RAISE NOTICE 'Checking for Tables with RLS Enabled but No Policies...';
    RAISE NOTICE '─────────────────────────────────────────────────────';

    FOR orphan_rec IN
        SELECT
            schemaname,
            tablename
        FROM pg_tables
        WHERE schemaname = 'public'
        AND rowsecurity = true
        AND NOT EXISTS (
            SELECT 1
            FROM pg_policies
            WHERE pg_policies.schemaname = pg_tables.schemaname
            AND pg_policies.tablename = pg_tables.tablename
        )
        ORDER BY tablename
    LOOP
        orphan_count := orphan_count + 1;
        RAISE NOTICE '⚠️  Table: %.% has RLS enabled but NO policies',
            orphan_rec.schemaname,
            orphan_rec.tablename;
        RAISE NOTICE '   This will DENY ALL ACCESS to regular users!';
    END LOOP;

    IF orphan_count = 0 THEN
        RAISE NOTICE '✅ All tables with RLS enabled have policies defined';
    ELSE
        RAISE NOTICE '';
        RAISE NOTICE '⚠️  Found % tables with RLS enabled but no policies', orphan_count;
        RAISE NOTICE '   Action required: Add policies or disable RLS for these tables';
    END IF;

    RAISE NOTICE '─────────────────────────────────────────────────────';
END $$;

-- =====================================================
-- SUMMARY STATISTICS
-- =====================================================

DO $$
DECLARE
    stats_rec RECORD;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '═════════════════════════════════════════════════════';
    RAISE NOTICE 'RLS POLICY STATISTICS SUMMARY';
    RAISE NOTICE '═════════════════════════════════════════════════════';

    -- Overall statistics
    SELECT
        COUNT(DISTINCT tablename) as tables_with_policies,
        COUNT(*) as total_policies,
        COUNT(*) FILTER (WHERE permissive = 'PERMISSIVE') as permissive_policies,
        COUNT(*) FILTER (WHERE permissive = 'RESTRICTIVE') as restrictive_policies,
        COUNT(*) FILTER (WHERE cmd = 'SELECT') as select_policies,
        COUNT(*) FILTER (WHERE cmd = 'INSERT') as insert_policies,
        COUNT(*) FILTER (WHERE cmd = 'UPDATE') as update_policies,
        COUNT(*) FILTER (WHERE cmd = 'DELETE') as delete_policies,
        COUNT(*) FILTER (WHERE cmd = 'ALL') as all_policies
    INTO stats_rec
    FROM pg_policies
    WHERE schemaname = 'public';

    RAISE NOTICE '';
    RAISE NOTICE 'Tables with RLS policies: %', stats_rec.tables_with_policies;
    RAISE NOTICE 'Total policies: %', stats_rec.total_policies;
    RAISE NOTICE '';
    RAISE NOTICE 'By Type:';
    RAISE NOTICE '  Permissive policies:  %', stats_rec.permissive_policies;
    RAISE NOTICE '  Restrictive policies: %', stats_rec.restrictive_policies;
    RAISE NOTICE '';
    RAISE NOTICE 'By Command:';
    RAISE NOTICE '  SELECT: %', stats_rec.select_policies;
    RAISE NOTICE '  INSERT: %', stats_rec.insert_policies;
    RAISE NOTICE '  UPDATE: %', stats_rec.update_policies;
    RAISE NOTICE '  DELETE: %', stats_rec.delete_policies;
    RAISE NOTICE '  ALL:    %', stats_rec.all_policies;

    RAISE NOTICE '';
    RAISE NOTICE '═════════════════════════════════════════════════════';
    RAISE NOTICE '✅ RLS POLICY VERIFICATION COMPLETE';
    RAISE NOTICE '═════════════════════════════════════════════════════';
END $$;

COMMIT;
