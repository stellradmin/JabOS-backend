-- =============================================================================
-- STELLR RETENTION DATA POPULATION
-- =============================================================================
-- This migration populates initial retention and cohort data
-- Run AFTER retention_analytics_schema and threshold_management_schema
-- =============================================================================

DO $$
DECLARE
  v_rows_affected INTEGER;
  v_cohorts_count INTEGER;
  v_segments_count INTEGER;
BEGIN
  RAISE NOTICE 'Starting retention data population...';

  -- ---------------------------------------------------------------------------
  -- 1. REFRESH RETENTION COHORTS (Last 90 days)
  -- ---------------------------------------------------------------------------
  RAISE NOTICE 'Calculating retention cohorts for last 90 days...';

  v_rows_affected := public.refresh_retention_cohorts();

  SELECT COUNT(*) INTO v_cohorts_count
  FROM public.retention_cohorts;

  RAISE NOTICE 'Retention cohorts refreshed: % rows upserted, % total cohorts', v_rows_affected, v_cohorts_count;

  -- ---------------------------------------------------------------------------
  -- 2. POPULATE COHORT SEGMENTS (Signup Month)
  -- ---------------------------------------------------------------------------
  RAISE NOTICE 'Analyzing cohort segments by signup month...';

  INSERT INTO public.cohort_segments (
    cohort_name,
    cohort_type,
    user_count,
    avg_matches,
    avg_messages,
    retention_d7,
    retention_d30,
    analysis_date
  )
  SELECT
    cohort_name,
    cohort_type,
    user_count,
    avg_matches,
    avg_messages,
    retention_d7,
    retention_d30,
    CURRENT_DATE as analysis_date
  FROM public.analyze_cohort_segments()
  ON CONFLICT (cohort_name, cohort_type, analysis_date)
  DO UPDATE SET
    user_count = EXCLUDED.user_count,
    avg_matches = EXCLUDED.avg_matches,
    avg_messages = EXCLUDED.avg_messages,
    retention_d7 = EXCLUDED.retention_d7,
    retention_d30 = EXCLUDED.retention_d30;

  GET DIAGNOSTICS v_rows_affected = ROW_COUNT;

  SELECT COUNT(*) INTO v_segments_count
  FROM public.cohort_segments
  WHERE analysis_date = CURRENT_DATE;

  RAISE NOTICE 'Cohort segments updated: % rows upserted, % total segments for today', v_rows_affected, v_segments_count;

  -- ---------------------------------------------------------------------------
  -- 3. CREATE SAMPLE ANALYTICS EVENTS (If None Exist)
  -- ---------------------------------------------------------------------------
  -- This ensures we have some data for testing even in dev environments

  IF NOT EXISTS (SELECT 1 FROM public.analytics_events LIMIT 1) THEN
    RAISE NOTICE 'No analytics events found. Creating sample data for testing...';

    -- Insert sample events for the last 7 days
    INSERT INTO public.analytics_events (user_id, event_name, created_at)
    SELECT
      u.id as user_id,
      (ARRAY['app_opened', 'profile_view', 'swipe_right', 'message_sent'])[floor(random() * 4 + 1)] as event_name,
      u.created_at + (random() * INTERVAL '7 days') as created_at
    FROM auth.users u
    WHERE u.created_at >= CURRENT_DATE - INTERVAL '30 days'
    LIMIT 1000;

    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    RAISE NOTICE 'Created % sample analytics events', v_rows_affected;
  ELSE
    RAISE NOTICE 'Analytics events already exist, skipping sample data creation';
  END IF;

  -- ---------------------------------------------------------------------------
  -- SUMMARY
  -- ---------------------------------------------------------------------------
  RAISE NOTICE '=================================================================';
  RAISE NOTICE 'Retention data population complete!';
  RAISE NOTICE 'Retention cohorts: %', v_cohorts_count;
  RAISE NOTICE 'Cohort segments: %', v_segments_count;
  RAISE NOTICE '=================================================================';

END $$;

-- =============================================================================
-- VERIFICATION QUERIES
-- =============================================================================
-- Run these to verify data was populated:
--
-- 1. Check retention cohorts:
-- SELECT cohort_date, cohort_size, day_1_rate, day_7_rate, day_30_rate
-- FROM public.retention_cohorts
-- ORDER BY cohort_date DESC
-- LIMIT 10;
--
-- 2. Check cohort segments:
-- SELECT cohort_name, cohort_type, user_count, avg_matches, avg_messages
-- FROM public.cohort_segments
-- WHERE analysis_date = CURRENT_DATE
-- ORDER BY user_count DESC;
--
-- 3. Check analytics events count:
-- SELECT COUNT(*) as total_events,
--        COUNT(DISTINCT user_id) as unique_users,
--        event_name,
--        COUNT(*) as event_count
-- FROM public.analytics_events
-- WHERE created_at >= CURRENT_DATE - INTERVAL '7 days'
-- GROUP BY event_name
-- ORDER BY event_count DESC;
-- =============================================================================
