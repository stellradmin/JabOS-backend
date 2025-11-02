-- PHASE 1 SECURITY: Complete RLS implementation on missing tables
-- Migration: complete_rls_implementation
-- Created: 2024-09-04
-- Purpose: Enable Row Level Security on 5 remaining tables to close critical security gap
-- NOTE: Made all table operations conditional to handle missing tables

-- Enable RLS on tables only if they exist
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'edge_function_logs') THEN
        ALTER TABLE edge_function_logs ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'gdpr_compliance_dashboard') THEN
        ALTER TABLE gdpr_compliance_dashboard ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'migration_logs') THEN
        ALTER TABLE migration_logs ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'performance_metrics') THEN
        ALTER TABLE performance_metrics ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'users_natal_backup') THEN
        ALTER TABLE users_natal_backup ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

-- =====================================================
-- RLS POLICIES FOR SYSTEM TABLES
-- =====================================================

-- edge_function_logs: Service role access only (system logs)
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'edge_function_logs') THEN
        DROP POLICY IF EXISTS "Service role can manage edge function logs" ON edge_function_logs;
        CREATE POLICY "Service role can manage edge function logs" ON edge_function_logs
            FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');
    END IF;
END $$;

-- migration_logs: Service role access only (system logs)
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'migration_logs') THEN
        DROP POLICY IF EXISTS "Service role can manage migration logs" ON migration_logs;
        CREATE POLICY "Service role can manage migration logs" ON migration_logs
            FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');
    END IF;
END $$;

-- performance_metrics: Service role access only (system metrics)
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'performance_metrics') THEN
        DROP POLICY IF EXISTS "Service role can manage performance metrics" ON performance_metrics;
        CREATE POLICY "Service role can manage performance metrics" ON performance_metrics
            FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');
    END IF;
END $$;

-- =====================================================
-- RLS POLICIES FOR USER DATA TABLES
-- =====================================================

-- gdpr_compliance_dashboard: Users can view their own data
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'gdpr_compliance_dashboard') THEN
        DROP POLICY IF EXISTS "Users can view their GDPR compliance data" ON gdpr_compliance_dashboard;
        CREATE POLICY "Users can view their GDPR compliance data" ON gdpr_compliance_dashboard
            FOR SELECT USING (
                auth.uid() = user_id OR
                auth.jwt() ->> 'role' = 'service_role'
            );

        DROP POLICY IF EXISTS "Service role can manage GDPR compliance data" ON gdpr_compliance_dashboard;
        CREATE POLICY "Service role can manage GDPR compliance data" ON gdpr_compliance_dashboard
            FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');
    END IF;
END $$;

-- users_natal_backup: Users can manage their own backup data
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'users_natal_backup') THEN
        DROP POLICY IF EXISTS "Users can view their natal backup" ON users_natal_backup;
        CREATE POLICY "Users can view their natal backup" ON users_natal_backup
            FOR SELECT USING (
                auth.uid() = user_id OR
                auth.jwt() ->> 'role' = 'service_role'
            );

        DROP POLICY IF EXISTS "Users can insert their natal backup" ON users_natal_backup;
        CREATE POLICY "Users can insert their natal backup" ON users_natal_backup
            FOR INSERT WITH CHECK (auth.uid() = user_id);

        DROP POLICY IF EXISTS "Users can update their natal backup" ON users_natal_backup;
        CREATE POLICY "Users can update their natal backup" ON users_natal_backup
            FOR UPDATE USING (auth.uid() = user_id);

        DROP POLICY IF EXISTS "Service role can manage all natal backups" ON users_natal_backup;
        CREATE POLICY "Service role can manage all natal backups" ON users_natal_backup
            FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');
    END IF;
END $$;

-- =====================================================
-- SECURITY MONITORING ENHANCEMENTS
-- =====================================================

-- Add RLS violation logging function (if security_monitoring_log table exists)
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'security_monitoring_log') THEN
        CREATE OR REPLACE FUNCTION log_rls_policy_violation()
        RETURNS TRIGGER AS $func$
        BEGIN
            INSERT INTO security_monitoring_log (
                event_type,
                severity,
                details,
                user_id,
                ip_address,
                user_agent,
                timestamp
            ) VALUES (
                'rls_policy_violation',
                'high',
                jsonb_build_object(
                    'table', TG_TABLE_NAME,
                    'operation', TG_OP,
                    'attempted_access', 'blocked_by_rls'
                ),
                auth.uid(),
                current_setting('request.headers', true)::json->>'x-forwarded-for',
                current_setting('request.headers', true)::json->>'user-agent',
                NOW()
            );
            RETURN NULL;
        END;
        $func$ LANGUAGE plpgsql SECURITY DEFINER;
    END IF;
END $$;

-- =====================================================
-- VERIFICATION QUERIES
-- =====================================================

-- Verify RLS is enabled on all existing tables
DO $$
DECLARE
    rec RECORD;
    table_count INTEGER := 0;
    rls_enabled_count INTEGER := 0;
BEGIN
    -- Check RLS status on our target tables (only those that exist)
    FOR rec IN
        SELECT tablename, rowsecurity
        FROM pg_tables
        WHERE schemaname = 'public'
          AND tablename IN ('edge_function_logs', 'gdpr_compliance_dashboard', 'migration_logs', 'performance_metrics', 'users_natal_backup')
    LOOP
        table_count := table_count + 1;
        IF rec.rowsecurity THEN
            rls_enabled_count := rls_enabled_count + 1;
        END IF;

        RAISE NOTICE 'Table: %, RLS Enabled: %', rec.tablename, rec.rowsecurity;
    END LOOP;

    IF table_count = 0 THEN
        RAISE NOTICE 'No target tables found - this is OK if they have not been created yet';
    ELSE
        RAISE NOTICE 'RLS Migration Complete: %/% existing tables have RLS enabled', rls_enabled_count, table_count;

        IF rls_enabled_count = table_count THEN
            RAISE NOTICE 'SUCCESS: All existing target tables now have RLS enabled';

            -- Log successful migration (only if security_monitoring_log exists)
            IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'security_monitoring_log') THEN
                INSERT INTO security_monitoring_log (
                    event_type,
                    severity,
                    details,
                    user_id,
                    timestamp
                ) VALUES (
                    'rls_migration_complete',
                    'info',
                    jsonb_build_object(
                        'tables_enabled', ARRAY['edge_function_logs', 'gdpr_compliance_dashboard', 'migration_logs', 'performance_metrics', 'users_natal_backup'],
                        'total_count', table_count
                    ),
                    auth.uid(),
                    NOW()
                );
            END IF;
        ELSE
            RAISE WARNING 'Only %/% existing tables have RLS enabled', rls_enabled_count, table_count;
        END IF;
    END IF;
END
$$;
