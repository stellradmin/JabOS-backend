-- Fix Churn Rescue System Schema Bugs
-- Align database schema with TypeScript implementation

-- =============================================================================
-- FIX 1: Change risk_score from NUMERIC(4,3) [0-1] to INTEGER [0-100]
-- =============================================================================
-- The TypeScript implementation calculates 0-100 integer scores which is more
-- intuitive than 0-1 decimals. Update the schema to match.

ALTER TABLE public.member_risk_scores
  DROP CONSTRAINT IF EXISTS member_risk_scores_risk_score_check;

ALTER TABLE public.member_risk_scores
  ALTER COLUMN risk_score TYPE INTEGER USING (risk_score * 100)::INTEGER;

ALTER TABLE public.member_risk_scores
  ADD CONSTRAINT member_risk_scores_risk_score_check
  CHECK (risk_score >= 0 AND risk_score <= 100);

-- Update comment to reflect new range
COMMENT ON COLUMN public.member_risk_scores.risk_score IS
  'Churn risk score from 0 (no risk) to 100 (maximum risk)';

-- =============================================================================
-- FIX 2: Add missing columns used by TypeScript implementation
-- =============================================================================

-- Add attendance_drop_rate (percentage drop in attendance)
ALTER TABLE public.member_risk_scores
  ADD COLUMN IF NOT EXISTS attendance_drop_rate NUMERIC(5,2);

COMMENT ON COLUMN public.member_risk_scores.attendance_drop_rate IS
  'Percentage drop in attendance comparing last 30 days vs previous 30 days';

-- Add engagement_score (overall engagement metric 0-100)
ALTER TABLE public.member_risk_scores
  ADD COLUMN IF NOT EXISTS engagement_score INTEGER CHECK (engagement_score >= 0 AND engagement_score <= 100);

COMMENT ON COLUMN public.member_risk_scores.engagement_score IS
  'Overall member engagement score from 0 (no engagement) to 100 (highly engaged)';

-- Add next_expected_visit (prediction of when member will return)
ALTER TABLE public.member_risk_scores
  ADD COLUMN IF NOT EXISTS next_expected_visit TIMESTAMPTZ;

COMMENT ON COLUMN public.member_risk_scores.next_expected_visit IS
  'Predicted date/time of member''s next visit based on historical patterns';

-- Rename calculated_date to calculated_at for consistency with created_at pattern
-- Note: We keep calculated_date as primary key component, but add calculated_at for timestamp
ALTER TABLE public.member_risk_scores
  ADD COLUMN IF NOT EXISTS calculated_at TIMESTAMPTZ DEFAULT NOW();

COMMENT ON COLUMN public.member_risk_scores.calculated_at IS
  'Exact timestamp when risk score was calculated';

-- Add notes column for manual override explanations
ALTER TABLE public.member_risk_scores
  ADD COLUMN IF NOT EXISTS notes TEXT;

COMMENT ON COLUMN public.member_risk_scores.notes IS
  'Optional notes, e.g., when coach manually marks member as safe';

-- =============================================================================
-- FIX 3: Add missing columns to churn_interventions
-- =============================================================================

-- Add message column (used by TypeScript but not in schema)
ALTER TABLE public.churn_interventions
  ADD COLUMN IF NOT EXISTS message TEXT;

COMMENT ON COLUMN public.churn_interventions.message IS
  'The intervention message content sent to the member';

-- Add scheduled_for column (used by TypeScript but not in schema)
ALTER TABLE public.churn_interventions
  ADD COLUMN IF NOT EXISTS scheduled_for TIMESTAMPTZ;

COMMENT ON COLUMN public.churn_interventions.scheduled_for IS
  'Scheduled delivery time for the intervention';

-- Add triggered_by column (used by TypeScript but not in schema)
ALTER TABLE public.churn_interventions
  ADD COLUMN IF NOT EXISTS triggered_by UUID REFERENCES public.users(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.churn_interventions.triggered_by IS
  'User who triggered this intervention (coach/owner)';

-- =============================================================================
-- FIX 4: Add missing columns to nudge_queue
-- =============================================================================

-- Add nudge_type column (used by TypeScript but not in schema)
ALTER TABLE public.nudge_queue
  ADD COLUMN IF NOT EXISTS nudge_type TEXT CHECK (nudge_type IN ('email', 'sms', 'in_app', 'call'));

COMMENT ON COLUMN public.nudge_queue.nudge_type IS
  'Type of nudge being sent (email, sms, in_app notification, or phone call)';

-- Add scheduled_send_at column (used by TypeScript instead of scheduled_for)
ALTER TABLE public.nudge_queue
  ADD COLUMN IF NOT EXISTS scheduled_send_at TIMESTAMPTZ;

COMMENT ON COLUMN public.nudge_queue.scheduled_send_at IS
  'When the nudge should be sent (alternative to scheduled_for for clarity)';

-- Add days_since_last_activity column (renamed from days_since_last_visit for clarity)
ALTER TABLE public.member_risk_scores
  RENAME COLUMN days_since_last_visit TO days_since_last_activity;

-- Update index to use new column name
DROP INDEX IF EXISTS public.idx_risk_scores_days_since_visit;
CREATE INDEX IF NOT EXISTS idx_risk_scores_days_since_activity
  ON public.member_risk_scores(organization_id, days_since_last_activity DESC)
  WHERE days_since_last_activity > 7;

-- =============================================================================
-- MIGRATION SUMMARY
-- =============================================================================
-- This migration fixes the schema-code mismatch identified in the audit:
--
-- 1. Changed risk_score from NUMERIC(4,3) [0-1] to INTEGER [0-100]
--    - More intuitive scoring system
--    - Matches TypeScript implementation
--
-- 2. Added missing columns to member_risk_scores:
--    - attendance_drop_rate (NUMERIC)
--    - engagement_score (INTEGER 0-100)
--    - next_expected_visit (TIMESTAMPTZ)
--    - calculated_at (TIMESTAMPTZ)
--    - notes (TEXT)
--
-- 3. Added missing columns to churn_interventions:
--    - message (TEXT)
--    - scheduled_for (TIMESTAMPTZ)
--    - triggered_by (UUID FK)
--
-- 4. Added missing columns to nudge_queue:
--    - nudge_type (TEXT)
--    - scheduled_send_at (TIMESTAMPTZ)
--
-- 5. Renamed days_since_last_visit → days_since_last_activity
--
-- After this migration, TypeScript code only needs to:
-- - Change risk_level → risk_band (column name fix)
-- - Change message_content → message_body (column name fix)
-- - Remove all 'as any' type casts
