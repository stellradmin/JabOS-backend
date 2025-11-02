-- Add current location fields to profiles table for distance-based matching

-- Add current city name column
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS current_city TEXT DEFAULT NULL;

-- Add current city latitude
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS current_city_lat NUMERIC DEFAULT NULL;

-- Add current city longitude
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS current_city_lng NUMERIC DEFAULT NULL;

-- Create geospatial index for efficient distance queries
CREATE INDEX IF NOT EXISTS idx_profiles_current_location
  ON public.profiles(current_city_lat, current_city_lng)
  WHERE current_city_lat IS NOT NULL AND current_city_lng IS NOT NULL;

-- Add check constraints for valid coordinate ranges
ALTER TABLE public.profiles
  ADD CONSTRAINT check_current_city_lat_range
  CHECK (current_city_lat IS NULL OR (current_city_lat >= -90 AND current_city_lat <= 90));

ALTER TABLE public.profiles
  ADD CONSTRAINT check_current_city_lng_range
  CHECK (current_city_lng IS NULL OR (current_city_lng >= -180 AND current_city_lng <= 180));

-- Add comments for documentation
COMMENT ON COLUMN public.profiles.current_city IS 'User''s current city for distance-based matching';
COMMENT ON COLUMN public.profiles.current_city_lat IS 'Latitude of user''s current city';
COMMENT ON COLUMN public.profiles.current_city_lng IS 'Longitude of user''s current city';

-- Grant permissions
GRANT SELECT, UPDATE ON public.profiles TO authenticated;
GRANT SELECT ON public.profiles TO service_role;
