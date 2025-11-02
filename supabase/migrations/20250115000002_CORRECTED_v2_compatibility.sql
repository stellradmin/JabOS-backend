-- CORRECTED V2: Fix ambiguous column reference
-- Quick fix for: column reference "id" is ambiguous

BEGIN;

DROP FUNCTION IF EXISTS get_potential_matches_optimized(
    uuid, uuid[], text, integer, integer, integer, text, integer, integer
);

CREATE OR REPLACE FUNCTION get_potential_matches_optimized(
    viewer_id UUID,
    exclude_user_ids UUID[] DEFAULT '{}',
    zodiac_filter TEXT DEFAULT NULL,
    min_age_filter INTEGER DEFAULT NULL,
    max_age_filter INTEGER DEFAULT NULL,
    max_distance_km INTEGER DEFAULT NULL,
    activity_filter TEXT DEFAULT NULL,
    limit_count INTEGER DEFAULT 10,
    offset_count INTEGER DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    display_name TEXT,
    avatar_url TEXT,
    gender TEXT,
    age INTEGER,
    zodiac_sign TEXT,
    interests TEXT[],
    education_level TEXT,
    bio TEXT,
    compatibility_score NUMERIC,
    distance_km NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    viewer_profile RECORD;
    viewer_user RECORD;
    match_id UUID;
    compatibility_result JSONB;
    compatibility_value NUMERIC;
BEGIN
    -- Get viewer's profile and user data (FIX: qualify column names)
    SELECT * INTO viewer_profile FROM profiles p WHERE p.id = viewer_id;
    SELECT * INTO viewer_user FROM users u WHERE u.id = viewer_id;

    IF viewer_profile IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH potential_matches AS (
        SELECT
            p.id,
            p.display_name,
            p.avatar_url,
            p.gender,
            p.age,
            p.zodiac_sign,
            ARRAY[]::TEXT[] as interests,
            p.education_level,
            COALESCE(p.bio, 'No bio') as bio,
            NULL::NUMERIC as distance_km
        FROM profiles p
        LEFT JOIN users u ON u.id = p.id
        LEFT JOIN swipe_exclusion_cache sec ON sec.swiper_id = viewer_id
        WHERE
            p.id != viewer_id
            AND (sec.swiped_user_ids IS NULL OR NOT (p.id = ANY(sec.swiped_user_ids)))
            AND NOT (p.id = ANY(exclude_user_ids))
            AND (zodiac_filter IS NULL OR p.zodiac_sign = zodiac_filter)
            AND (min_age_filter IS NULL OR p.age >= min_age_filter)
            AND (max_age_filter IS NULL OR p.age <= max_age_filter)
            AND (activity_filter IS NULL OR p.activity_preferences ? activity_filter)
            AND (
                (viewer_user.looking_for IS NULL OR array_length(viewer_user.looking_for, 1) IS NULL) OR
                (
                    CASE
                        WHEN 'Males' = ANY(viewer_user.looking_for) AND p.gender = 'Male' THEN true
                        WHEN 'Females' = ANY(viewer_user.looking_for) AND p.gender = 'Female' THEN true
                        WHEN 'Non-Binary' = ANY(viewer_user.looking_for) AND p.gender = 'Non-binary' THEN true
                        WHEN 'Both' = ANY(viewer_user.looking_for) THEN true
                        ELSE false
                    END
                )
            )
            AND (
                (u.looking_for IS NULL OR array_length(u.looking_for, 1) IS NULL) OR
                (
                    CASE
                        WHEN 'Males' = ANY(u.looking_for) AND viewer_profile.gender = 'Male' THEN true
                        WHEN 'Females' = ANY(u.looking_for) AND viewer_profile.gender = 'Female' THEN true
                        WHEN 'Non-Binary' = ANY(u.looking_for) AND viewer_profile.gender = 'Non-binary' THEN true
                        WHEN 'Both' = ANY(u.looking_for) THEN true
                        ELSE false
                    END
                )
            )
        LIMIT (limit_count * 2)
    ),
    compatibility_calculated AS (
        SELECT
            pm.*,
            COALESCE(
                (SELECT cs.compatibility_score
                 FROM compatibility_scores cs
                 WHERE (cs.user_id = viewer_id AND cs.potential_match_id = pm.id) OR
                       (cs.user_id = pm.id AND cs.potential_match_id = viewer_id)
                 ORDER BY cs.calculated_at DESC
                 LIMIT 1),
                75.0
            ) as calculated_score
        FROM potential_matches pm
    )
    SELECT
        cc.id,
        cc.display_name,
        cc.avatar_url,
        cc.gender,
        cc.age,
        cc.zodiac_sign,
        cc.interests,
        cc.education_level,
        cc.bio,
        cc.calculated_score as compatibility_score,
        cc.distance_km
    FROM compatibility_calculated cc
    ORDER BY cc.calculated_score DESC
    LIMIT limit_count
    OFFSET offset_count;

    -- Calculate and cache real compatibility scores
    FOR match_id IN
        SELECT cc.id FROM compatibility_calculated cc
    LOOP
        BEGIN
            compatibility_result := calculate_compatibility_scores(viewer_id, match_id);
            compatibility_value := (compatibility_result->>'overall_score')::NUMERIC;

            INSERT INTO compatibility_scores (
                user_id,
                potential_match_id,
                compatibility_score,
                score_components,
                calculated_at,
                created_at,
                updated_at
            )
            VALUES (
                viewer_id,
                match_id,
                compatibility_value,
                compatibility_result,
                NOW(),
                NOW(),
                NOW()
            )
            ON CONFLICT (user_id, potential_match_id) DO UPDATE
            SET
                compatibility_score = EXCLUDED.compatibility_score,
                score_components = EXCLUDED.score_components,
                calculated_at = NOW(),
                updated_at = NOW();
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING 'Compatibility calculation failed for % and %: %', viewer_id, match_id, SQLERRM;
        END;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION get_potential_matches_optimized TO authenticated;
GRANT EXECUTE ON FUNCTION get_potential_matches_optimized TO anon;

COMMIT;
