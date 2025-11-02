-- =====================================================
-- FIX CRON JOB URLS TO POINT TO NEW DATABASE
-- =====================================================
-- This migration updates cron jobs to point to the NEW database
-- OLD: https://sidtjllhpujgbitsutxl.supabase.co
-- NEW: https://bodiwrrbjpfuvepnpnsv.supabase.co
-- Date: 2025-10-21
-- =====================================================

BEGIN;

-- =====================================================
-- 1. RESCHEDULE CRON JOBS WITH NEW URLs
-- =====================================================

-- Grant permissions if needed
GRANT USAGE ON SCHEMA cron TO postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA cron TO postgres;

-- Job 1: calculate-daily-metrics (runs daily at 2 AM)
SELECT cron.unschedule('calculate-daily-metrics');
SELECT cron.schedule(
  'calculate-daily-metrics',
  '0 2 * * *',
  $$
  select net.http_post(
    url := 'https://bodiwrrbjpfuvepnpnsv.supabase.co/functions/v1/calculate-metrics',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  ) as request_id;
  $$
);

-- Job 2: aggregate-stats (runs every 5 minutes)
SELECT cron.unschedule('aggregate-stats');
SELECT cron.schedule(
  'aggregate-stats',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://bodiwrrbjpfuvepnpnsv.supabase.co/functions/v1/aggregate-daily-stats',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key'),
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object('window_minutes', 5)
  ) as request_id;
  $$
);

-- Job 3: check-alerts (runs every 5 minutes)
SELECT cron.unschedule('check-alerts');
SELECT cron.schedule(
  'check-alerts',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://bodiwrrbjpfuvepnpnsv.supabase.co/functions/v1/send-alerts',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  ) as request_id;
  $$
);

-- Note: Job 4 (refresh-engagement-stats) uses direct SQL, no URL to update

-- =====================================================
-- 2. VALIDATION: ENSURE NO OLD URLs REMAIN
-- =====================================================

DO $$
DECLARE
    old_url_count INTEGER;
    job_record RECORD;
BEGIN
    -- Count jobs still pointing to OLD database
    SELECT COUNT(*) INTO old_url_count
    FROM cron.job
    WHERE command LIKE '%sidtjllhpujgbitsutxl%';

    IF old_url_count > 0 THEN
        -- List problematic jobs
        RAISE WARNING '⚠️  WARNING: % job(s) still point to OLD database:', old_url_count;
        FOR job_record IN
            SELECT jobname FROM cron.job
            WHERE command LIKE '%sidtjllhpujgbitsutxl%'
        LOOP
            RAISE WARNING '  - %', job_record.jobname;
        END LOOP;
        RAISE EXCEPTION '❌ ERROR: Some cron jobs still point to OLD database URL!';
    ELSE
        RAISE NOTICE '✅ Validation passed: No cron jobs point to OLD database';
    END IF;

    -- Verify NEW URL is present
    SELECT COUNT(*) INTO old_url_count
    FROM cron.job
    WHERE command LIKE '%bodiwrrbjpfuvepnpnsv%';

    IF old_url_count = 0 THEN
        RAISE WARNING '⚠️  WARNING: No cron jobs found pointing to NEW database URL';
    ELSE
        RAISE NOTICE '✅ Found % cron job(s) pointing to NEW database', old_url_count;
    END IF;

    -- List all current jobs
    RAISE NOTICE '--- Current Cron Jobs ---';
    FOR job_record IN
        SELECT jobid, jobname, schedule, active
        FROM cron.job
        ORDER BY jobid
    LOOP
        RAISE NOTICE 'Job %: % [%] (active: %)',
            job_record.jobid,
            job_record.jobname,
            job_record.schedule,
            job_record.active;
    END LOOP;
END $$;

COMMIT;

-- =====================================================
-- SUMMARY
-- =====================================================
-- ✅ Updated: calculate-daily-metrics → bodiwrrbjpfuvepnpnsv
-- ✅ Updated: aggregate-stats → bodiwrrbjpfuvepnpnsv
-- ✅ Updated: check-alerts → bodiwrrbjpfuvepnpnsv
-- ✅ Verified: No jobs point to OLD database (sidtjllhpujgbitsutxl)
-- =====================================================
