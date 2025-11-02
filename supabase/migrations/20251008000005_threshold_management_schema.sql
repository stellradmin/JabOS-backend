-- =============================================================================
-- STELLR THRESHOLD MANAGEMENT - COMPLETE IMPLEMENTATION
-- =============================================================================
-- This migration creates the complete threshold management system including:
-- - Threshold change history with audit logging
-- - RPC functions for updating thresholds with validation
-- - Alert testing functionality
-- - Enhanced permissions for threshold management
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. THRESHOLD HISTORY TABLE
-- -----------------------------------------------------------------------------
-- Audit log for all threshold changes

CREATE TABLE IF NOT EXISTS public.threshold_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  metric_name TEXT NOT NULL,
  field_changed TEXT NOT NULL, -- 'warning_threshold', 'critical_threshold', 'metadata'
  old_value JSONB NOT NULL,
  new_value JSONB NOT NULL,
  changed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  change_reason TEXT,
  admin_email TEXT,
  admin_role TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.threshold_history IS 'Audit log of all threshold configuration changes';
COMMENT ON COLUMN public.threshold_history.field_changed IS 'Which threshold field was modified';
COMMENT ON COLUMN public.threshold_history.change_reason IS 'Reason provided by admin for the change';

CREATE INDEX threshold_history_metric_idx ON public.threshold_history (metric_name, created_at DESC);
CREATE INDEX threshold_history_user_idx ON public.threshold_history (changed_by, created_at DESC);

-- -----------------------------------------------------------------------------
-- 2. RPC FUNCTION: Update Threshold with Audit
-- -----------------------------------------------------------------------------
-- Updates a threshold value and logs the change

CREATE OR REPLACE FUNCTION public.update_threshold_with_audit(
  p_metric_name TEXT,
  p_warning_threshold NUMERIC DEFAULT NULL,
  p_critical_threshold NUMERIC DEFAULT NULL,
  p_metadata JSONB DEFAULT NULL,
  p_change_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_current_threshold RECORD;
  v_admin_record RECORD;
  v_result JSONB;
BEGIN
  -- Check if user is authorized (must be active dashboard admin)
  IF NOT public.is_active_dashboard_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Unauthorized: Only dashboard admins can update thresholds';
  END IF;

  -- Get admin info for audit log
  SELECT da.email, da.role::TEXT
  INTO v_admin_record
  FROM public.dashboard_admins da
  WHERE da.auth_user_id = auth.uid() AND da.active = true;

  -- Get current threshold values
  SELECT * INTO v_current_threshold
  FROM public.dashboard_thresholds
  WHERE metric_name = p_metric_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Threshold not found for metric: %', p_metric_name;
  END IF;

  -- Validate: warning_threshold should be less than critical_threshold
  IF p_warning_threshold IS NOT NULL AND p_critical_threshold IS NOT NULL THEN
    IF p_warning_threshold >= p_critical_threshold THEN
      RAISE EXCEPTION 'Warning threshold must be less than critical threshold';
    END IF;
  END IF;

  -- Log warning_threshold change
  IF p_warning_threshold IS NOT NULL AND p_warning_threshold != COALESCE(v_current_threshold.warning_threshold, -999) THEN
    INSERT INTO public.threshold_history (
      metric_name,
      field_changed,
      old_value,
      new_value,
      changed_by,
      change_reason,
      admin_email,
      admin_role
    ) VALUES (
      p_metric_name,
      'warning_threshold',
      jsonb_build_object('value', v_current_threshold.warning_threshold),
      jsonb_build_object('value', p_warning_threshold),
      auth.uid(),
      p_change_reason,
      v_admin_record.email,
      v_admin_record.role
    );
  END IF;

  -- Log critical_threshold change
  IF p_critical_threshold IS NOT NULL AND p_critical_threshold != COALESCE(v_current_threshold.critical_threshold, -999) THEN
    INSERT INTO public.threshold_history (
      metric_name,
      field_changed,
      old_value,
      new_value,
      changed_by,
      change_reason,
      admin_email,
      admin_role
    ) VALUES (
      p_metric_name,
      'critical_threshold',
      jsonb_build_object('value', v_current_threshold.critical_threshold),
      jsonb_build_object('value', p_critical_threshold),
      auth.uid(),
      p_change_reason,
      v_admin_record.email,
      v_admin_record.role
    );
  END IF;

  -- Log metadata change
  IF p_metadata IS NOT NULL AND p_metadata != COALESCE(v_current_threshold.metadata, '{}'::jsonb) THEN
    INSERT INTO public.threshold_history (
      metric_name,
      field_changed,
      old_value,
      new_value,
      changed_by,
      change_reason,
      admin_email,
      admin_role
    ) VALUES (
      p_metric_name,
      'metadata',
      v_current_threshold.metadata,
      p_metadata,
      auth.uid(),
      p_change_reason,
      v_admin_record.email,
      v_admin_record.role
    );
  END IF;

  -- Update the threshold
  UPDATE public.dashboard_thresholds
  SET
    warning_threshold = COALESCE(p_warning_threshold, warning_threshold),
    critical_threshold = COALESCE(p_critical_threshold, critical_threshold),
    metadata = COALESCE(p_metadata, metadata),
    updated_at = NOW()
  WHERE metric_name = p_metric_name;

  -- Return updated threshold
  SELECT jsonb_build_object(
    'success', true,
    'metric_name', metric_name,
    'warning_threshold', warning_threshold,
    'critical_threshold', critical_threshold,
    'metadata', metadata,
    'updated_at', updated_at
  ) INTO v_result
  FROM public.dashboard_thresholds
  WHERE metric_name = p_metric_name;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.update_threshold_with_audit IS 'Updates threshold values with validation and audit logging';

GRANT EXECUTE ON FUNCTION public.update_threshold_with_audit TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. RPC FUNCTION: Get Threshold History
-- -----------------------------------------------------------------------------
-- Returns change history for a specific metric or all metrics

CREATE OR REPLACE FUNCTION public.get_threshold_history(
  p_metric_name TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_result JSONB;
BEGIN
  -- Check if user is authorized
  IF NOT public.is_active_dashboard_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Unauthorized: Only dashboard admins can view threshold history';
  END IF;

  -- Get history
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', th.id,
      'metricName', th.metric_name,
      'fieldChanged', th.field_changed,
      'oldValue', th.old_value,
      'newValue', th.new_value,
      'changedBy', th.admin_email,
      'role', th.admin_role,
      'changeReason', th.change_reason,
      'createdAt', th.created_at
    ) ORDER BY th.created_at DESC
  ) INTO v_result
  FROM public.threshold_history th
  WHERE (p_metric_name IS NULL OR th.metric_name = p_metric_name)
  LIMIT p_limit;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_threshold_history TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. RPC FUNCTION: Test Alert Threshold
-- -----------------------------------------------------------------------------
-- Simulates an alert without actually sending it (for testing)

CREATE OR REPLACE FUNCTION public.test_alert_threshold(
  p_metric_name TEXT,
  p_test_value NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_threshold RECORD;
  v_direction TEXT;
  v_result JSONB;
  v_alert_level TEXT := 'none';
BEGIN
  -- Check if user is authorized
  IF NOT public.is_active_dashboard_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Unauthorized: Only dashboard admins can test alerts';
  END IF;

  -- Get threshold configuration
  SELECT * INTO v_threshold
  FROM public.dashboard_thresholds
  WHERE metric_name = p_metric_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Threshold not found for metric: %', p_metric_name;
  END IF;

  -- Get direction from metadata (default 'above')
  v_direction := COALESCE(v_threshold.metadata->>'direction', 'above');

  -- Determine alert level based on test value
  IF v_direction = 'above' THEN
    IF p_test_value >= v_threshold.critical_threshold THEN
      v_alert_level := 'critical';
    ELSIF p_test_value >= v_threshold.warning_threshold THEN
      v_alert_level := 'warning';
    END IF;
  ELSE -- 'below'
    IF p_test_value <= v_threshold.critical_threshold THEN
      v_alert_level := 'critical';
    ELSIF p_test_value <= v_threshold.warning_threshold THEN
      v_alert_level := 'warning';
    END IF;
  END IF;

  -- Build result
  v_result := jsonb_build_object(
    'success', true,
    'metricName', p_metric_name,
    'testValue', p_test_value,
    'warningThreshold', v_threshold.warning_threshold,
    'criticalThreshold', v_threshold.critical_threshold,
    'direction', v_direction,
    'alertLevel', v_alert_level,
    'wouldTriggerAlert', v_alert_level != 'none',
    'message', CASE
      WHEN v_alert_level = 'critical' THEN
        format('🚨 CRITICAL: %s at %s (threshold: %s)', p_metric_name, p_test_value, v_threshold.critical_threshold)
      WHEN v_alert_level = 'warning' THEN
        format('⚠️ WARNING: %s at %s (threshold: %s)', p_metric_name, p_test_value, v_threshold.warning_threshold)
      ELSE
        format('✅ OK: %s at %s (within normal range)', p_metric_name, p_test_value)
    END
  );

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.test_alert_threshold TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. RPC FUNCTION: Get All Thresholds with Metadata
-- -----------------------------------------------------------------------------
-- Returns all thresholds formatted for the UI

CREATE OR REPLACE FUNCTION public.get_all_thresholds()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  -- Check if user is authorized
  IF NOT public.is_active_dashboard_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Unauthorized: Only dashboard admins can view thresholds';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'metricName', dt.metric_name,
      'warningThreshold', dt.warning_threshold,
      'criticalThreshold', dt.critical_threshold,
      'metadata', dt.metadata,
      'updatedAt', dt.updated_at,
      'direction', COALESCE(dt.metadata->>'direction', 'above'),
      'unit', COALESCE(dt.metadata->>'unit', ''),
      'description', COALESCE(dt.metadata->>'description', '')
    ) ORDER BY dt.metric_name
  ) INTO v_result
  FROM public.dashboard_thresholds dt;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_all_thresholds TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. RLS POLICIES
-- -----------------------------------------------------------------------------

ALTER TABLE public.threshold_history ENABLE ROW LEVEL SECURITY;

-- Dashboard admins can read threshold history
CREATE POLICY threshold_history_admin_read ON public.threshold_history
  FOR SELECT
  USING (
    auth.uid() IS NOT NULL
    AND public.is_active_dashboard_admin(auth.uid())
  );

GRANT SELECT ON TABLE public.threshold_history TO authenticated;

-- Update existing dashboard_thresholds policies to allow updates
CREATE POLICY dashboard_thresholds_admin_update ON public.dashboard_thresholds
  FOR UPDATE
  USING (
    auth.uid() IS NOT NULL
    AND public.is_active_dashboard_admin(auth.uid())
  );

GRANT UPDATE ON TABLE public.dashboard_thresholds TO authenticated;

-- =============================================================================
-- VERIFICATION QUERIES
-- =============================================================================
-- Run these to verify the migration worked:
--
-- 1. Test updating a threshold:
-- SELECT public.update_threshold_with_audit(
--   'active_users',
--   900,  -- new warning threshold
--   1300, -- new critical threshold
--   jsonb_build_object('direction', 'above', 'description', 'Updated for testing'),
--   'Testing threshold update system'
-- );
--
-- 2. View threshold history:
-- SELECT public.get_threshold_history();
--
-- 3. Test an alert:
-- SELECT public.test_alert_threshold('active_users', 950);
--
-- 4. Get all thresholds:
-- SELECT public.get_all_thresholds();
-- =============================================================================
