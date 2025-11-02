-- Restore aspects-based astrological compatibility (original algorithm, core bodies only)
begin;

-- Helper to normalize sign + degree to an absolute zodiac degree
create or replace function public.calculate_absolute_degree(sign_name TEXT, degree_within_sign FLOAT)
RETURNS FLOAT
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    sign_offset FLOAT;
    validated_degree FLOAT;
BEGIN
    IF sign_name IS NULL THEN
        RETURN 0.0;
    END IF;

    validated_degree := COALESCE(degree_within_sign, 0.0);
    validated_degree := GREATEST(0.0, LEAST(30.0, validated_degree));

    CASE UPPER(TRIM(sign_name))
        WHEN 'ARIES' THEN sign_offset := 0.0;
        WHEN 'TAURUS' THEN sign_offset := 30.0;
        WHEN 'GEMINI' THEN sign_offset := 60.0;
        WHEN 'CANCER' THEN sign_offset := 90.0;
        WHEN 'LEO' THEN sign_offset := 120.0;
        WHEN 'VIRGO' THEN sign_offset := 150.0;
        WHEN 'LIBRA' THEN sign_offset := 180.0;
        WHEN 'SCORPIO' THEN sign_offset := 210.0;
        WHEN 'SAGITTARIUS' THEN sign_offset := 240.0;
        WHEN 'CAPRICORN' THEN sign_offset := 270.0;
        WHEN 'AQUARIUS' THEN sign_offset := 300.0;
        WHEN 'PISCES' THEN sign_offset := 330.0;
        ELSE sign_offset := 0.0;
    END CASE;

    RETURN sign_offset + validated_degree;
END;
$$;

create or replace function public.calculate_astrological_compatibility(
    user_a_chart jsonb,
    user_b_chart jsonb
)
returns jsonb
language plpgsql STABLE
as $$
DECLARE
    raw_harmony_score FLOAT := 0.0;
    total_aspect_weight FLOAT := 0.0;
    final_score FLOAT;
    letter_grade TEXT;

    core_bodies TEXT[] := ARRAY['Sun', 'Moon', 'Ascendant', 'Mercury', 'Venus', 'Mars'];

    aspect_orbs JSONB := '{
        "CONJUNCTION": 8.0,
        "OPPOSITION": 8.0,
        "TRINE": 8.0,
        "SQUARE": 8.0,
        "SEXTILE": 6.0,
        "QUINCUNX": 3.0
    }'::JSONB;

    aspect_angles JSONB := '{
        "CONJUNCTION": 0.0,
        "SEXTILE": 60.0,
        "SQUARE": 90.0,
        "TRINE": 120.0,
        "OPPOSITION": 180.0,
        "QUINCUNX": 150.0
    }'::JSONB;

    body1_name TEXT;
    body2_name TEXT;
    body1_data JSONB;
    body2_data JSONB;
    body1_degree FLOAT;
    body2_degree FLOAT;
    angle_diff FLOAT;
    aspect_type TEXT;
    orb_limit FLOAT;
    diff_from_target FLOAT;
    aspect_weight FLOAT;
    harmony_contribution FLOAT;
    base_weight FLOAT;
    tightness_factor FLOAT;
    processed_pairs TEXT[] := '{}';
    pair_key TEXT;
    aspects_found INT := 0;
BEGIN
    IF user_a_chart IS NULL OR user_b_chart IS NULL THEN
        RETURN jsonb_build_object(
            'overall_score', 50,
            'grade', 'C',
            'details', 'Insufficient astrological data',
            'aspects_found', 0
        );
    END IF;

    IF user_a_chart->'placements' IS NULL OR user_b_chart->'placements' IS NULL THEN
        RETURN jsonb_build_object(
            'overall_score', 50,
            'grade', 'C',
            'details', 'Invalid chart structure - missing placements',
            'aspects_found', 0
        );
    END IF;

    FOREACH body1_name IN ARRAY core_bodies LOOP
        FOREACH body2_name IN ARRAY core_bodies LOOP
            IF body1_name <= body2_name THEN
                pair_key := body1_name || '-' || body2_name;
            ELSE
                pair_key := body2_name || '-' || body1_name;
            END IF;

            IF pair_key = ANY(processed_pairs) THEN
                CONTINUE;
            END IF;
            processed_pairs := processed_pairs || pair_key;

            body1_data := user_a_chart->'placements'->body1_name;
            body2_data := user_b_chart->'placements'->body2_name;
            IF body1_data IS NULL OR body2_data IS NULL THEN
                CONTINUE;
            END IF;

            BEGIN
                body1_degree := COALESCE(
                    CASE WHEN jsonb_typeof(body1_data->'absolute_degree') = 'number'
                         THEN (body1_data->>'absolute_degree')::FLOAT ELSE NULL END,
                    public.calculate_absolute_degree(body1_data->>'sign', COALESCE((body1_data->>'degree')::FLOAT, 0.0))
                );
                body2_degree := COALESCE(
                    CASE WHEN jsonb_typeof(body2_data->'absolute_degree') = 'number'
                         THEN (body2_data->>'absolute_degree')::FLOAT ELSE NULL END,
                    public.calculate_absolute_degree(body2_data->>'sign', COALESCE((body2_data->>'degree')::FLOAT, 0.0))
                );
            EXCEPTION WHEN OTHERS THEN
                CONTINUE;
            END;

            IF body1_degree < 0 OR body1_degree >= 360 OR body2_degree < 0 OR body2_degree >= 360 THEN
                CONTINUE;
            END IF;

            angle_diff := ABS(body1_degree - body2_degree);
            IF angle_diff > 180.0 THEN
                angle_diff := 360.0 - angle_diff;
            END IF;

            FOR aspect_type IN SELECT key FROM jsonb_each(aspect_orbs) ORDER BY value::FLOAT ASC LOOP
                orb_limit := (aspect_orbs->>aspect_type)::FLOAT;
                diff_from_target := ABS(angle_diff - (aspect_angles->>aspect_type)::FLOAT);

                IF diff_from_target <= orb_limit THEN
                    base_weight := 1.0;
                    IF body1_name IN ('Sun','Moon','Ascendant') OR body2_name IN ('Sun','Moon','Ascendant') THEN
                        base_weight := 1.5;
                    END IF;
                    IF (body1_name='Sun' AND body2_name='Moon') OR (body1_name='Moon' AND body2_name='Sun') THEN
                        base_weight := 2.0;
                    END IF;
                    IF (body1_name='Venus' AND body2_name='Mars') OR (body1_name='Mars' AND body2_name='Venus') THEN
                        base_weight := 1.7;
                    END IF;

                    IF orb_limit > 0 THEN
                        tightness_factor := GREATEST(0.0, LEAST(1.0, 1.0 - (diff_from_target / orb_limit)));
                        aspect_weight := base_weight * (1.0 + tightness_factor * 0.5);
                    ELSE
                        aspect_weight := base_weight;
                    END IF;

                    CASE aspect_type
                        WHEN 'TRINE' THEN harmony_contribution := 1.0;
                        WHEN 'SEXTILE' THEN harmony_contribution := 0.7;
                        WHEN 'CONJUNCTION' THEN harmony_contribution := 0.3;
                        WHEN 'OPPOSITION' THEN harmony_contribution := -0.5;
                        WHEN 'SQUARE' THEN harmony_contribution := -0.7;
                        WHEN 'QUINCUNX' THEN harmony_contribution := -0.3;
                        ELSE harmony_contribution := 0.0;
                    END CASE;

                    IF aspect_weight > 0 THEN
                        raw_harmony_score := raw_harmony_score + (harmony_contribution * aspect_weight);
                        total_aspect_weight := total_aspect_weight + aspect_weight;
                        aspects_found := aspects_found + 1;
                    END IF;

                    EXIT; -- tightest aspect handled
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;

    IF total_aspect_weight > 0 THEN
        final_score := GREATEST(0.0, LEAST(100.0, 50.0 + ((raw_harmony_score / total_aspect_weight) * 25.0)));
    ELSE
        final_score := 50.0;
    END IF;

    IF final_score >= 90.0 THEN
        letter_grade := 'A';
    ELSIF final_score >= 80.0 THEN
        letter_grade := 'B';
    ELSIF final_score >= 70.0 THEN
        letter_grade := 'C';
    ELSIF final_score >= 60.0 THEN
        letter_grade := 'D';
    ELSE
        letter_grade := 'F';
    END IF;

    RETURN jsonb_build_object(
        'overall_score', ROUND(final_score),
        'grade', letter_grade,
        'harmony_score', ROUND(raw_harmony_score, 2),
        'total_weight', ROUND(total_aspect_weight, 2),
        'aspects_found', aspects_found
    );
END;
$$;

-- Tighten execution privileges for security and clarity
-- Helper function (calculate_absolute_degree)
REVOKE EXECUTE ON FUNCTION public.calculate_absolute_degree(TEXT, FLOAT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.calculate_absolute_degree(TEXT, FLOAT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_absolute_degree(TEXT, FLOAT) TO service_role;

-- Main compatibility function
REVOKE EXECUTE ON FUNCTION public.calculate_astrological_compatibility(JSONB, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.calculate_astrological_compatibility(JSONB, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_astrological_compatibility(JSONB, JSONB) TO service_role;

commit;
