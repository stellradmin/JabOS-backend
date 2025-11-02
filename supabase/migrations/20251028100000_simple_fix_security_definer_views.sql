-- ===============================================================
-- SIMPLE FIX FOR SECURITY DEFINER VIEWS
-- Version: 1.0
-- Date: 2025-10-28
-- Purpose: Simple fix for SECURITY DEFINER views without complex DO blocks
-- ===============================================================

-- 1. Fix secure_profile_view
DROP VIEW IF EXISTS public.secure_profile_view CASCADE;
CREATE VIEW public.secure_profile_view
WITH (security_invoker = true)
AS
SELECT
    p.id,
    p.display_name,
    p.age,
    p.gender,
    p.zodiac_sign,
    CASE
        WHEN array_length(p.interests, 1) > 3
        THEN p.interests[1:3] || ARRAY['...']
        ELSE p.interests
    END AS interests_preview,
    p.avatar_url,
    CASE
        WHEN p.education_level IS NOT NULL
        THEN SPLIT_PART(p.education_level, ' ', 1)
        ELSE NULL
    END AS education_category,
    CASE
        WHEN p.location IS NOT NULL AND p.location ? 'city'
        THEN p.location->>'city'
        ELSE NULL
    END AS city,
    p.created_at
FROM public.profiles p
WHERE p.onboarding_completed = true;

-- 2. Fix secure_match_view
DROP VIEW IF EXISTS public.secure_match_view CASCADE;
CREATE VIEW public.secure_match_view
WITH (security_invoker = true)
AS
SELECT
    m.id,
    m.user1_id,
    m.user2_id,
    m.matched_at,
    m.status,
    m.compatibility_score,
    CASE
        WHEN m.compatibility_score >= 80 THEN 'A'
        WHEN m.compatibility_score >= 65 THEN 'B'
        WHEN m.compatibility_score >= 50 THEN 'C'
        ELSE 'D'
    END AS compatibility_grade,
    m.conversation_id
FROM public.matches m
WHERE m.status = 'active';

-- 3. Fix edge_function_performance view
DROP VIEW IF EXISTS public.edge_function_performance CASCADE;
CREATE VIEW public.edge_function_performance
WITH (security_invoker = true)
AS
SELECT
    function_name,
    COUNT(*) as total_calls,
    AVG(execution_time_ms) as avg_execution_time_ms,
    MAX(execution_time_ms) as max_execution_time_ms,
    MIN(execution_time_ms) as min_execution_time_ms,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY execution_time_ms) as median_execution_time_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY execution_time_ms) as p95_execution_time_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY execution_time_ms) as p99_execution_time_ms,
    COUNT(*) FILTER (WHERE status_code >= 200 AND status_code < 300) as success_count,
    COUNT(*) FILTER (WHERE status_code >= 400) as error_count,
    (COUNT(*) FILTER (WHERE status_code >= 200 AND status_code < 300)::float / NULLIF(COUNT(*), 0) * 100) as success_rate_percent,
    DATE_TRUNC('hour', created_at) as hour
FROM public.edge_function_logs
GROUP BY function_name, DATE_TRUNC('hour', created_at)
ORDER BY hour DESC, total_calls DESC;

-- 4. Fix user_read_receipt_summary view
DROP VIEW IF EXISTS public.user_read_receipt_summary CASCADE;
CREATE VIEW public.user_read_receipt_summary
WITH (security_invoker = true)
AS
SELECT
    p.id as user_id,
    p.display_name,
    COALESCE(us.read_receipts_enabled, true) as read_receipts_enabled,
    COUNT(mrr.id) as total_messages_read,
    COUNT(mrr.id) FILTER (WHERE mrr.mutual_receipts_enabled = true) as receipts_shared,
    COUNT(sent_messages.id) as total_messages_sent,
    COUNT(sent_receipts.id) as receipts_received
FROM public.profiles p
LEFT JOIN public.user_settings us ON us.user_id = p.id
LEFT JOIN public.message_read_receipts mrr ON mrr.reader_id = p.id
LEFT JOIN public.messages sent_messages ON sent_messages.sender_id = p.id
LEFT JOIN public.message_read_receipts sent_receipts ON sent_receipts.sender_id = p.id
WHERE p.onboarding_completed = true
GROUP BY p.id, p.display_name, us.read_receipts_enabled;

-- 5. Fix discoverable_users_with_preferences view
DROP VIEW IF EXISTS public.discoverable_users_with_preferences CASCADE;
CREATE VIEW public.discoverable_users_with_preferences
WITH (security_invoker = true)
AS
SELECT
    p.id as user_id,
    p.display_name,
    p.gender,
    p.age,
    p.zodiac_sign,
    p.avatar_url,
    p.interests,
    p.bio,
    p.location,
    (p.location->>'lat')::float as latitude,
    (p.location->>'lng')::float as longitude,
    us.gender_preference,
    us.min_age_preference,
    us.max_age_preference,
    us.preferred_distance_km,
    us.discovery_enabled
FROM public.profiles p
LEFT JOIN public.user_settings us ON us.user_id = p.id
WHERE p.onboarding_completed = true
    AND COALESCE(us.discovery_enabled, true) = true;

-- 6. Fix discoverable_profiles view
DROP VIEW IF EXISTS public.discoverable_profiles CASCADE;
CREATE VIEW public.discoverable_profiles
WITH (security_invoker = true)
AS
SELECT
    id,
    display_name,
    age,
    zodiac_sign,
    gender,
    interests,
    avatar_url,
    bio,
    CASE
        WHEN location IS NOT NULL AND location ? 'city'
        THEN jsonb_build_object('city', location->>'city')
        ELSE NULL
    END AS location,
    created_at,
    onboarding_completed
FROM public.profiles
WHERE onboarding_completed = true;

-- Enable RLS on compatibility_performance_log
ALTER TABLE IF EXISTS public.compatibility_performance_log ENABLE ROW LEVEL SECURITY;

-- Enable RLS on materialized_view_performance
ALTER TABLE IF EXISTS public.materialized_view_performance ENABLE ROW LEVEL SECURITY;
