import { serve } from 'std/http/server.ts'; // Using import map
import { createClient, SupabaseClient } from '@supabase/supabase-js'; // Using import map
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts'; // Zod often used directly via URL
import { calculateZodiacFromBirthInfo } from '../_shared/zodiac-calculator.ts';
import { sanitizeJSONB, sanitizeForSQL, detectSQLInjection } from '../_shared/sql-injection-protection.ts';

import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';
// Define the expected payload structure with Zod
const BirthInfoSchema = z.object({
  date: z.string(), // Assuming ISO date string
  city: z.string(),
  time: z.string(),
});

const QuestionnaireResultSchema = z.object({
  question: z.string(),
  answer: z.string(),
});

const ProfileSetupDataSchema = z.object({
  // Fields from ProfileSetupFlow
  gender: z.string(),
  age: z.number().min(18),
  educationLevel: z.string().optional().nullable(),
  politics: z.string().optional().nullable(),
  isSingle: z.boolean().optional().nullable(),
  hasKids: z.boolean().optional().nullable(),
  wantsKids: z.boolean().optional().nullable(),
  traits: z.array(z.string()).optional().nullable(),
  interests: z.array(z.string()).optional().nullable(),
  // photoUri is handled client-side for upload, only publicImageUrl comes here
});

const OnboardingPayloadSchema = z.object({
  userId: z.string().uuid(), // Authenticated user ID
  fullName: z.string().optional().nullable(), // From auth metadata or profile setup
  publicImageUrl: z.string().url().optional().nullable(),
  birthInfo: BirthInfoSchema.optional().nullable(),
  questionnaireResults: z.array(QuestionnaireResultSchema).optional().nullable(),
  profileSetupData: ProfileSetupDataSchema, // Contains gender, age, preferences etc.
  deviceTimezone: z.string().optional().nullable(),
});

// CORS Headers 
// Note: If you have a shared/cors.ts via import map, you can import corsHeaders from there.
// For this example, defining it locally to ensure it's present.
const corsHeaders = {
  'Access-Control-Allow-Origin': '*', // Adjust for production
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};


const USER_PROFILE_TABLE = 'profiles'; // Changed to 'profiles'

serve(async (req: Request) => {
  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/complete-onboarding-profile', undefined, RateLimitCategory.AUTHENTICATION);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }


  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  // Initialize Supabase client with user's JWT for RLS
  const userAuthHeader = req.headers.get('Authorization');
  if (!userAuthHeader) {
    return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401,
    });
  }
  
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

  if (!supabaseUrl || !supabaseAnonKey) {
return new Response(JSON.stringify({ error: 'Server configuration error.' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500,
    });
  }

  const userSupabaseClient = createClient(
    supabaseUrl,
    supabaseAnonKey,
    { global: { headers: { Authorization: userAuthHeader } } }
  );

  const { data: { user }, error: userError } = await userSupabaseClient.auth.getUser();

  if (userError || !user) {
    return new Response(JSON.stringify({ error: 'User not authenticated or token invalid' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401,
    });
  }

  try {
    const body = await req.json();
    // Add userId to body before validation, as it comes from authenticated user, not client payload directly
    const validatedPayload = OnboardingPayloadSchema.parse({ ...body, userId: user.id });

    // Calculate zodiac sign from birth info if available
    let calculatedZodiacSign: string | null = null;
    if (validatedPayload.birthInfo) {
      calculatedZodiacSign = calculateZodiacFromBirthInfo(validatedPayload.birthInfo);
      // Debug logging removed for security
}

    // CRITICAL SECURITY: Sanitize all user input to prevent SQL/JSONB injection
    
    // Sanitize text fields for SQL injection
    const displayNameSanitized = validatedPayload.fullName 
      ? sanitizeForSQL(validatedPayload.fullName, { maxLength: 100, preserveSpaces: true })
      : null;
    
    const genderSanitized = sanitizeForSQL(validatedPayload.profileSetupData.gender, { maxLength: 20 });
    
    // Sanitize JSONB fields to prevent injection attacks
    const questionnaireResponsesSanitized = validatedPayload.questionnaireResults 
      ? sanitizeJSONB(validatedPayload.questionnaireResults, {
          maxDepth: 3,
          maxKeys: 20,
          maxStringLength: 500
        })
      : null;
    
    const personalityTraitsSanitized = validatedPayload.profileSetupData.traits
      ? sanitizeJSONB(validatedPayload.profileSetupData.traits, {
          maxDepth: 2,
          maxKeys: 10,
          maxStringLength: 50
        })
      : null;
    
    const interestsSanitized = validatedPayload.profileSetupData.interests
      ? sanitizeJSONB(validatedPayload.profileSetupData.interests, {
          maxDepth: 2,
          maxKeys: 20,
          maxStringLength: 50
        })
      : null;
    
    // Log security events if high-risk content was sanitized
    if (questionnaireResponsesSanitized?.securityRisk === 'critical' || 
        personalityTraitsSanitized?.securityRisk === 'critical' ||
        interestsSanitized?.securityRisk === 'critical') {
      console.warn('CRITICAL: SQL injection attempt blocked in onboarding profile data');
    }
    
    // Construct the profile update object with sanitized data
    const profileDataToUpdate: any = {
      display_name: displayNameSanitized?.sanitized || null,
      avatar_url: validatedPayload.publicImageUrl, // URLs are validated by Zod schema
      gender: genderSanitized.sanitized,
      // Add calculated zodiac sign (safe - generated server-side)
      zodiac_sign: calculatedZodiacSign,
      // Profile setup data mapped to actual columns
      // age is derived via DB trigger from users.birth_date
      education_level: validatedPayload.profileSetupData.educationLevel 
        ? sanitizeForSQL(validatedPayload.profileSetupData.educationLevel, { maxLength: 50 }).sanitized
        : null,
      politics: validatedPayload.profileSetupData.politics
        ? sanitizeForSQL(validatedPayload.profileSetupData.politics, { maxLength: 50 }).sanitized
        : null,
      is_single: validatedPayload.profileSetupData.isSingle, // Boolean - safe
      has_kids: validatedPayload.profileSetupData.hasKids, // Boolean - safe
      wants_kids: validatedPayload.profileSetupData.wantsKids, // Boolean - safe
      traits: personalityTraitsSanitized?.sanitized || null,
      interests: interestsSanitized?.sanitized || null,
      onboarding_completed: true,
      updated_at: new Date().toISOString(),
    };
    
    // Update users table with birth data and generate natal chart if provided
    if (validatedPayload.birthInfo) {
      console.log('[ONBOARDING] Natal chart: birthInfo present', {
        hasDate: !!validatedPayload.birthInfo?.date,
        hasTime: !!validatedPayload.birthInfo?.time,
        citySample: (validatedPayload.birthInfo?.city || '').slice(0, 32)
      });
      let natalChartData: any = null;
      let sunSign: string | null = null;
      let moonSign: string | null = null;
      let risingSign: string | null = null;
      let birthLat: number | null = null;
      let birthLng: number | null = null;
      
      try {
        // Import unified natal chart service and geocoding
        const { UnifiedNatalChartService } = await import('../../../lib/services/unified-natal-chart-service.ts');
        const { convertCityToCoordinates } = await import('../_shared/geocoding-service.ts');
        
        // Convert city to coordinates
        const coordinates = await convertCityToCoordinates(validatedPayload.birthInfo.city);
        console.log('[ONBOARDING] Natal chart: geocoded', {
          lat: Math.round(coordinates.lat * 1000) / 1000,
          lng: Math.round(coordinates.lng * 1000) / 1000,
          tz: coordinates.tz || null
        });
        birthLat = coordinates.lat;
        birthLng = coordinates.lng;
        
        // Parse birth date and time robustly
        const monthMap: Record<string, number> = {
          january: 1, february: 2, march: 3, april: 4, may: 5, june: 6,
          july: 7, august: 8, september: 9, october: 10, november: 11, december: 12,
          jan: 1, feb: 2, mar: 3, apr: 4, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12,
        };
        const dateStr = (validatedPayload.birthInfo.date || '').trim();
        let birthDate: Date | null = null;

        // ISO YYYY-MM-DD
        let m = dateStr.match(/^(\d{4})-(\d{2})-(\d{2})$/);
        if (m) {
          birthDate = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
        }
        // M/D/YYYY or MM/DD/YYYY
        if (!birthDate) {
          m = dateStr.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
          if (m) {
            birthDate = new Date(Number(m[3]), Number(m[1]) - 1, Number(m[2]));
          }
        }
        // Month D, YYYY (full or abbreviated month)
        if (!birthDate) {
          m = dateStr.match(/^([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})$/);
          if (m) {
            const monthName = m[1].toLowerCase();
            const monthNum = monthMap[monthName] || monthMap[monthName.slice(0,3)];
            if (monthNum) {
              birthDate = new Date(Number(m[3]), monthNum - 1, Number(m[2]));
            }
          }
        }
        if (!birthDate || isNaN(birthDate.getTime())) {
          throw new Error(`Invalid birth date: ${validatedPayload.birthInfo.date}`);
        }
        
        // Parse time string to get hour and minute
        let timeComponents = UnifiedNatalChartService.parseTimeString(validatedPayload.birthInfo.time);
        if (!timeComponents) {
          // Be lenient: default to noon rather than failing chart generation
          console.warn('[ONBOARDING] Natal chart: invalid or missing time; defaulting to 12:00', { time: validatedPayload.birthInfo.time });
          timeComponents = { hour: 12, minute: 0 };
        } else {
          console.log('[ONBOARDING] Natal chart: time parsed', timeComponents);
        }
        
        // Do not set profiles.age directly; DB trigger syncs from users.birth_date

        // Prepare birth data for unified service
        const birthDataInput = {
          birthYear: birthDate.getFullYear(),
          birthMonth: birthDate.getMonth() + 1, // Convert to 1-12
          birthDay: birthDate.getDate(),
          birthHour: timeComponents.hour,
          birthMinute: timeComponents.minute,
          latitude: coordinates.lat,
          longitude: coordinates.lng,
          userId: user.id,
          timezone: coordinates.tz || validatedPayload.deviceTimezone || undefined
        };
        
        // Generate natal chart using unified service
        console.log('[ONBOARDING] Natal chart: generating with UnifiedNatalChartService');
        const chartResult = await UnifiedNatalChartService.generateNatalChart(birthDataInput);
        
        if (!chartResult.success || !chartResult.data) {
          console.warn('[ONBOARDING] Natal chart: unified service failed', { error: chartResult.error, validationErrors: chartResult.validationErrors });
          throw new Error(`Natal chart generation failed: ${chartResult.error}`);
        }
        
        const natalChart = chartResult.data;
        
        // Extract core signs for quick database queries
        if (natalChart.CorePlacements.Sun) {
          sunSign = natalChart.CorePlacements.Sun.Sign;
        }
        if (natalChart.CorePlacements.Moon) {
          moonSign = natalChart.CorePlacements.Moon.Sign;
        }
        if (natalChart.CorePlacements.Ascendant) {
          risingSign = natalChart.CorePlacements.Ascendant.Sign;
        }
        
        // Store the complete natal chart data (both unified and UI-friendly formats)
        const core = natalChart.CorePlacements || {} as Record<string, any>;
        const order = ['Sun','Moon','Mercury','Venus','Mars','Jupiter','Saturn','Uranus','Neptune','Pluto'];
        const planets = order
          .map((name) => {
            const p = core[name];
            if (!p) return null;
            return { name, sign: p.Sign, degree: typeof p.Degree === 'number' ? p.Degree : 0 };
          })
          .filter(Boolean);

        // Build 'placements' map for DB synastry compatibility (legacy expectation)
        const placements: Record<string, any> = {};
        ['Sun','Moon','Ascendant','Mercury','Venus','Mars','Jupiter','Saturn','Uranus','Neptune','Pluto'].forEach((name) => {
          const p = (natalChart.CorePlacements as any)?.[name];
          if (p) {
            placements[name] = {
              sign: p.Sign,
              degree: typeof p.Degree === 'number' ? p.Degree : 0,
              absolute_degree: typeof p.AbsoluteDegree === 'number' ? p.AbsoluteDegree : undefined
            };
          }
        });

        natalChartData = {
          corePlacements: natalChart.CorePlacements,
          placements, // legacy-compatible for DB calc
          birthData: natalChart.BirthData,
          chartData: { planets },
          calculatedAt: new Date().toISOString(),
          version: '2.0'
        };

        // Also prepare a sanitized subset for the public profiles table (display-only)
        if (planets && (planets as any[]).length > 0) {
          // Attach to profile update payload later
          (profileDataToUpdate as any).natal_chart_data = { chartData: { planets } };
        }
        
      } catch (error) {
        console.warn('[ONBOARDING] Error calculating natal chart', { message: (error as Error)?.message });
        // Continue without natal chart data - don't fail the entire onboarding
      }
      
      const userUpdatePayload: any = {
        birth_date: validatedPayload.birthInfo.date,
        birth_location: validatedPayload.birthInfo.city,
        birth_time: validatedPayload.birthInfo.time,
        birth_city: validatedPayload.birthInfo.city,
        birth_lat: birthLat,
        birth_lng: birthLng,
        updated_at: new Date().toISOString(),
      };
      // Only attach chart/signs if we actually computed them
      if (natalChartData) {
        userUpdatePayload.natal_chart_data = natalChartData;
      }
      if (sunSign) userUpdatePayload.sun_sign = sunSign;
      if (moonSign) userUpdatePayload.moon_sign = moonSign;
      if (risingSign) userUpdatePayload.rising_sign = risingSign;

      const { error: userUpdateError } = await userSupabaseClient
        .from('users')
        .update(userUpdatePayload)
        .eq('id', user.id);

      if (userUpdateError) {
        console.warn('[ONBOARDING] Error updating user birth data', userUpdateError);
        // Don't throw error, continue with profile update
      }
    }

    // Remove undefined/null fields to avoid overwriting with null if not intended by your DB schema/triggers
    for (const key in profileDataToUpdate) {
      if (profileDataToUpdate[key] === undefined || profileDataToUpdate[key] === null) {
        // If you want to explicitly set fields to null in the DB, remove 'profileDataToUpdate[key] === null'
        // and ensure your Zod schemas .nullable() accordingly.
        delete profileDataToUpdate[key]; 
      }
    }

    const { data, error } = await userSupabaseClient
      .from(USER_PROFILE_TABLE)
      .update(profileDataToUpdate)
      .eq('id', user.id) // Changed to use 'id' as the column linking to auth.users.id
      .select()
      .single();

    if (error) {
throw error;
    }

    return new Response(JSON.stringify(data), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (e) {
const errorMessage = e instanceof Error ? e.message : 'An unexpected error occurred.';
    const errorDetails = e instanceof ZodError ? e.flatten() : undefined;
    return new Response(JSON.stringify({ error: errorMessage, details: errorDetails, type: e.name }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: e instanceof ZodError ? 400 : 500,
    });
  }
});
