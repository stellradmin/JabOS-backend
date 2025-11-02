-- Replace calculate_astrological_compatibility to remove aspects usage

-- Helper 1: Extract sign from various chart formats
CREATE OR REPLACE FUNCTION public.get_sign(j jsonb, body_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  WITH src AS (
    SELECT j
  )
  -- v2.0 corePlacements (lower)
  , v1 AS (
    SELECT (j->'corePlacements'->body_name->>'sign') AS s FROM src
  )
  , v1b AS (
    SELECT COALESCE((SELECT s FROM v1), (j->'CorePlacements'->body_name->>'Sign')) AS s FROM src
  )
  , v2 AS (
    SELECT COALESCE(
      (SELECT s FROM v1b),
      (SELECT p->>'sign'
         FROM jsonb_array_elements(j->'chartData'->'planets') p
        WHERE LOWER(p->>'name') = LOWER(body_name)
        LIMIT 1),
      (j->body_name->>'sign'),
      (j->>(LOWER(body_name) || '_sign'))
    ) AS s
  )
  SELECT s FROM v2
$$;

-- Helper 2: Get element from zodiac sign
CREATE OR REPLACE FUNCTION public.element_of(sign text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE sign
    WHEN 'Aries' THEN 'Fire' WHEN 'Leo' THEN 'Fire' WHEN 'Sagittarius' THEN 'Fire'
    WHEN 'Taurus' THEN 'Earth' WHEN 'Virgo' THEN 'Earth' WHEN 'Capricorn' THEN 'Earth'
    WHEN 'Gemini' THEN 'Air' WHEN 'Libra' THEN 'Air' WHEN 'Aquarius' THEN 'Air'
    WHEN 'Cancer' THEN 'Water' WHEN 'Scorpio' THEN 'Water' WHEN 'Pisces' THEN 'Water'
    ELSE NULL END
$$;

-- Helper 3: Calculate compatibility score for a pair of signs
CREATE OR REPLACE FUNCTION public.pair_score(a text, b text)
RETURNS float
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  ea text;
  eb text;
BEGIN
  IF a IS NULL OR b IS NULL THEN RETURN 0.5; END IF;
  ea := element_of(a);
  eb := element_of(b);
  IF ea IS NULL OR eb IS NULL THEN RETURN 0.5; END IF;
  IF ea = eb THEN RETURN 1.0; END IF;
  IF (ea='Fire' AND eb='Air') OR (ea='Air' AND eb='Fire') OR (ea='Earth' AND eb='Water') OR (ea='Water' AND eb='Earth') THEN
    RETURN 0.85;
  END IF;
  RETURN 0.6;
END;
$$;

-- Main function: Calculate astrological compatibility
CREATE OR REPLACE FUNCTION public.calculate_astrological_compatibility(
    user_a_chart jsonb,
    user_b_chart jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  -- extracted signs
  sun_a text; sun_b text;
  moon_a text; moon_b text;
  asc_a text; asc_b text;
  -- computed
  score float := 50.0;
  grade text := 'C';
BEGIN
  -- extract signs
  sun_a := get_sign(user_a_chart, 'Sun');
  sun_b := get_sign(user_b_chart, 'Sun');
  moon_a := get_sign(user_a_chart, 'Moon');
  moon_b := get_sign(user_b_chart, 'Moon');
  asc_a := get_sign(user_a_chart, 'Ascendant');
  asc_b := get_sign(user_b_chart, 'Ascendant');

  -- weights: placements-only, no aspects
  -- Sun-Sun 45%, Moon-Moon 25%, Asc-Asc 15%, Sun-Moon cross avg 15%
  score := 100.0 * (
     0.45 * pair_score(sun_a, sun_b) +
     0.25 * pair_score(moon_a, moon_b) +
     0.15 * pair_score(asc_a, asc_b) +
     0.15 * ((pair_score(sun_a, moon_b) + pair_score(moon_a, sun_b)) / 2.0)
  );

  score := GREATEST(0.0, LEAST(100.0, score));

  grade := CASE
    WHEN score >= 90 THEN 'A'
    WHEN score >= 80 THEN 'B'
    WHEN score >= 70 THEN 'C'
    WHEN score >= 60 THEN 'D'
    ELSE 'F'
  END;

  RETURN jsonb_build_object(
    'overall_score', ROUND(score)::int,
    'grade', grade,
    'method', 'element_matching_v1'
  );
END;
$$;

