-- ROBUST AUDIT LOG TAXONOMY FIX
-- Unifies operation_type values across audit logs and triggers
-- 1) Drops brittle CHECK
-- 2) Introduces enum audit_operation_type with canonical values
-- 3) Migrates existing rows to canonical values
-- 4) Updates trigger function to emit canonical values

-- 1) Drop existing CHECK constraint if present
DO $$
DECLARE
  v_constraint_name text;
BEGIN
  SELECT tc.constraint_name INTO v_constraint_name
  FROM information_schema.table_constraints tc
  WHERE tc.table_schema = 'public'
    AND tc.table_name = 'audit_logs'
    AND tc.constraint_type = 'CHECK'
    AND tc.constraint_name ILIKE '%operation_type%';

  IF v_constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.audit_logs DROP CONSTRAINT %I', v_constraint_name);
  END IF;
END $$;

-- 2) Create enum with canonical values
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'audit_operation_type' AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.audit_operation_type AS ENUM (
      'match_request_created','match_request_updated','match_request_deleted',
      'match_created','match_updated','match_deleted',
      'conversation_created','conversation_updated','conversation_deleted',
      'message_sent','message_deleted','message_created',
      'swipe_recorded','swipe_created','swipe_deleted',
      'profile_updated',
      'auth_login','auth_logout',
      'subscription_changed',
      'error_occurred',
      'audit_cleanup',
      'profile_view'
    );
  END IF;
END $$;

-- 3) Migrate existing rows to canonical values before type change
-- Map plural table-derived values to canonical forms
-- Only run if column is TEXT type (not already enum)
DO $$
BEGIN
  IF (SELECT data_type FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'audit_logs'
      AND column_name = 'operation_type') IN ('text', 'character varying') THEN

    UPDATE public.audit_logs SET operation_type = 'match_request_created' WHERE operation_type IN ('match_requests_created');
    UPDATE public.audit_logs SET operation_type = 'match_request_updated' WHERE operation_type IN ('match_requests_updated');
    UPDATE public.audit_logs SET operation_type = 'match_request_deleted' WHERE operation_type IN ('match_requests_deleted');

    UPDATE public.audit_logs SET operation_type = 'match_created' WHERE operation_type IN ('matches_created');
    UPDATE public.audit_logs SET operation_type = 'match_updated' WHERE operation_type IN ('matches_updated');
    UPDATE public.audit_logs SET operation_type = 'match_deleted' WHERE operation_type IN ('matches_deleted');

    UPDATE public.audit_logs SET operation_type = 'conversation_created' WHERE operation_type IN ('conversations_created');
    UPDATE public.audit_logs SET operation_type = 'conversation_updated' WHERE operation_type IN ('conversations_updated');
    UPDATE public.audit_logs SET operation_type = 'conversation_deleted' WHERE operation_type IN ('conversations_deleted');

    UPDATE public.audit_logs SET operation_type = 'message_sent' WHERE operation_type IN ('messages_created','message_create','message_inserted');
    UPDATE public.audit_logs SET operation_type = 'message_deleted' WHERE operation_type IN ('messages_deleted');

    UPDATE public.audit_logs SET operation_type = 'swipe_recorded' WHERE operation_type IN ('swipes_created','swipe_created');
    UPDATE public.audit_logs SET operation_type = 'swipe_deleted' WHERE operation_type IN ('swipes_deleted');
  ELSE
    RAISE NOTICE 'audit_logs.operation_type is already an enum, skipping data migration';
  END IF;
END $$;

-- 3b) Alter column to enum type
ALTER TABLE public.audit_logs
  ALTER COLUMN operation_type TYPE public.audit_operation_type
  USING 
    CASE 
      WHEN operation_type = 'match_request_created' THEN 'match_request_created'::public.audit_operation_type
      WHEN operation_type = 'match_request_updated' THEN 'match_request_updated'::public.audit_operation_type
      WHEN operation_type = 'match_request_deleted' THEN 'match_request_deleted'::public.audit_operation_type
      WHEN operation_type = 'match_created' THEN 'match_created'::public.audit_operation_type
      WHEN operation_type = 'match_updated' THEN 'match_updated'::public.audit_operation_type
      WHEN operation_type = 'match_deleted' THEN 'match_deleted'::public.audit_operation_type
      WHEN operation_type = 'conversation_created' THEN 'conversation_created'::public.audit_operation_type
      WHEN operation_type = 'conversation_updated' THEN 'conversation_updated'::public.audit_operation_type
      WHEN operation_type = 'conversation_deleted' THEN 'conversation_deleted'::public.audit_operation_type
      WHEN operation_type = 'message_sent' THEN 'message_sent'::public.audit_operation_type
      WHEN operation_type = 'message_deleted' THEN 'message_deleted'::public.audit_operation_type
      WHEN operation_type = 'message_created' THEN 'message_created'::public.audit_operation_type
      WHEN operation_type = 'swipe_recorded' THEN 'swipe_recorded'::public.audit_operation_type
      WHEN operation_type = 'swipe_created' THEN 'swipe_created'::public.audit_operation_type
      WHEN operation_type = 'swipe_deleted' THEN 'swipe_deleted'::public.audit_operation_type
      WHEN operation_type = 'profile_updated' THEN 'profile_updated'::public.audit_operation_type
      WHEN operation_type = 'auth_login' THEN 'auth_login'::public.audit_operation_type
      WHEN operation_type = 'auth_logout' THEN 'auth_logout'::public.audit_operation_type
      WHEN operation_type = 'subscription_changed' THEN 'subscription_changed'::public.audit_operation_type
      WHEN operation_type = 'error_occurred' THEN 'error_occurred'::public.audit_operation_type
      WHEN operation_type = 'audit_cleanup' THEN 'audit_cleanup'::public.audit_operation_type
      WHEN operation_type = 'profile_view' THEN 'profile_view'::public.audit_operation_type
      ELSE 'error_occurred'::public.audit_operation_type
    END;

-- 4) Update audit trigger function to use canonical mapping
CREATE OR REPLACE FUNCTION public.audit_trigger_function()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID;
    v_operation_type public.audit_operation_type;
    v_old_data JSONB;
    v_new_data JSONB;
    v_base TEXT;
BEGIN
    v_user_id := COALESCE(auth.uid(), (current_setting('app.current_user_id', true))::UUID);

    -- Canonical base mapping
    v_base := CASE TG_TABLE_NAME
        WHEN 'match_requests' THEN 'match_request'
        WHEN 'matches' THEN 'match'
        WHEN 'conversations' THEN 'conversation'
        WHEN 'messages' THEN 'message'
        WHEN 'swipes' THEN 'swipe'
        ELSE TG_TABLE_NAME
    END;

    -- Determine operation type with domain-specific overrides
    IF TG_TABLE_NAME = 'messages' AND TG_OP = 'INSERT' THEN
      v_operation_type := 'message_sent';
    ELSIF TG_TABLE_NAME = 'swipes' AND TG_OP = 'INSERT' THEN
      v_operation_type := 'swipe_recorded';
    ELSE
      v_operation_type := (
        CASE TG_OP
          WHEN 'INSERT' THEN (v_base || '_created')::public.audit_operation_type
          WHEN 'UPDATE' THEN (v_base || '_updated')::public.audit_operation_type
          WHEN 'DELETE' THEN (v_base || '_deleted')::public.audit_operation_type
        END
      );
    END IF;

    -- Data snapshots
    CASE TG_OP
      WHEN 'INSERT' THEN v_new_data := to_jsonb(NEW); v_old_data := NULL;
      WHEN 'UPDATE' THEN v_new_data := to_jsonb(NEW); v_old_data := to_jsonb(OLD);
      WHEN 'DELETE' THEN v_new_data := NULL; v_old_data := to_jsonb(OLD);
    END CASE;

    INSERT INTO public.audit_logs (
        user_id,
        operation_type,
        table_name,
        record_id,
        old_data,
        new_data,
        context
    ) VALUES (
        v_user_id,
        v_operation_type,
        TG_TABLE_NAME,
        COALESCE(NEW.id, OLD.id),
        v_old_data,
        v_new_data,
        jsonb_build_object(
            'trigger_op', TG_OP,
            'trigger_name', TG_NAME,
            'schema_name', TG_TABLE_SCHEMA
        )
    );

    IF TG_OP = 'DELETE' THEN
      RETURN OLD; 
    ELSE 
      RETURN NEW; 
    END IF;
END;
$$;
