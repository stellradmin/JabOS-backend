-- =============================================
-- JabOS Mobile - Main Matching Function
-- get_training_partners_optimized
-- Adapted from Stellr's get_potential_matches_optimized
-- =============================================

CREATE OR REPLACE FUNCTION jabos_mobile.get_training_partners_optimized(
  viewer_id UUID,
  viewer_org_id UUID,
  weight_class_filter TEXT DEFAULT 'any',
  experience_filter TEXT DEFAULT 'any',
  training_type_filter TEXT DEFAULT 'any',
  allow_cross_gym BOOLEAN DEFAULT false,
  max_distance_km INTEGER DEFAULT 25,
  exclude_user_ids UUID[] DEFAULT ARRAY[]::UUID[],
  limit_count INTEGER DEFAULT 20,
  offset_count INTEGER DEFAULT 0
)
RETURNS TABLE (
  user_id UUID,
  display_name TEXT,
  avatar_url TEXT,
  weight_class TEXT,
  experience_level TEXT,
  organization_id UUID,
  organization_name TEXT,
  is_same_gym BOOLEAN,
  distance_km NUMERIC,
  compatibility_score INTEGER,
  physical_grade TEXT,
  style_grade TEXT,
  overall_score INTEGER,
  is_match_recommended BOOLEAN,
  total_sparring_sessions INTEGER,
  current_level INTEGER,
  stance TEXT,
  bio TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'jabos_mobile', 'auth', 'extensions'
AS $$
DECLARE
  v_viewer_swipes UUID[];
BEGIN
  -- Get all users the viewer has already swiped on
  -- This prevents showing the same person twice (like Stellr's swipe_exclusion_cache)
  SELECT ARRAY_AGG(swiped_id)
  INTO v_viewer_swipes
  FROM jabos_mobile.partner_swipes
  WHERE swiper_id = viewer_id;

  -- Combine with explicitly excluded users
  v_viewer_swipes := COALESCE(v_viewer_swipes, ARRAY[]::UUID[]) || exclude_user_ids;

  -- Main query: Find potential training partners
  RETURN QUERY
  SELECT
    mp.user_id,
    u.display_name,
    u.avatar_url,
    mp.weight_class,
    mp.experience_level,
    mp.organization_id,
    o.name AS organization_name,

    -- Is same gym flag (for prioritization)
    (mp.organization_id = viewer_org_id) AS is_same_gym,

    -- Distance calculation (for cross-gym matching)
    -- TODO: Implement actual distance calculation when gym locations added
    0::NUMERIC AS distance_km,

    -- Compatibility scoring (from cache or calculate on-the-fly)
    COALESCE(
      (SELECT compatibility_score
       FROM jabos_mobile.user_compatibility_cache ucc
       WHERE (ucc.user1_id = LEAST(viewer_id, mp.user_id)
         AND ucc.user2_id = GREATEST(viewer_id, mp.user_id))
         AND ucc.expires_at > NOW()
      ),
      -- Fallback: Calculate compatibility on-the-fly
      COALESCE(
        (jabos_mobile.calculate_training_compatibility(viewer_id, mp.user_id)->>'overallScore')::INTEGER,
        0
      )
    ) AS compatibility_score,

    -- Compatibility grades
    COALESCE(
      (SELECT physical_grade
       FROM jabos_mobile.user_compatibility_cache ucc
       WHERE (ucc.user1_id = LEAST(viewer_id, mp.user_id)
         AND ucc.user2_id = GREATEST(viewer_id, mp.user_id))
         AND ucc.expires_at > NOW()
      ),
      (jabos_mobile.calculate_training_compatibility(viewer_id, mp.user_id)->>'PhysicalGrade')::TEXT
    ) AS physical_grade,

    COALESCE(
      (SELECT style_grade
       FROM jabos_mobile.user_compatibility_cache ucc
       WHERE (ucc.user1_id = LEAST(viewer_id, mp.user_id)
         AND ucc.user2_id = GREATEST(viewer_id, mp.user_id))
         AND ucc.expires_at > NOW()
      ),
      (jabos_mobile.calculate_training_compatibility(viewer_id, mp.user_id)->>'StyleGrade')::TEXT
    ) AS style_grade,

    -- Overall score (same as compatibility_score, kept for consistency with Stellr)
    COALESCE(
      (SELECT overall_score
       FROM jabos_mobile.user_compatibility_cache ucc
       WHERE (ucc.user1_id = LEAST(viewer_id, mp.user_id)
         AND ucc.user2_id = GREATEST(viewer_id, mp.user_id))
         AND ucc.expires_at > NOW()
      ),
      COALESCE(
        (jabos_mobile.calculate_training_compatibility(viewer_id, mp.user_id)->>'overallScore')::INTEGER,
        0
      )
    ) AS overall_score,

    -- Is match recommended (score >= 60)
    COALESCE(
      (SELECT is_recommended
       FROM jabos_mobile.user_compatibility_cache ucc
       WHERE (ucc.user1_id = LEAST(viewer_id, mp.user_id)
         AND ucc.user2_id = GREATEST(viewer_id, mp.user_id))
         AND ucc.expires_at > NOW()
      ),
      COALESCE(
        (jabos_mobile.calculate_training_compatibility(viewer_id, mp.user_id)->>'IsMatchRecommended')::BOOLEAN,
        false
      )
    ) AS is_match_recommended,

    -- Additional profile info
    mp.total_sparring_sessions,
    COALESCE(mprog.current_level, 1) AS current_level,
    mp.stance,
    COALESCE(mp.bio, '') AS bio

  FROM public.member_profiles mp
  JOIN public.users u ON mp.user_id = u.id
  JOIN public.organizations o ON mp.organization_id = o.id
  LEFT JOIN public.member_progress mprog ON mp.user_id = mprog.user_id

  WHERE
    -- ===================================================================
    -- ELIGIBILITY GATES (from JabOS sparring system)
    -- ===================================================================

    -- Must be marked as looking for sparring
    mp.looking_for_sparring = true

    -- Must be sparring eligible (coach approved)
    AND mp.sparring_eligible = true

    -- Must have active membership with sparring access
    AND EXISTS (
      SELECT 1
      FROM public.member_subscriptions ms
      JOIN public.membership_plans mplan ON ms.membership_plan_id = mplan.id
      WHERE ms.user_id = mp.user_id
        AND ms.status = 'active'
        AND mplan.allows_sparring = true
    )

    -- ===================================================================
    -- ORGANIZATION FILTERING (multi-tenancy + cross-gym)
    -- ===================================================================

    AND (
      -- Same gym only mode
      (NOT allow_cross_gym AND mp.organization_id = viewer_org_id)
      OR
      -- Cross-gym mode: both organizations must allow cross-gym matching
      (allow_cross_gym
       AND EXISTS (
         SELECT 1 FROM public.organizations org
         WHERE org.id = mp.organization_id
         AND org.cross_gym_matching_enabled = true
       )
       AND EXISTS (
         SELECT 1 FROM public.organizations org
         WHERE org.id = viewer_org_id
         AND org.cross_gym_matching_enabled = true
       )
      )
    )

    -- ===================================================================
    -- WEIGHT CLASS FILTERING (replaces Stellr's zodiac filtering)
    -- ===================================================================

    AND (
      weight_class_filter = 'any'
      OR mp.weight_class = weight_class_filter
      OR mp.weight_class = ANY(jabos_mobile.get_adjacent_weight_classes(weight_class_filter))
    )

    -- ===================================================================
    -- EXPERIENCE LEVEL FILTERING (replaces Stellr's age filtering)
    -- ===================================================================

    AND (
      experience_filter = 'any'
      OR mp.experience_level = experience_filter
      OR mp.experience_level = ANY(jabos_mobile.get_compatible_experience_levels(experience_filter))
    )

    -- ===================================================================
    -- TRAINING TYPE FILTERING (replaces Stellr's activity filtering)
    -- CORE FEATURE: Bidirectional matching like Stellr
    -- ===================================================================

    AND (
      training_type_filter = 'any'
      OR EXISTS (
        SELECT 1
        FROM jabos_mobile.training_preferences tp
        WHERE tp.user_id = mp.user_id
        AND training_type_filter = ANY(tp.preferred_training_types)
      )
    )

    -- ===================================================================
    -- EXCLUSIONS
    -- ===================================================================

    -- Exclude self
    AND mp.user_id != viewer_id

    -- Exclude already swiped users
    AND NOT (mp.user_id = ANY(v_viewer_swipes))

    -- Exclude blocked users (bidirectional)
    AND NOT EXISTS (
      SELECT 1
      FROM jabos_mobile.user_blocks ub
      WHERE (ub.blocking_user_id = viewer_id AND ub.blocked_user_id = mp.user_id)
         OR (ub.blocking_user_id = mp.user_id AND ub.blocked_user_id = viewer_id)
    )

    -- Exclude users with pending match requests (prevent duplicate requests)
    AND NOT EXISTS (
      SELECT 1
      FROM jabos_mobile.match_requests mr
      WHERE (mr.requester_id = viewer_id AND mr.target_id = mp.user_id)
         OR (mr.requester_id = mp.user_id AND mr.target_id = viewer_id)
        AND mr.status IN ('pending', 'accepted')
    )

  -- ===================================================================
  -- RANKING & SORTING (like Stellr's prioritization)
  -- ===================================================================
  ORDER BY
    is_same_gym DESC,              -- Prioritize same gym (like Stellr prioritizes local)
    is_match_recommended DESC,     -- Recommended matches first (score >= 60)
    compatibility_score DESC,      -- Then by compatibility
    mp.total_sparring_sessions DESC, -- Experienced partners preferred
    mp.created_at DESC             -- Finally by recency

  LIMIT limit_count
  OFFSET offset_count;

END;
$$;

COMMENT ON FUNCTION jabos_mobile.get_training_partners_optimized IS
'Main matching algorithm for finding training partners.
Filters by: eligibility gates, organization, weight class, experience, training type preferences.
Returns: Ranked list with compatibility scores, grades, and profile info.
Uses compatibility cache for performance (like Stellr).
Adapted from Stellr''s get_potential_matches_optimized.';

-- =============================================
-- Grant execute permission
-- =============================================
GRANT EXECUTE ON FUNCTION jabos_mobile.get_training_partners_optimized TO authenticated;
