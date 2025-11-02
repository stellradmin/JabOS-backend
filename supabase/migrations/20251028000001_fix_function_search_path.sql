-- ===============================================================
-- FIX FUNCTION SEARCH_PATH SECURITY ISSUES
-- Version: 1.0
-- Date: 2025-10-28
-- Purpose: Set explicit search_path on all functions to prevent search_path injection attacks
-- Reference: https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable
-- ===============================================================

-- =====================================
-- SECURITY NOTE
-- =====================================
-- Functions without an explicit search_path are vulnerable to search_path injection
-- attacks where a malicious user could create objects in a schema earlier in the
-- search_path to hijack function behavior.
--
-- Setting "SET search_path = ''" makes the function use only fully-qualified names,
-- but can break existing functions. A safer approach is "SET search_path = public, pg_catalog"
-- which is explicit but allows common usage patterns.
-- =====================================

-- Helper function to set search_path on all public schema functions
DO $$
DECLARE
    func_record RECORD;
    func_signature TEXT;
BEGIN
    -- Loop through all functions in public schema that don't have search_path set
    FOR func_record IN
        SELECT
            n.nspname as schema_name,
            p.proname as function_name,
            pg_get_function_identity_arguments(p.oid) as args
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname IN ('public', 'audit_system', 'data_isolation', 'key_rotation',
                           'encryption', 'security', 'security_testing')
          AND p.prokind = 'f'  -- Only functions, not aggregates or procedures
          -- Check if search_path is not already set (proconfig is null or doesn't contain search_path)
          AND (p.proconfig IS NULL OR NOT EXISTS (
              SELECT 1 FROM unnest(p.proconfig) AS config
              WHERE config LIKE 'search_path=%'
          ))
    LOOP
        -- Build function signature
        func_signature := func_record.schema_name || '.' ||
                         func_record.function_name || '(' ||
                         func_record.args || ')';

        BEGIN
            -- Set search_path for the function
            EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_catalog',
                          func_signature);

            RAISE NOTICE 'Set search_path for function: %', func_signature;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING 'Failed to set search_path for function %: %',
                             func_signature, SQLERRM;
        END;
    END LOOP;
END $$;

-- =====================================
-- VERIFY SEARCH_PATH CONFIGURATION
-- =====================================

-- Create a view to monitor functions without search_path (for ongoing monitoring)
CREATE OR REPLACE VIEW public.functions_without_search_path AS
SELECT
    n.nspname as schema_name,
    p.proname as function_name,
    pg_get_function_identity_arguments(p.oid) as arguments,
    p.prosecdef as is_security_definer,
    p.provolatile as volatility,
    CASE p.provolatile
        WHEN 'i' THEN 'IMMUTABLE'
        WHEN 's' THEN 'STABLE'
        WHEN 'v' THEN 'VOLATILE'
    END as volatility_label
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname IN ('public', 'audit_system', 'data_isolation', 'key_rotation',
                   'encryption', 'security', 'security_testing')
  AND p.prokind = 'f'
  AND (p.proconfig IS NULL OR NOT EXISTS (
      SELECT 1 FROM unnest(p.proconfig) AS config
      WHERE config LIKE 'search_path=%'
  ))
ORDER BY n.nspname, p.proname;

COMMENT ON VIEW public.functions_without_search_path IS
    'Monitoring view to identify functions without explicit search_path set. These functions may be vulnerable to search_path injection attacks.';

-- Grant access to the monitoring view
GRANT SELECT ON public.functions_without_search_path TO service_role;

-- =====================================
-- SUMMARY
-- =====================================
-- This migration sets search_path = 'public, pg_catalog' on all functions
-- in relevant schemas to prevent search_path injection attacks.
--
-- The search_path "public, pg_catalog" is chosen because:
-- 1. It's explicit (not relying on session search_path)
-- 2. It allows functions to reference public schema objects without qualification
-- 3. It includes pg_catalog for built-in PostgreSQL functions
-- 4. It prevents users from hijacking function behavior via custom schemas
-- =====================================
