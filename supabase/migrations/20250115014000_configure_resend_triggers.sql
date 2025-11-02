-- Configure Resend transactional email orchestration via Supabase triggers

BEGIN;

CREATE EXTENSION IF NOT EXISTS "http";

CREATE TABLE IF NOT EXISTS public.app_settings (
    key text PRIMARY KEY,
    value text NOT NULL,
    updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Service role manage app settings" ON public.app_settings;
CREATE POLICY "Service role manage app settings"
    ON public.app_settings
    FOR ALL
    USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

INSERT INTO public.app_settings (key, value)
VALUES
    ('functions_base_url', 'https://YOUR-PROJECT.functions.supabase.co'),
    ('edge_service_token', 'SERVICE_ROLE_OR_ANON_JWT')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.get_app_setting(setting_key text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    setting_value text;
BEGIN
    SELECT value INTO setting_value
    FROM public.app_settings
    WHERE key = setting_key;

    RETURN setting_value;
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_transactional_email(
    p_event_type text,
    p_user_id uuid,
    p_email text,
    p_payload jsonb DEFAULT '{}'::jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    base_url text;
    service_token text;
    request_payload jsonb;
BEGIN
    INSERT INTO public.transactional_email_queue (user_id, email, event_type, payload)
    VALUES (p_user_id, p_email, p_event_type, p_payload)
    ON CONFLICT DO NOTHING;

    base_url := public.get_app_setting('functions_base_url');
    IF base_url IS NULL THEN
        RAISE NOTICE 'functions_base_url not configured';
        RETURN;
    END IF;

    request_payload := jsonb_build_object(
        'mode', 'send_event',
        'event', jsonb_build_object(
            'event_type', p_event_type,
            'email', p_email,
            'user_id', p_user_id,
            'payload', p_payload
        )
    );

    service_token := public.get_app_setting('edge_service_token');

    BEGIN
        PERFORM net.http_post(
            url := base_url || '/resend-transactional-dispatcher',
            headers := coalesce(
                jsonb_build_object('Content-Type', 'application/json') ||
                CASE WHEN service_token IS NOT NULL THEN jsonb_build_object('Authorization', 'Bearer ' || service_token) ELSE '{}'::jsonb END,
                jsonb_build_object('Content-Type', 'application/json')
            ),
            body := request_payload::text
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Failed to call Edge function for %: %', p_event_type, SQLERRM;
    END;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_auth_user_signup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    user_name text;
BEGIN
    user_name := COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_user_meta_data ->> 'name');
    PERFORM public.enqueue_transactional_email(
        'email_verification',
        NEW.id,
        NEW.email,
        jsonb_build_object('name', user_name)
    );
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_auth_email_verified()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    user_name text;
BEGIN
    IF OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL THEN
        user_name := COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_user_meta_data ->> 'name');
        PERFORM public.enqueue_transactional_email(
            'welcome',
            NEW.id,
            NEW.email,
            jsonb_build_object('name', user_name)
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_auth_password_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF NEW.encrypted_password IS DISTINCT FROM OLD.encrypted_password THEN
        PERFORM public.enqueue_transactional_email(
            'password_changed',
            NEW.id,
            NEW.email,
            jsonb_build_object('name', NEW.raw_user_meta_data ->> 'full_name')
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_auth_account_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    PERFORM public.enqueue_transactional_email(
        'account_deleted',
        OLD.id,
        OLD.email,
        jsonb_build_object('name', OLD.raw_user_meta_data ->> 'full_name')
    );
    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_auth_user_signup ON auth.users;
CREATE TRIGGER trg_auth_user_signup
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_auth_user_signup();

DROP TRIGGER IF EXISTS trg_auth_user_email_verified ON auth.users;
CREATE TRIGGER trg_auth_user_email_verified
AFTER UPDATE ON auth.users
FOR EACH ROW
WHEN (OLD.email_confirmed_at IS DISTINCT FROM NEW.email_confirmed_at)
EXECUTE FUNCTION public.handle_auth_email_verified();

DROP TRIGGER IF EXISTS trg_auth_user_password_change ON auth.users;
CREATE TRIGGER trg_auth_user_password_change
AFTER UPDATE ON auth.users
FOR EACH ROW
WHEN (OLD.encrypted_password IS DISTINCT FROM NEW.encrypted_password)
EXECUTE FUNCTION public.handle_auth_password_change();

DROP TRIGGER IF EXISTS trg_auth_user_delete ON auth.users;
CREATE TRIGGER trg_auth_user_delete
AFTER DELETE ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_auth_account_delete();

CREATE OR REPLACE FUNCTION public.enqueue_password_reset(p_email text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    auth_user auth.users;
BEGIN
    SELECT * INTO auth_user
    FROM auth.users
    WHERE email = p_email
    LIMIT 1;

    IF auth_user IS NULL THEN
        RAISE EXCEPTION 'User not found for %', p_email USING ERRCODE = 'NO_DATA_FOUND';
    END IF;

    PERFORM public.enqueue_transactional_email(
        'password_reset',
        auth_user.id,
        auth_user.email,
        jsonb_build_object('name', auth_user.raw_user_meta_data ->> 'full_name')
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.enqueue_password_reset(text) TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE ON public.transactional_email_queue TO service_role;

COMMIT;
