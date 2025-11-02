-- Create a function to clear user onboarding data
CREATE OR REPLACE FUNCTION clear_user_onboarding_data(user_email TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER -- This allows the function to bypass RLS
AS $$
DECLARE
    target_user_id uuid;
    result_message TEXT;
BEGIN
    -- Find the user ID by email
    SELECT id INTO target_user_id 
    FROM auth.users 
    WHERE email = user_email;
    
    -- Check if user exists
    IF target_user_id IS NULL THEN
        RETURN 'User not found with email: ' || user_email;
    END IF;
    
    -- Clear profiles table data
    UPDATE profiles 
    SET 
        onboarding_completed = false,
        education_level = null,
        politics = null,
        is_single = null,
        has_kids = null,
        wants_kids = null,
        traits = null,
        interests = null,
        avatar_url = null,
        age = null,
        gender = null
    WHERE id = target_user_id;
    
    -- Clear users table data  
    UPDATE users
    SET 
        birth_date = null,
        birth_location = null,
        birth_time = null,
        questionnaire_responses = null
    WHERE id = target_user_id;
    
    result_message := 'Successfully cleared onboarding data for user: ' || user_email || ' (ID: ' || target_user_id || ')';
    
    RETURN result_message;
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'Error clearing onboarding data: ' || SQLERRM;
END;
$$;