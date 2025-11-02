-- Fix compatibility algorithm to handle both data structures
-- This migration fixes the JSONB casting error in questionnaire compatibility calculation

-- Enhanced helper function to extract numeric value from questionnaire responses
CREATE OR REPLACE FUNCTION extract_questionnaire_answer(
    responses JSONB,
    question_index INT
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    response_value JSONB;
    numeric_answer INT;
    text_answer TEXT;
BEGIN
    -- Get the response value at the given index
    response_value := responses->question_index;
    
    -- Handle different data structures
    IF response_value IS NULL THEN
        RETURN 3; -- Default neutral response
    END IF;
    
    -- Case 1: Direct numeric value (expected format)
    IF jsonb_typeof(response_value) = 'number' THEN
        RETURN (response_value)::INT;
    END IF;
    
    -- Case 2: Object with answer field {question: "...", answer: "..."}
    IF jsonb_typeof(response_value) = 'object' AND response_value ? 'answer' THEN
        text_answer := response_value->>'answer';
        
        -- Convert text answers to numeric scale (1-5)
        CASE UPPER(text_answer)
            WHEN 'STRONGLY DISAGREE' THEN numeric_answer := 1;
            WHEN 'DISAGREE' THEN numeric_answer := 2;
            WHEN 'NEUTRAL' THEN numeric_answer := 3;
            WHEN 'AGREE' THEN numeric_answer := 4;
            WHEN 'STRONGLY AGREE' THEN numeric_answer := 5;
            ELSE numeric_answer := 3; -- Default to neutral
        END CASE;
        
        RETURN numeric_answer;
    END IF;
    
    -- Case 3: Direct text value
    IF jsonb_typeof(response_value) = 'string' THEN
        text_answer := response_value #>> '{}';
        
        CASE UPPER(text_answer)
            WHEN 'STRONGLY DISAGREE' THEN numeric_answer := 1;
            WHEN 'DISAGREE' THEN numeric_answer := 2;
            WHEN 'NEUTRAL' THEN numeric_answer := 3;
            WHEN 'AGREE' THEN numeric_answer := 4;
            WHEN 'STRONGLY AGREE' THEN numeric_answer := 5;
            ELSE numeric_answer := 3;
        END CASE;
        
        RETURN numeric_answer;
    END IF;
    
    -- Default case
    RETURN 3;
END;
$$;

-- Updated questionnaire compatibility function with proper data handling
CREATE OR REPLACE FUNCTION calculate_questionnaire_compatibility(
    user_a_responses JSONB,
    user_b_responses JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    group_scores JSONB := '{}'::JSONB;
    overall_score FLOAT := 0;
    grade TEXT;
    group_num INT;
    question_num INT;
    answer_a INT;
    answer_b INT;
    divergence INT;
    question_score INT;
    group_total INT;
    group_avg FLOAT;
    group_norm FLOAT;
    total_groups INT := 5;
    questions_per_group INT := 5;
    total_questions INT;
    question_index INT;
BEGIN
    -- Handle null or empty responses
    IF user_a_responses IS NULL OR user_b_responses IS NULL THEN
        RETURN jsonb_build_object(
            'overall_score', 50,
            'grade', 'C',
            'group_scores', '{}'::JSONB,
            'error', 'Missing questionnaire data'
        );
    END IF;
    
    -- Get the actual number of questions from the responses
    total_questions := GREATEST(
        jsonb_array_length(user_a_responses),
        jsonb_array_length(user_b_responses)
    );
    
    -- If we have fewer questions, adjust groups accordingly
    IF total_questions < 25 THEN
        total_groups := GREATEST(1, total_questions / 5);
        questions_per_group := CASE 
            WHEN total_questions <= 5 THEN total_questions
            ELSE 5
        END;
    END IF;
    
    -- Initialize group scores
    FOR group_num IN 1..total_groups LOOP
        group_total := 0;
        
        -- Calculate scores for each question in this group
        FOR question_num IN 1..questions_per_group LOOP
            -- Calculate actual question index (0-based)
            question_index := (group_num - 1) * questions_per_group + question_num - 1;
            
            -- Skip if we've exceeded available questions
            IF question_index >= total_questions THEN
                EXIT;
            END IF;
            
            -- Get answers using the enhanced extraction function
            answer_a := extract_questionnaire_answer(user_a_responses, question_index);
            answer_b := extract_questionnaire_answer(user_b_responses, question_index);
            
            -- Calculate divergence (0-4)
            divergence := ABS(answer_a - answer_b);
            
            -- Calculate raw question compatibility score (0-4, where 4 is highest)
            question_score := 4 - divergence;
            
            -- Add to group total
            group_total := group_total + question_score;
        END LOOP;
        
        -- Calculate group average (0-4)
        group_avg := group_total::FLOAT / questions_per_group;
        
        -- Normalize to percentage (0-100)
        group_norm := (group_avg / 4.0) * 100.0;
        
        -- Store group score
        group_scores := group_scores || jsonb_build_object('group_' || group_num, group_norm);
        
        -- Add to overall total
        overall_score := overall_score + group_norm;
    END LOOP;
    
    -- Calculate overall normalized score (average of all groups)
    overall_score := overall_score / total_groups;
    
    -- Determine letter grade
    IF overall_score >= 90 THEN
        grade := 'A';
    ELSIF overall_score >= 80 THEN
        grade := 'B';
    ELSIF overall_score >= 70 THEN
        grade := 'C';
    ELSIF overall_score >= 60 THEN
        grade := 'D';
    ELSE
        grade := 'F';
    END IF;
    
    RETURN jsonb_build_object(
        'overall_score', ROUND(overall_score),
        'grade', grade,
        'group_scores', group_scores,
        'questions_processed', total_questions,
        'groups_used', total_groups
    );
END;
$$;

-- Grant permissions for the new function
GRANT EXECUTE ON FUNCTION extract_questionnaire_answer(JSONB, INT) TO authenticated;

-- Add comments
COMMENT ON FUNCTION extract_questionnaire_answer(JSONB, INT) IS 
'Extracts numeric answer value from questionnaire responses, handling multiple data formats including objects and text responses.';

COMMENT ON FUNCTION calculate_questionnaire_compatibility(JSONB, JSONB) IS 
'Enhanced questionnaire compatibility calculation that handles various response data formats and adapts to different questionnaire lengths.';