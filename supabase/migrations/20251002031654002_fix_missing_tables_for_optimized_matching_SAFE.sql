-- Fix Missing Tables for Optimized Matching Edge Function (SAFE VERSION)
-- This migration creates the missing tables that the get_potential_matches_optimized SQL function references
-- SAFE: Drops existing tables and policies before creating them to avoid conflicts

-- Note: Migration 001 already ran, so we need to handle existing tables
DO $$
BEGIN
  -- Drop compatibility_scores if it exists with old schema (user1_id, user2_id)
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'compatibility_scores'
  ) THEN
    DROP TABLE public.compatibility_scores CASCADE;
  END IF;
END $$;

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

-- Create indexes for blocks table
CREATE INDEX IF NOT EXISTS idx_blocks_blocker ON public.blocks(blocker_id);
CREATE INDEX IF NOT EXISTS idx_blocks_blocked ON public.blocks(blocked_id);
CREATE INDEX IF NOT EXISTS idx_blocks_created ON public.blocks(created_at DESC);

-- RLS Policies for blocks table
ALTER TABLE public.blocks ENABLE ROW LEVEL SECURITY;

-- DROP existing policies first to avoid conflicts
DROP POLICY IF EXISTS "Users can view their own blocks" ON public.blocks;
DROP POLICY IF EXISTS "Users can create blocks" ON public.blocks;
DROP POLICY IF EXISTS "Users can delete their own blocks" ON public.blocks;
DROP POLICY IF EXISTS "Service role has full access to blocks" ON public.blocks;

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

-- Users can delete their own blocks
CREATE POLICY "Users can delete their own blocks"
  ON public.blocks
  FOR DELETE
  USING (auth.uid() = blocker_id);

-- Service role has full access to blocks
CREATE POLICY "Service role has full access to blocks"
  ON public.blocks
  USING (auth.jwt()->>'role' = 'service_role');

-- ============================================================================
-- 2. CREATE COMPATIBILITY_SCORES TABLE
-- ============================================================================
-- Stores pre-calculated compatibility scores between user pairs
-- Allows for faster match retrieval and personalized recommendations
CREATE TABLE public.compatibility_scores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  potential_match_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  compatibility_score NUMERIC(5,2) NOT NULL CHECK (compatibility_score >= 0 AND compatibility_score <= 100),
  score_components JSONB,
  calculated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT compatibility_no_self_match CHECK (user_id <> potential_match_id),
  CONSTRAINT compatibility_unique_pair UNIQUE(user_id, potential_match_id)
);

-- Create indexes for compatibility_scores
CREATE INDEX IF NOT EXISTS idx_compatibility_user ON public.compatibility_scores(user_id);
CREATE INDEX IF NOT EXISTS idx_compatibility_match ON public.compatibility_scores(potential_match_id);
CREATE INDEX IF NOT EXISTS idx_compatibility_score ON public.compatibility_scores(compatibility_score DESC);
CREATE INDEX IF NOT EXISTS idx_compatibility_calculated ON public.compatibility_scores(calculated_at DESC);
CREATE INDEX IF NOT EXISTS idx_compatibility_expires ON public.compatibility_scores(expires_at)
  WHERE expires_at IS NOT NULL;

-- RLS Policies for compatibility_scores table
ALTER TABLE public.compatibility_scores ENABLE ROW LEVEL SECURITY;

-- DROP existing policies first to avoid conflicts
DROP POLICY IF EXISTS "Users can view their own compatibility scores" ON public.compatibility_scores;
DROP POLICY IF EXISTS "Service role has full access to compatibility scores" ON public.compatibility_scores;
DROP POLICY IF EXISTS "Authenticated users can insert compatibility scores" ON public.compatibility_scores;
DROP POLICY IF EXISTS "Authenticated users can update compatibility scores" ON public.compatibility_scores;

-- Users can view their own compatibility scores
CREATE POLICY "Users can view their own compatibility scores"
  ON public.compatibility_scores
  FOR SELECT
  USING (auth.uid() = user_id);

-- Service role has full access to compatibility scores
CREATE POLICY "Service role has full access to compatibility scores"
  ON public.compatibility_scores
  USING (auth.jwt()->>'role' = 'service_role');

-- Authenticated users can insert compatibility scores
CREATE POLICY "Authenticated users can insert compatibility scores"
  ON public.compatibility_scores
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Authenticated users can update compatibility scores
CREATE POLICY "Authenticated users can update compatibility scores"
  ON public.compatibility_scores
  FOR UPDATE
  USING (auth.uid() = user_id);

-- ============================================================================
-- 3. CREATE TRIGGER FOR UPDATED_AT
-- ============================================================================
-- Automatically update the updated_at timestamp on compatibility_scores
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_compatibility_scores_updated_at ON public.compatibility_scores;
CREATE TRIGGER update_compatibility_scores_updated_at
  BEFORE UPDATE ON public.compatibility_scores
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

COMMIT;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================
-- Run these to verify the migration succeeded:
--
-- 1. Check blocks table exists:
-- SELECT COUNT(*) FROM public.blocks;
--
-- 2. Check compatibility_scores table exists:
-- SELECT COUNT(*) FROM public.compatibility_scores;
--
-- 3. Check RLS is enabled:
-- SELECT tablename, rowsecurity FROM pg_tables
-- WHERE schemaname = 'public'
-- AND tablename IN ('blocks', 'compatibility_scores');
--
-- 4. Check policies exist:
-- SELECT tablename, policyname FROM pg_policies
-- WHERE schemaname = 'public'
-- AND tablename IN ('blocks', 'compatibility_scores');
-- ============================================================================
