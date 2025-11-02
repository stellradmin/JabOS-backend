-- Migration for adding check_match_eligibility function

CREATE OR REPLACE FUNCTION check_match_eligibility(user1_id UUID, user2_id UUID)
RETURNS JSONB AS $$
DECLARE
    user1_age INT;
    user2_age INT;
    user1_app_settings JSONB;
    user2_app_settings JSONB;
    user1_location JSONB;
    user2_location JSONB;
    user1_min_age INT;
    user1_max_age INT;
    user1_max_distance INT;
    user2_min_age INT;
    user2_max_age INT;
    user2_max_distance INT;
    distance DOUBLE PRECISION;
    earth_radius CONSTANT DOUBLE PRECISION := 6371; -- Earth's radius in km
    eligibility JSONB := '{}';
BEGIN
    -- Fetch user data
    SELECT age, app_settings, location 
    INTO user1_age, user1_app_settings, user1_location 
    FROM profiles WHERE id = user1_id;
    
    SELECT age, app_settings, location 
    INTO user2_age, user2_app_settings, user2_location 
    FROM profiles WHERE id = user2_id;

    -- Extract preference data with defaults
    user1_min_age := COALESCE((user1_app_settings->>'min_age_preference')::INT, 18);
    user1_max_age := COALESCE((user1_app_settings->>'max_age_preference')::INT, 100);
    user1_max_distance := COALESCE((user1_app_settings->>'distance')::INT, 50);
    user2_min_age := COALESCE((user2_app_settings->>'min_age_preference')::INT, 18);
    user2_max_age := COALESCE((user2_app_settings->>'max_age_preference')::INT, 100);
    user2_max_distance := COALESCE((user2_app_settings->>'distance')::INT, 50);

    -- Age eligibility checks
    eligibility := jsonb_set(eligibility, '{user1_age_eligible}',
        to_jsonb(user2_age BETWEEN user1_min_age AND user1_max_age));
    eligibility := jsonb_set(eligibility, '{user2_age_eligible}',
        to_jsonb(user1_age BETWEEN user2_min_age AND user2_max_age));

    -- Calculate distance using Haversine formula (if location data exists)
    IF user1_location IS NOT NULL AND user2_location IS NOT NULL AND 
       user1_location->>'lat' IS NOT NULL AND user1_location->>'lng' IS NOT NULL AND
       user2_location->>'lat' IS NOT NULL AND user2_location->>'lng' IS NOT NULL THEN
       
        distance := earth_radius * acos(
            sin(radians((user1_location->>'lat')::DOUBLE PRECISION)) *
            sin(radians((user2_location->>'lat')::DOUBLE PRECISION)) +
            cos(radians((user1_location->>'lat')::DOUBLE PRECISION)) *
            cos(radians((user2_location->>'lat')::DOUBLE PRECISION)) *
            cos(radians((user2_location->>'lng')::DOUBLE PRECISION) - radians((user1_location->>'lng')::DOUBLE PRECISION))
        );
        
        -- Convert to miles
        distance := distance * 0.621371;

        -- Distance eligibility checks
        eligibility := jsonb_set(eligibility, '{user1_distance_eligible}',
            to_jsonb(distance <= user1_max_distance));
        eligibility := jsonb_set(eligibility, '{user2_distance_eligible}',
            to_jsonb(distance <= user2_max_distance));
    ELSE
        -- If no location data, assume distance is compatible
        eligibility := jsonb_set(eligibility, '{user1_distance_eligible}', to_jsonb(true));
        eligibility := jsonb_set(eligibility, '{user2_distance_eligible}', to_jsonb(true));
    END IF;

    -- Add overall eligibility
    eligibility := jsonb_set(eligibility, '{eligible}',
        to_jsonb(
            (eligibility->>'user1_age_eligible')::BOOLEAN AND
            (eligibility->>'user2_age_eligible')::BOOLEAN AND
            (eligibility->>'user1_distance_eligible')::BOOLEAN AND
            (eligibility->>'user2_distance_eligible')::BOOLEAN
        ));

    RETURN eligibility;
END;
$$ LANGUAGE plpgsql;
