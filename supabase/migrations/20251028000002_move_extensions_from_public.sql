-- ===============================================================
-- MOVE EXTENSIONS OUT OF PUBLIC SCHEMA
-- Version: 1.0
-- Date: 2025-10-28
-- Purpose: Move PostGIS, HTTP, and FuzzyStrMatch extensions to the extensions schema
-- Reference: https://supabase.com/docs/guides/database/database-linter?lint=0014_extension_in_public
-- ===============================================================

-- =====================================
-- SECURITY NOTE
-- =====================================
-- Extensions in the public schema can:
-- 1. Expose additional attack surface via PostgREST API
-- 2. Cause naming conflicts with application objects
-- 3. Make it harder to control access to extension functions
--
-- Moving extensions to a dedicated schema improves security and organization.
-- =====================================

-- Create extensions schema if it doesn't exist
CREATE SCHEMA IF NOT EXISTS extensions;

-- Grant usage on extensions schema to necessary roles
GRANT USAGE ON SCHEMA extensions TO postgres, anon, authenticated, service_role;

-- =====================================
-- MOVE POSTGIS EXTENSION
-- =====================================

-- Note: PostGIS is complex with many dependent objects. We need to:
-- 1. Move the extension to the extensions schema
-- 2. Update search_path so existing code can still find PostGIS functions
-- 3. Create wrapper functions in public schema if needed for backward compatibility

DO $$
BEGIN
    -- Check if postgis is in public schema
    IF EXISTS (
        SELECT 1 FROM pg_extension
        WHERE extname = 'postgis'
          AND extnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    ) THEN
        -- Move postgis extension to extensions schema
        ALTER EXTENSION postgis SET SCHEMA extensions;
        RAISE NOTICE 'Moved postgis extension to extensions schema';
    ELSE
        RAISE NOTICE 'postgis extension is not in public schema or does not exist';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to move postgis extension: %', SQLERRM;
        RAISE WARNING 'This may require manual intervention or may already be handled';
END $$;

-- =====================================
-- MOVE HTTP EXTENSION
-- =====================================

DO $$
BEGIN
    -- Check if http is in public schema
    IF EXISTS (
        SELECT 1 FROM pg_extension
        WHERE extname = 'http'
          AND extnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    ) THEN
        -- Move http extension to extensions schema
        ALTER EXTENSION http SET SCHEMA extensions;
        RAISE NOTICE 'Moved http extension to extensions schema';
    ELSE
        RAISE NOTICE 'http extension is not in public schema or does not exist';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to move http extension: %', SQLERRM;
        RAISE WARNING 'This may require manual intervention or may already be handled';
END $$;

-- =====================================
-- MOVE FUZZYSTRMATCH EXTENSION
-- =====================================

DO $$
BEGIN
    -- Check if fuzzystrmatch is in public schema
    IF EXISTS (
        SELECT 1 FROM pg_extension
        WHERE extname = 'fuzzystrmatch'
          AND extnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    ) THEN
        -- Move fuzzystrmatch extension to extensions schema
        ALTER EXTENSION fuzzystrmatch SET SCHEMA extensions;
        RAISE NOTICE 'Moved fuzzystrmatch extension to extensions schema';
    ELSE
        RAISE NOTICE 'fuzzystrmatch extension is not in public schema or does not exist';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to move fuzzystrmatch extension: %', SQLERRM;
        RAISE WARNING 'This may require manual intervention or may already be handled';
END $$;

-- =====================================
-- UPDATE SEARCH_PATH FOR COMPATIBILITY
-- =====================================

-- Update database default search_path to include extensions schema
-- This ensures existing code can still find extension functions
ALTER DATABASE postgres SET search_path TO "$user", public, extensions, pg_catalog;

-- Update search_path for common roles
ALTER ROLE anon SET search_path TO "$user", public, extensions, pg_catalog;
ALTER ROLE authenticated SET search_path TO "$user", public, extensions, pg_catalog;
ALTER ROLE service_role SET search_path TO "$user", public, extensions, pg_catalog;

-- =====================================
-- CREATE WRAPPER FUNCTIONS (OPTIONAL)
-- =====================================

-- If you have code that explicitly references public.ST_* functions,
-- you can create wrapper functions. However, with the search_path set correctly,
-- this should not be necessary.

-- Example wrapper (uncomment if needed):
-- CREATE OR REPLACE FUNCTION public.ST_Distance(geom1 geometry, geom2 geometry)
-- RETURNS float8
-- LANGUAGE sql
-- IMMUTABLE
-- PARALLEL SAFE
-- AS $$
--     SELECT extensions.ST_Distance($1, $2);
-- $$;

-- =====================================
-- VERIFY MIGRATION
-- =====================================

-- Create a verification view to check extension locations
CREATE OR REPLACE VIEW public.extension_schema_audit AS
SELECT
    e.extname as extension_name,
    n.nspname as schema_name,
    CASE
        WHEN n.nspname = 'public' THEN 'WARNING: Extension in public schema'
        WHEN n.nspname = 'extensions' THEN 'OK: Extension in extensions schema'
        ELSE 'INFO: Extension in ' || n.nspname || ' schema'
    END as status
FROM pg_extension e
JOIN pg_namespace n ON e.extnamespace = n.oid
WHERE e.extname IN ('postgis', 'http', 'fuzzystrmatch', 'postgis_topology',
                   'postgis_raster', 'postgis_sfcgal', 'address_standardizer',
                   'address_standardizer_data_us')
ORDER BY e.extname;

COMMENT ON VIEW public.extension_schema_audit IS
    'Audit view to verify extensions are in the correct schema (extensions, not public)';

-- Grant access to the audit view
GRANT SELECT ON public.extension_schema_audit TO service_role;

-- =====================================
-- NOTES AND WARNINGS
-- =====================================

-- IMPORTANT: After running this migration:
--
-- 1. Test your application thoroughly, especially:
--    - Any code using PostGIS functions (ST_*, geography, geometry types)
--    - Any code using HTTP functions (http_get, http_post, etc.)
--    - Any code using fuzzy string matching (soundex, levenshtein, etc.)
--
-- 2. If you have Edge Functions or client code that references these extensions:
--    - They should still work due to the updated search_path
--    - If not, you may need to qualify function calls with extensions.function_name
--
-- 3. If you encounter issues:
--    - Check if functions need to be explicitly qualified with extensions. prefix
--    - Consider creating wrapper functions in public schema
--    - Review and update any code that explicitly references public.ST_* functions
--
-- 4. To verify the migration:
--    SELECT * FROM public.extension_schema_audit;
-- =====================================
