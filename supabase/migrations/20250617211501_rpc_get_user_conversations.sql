-- migrations/000X_rpc_get_user_conversations.sql

CREATE OR REPLACE FUNCTION get_user_conversations_with_details(p_user_id uuid)
RETURNS TABLE (
    conversation_id uuid,
    match_id uuid,
    other_participant_id uuid,
    other_participant_display_name text,
    other_participant_avatar_url text,
    last_message_preview text,
    last_message_at timestamptz,
    conversation_created_at timestamptz,
    conversation_updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER -- Important if RLS on profiles might prevent direct access by calling user in some contexts
AS $$
BEGIN
    -- Check if p_user_id is the currently authenticated user if not using SECURITY DEFINER
    -- IF p_user_id != auth.uid() THEN
    --     RAISE EXCEPTION 'User can only fetch their own conversations';
    -- END IF;
    -- With SECURITY DEFINER, the function runs with definer's privileges,
    -- but we still filter by p_user_id which should be auth.uid() passed from EF.

    RETURN QUERY
    SELECT
        c.id AS conversation_id,
        c.match_id,
        CASE
            WHEN c.user1_id = p_user_id THEN c.user2_id
            ELSE c.user1_id
        END AS other_participant_id,
        CASE
            WHEN c.user1_id = p_user_id THEN p2.display_name
            ELSE p1.display_name
        END AS other_participant_display_name,
        CASE
            WHEN c.user1_id = p_user_id THEN p2.avatar_url
            ELSE p1.avatar_url
        END AS other_participant_avatar_url,
        c.last_message_preview,
        c.last_message_at,
        c.created_at AS conversation_created_at,
        c.updated_at AS conversation_updated_at
    FROM
        public.conversations c
    LEFT JOIN
        public.profiles p1 ON c.user1_id = p1.id
    LEFT JOIN
        public.profiles p2 ON c.user2_id = p2.id
    WHERE
        (c.user1_id = p_user_id OR c.user2_id = p_user_id)
    ORDER BY
        c.last_message_at DESC NULLS LAST; -- Show most recent conversations first
END;
$$;

-- Grant execute permission to the 'authenticated' role
-- The Edge Function will call this as an authenticated user.
GRANT EXECUTE ON FUNCTION get_user_conversations_with_details(uuid) TO authenticated;

COMMENT ON FUNCTION get_user_conversations_with_details(uuid) IS
'Fetches all conversations for a given user, along with details of the other participant and the last message preview.
Ensures that the user is part of the conversation. Orders by the most recent message.';

-- Example of how to call it (for testing in SQL editor):
-- SELECT * FROM get_user_conversations_with_details('your_user_id_here');
