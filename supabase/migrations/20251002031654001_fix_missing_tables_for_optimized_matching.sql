-- Fix Missing Tables for Optimized Matching Edge Function
-- This migration creates the missing tables that the get_potential_matches_optimized SQL function references

BEGIN;

-- ============================================================================
-- 1. CREATE BLOCKS TABLE
-- ============================================================================
-- Allows users to block other users from appearing in their match discovery
CREATE TABLE IF NOT EXISTS public.blocks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  blocker_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  blocked_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  blocked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT blocks_no_self_block CHECK (blocker_id <> blocked_id),
  CONSTRAINT blocks_unique_pair UNIQUE(blocker_id, blocked_id)
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_blocks_blocker ON public.blocks(blocker_id);
CREATE INDEX IF NOT EXISTS idx_blocks_blocked ON public.blocks(blocked_id);
CREATE INDEX IF NOT EXISTS idx_blocks_created ON public.blocks(created_at DESC);

-- RLS Policies for blocks table
ALTER TABLE public.blocks ENABLE ROW LEVEL SECURITY;

-- Users can view their own blocks (who they blocked)
CREATE POLICY "Users can view their own blocks"
  ON public.blocks
  FOR SELECT
  USING (auth.uid() = blocker_id);

-- Users can create blocks
CREATE POLICY "Users can create blocks"
  ON public.blocks
  FOR INSERT
  WITH CHECK (auth.uid() = blocker_id);

-- Users can delete their own blocks (unblock)
CREATE POLICY "Users can delete their own blocks"
  ON public.blocks
  FOR DELETE
  USING (auth.uid() = blocker_id);

-- Service role has full access
CREATE POLICY "Service role has full access to blocks"
  ON public.blocks
  FOR ALL
  USING (auth.jwt()->>'role' = 'service_role');

COMMENT ON TABLE public.blocks IS 'User blocking system - prevents blocked users from appearing in match discovery';
COMMENT ON COLUMN public.blocks.blocker_id IS 'User who initiated the block';
COMMENT ON COLUMN public.blocks.blocked_id IS 'User who was blocked';
COMMENT ON COLUMN public.blocks.reason IS 'Optional reason for blocking (e.g., inappropriate behavior, spam)';

-- ============================================================================
-- 2. CREATE COMPATIBILITY_SCORES TABLE
-- ============================================================================
-- Stores calculated compatibility scores between users for faster matching
CREATE TABLE IF NOT EXISTS public.compatibility_scores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user1_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  user2_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  compatibility_score INTEGER NOT NULL DEFAULT 50 CHECK (compatibility_score >= 0 AND compatibility_score <= 100),
  astrological_score NUMERIC CHECK (astrological_score IS NULL OR (astrological_score >= 0 AND astrological_score <= 100)),
  questionnaire_score NUMERIC CHECK (questionnaire_score IS NULL OR (questionnaire_score >= 0 AND questionnaire_score <= 100)),
  calculation_metadata JSONB DEFAULT '{}'::jsonb,
  calculated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT compatibility_no_self_score CHECK (user1_id <> user2_id),
  CONSTRAINT compatibility_unique_pair UNIQUE(user1_id, user2_id)
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_compatibility_user1 ON public.compatibility_scores(user1_id);
CREATE INDEX IF NOT EXISTS idx_compatibility_user2 ON public.compatibility_scores(user2_id);
CREATE INDEX IF NOT EXISTS idx_compatibility_calculated ON public.compatibility_scores(calculated_at DESC);
CREATE INDEX IF NOT EXISTS idx_compatibility_score ON public.compatibility_scores(compatibility_score DESC);
CREATE INDEX IF NOT EXISTS idx_compatibility_expires ON public.compatibility_scores(expires_at) WHERE expires_at IS NOT NULL;

-- Composite index for efficient lookups
CREATE INDEX IF NOT EXISTS idx_compatibility_pair_lookup ON public.compatibility_scores(user1_id, user2_id);

-- RLS Policies for compatibility_scores table
ALTER TABLE public.compatibility_scores ENABLE ROW LEVEL SECURITY;

-- Users can view their own compatibility scores
CREATE POLICY "Users can view their own compatibility scores"
  ON public.compatibility_scores
  FOR SELECT
  USING (auth.uid() = user1_id OR auth.uid() = user2_id);

-- Service role can manage all compatibility scores
CREATE POLICY "Service role has full access to compatibility scores"
  ON public.compatibility_scores
  FOR ALL
  USING (auth.jwt()->>'role' = 'service_role');

-- Background jobs can insert/update compatibility scores
CREATE POLICY "Authenticated users can insert compatibility scores"
  ON public.compatibility_scores
  FOR INSERT
  WITH CHECK (auth.uid() = user1_id OR auth.uid() = user2_id OR auth.jwt()->>'role' = 'service_role');

CREATE POLICY "Authenticated users can update compatibility scores"
  ON public.compatibility_scores
  FOR UPDATE
  USING (auth.uid() = user1_id OR auth.uid() = user2_id OR auth.jwt()->>'role' = 'service_role');

COMMENT ON TABLE public.compatibility_scores IS 'Pre-calculated compatibility scores for efficient matching - includes astrological and questionnaire-based scoring';
COMMENT ON COLUMN public.compatibility_scores.compatibility_score IS 'Overall compatibility score (0-100) combining all algorithms';
COMMENT ON COLUMN public.compatibility_scores.astrological_score IS 'Astrological compatibility score based on natal chart analysis';
COMMENT ON COLUMN public.compatibility_scores.questionnaire_score IS 'Questionnaire-based compatibility score from 25-question algorithm';
COMMENT ON COLUMN public.compatibility_scores.calculation_metadata IS 'Detailed breakdown and metadata from compatibility calculation';
COMMENT ON COLUMN public.compatibility_scores.expires_at IS 'When this score expires and should be recalculated (optional)';

-- ============================================================================
-- 3. CREATE TRIGGER FOR UPDATED_AT
-- ============================================================================
-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION update_compatibility_scores_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_compatibility_scores_updated_at
  BEFORE UPDATE ON public.compatibility_scores
  FOR EACH ROW
  EXECUTE FUNCTION update_compatibility_scores_updated_at();

-- ============================================================================
-- 4. GRANT PERMISSIONS
-- ============================================================================
-- Grant appropriate permissions
GRANT SELECT ON public.blocks TO authenticated;
GRANT INSERT, DELETE ON public.blocks TO authenticated;
GRANT ALL ON public.blocks TO service_role;

GRANT SELECT ON public.compatibility_scores TO authenticated;
GRANT INSERT, UPDATE ON public.compatibility_scores TO authenticated;
GRANT ALL ON public.compatibility_scores TO service_role;

COMMIT;
