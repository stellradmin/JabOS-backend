-- FINAL FIX: Activity filtering using correct JSONB path
-- Activities are stored in nested array: activity_preferences->'preferred_activities'
-- Need to use @> operator instead of ? operator

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
BEGIN
    RETURN QUERY
    WITH viewer_data AS (
        SELECT
            p.gender as viewer_gender,
            COALESCE(u.looking_for, ARRAY[]::TEXT[]) as viewer_looking_for
        FROM profiles p
        LEFT JOIN users u ON u.id = p.id
        WHERE p.id = viewer_id
    ),
    potential_matches AS (
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
            NULL::NUMERIC as distance_km,
            u.looking_for as match_looking_for
        FROM profiles p
        LEFT JOIN users u ON u.id = p.id
        LEFT JOIN swipe_exclusion_cache sec ON sec.swiper_id = viewer_id
        CROSS JOIN viewer_data vd
        WHERE
            p.id != viewer_id
            AND (sec.swiped_user_ids IS NULL OR NOT (p.id = ANY(sec.swiped_user_ids)))
            AND NOT (p.id = ANY(exclude_user_ids))
            AND (zodiac_filter IS NULL OR p.zodiac_sign = zodiac_filter)
            AND (min_age_filter IS NULL OR p.age >= min_age_filter)
            AND (max_age_filter IS NULL OR p.age <= max_age_filter)
            -- FIXED: Activity filtering using correct JSONB path for nested array
            AND (
                activity_filter IS NULL OR
                p.activity_preferences->'preferred_activities' @> jsonb_build_array(activity_filter)
            )
            -- Viewer's gender preference
            AND (
                (vd.viewer_looking_for IS NULL OR array_length(vd.viewer_looking_for, 1) IS NULL) OR
                (
                    CASE
                        WHEN 'Males' = ANY(vd.viewer_looking_for) AND p.gender = 'Male' THEN true
                        WHEN 'Females' = ANY(vd.viewer_looking_for) AND p.gender = 'Female' THEN true
                        WHEN 'Non-Binary' = ANY(vd.viewer_looking_for) AND p.gender = 'Non-binary' THEN true
                        WHEN 'Both' = ANY(vd.viewer_looking_for) THEN true
                        ELSE false
                    END
                )
            )
            -- Match's gender preference
            AND (
                (u.looking_for IS NULL OR array_length(u.looking_for, 1) IS NULL) OR
                (
                    CASE
                        WHEN 'Males' = ANY(u.looking_for) AND vd.viewer_gender = 'Male' THEN true
                        WHEN 'Females' = ANY(u.looking_for) AND vd.viewer_gender = 'Female' THEN true
                        WHEN 'Non-Binary' = ANY(u.looking_for) AND vd.viewer_gender = 'Non-binary' THEN true
                        WHEN 'Both' = ANY(u.looking_for) THEN true
                        ELSE false
                    END
                )
            )
        LIMIT (limit_count * 2)
    )
    SELECT
        pm.id,
        pm.display_name,
        pm.avatar_url,
        pm.gender,
        pm.age,
        pm.zodiac_sign,
        pm.interests,
        pm.education_level,
        pm.bio,
        COALESCE(
            (SELECT cs.compatibility_score
             FROM compatibility_scores cs
             WHERE (cs.user_id = viewer_id AND cs.potential_match_id = pm.id) OR
                   (cs.user_id = pm.id AND cs.potential_match_id = viewer_id)
             ORDER BY cs.calculated_at DESC
             LIMIT 1),
            75.0
        ) as compatibility_score,
        pm.distance_km
    FROM potential_matches pm
    ORDER BY
        COALESCE(
            (SELECT cs.compatibility_score
             FROM compatibility_scores cs
             WHERE (cs.user_id = viewer_id AND cs.potential_match_id = pm.id) OR
                   (cs.user_id = pm.id AND cs.potential_match_id = viewer_id)
             ORDER BY cs.calculated_at DESC
             LIMIT 1),
            75.0
        ) DESC
    LIMIT limit_count
    OFFSET offset_count;
END;
$$;

COMMENT ON FUNCTION get_potential_matches_optimized IS
'FINAL WORKING VERSION:
- Activity filtering via JSONB @> operator on nested array
- Zodiac, age, gender preference filtering
- Cached compatibility scores with 75.0 default
- Edge function calculates real scores async';

GRANT EXECUTE ON FUNCTION get_potential_matches_optimized TO authenticated;
GRANT EXECUTE ON FUNCTION get_potential_matches_optimized TO anon;

COMMIT;
