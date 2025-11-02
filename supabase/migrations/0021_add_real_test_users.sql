-- Add real test users for matching functionality
-- Migration: 0021_add_real_test_users.sql

-- Note: This migration is commented out due to schema mismatches
-- Uncomment and adjust column names when the profiles table schema is finalized

/*

-- Test User 1: Emma Thompson
INSERT INTO public.profiles (
  id,
  full_name,
  display_name,
  avatar_url,
  gender,
  age,
  zodiac_sign,
  activity_preferences,
  education_level,
  politics,
  is_single,
  has_kids,
  wants_kids,
  traits,
  interests,
  onboarding_completed,
  created_at,
  updated_at
) VALUES (
  '11111111-1111-1111-1111-111111111111',
  'Emma Thompson',
  'Emma',
  null,
  'female',
  28,
  'Leo',
  '{"preferredActivities": ["Coffee", "Dinner", "Drinks"], "avoidedActivities": ["Movies"]}',
  'Bachelor''s Degree',
  'Progressive',
  true,
  false,
  'Yes',
  ARRAY['Kind', 'Creative', 'Adventurous'],
  ARRAY['Art', 'Travel', 'Yoga', 'Photography'],
  true,
  NOW() - INTERVAL '30 days',
  NOW()
) ON CONFLICT (id) DO UPDATE SET 
  display_name = EXCLUDED.display_name,
  gender = EXCLUDED.gender,
  age = EXCLUDED.age,
  zodiac_sign = EXCLUDED.zodiac_sign,
  activity_preferences = EXCLUDED.activity_preferences,
  onboarding_completed = EXCLUDED.onboarding_completed;

-- Test User 2: Michael Chen
INSERT INTO public.profiles (
  id,
  full_name,
  display_name,
  avatar_url,
  gender,
  age,
  zodiac_sign,
  activity_preferences,
  education_level,
  politics,
  is_single,
  has_kids,
  wants_kids,
  traits,
  interests,
  onboarding_completed,
  created_at,
  updated_at
) VALUES (
  '22222222-2222-2222-2222-222222222222',
  'Michael Chen',
  'Michael',
  null,
  'male',
  32,
  'Scorpio',
  '{"preferredActivities": ["Dinner", "Activity", "Coffee"], "avoidedActivities": []}',
  'Master''s Degree',
  'Moderate',
  true,
  false,
  'Maybe',
  ARRAY['Intellectual', 'Funny', 'Ambitious'],
  ARRAY['Technology', 'Music', 'Cooking', 'Fitness'],
  true,
  NOW() - INTERVAL '25 days',
  NOW()
) ON CONFLICT (id) DO UPDATE SET 
  display_name = EXCLUDED.display_name,
  gender = EXCLUDED.gender,
  age = EXCLUDED.age,
  zodiac_sign = EXCLUDED.zodiac_sign,
  activity_preferences = EXCLUDED.activity_preferences,
  onboarding_completed = EXCLUDED.onboarding_completed;

-- Test User 3: Sarah Johnson
INSERT INTO public.profiles (
  id,
  full_name,
  display_name,
  avatar_url,
  gender,
  age,
  zodiac_sign,
  activity_preferences,
  education_level,
  politics,
  is_single,
  has_kids,
  wants_kids,
  traits,
  interests,
  onboarding_completed,
  created_at,
  updated_at
) VALUES (
  '33333333-3333-3333-3333-333333333333',
  'Sarah Johnson',
  'Sarah',
  null,
  'female',
  30,
  'Taurus',
  '{"preferredActivities": ["Coffee", "Activity", "Drinks"], "avoidedActivities": ["Movies"]}',
  'Bachelor''s Degree',
  'Progressive',
  true,
  false,
  'Yes',
  ARRAY['Adventurous', 'Compassionate', 'Driven'],
  ARRAY['Hiking', 'Reading', 'Wine', 'Dogs'],
  true,
  NOW() - INTERVAL '20 days',
  NOW()
) ON CONFLICT (id) DO UPDATE SET 
  display_name = EXCLUDED.display_name,
  gender = EXCLUDED.gender,
  age = EXCLUDED.age,
  zodiac_sign = EXCLUDED.zodiac_sign,
  activity_preferences = EXCLUDED.activity_preferences,
  onboarding_completed = EXCLUDED.onboarding_completed;

-- Test User 4: David Martinez
INSERT INTO public.profiles (
  id,
  full_name,
  display_name,
  avatar_url,
  gender,
  age,
  zodiac_sign,
  activity_preferences,
  education_level,
  politics,
  is_single,
  has_kids,
  wants_kids,
  traits,
  interests,
  onboarding_completed,
  created_at,
  updated_at
) VALUES (
  '44444444-4444-4444-4444-444444444444',
  'David Martinez',
  'David',
  null,
  'male',
  29,
  'Cancer',
  '{"preferredActivities": ["Drinks", "Dinner", "Activity"], "avoidedActivities": []}',
  'Bachelor''s Degree',
  'Progressive',
  true,
  false,
  'Yes',
  ARRAY['Funny', 'Romantic', 'Athletic'],
  ARRAY['Sports', 'Movies', 'Travel', 'Gaming'],
  true,
  NOW() - INTERVAL '15 days',
  NOW()
) ON CONFLICT (id) DO UPDATE SET 
  display_name = EXCLUDED.display_name,
  gender = EXCLUDED.gender,
  age = EXCLUDED.age,
  zodiac_sign = EXCLUDED.zodiac_sign,
  activity_preferences = EXCLUDED.activity_preferences,
  onboarding_completed = EXCLUDED.onboarding_completed;

-- Test User 5: Olivia Williams
INSERT INTO public.profiles (
  id,
  full_name,
  display_name,
  avatar_url,
  gender,
  age,
  zodiac_sign,
  activity_preferences,
  education_level,
  politics,
  is_single,
  has_kids,
  wants_kids,
  traits,
  interests,
  onboarding_completed,
  created_at,
  updated_at
) VALUES (
  '55555555-5555-5555-5555-555555555555',
  'Olivia Williams',
  'Olivia',
  null,
  'female',
  27,
  'Gemini',
  '{"preferredActivities": ["Coffee", "Drinks", "Movies"], "avoidedActivities": []}',
  'Master''s Degree',
  'Progressive',
  true,
  false,
  'Maybe',
  ARRAY['Creative', 'Independent', 'Witty'],
  ARRAY['Writing', 'Film', 'Jazz', 'Fashion'],
  true,
  NOW() - INTERVAL '10 days',
  NOW()
) ON CONFLICT (id) DO UPDATE SET 
  display_name = EXCLUDED.display_name,
  gender = EXCLUDED.gender,
  age = EXCLUDED.age,
  zodiac_sign = EXCLUDED.zodiac_sign,
  activity_preferences = EXCLUDED.activity_preferences,
  onboarding_completed = EXCLUDED.onboarding_completed;

-- Test User 6: James Wilson
INSERT INTO public.profiles (
  id,
  full_name,
  display_name,
  avatar_url,
  gender,
  age,
  zodiac_sign,
  activity_preferences,
  education_level,
  politics,
  is_single,
  has_kids,
  wants_kids,
  traits,
  interests,
  onboarding_completed,
  created_at,
  updated_at
) VALUES (
  '66666666-6666-6666-6666-666666666666',
  'James Wilson',
  'James',
  null,
  'male',
  34,
  'Aries',
  '{"preferredActivities": ["Dinner", "Coffee", "Activity"], "avoidedActivities": ["Movies"]}',
  'PhD',
  'Moderate',
  true,
  false,
  'No',
  ARRAY['Intellectual', 'Caring', 'Confident'],
  ARRAY['Science', 'Cycling', 'Classical Music', 'Chess'],
  true,
  NOW() - INTERVAL '5 days',
  NOW()
) ON CONFLICT (id) DO UPDATE SET 
  display_name = EXCLUDED.display_name,
  gender = EXCLUDED.gender,
  age = EXCLUDED.age,
  zodiac_sign = EXCLUDED.zodiac_sign,
  activity_preferences = EXCLUDED.activity_preferences,
  onboarding_completed = EXCLUDED.onboarding_completed;

-- Add bio information to make profiles more realistic
UPDATE public.profiles SET bio = 'Adventurous soul who loves exploring new coffee shops and art galleries. Looking for someone to share deep conversations and spontaneous adventures.' WHERE id = '11111111-1111-1111-1111-111111111111';
UPDATE public.profiles SET bio = 'Tech enthusiast by day, chef by night. I believe in intellectual conversations over good food and wine. Let''s explore the city together!' WHERE id = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET bio = 'Nature lover and bookworm. I enjoy hiking trails as much as cozy nights with a good book. Looking for a genuine connection.' WHERE id = '33333333-3333-3333-3333-333333333333';
UPDATE public.profiles SET bio = 'Sports fanatic with a romantic side. I can teach you salsa dancing or we can catch a game together. Life is about balance!' WHERE id = '44444444-4444-4444-4444-444444444444';
UPDATE public.profiles SET bio = 'Creative writer with a passion for jazz and indie films. Seeking someone who appreciates art, humor, and midnight conversations.' WHERE id = '55555555-5555-5555-5555-555555555555';
UPDATE public.profiles SET bio = 'Scientist with a love for classical music and strategic thinking. Looking for intellectual stimulation and genuine companionship.' WHERE id = '66666666-6666-6666-6666-666666666666';

-- Create indexes for better matching performance
CREATE INDEX IF NOT EXISTS idx_profiles_gender_age ON public.profiles(gender, age);
CREATE INDEX IF NOT EXISTS idx_profiles_zodiac_sign ON public.profiles(zodiac_sign);
CREATE INDEX IF NOT EXISTS idx_profiles_onboarding_completed ON public.profiles(onboarding_completed);

*/

-- Create indexes for better matching performance (these can run safely)
CREATE INDEX IF NOT EXISTS idx_profiles_gender_age ON public.profiles(gender, age);
CREATE INDEX IF NOT EXISTS idx_profiles_zodiac_sign ON public.profiles(zodiac_sign);
CREATE INDEX IF NOT EXISTS idx_profiles_onboarding_completed ON public.profiles(onboarding_completed);

-- Grant necessary permissions
GRANT SELECT ON public.profiles TO anon;
GRANT SELECT ON public.profiles TO authenticated;