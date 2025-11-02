-- Configure Auth Schema Email Triggers for Resend Integration
-- This migration creates triggers on auth.users for automatic transactional emails
-- Functions are in public schema due to auth schema restrictions

-- Function: Handle new user signup (send verification email)
CREATE OR REPLACE FUNCTION public.handle_user_signup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
    user_name text;
BEGIN
    user_name := COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_user_meta_data ->> 'name');

    -- Only enqueue if function exists
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'enqueue_transactional_email') THEN
        PERFORM public.enqueue_transactional_email(
            'email_verification',
            NEW.id,
            NEW.email,
            jsonb_build_object('name', user_name)
        );
    END IF;

    RETURN NEW;
END;
$$;

-- Function: Handle email verification (send welcome email)
CREATE OR REPLACE FUNCTION public.handle_email_verified()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
    user_name text;
BEGIN
    IF OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL THEN
        user_name := COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_user_meta_data ->> 'name');

        -- Only enqueue if function exists
        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'enqueue_transactional_email') THEN
            PERFORM public.enqueue_transactional_email(
                'welcome',
                NEW.id,
                NEW.email,
                jsonb_build_object('name', user_name)
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- Function: Handle password change (send notification)
CREATE OR REPLACE FUNCTION public.handle_password_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
BEGIN
    IF NEW.encrypted_password IS DISTINCT FROM OLD.encrypted_password THEN
        -- Only enqueue if function exists
        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'enqueue_transactional_email') THEN
            PERFORM public.enqueue_transactional_email(
                'password_changed',
                NEW.id,
                NEW.email,
                jsonb_build_object('name', NEW.raw_user_meta_data ->> 'full_name')
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- Function: Handle account deletion (send confirmation)
CREATE OR REPLACE FUNCTION public.handle_account_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
BEGIN
    -- Only enqueue if function exists
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'enqueue_transactional_email') THEN
        PERFORM public.enqueue_transactional_email(
            'account_deleted',
            OLD.id,
            OLD.email,
            jsonb_build_object('name', OLD.raw_user_meta_data ->> 'full_name')
        );
    END IF;

    RETURN OLD;
END;
$$;

-- Create/Replace Triggers on auth.users
DROP TRIGGER IF EXISTS trg_auth_user_signup ON auth.users;
CREATE TRIGGER trg_auth_user_signup
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_user_signup();

DROP TRIGGER IF EXISTS trg_auth_user_email_verified ON auth.users;
CREATE TRIGGER trg_auth_user_email_verified
AFTER UPDATE ON auth.users
FOR EACH ROW
WHEN (OLD.email_confirmed_at IS DISTINCT FROM NEW.email_confirmed_at)
EXECUTE FUNCTION public.handle_email_verified();

DROP TRIGGER IF EXISTS trg_auth_user_password_change ON auth.users;
CREATE TRIGGER trg_auth_user_password_change
AFTER UPDATE ON auth.users
FOR EACH ROW
WHEN (OLD.encrypted_password IS DISTINCT FROM NEW.encrypted_password)
EXECUTE FUNCTION public.handle_password_change();

DROP TRIGGER IF EXISTS trg_auth_user_delete ON auth.users;
CREATE TRIGGER trg_auth_user_delete
AFTER DELETE ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_account_delete();
