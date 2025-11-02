-- Migration: Create Swipes Table
-- Description: Creates the missing swipes table that is referenced by existing Edge Functions and RLS policies

CREATE TABLE IF NOT EXISTS public.swipes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    swiper_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    swiped_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    swipe_type TEXT NOT NULL CHECK (swipe_type IN ('like', 'pass')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Ensure a user can only swipe on another user once
    UNIQUE(swiper_id, swiped_id)
);

-- Create indexes for performance (matching existing Edge Function queries)
CREATE INDEX IF NOT EXISTS idx_swipes_swiper_id ON public.swipes(swiper_id);
CREATE INDEX IF NOT EXISTS idx_swipes_swiped_id ON public.swipes(swiped_id);
CREATE INDEX IF NOT EXISTS idx_swipes_created_at ON public.swipes(created_at);

-- Add trigger for updated_at
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_updated_at_swipes
    BEFORE UPDATE ON public.swipes
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_updated_at();

-- Add comments
COMMENT ON TABLE public.swipes IS 'Tracks user swipe actions to prevent duplicate swipes and enable match detection';
COMMENT ON COLUMN public.swipes.swiper_id IS 'User who performed the swipe action';
COMMENT ON COLUMN public.swipes.swiped_id IS 'User who was swiped on';
COMMENT ON COLUMN public.swipes.swipe_type IS 'Type of swipe: like or pass';