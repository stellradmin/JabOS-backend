-- Align get_potential_matches_optimized RPC with Edge Function contract and restored preference logic
BEGIN;

-- Ensure any previous versions are removed so we can safely redefine the RPC with the new return shape
DROP FUNCTION IF EXISTS public.get_potential_matches_optimized(UUID, UUID[], TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS public.get_potential_matches_optimized(UUID, INTEGER, INTEGER);

CREATE OR REPLACE FUNCTION public.get_potential_matches_optimized(
    viewer_id UUID,
    exclude_user_ids UUID[] DEFAULT ARRAY[]::UUID[],
    zodiac_filter TEXT DEFAULT NULL,
    min_age_filter INTEGER DEFAULT NULL,
    max_age_filter INTEGER DEFAULT NULL,
    max_distance_km INTEGER DEFAULT NULL,
    limit_count INTEGER DEFAULT 50,
    offset_count INTEGER DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    display_name TEXT,
    age INTEGER,
    gender TEXT,
    zodiac_sign TEXT,
    height INTEGER,
    interests TEXT[],
    education_level TEXT,
    lat DECIMAL,
    lng DECIMAL,
    avatar_url TEXT,
    distance_km NUMERIC,
    compatibility_score INTEGER,
    last_active TIMESTAMPTZ,
    premium_user BOOLEAN,
    profile_image_url TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    viewer_ctx RECORD;
    settings_exist BOOLEAN := to_regclass('public.user_settings') IS NOT NULL;
    exclude_ids UUID[] := COALESCE(exclude_user_ids, ARRAY[]::UUID[]);
BEGIN
    IF settings_exist THEN
        EXECUTE '
            SELECT
                p.age AS viewer_age,
                p.gender AS viewer_gender,
                COALESCE(p.lat, viewer_user.birth_lat) AS viewer_lat,
                COALESCE(p.lng, viewer_user.birth_lng) AS viewer_lng,
                us.gender_preference,
                us.min_age_preference,
                us.max_age_preference,
                us.preferred_distance_km,
                us.discovery_enabled,
                us.incognito_mode
            FROM public.profiles p
            LEFT JOIN public.user_settings us ON us.user_id = p.id
            LEFT JOIN public.users viewer_user ON COALESCE(viewer_user.auth_user_id, viewer_user.id) = p.id
            WHERE p.id = $1
            LIMIT 1
        ' INTO viewer_ctx USING viewer_id;
    ELSE
        EXECUTE '
            SELECT
                p.age AS viewer_age,
                p.gender AS viewer_gender,
                COALESCE(p.lat, viewer_user.birth_lat) AS viewer_lat,
                COALESCE(p.lng, viewer_user.birth_lng) AS viewer_lng,
                NULL::TEXT AS gender_preference,
                NULL::INTEGER AS min_age_preference,
                NULL::INTEGER AS max_age_preference,
                NULL::INTEGER AS preferred_distance_km,
                TRUE::BOOLEAN AS discovery_enabled,
                FALSE::BOOLEAN AS incognito_mode
            FROM public.profiles p
            LEFT JOIN public.users viewer_user ON COALESCE(viewer_user.auth_user_id, viewer_user.id) = p.id
            WHERE p.id = $1
            LIMIT 1
        ' INTO viewer_ctx USING viewer_id;
    END IF;

    IF viewer_ctx IS NULL THEN
        RETURN;
    END IF;

    viewer_ctx.gender_preference := COALESCE(viewer_ctx.gender_preference, 'any');
    viewer_ctx.min_age_preference := COALESCE(viewer_ctx.min_age_preference, min_age_filter, 18);
    viewer_ctx.max_age_preference := COALESCE(viewer_ctx.max_age_preference, max_age_filter, 100);
    viewer_ctx.preferred_distance_km := COALESCE(max_distance_km, viewer_ctx.preferred_distance_km, 50);

    IF COALESCE(viewer_ctx.discovery_enabled, true) = false
       OR COALESCE(viewer_ctx.incognito_mode, false) = true THEN
        RETURN;
    END IF;

    IF settings_exist THEN
        RETURN QUERY EXECUTE '
            SELECT
                p.id,
                p.display_name,
                p.age,
                p.gender,
                p.zodiac_sign,
                p.height,
                COALESCE(p.interests, ''{}''::TEXT[]) AS interests,
                p.education_level,
                candidate_location.candidate_lat::DECIMAL AS lat,
                candidate_location.candidate_lng::DECIMAL AS lng,
                p.avatar_url,
                dist.distance_km,
                COALESCE(
                    (
                        SELECT compatibility_score
                        FROM public.compatibility_scores cs
                        WHERE (cs.user1_id = $1 AND cs.user2_id = p.id)
                           OR (cs.user1_id = p.id AND cs.user2_id = $1)
                        ORDER BY cs.calculated_at DESC
                        LIMIT 1
                    ),
                    50
                ) AS compatibility_score,
                p.updated_at AS last_active,
                COALESCE(candidate_user.subscription_status = ''active'', false) AS premium_user,
                p.avatar_url AS profile_image_url
            FROM public.profiles p
            LEFT JOIN public.user_settings target_settings ON target_settings.user_id = p.id
            LEFT JOIN public.users candidate_user ON COALESCE(candidate_user.auth_user_id, candidate_user.id) = p.id
            LEFT JOIN public.swipe_exclusion_cache sec ON sec.swiper_id = $1
            LEFT JOIN LATERAL (
                SELECT
                    COALESCE(p.lat, candidate_user.birth_lat) AS candidate_lat,
                    COALESCE(p.lng, candidate_user.birth_lng) AS candidate_lng
            ) candidate_location ON TRUE
            LEFT JOIN LATERAL (
                SELECT CASE
                    WHEN $2 IS NOT NULL AND $3 IS NOT NULL
                         AND candidate_location.candidate_lat IS NOT NULL
                         AND candidate_location.candidate_lng IS NOT NULL THEN
                        (6371 * acos(
                            LEAST(1.0, GREATEST(-1.0,
                                cos(radians($2)) * cos(radians(candidate_location.candidate_lat)) *
                                cos(radians(candidate_location.candidate_lng) - radians($3)) +
                                sin(radians($2)) * sin(radians(candidate_location.candidate_lat))
                            ))
                        ))::NUMERIC(10,2)
                    ELSE NULL
                END AS distance_km
            ) dist ON TRUE
            WHERE p.id <> $1
              AND p.onboarding_completed = true
              AND (cardinality($4) = 0 OR NOT (p.id = ANY($4)))
              AND (sec.swiped_user_ids IS NULL OR NOT (p.id = ANY(sec.swiped_user_ids)))
              AND ($5 IS NULL OR (p.zodiac_sign IS NOT NULL AND lower(p.zodiac_sign) = lower($5)))
              AND ($6 IS NULL OR (p.age IS NOT NULL AND p.age >= $6))
              AND ($7 IS NULL OR (p.age IS NOT NULL AND p.age <= $7))
              AND (p.age IS NULL OR p.age BETWEEN $8 AND $9)
              AND (
                  $10 IS NULL
                  OR $10::text = ''any''
                  OR (p.gender IS NOT NULL AND lower(p.gender) = lower($10))
              )
              AND (
                  target_settings.gender_preference IS NULL
                  OR target_settings.gender_preference = ''any''
                  OR $11 IS NULL
                  OR lower($11) = lower(target_settings.gender_preference)
              )
              AND (
                  $12 IS NULL
                  OR dist.distance_km IS NULL
                  OR dist.distance_km <= $12
              )
              AND (
                  target_settings.preferred_distance_km IS NULL
                  OR dist.distance_km IS NULL
                  OR dist.distance_km <= target_settings.preferred_distance_km
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM public.blocks b
                  WHERE (b.blocker_id = $1 AND b.blocked_id = p.id)
                     OR (b.blocker_id = p.id AND b.blocked_id = $1)
              )
              AND EXISTS (
                  SELECT 1
                  FROM public.users udata
                  WHERE COALESCE(udata.auth_user_id, udata.id) = p.id
                    AND udata.natal_chart_data IS NOT NULL
                    AND udata.questionnaire_responses IS NOT NULL
                    AND jsonb_typeof(udata.questionnaire_responses) = ''array''
                    AND jsonb_array_length(udata.questionnaire_responses) > 0
              )
            ORDER BY
                COALESCE(candidate_user.subscription_status = ''active'', false) DESC,
                dist.distance_km NULLS LAST,
                p.updated_at DESC
            LIMIT $13
            OFFSET $14
        ' USING viewer_id,
                 viewer_ctx.viewer_lat,
                 viewer_ctx.viewer_lng,
                 exclude_ids,
                 zodiac_filter,
                 min_age_filter,
                 max_age_filter,
                 viewer_ctx.min_age_preference,
                 viewer_ctx.max_age_preference,
                 viewer_ctx.gender_preference,
                 viewer_ctx.viewer_gender,
                 viewer_ctx.preferred_distance_km,
                 limit_count,
                 offset_count;
    ELSE
        RETURN QUERY EXECUTE '
            SELECT
                p.id,
                p.display_name,
                p.age,
                p.gender,
                p.zodiac_sign,
                p.height,
                COALESCE(p.interests, ''{}''::TEXT[]) AS interests,
                p.education_level,
                candidate_location.candidate_lat::DECIMAL AS lat,
                candidate_location.candidate_lng::DECIMAL AS lng,
                p.avatar_url,
                dist.distance_km,
                COALESCE(
                    (
                        SELECT compatibility_score
                        FROM public.compatibility_scores cs
                        WHERE (cs.user1_id = $1 AND cs.user2_id = p.id)
                           OR (cs.user1_id = p.id AND cs.user2_id = $1)
                        ORDER BY cs.calculated_at DESC
                        LIMIT 1
                    ),
                    50
                ) AS compatibility_score,
                p.updated_at AS last_active,
                COALESCE(candidate_user.subscription_status = ''active'', false) AS premium_user,
                p.avatar_url AS profile_image_url
            FROM public.profiles p
            LEFT JOIN public.users candidate_user ON COALESCE(candidate_user.auth_user_id, candidate_user.id) = p.id
            LEFT JOIN public.swipe_exclusion_cache sec ON sec.swiper_id = $1
            LEFT JOIN LATERAL (
                SELECT
                    COALESCE(p.lat, candidate_user.birth_lat) AS candidate_lat,
                    COALESCE(p.lng, candidate_user.birth_lng) AS candidate_lng
            ) candidate_location ON TRUE
            LEFT JOIN LATERAL (
                SELECT CASE
                    WHEN $2 IS NOT NULL AND $3 IS NOT NULL
                         AND candidate_location.candidate_lat IS NOT NULL
                         AND candidate_location.candidate_lng IS NOT NULL THEN
                        (6371 * acos(
                            LEAST(1.0, GREATEST(-1.0,
                                cos(radians($2)) * cos(radians(candidate_location.candidate_lat)) *
                                cos(radians(candidate_location.candidate_lng) - radians($3)) +
                                sin(radians($2)) * sin(radians(candidate_location.candidate_lat))
                            ))
                        ))::NUMERIC(10,2)
                    ELSE NULL
                END AS distance_km
            ) dist ON TRUE
            WHERE p.id <> $1
              AND p.onboarding_completed = true
              AND (cardinality($4) = 0 OR NOT (p.id = ANY($4)))
              AND (sec.swiped_user_ids IS NULL OR NOT (p.id = ANY(sec.swiped_user_ids)))
              AND ($5 IS NULL OR (p.zodiac_sign IS NOT NULL AND lower(p.zodiac_sign) = lower($5)))
              AND ($6 IS NULL OR (p.age IS NOT NULL AND p.age >= $6))
              AND ($7 IS NULL OR (p.age IS NOT NULL AND p.age <= $7))
              AND (p.age IS NULL OR p.age BETWEEN $8 AND $9)
              AND (
                  $10 IS NULL
                  OR $10::text = ''any''
                  OR (p.gender IS NOT NULL AND lower(p.gender) = lower($10))
              )
              AND (
                  $11 IS NULL
                  OR dist.distance_km IS NULL
                  OR dist.distance_km <= $11
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM public.blocks b
                  WHERE (b.blocker_id = $1 AND b.blocked_id = p.id)
                     OR (b.blocker_id = p.id AND b.blocked_id = $1)
              )
              AND EXISTS (
                  SELECT 1
                  FROM public.users udata
                  WHERE COALESCE(udata.auth_user_id, udata.id) = p.id
                    AND udata.natal_chart_data IS NOT NULL
                    AND udata.questionnaire_responses IS NOT NULL
                    AND jsonb_typeof(udata.questionnaire_responses) = ''array''
                    AND jsonb_array_length(udata.questionnaire_responses) > 0
              )
            ORDER BY
                COALESCE(candidate_user.subscription_status = ''active'', false) DESC,
                dist.distance_km NULLS LAST,
                p.updated_at DESC
            LIMIT $12
            OFFSET $13
        ' USING viewer_id,
                 viewer_ctx.viewer_lat,
                 viewer_ctx.viewer_lng,
                 exclude_ids,
                 zodiac_filter,
                 min_age_filter,
                 max_age_filter,
                 viewer_ctx.min_age_preference,
                 viewer_ctx.max_age_preference,
                 viewer_ctx.gender_preference,
                 viewer_ctx.preferred_distance_km,
                 limit_count,
                 offset_count;
    END IF;
END;
$$;

-- Backwards-compatible overload for legacy callers using the previous signature
CREATE OR REPLACE FUNCTION public.get_potential_matches_optimized(
    target_user_id UUID,
    max_distance_km INTEGER DEFAULT 100,
    result_limit INTEGER DEFAULT 200
)
RETURNS TABLE (
    id UUID,
    display_name TEXT,
    age INTEGER,
    gender TEXT,
    zodiac_sign TEXT,
    height INTEGER,
    interests TEXT[],
    education_level TEXT,
    lat DECIMAL,
    lng DECIMAL,
    avatar_url TEXT,
    distance_km NUMERIC,
    compatibility_score INTEGER,
    last_active TIMESTAMPTZ,
    premium_user BOOLEAN,
    profile_image_url TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.get_potential_matches_optimized(
        viewer_id => target_user_id,
        exclude_user_ids => ARRAY[]::UUID[],
        zodiac_filter => NULL,
        min_age_filter => NULL,
        max_age_filter => NULL,
        max_distance_km => max_distance_km,
        limit_count => result_limit,
        offset_count => 0
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_potential_matches_optimized(UUID, UUID[], TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_potential_matches_optimized(UUID, UUID[], TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_potential_matches_optimized(UUID, UUID[], TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_potential_matches_optimized(UUID, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_potential_matches_optimized(UUID, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_potential_matches_optimized(UUID, INTEGER, INTEGER) TO service_role;

COMMENT ON FUNCTION public.get_potential_matches_optimized(UUID, UUID[], TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) IS 'Returns potential matches with mutual preference enforcement and schema-compatible response payload for the optimized matching Edge Function.';
COMMENT ON FUNCTION public.get_potential_matches_optimized(UUID, INTEGER, INTEGER) IS 'Backwards-compatible wrapper for legacy callers of the optimized matching RPC.';

COMMIT;
