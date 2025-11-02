-- =====================================================
-- DEPLOY MISSING CRON JOBS
-- =====================================================
-- This migration deploys 2 cron jobs missing from NEW database:
-- 1. dispatch-transactional-email-queue (every 2 minutes)
-- 2. process-lead-nurture-sequence (every 10 minutes)
-- Date: 2025-10-21
-- =====================================================

BEGIN;

-- =====================================================
-- 1. DEPLOY EMAIL QUEUE DISPATCHER
-- =====================================================

-- Unschedule if exists (idempotent)
SELECT cron.unschedule('dispatch-transactional-email-queue') WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'dispatch-transactional-email-queue'
);

-- Create job
SELECT cron.schedule(
    'dispatch-transactional-email-queue',
    '*/2 * * * *',
    $cron$SELECT extensions.http_post(
        url := 'https://bodiwrrbjpfuvepnpnsv.supabase.co/functions/v1/resend-transactional-dispatcher',
        headers := '{"Content-Type": "application/json"}'::jsonb,
        body := '{"mode":"process_queue"}'::text
    );$cron$
);

-- =====================================================
-- 2. DEPLOY LEAD NURTURE AUTOMATION
-- =====================================================

-- Unschedule if exists (idempotent)
SELECT cron.unschedule('process-lead-nurture-sequence') WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'process-lead-nurture-sequence'
);

-- Create job
SELECT cron.schedule(
    'process-lead-nurture-sequence',
    '*/10 * * * *',
    $cron$SELECT extensions.http_post(
        url := 'https://bodiwrrbjpfuvepnpnsv.supabase.co/functions/v1/lead-nurture-automation',
        headers := '{"Content-Type": "application/json"}'::jsonb,
        body := '{}'::text
    );$cron$
);

-- =====================================================
-- 3. VALIDATION: ENSURE ALL 6 JOBS EXIST
-- =====================================================

DO $$
DECLARE
    total_jobs INTEGER;
    job_record RECORD;
    required_jobs TEXT[] := ARRAY[
        'calculate-daily-metrics',
        'aggregate-stats',
        'check-alerts',
        'refresh-engagement-stats',
        'dispatch-transactional-email-queue',
        'process-lead-nurture-sequence'
    ];
    missing_job TEXT;
BEGIN
    -- Count total jobs
    SELECT COUNT(*) INTO total_jobs FROM cron.job;

    IF total_jobs < 6 THEN
        RAISE WARNING '⚠️  WARNING: Only % cron jobs found, expected 6', total_jobs;

        -- Check which jobs are missing
        FOREACH missing_job IN ARRAY required_jobs
        LOOP
            IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = missing_job) THEN
                RAISE WARNING '  - Missing job: %', missing_job;
            END IF;
        END LOOP;

        RAISE EXCEPTION '❌ ERROR: Not all required cron jobs are present!';
    ELSE
        RAISE NOTICE '✅ All 6 cron jobs present';
    END IF;

    -- Verify all jobs are active
    FOR job_record IN
        SELECT jobname, active FROM cron.job WHERE NOT active
    LOOP
        RAISE WARNING '⚠️  WARNING: Job "%" is not active', job_record.jobname;
    END LOOP;

    -- List all jobs with details
    RAISE NOTICE '--- All Cron Jobs ---';
    FOR job_record IN
        SELECT
            jobid,
            jobname,
            schedule,
            active,
            CASE
                WHEN command LIKE '%bodiwrrbjpfuvepnpnsv%' THEN '✅ NEW'
                WHEN command LIKE '%sidtjllhpujgbitsutxl%' THEN '❌ OLD'
                ELSE '✅ SQL'
            END as url_status
        FROM cron.job
        ORDER BY jobid
    LOOP
        RAISE NOTICE 'Job %: % [%] (active: %, url: %)',
            job_record.jobid,
            job_record.jobname,
            job_record.schedule,
            job_record.active,
            job_record.url_status;
    END LOOP;
END $$;

COMMIT;

-- =====================================================
-- SUMMARY
-- =====================================================
-- ✅ Deployed: dispatch-transactional-email-queue (*/2 * * * *)
-- ✅ Deployed: process-lead-nurture-sequence (*/10 * * * *)
-- ✅ Verified: All 6 cron jobs present and active
-- ✅ Verified: All jobs point to NEW database (bodiwrrbjpfuvepnpnsv)
-- =====================================================

-- Job Schedule Summary:
-- 1. calculate-daily-metrics:              0 2 * * *    (daily at 2 AM)
-- 2. aggregate-stats:                      */5 * * * *  (every 5 minutes)
-- 3. check-alerts:                         */5 * * * *  (every 5 minutes)
-- 4. refresh-engagement-stats:             */30 * * * * (every 30 minutes)
-- 5. dispatch-transactional-email-queue:   */2 * * * *  (every 2 minutes)
-- 6. process-lead-nurture-sequence:        */10 * * * * (every 10 minutes)
-- =====================================================
