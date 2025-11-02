/**
 * STELLR COMPLETE ONBOARDING PROFILE - ENCRYPTED VERSION
 * 
 * Enhanced onboarding profile completion with field-level encryption
 * Implements comprehensive security for sensitive birth data and questionnaire responses
 * 
 * Security Features:
 * - Automatic encryption of birth data and questionnaire responses
 * - XChaCha20-Poly1305 AEAD encryption with hierarchical key management
 * - Input validation and SQL injection protection
 * - Rate limiting and authentication validation
 * - Comprehensive audit logging
 */

import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { corsHeaders } from '../_shared/cors.ts';
import { calculateZodiacFromBirthInfo } from '../_shared/zodiac-calculator.ts';
import { sanitizeJSONB, sanitizeForSQL } from '../_shared/sql-injection-protection.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { validateUUID, validateTextInput } from '../_shared/security-validation.ts';
import { 
  FieldEncryptionService, 
  getEncryptionService,
  encryptBirthData,
  checkSystemHealth
} from '../_shared/field-encryption-middleware.ts';
import { performanceMonitor } from '../_shared/performance-monitor.ts';
import { structuredLogger } from '../_shared/structured-logging.ts';
import { UnifiedNatalChartService } from '../../../lib/services/unified-natal-chart-service.ts';
import { convertCityToCoordinates } from '../_shared/geocoding-service.ts';

// =====================================================================================
// INPUT VALIDATION SCHEMAS
// Implements Fail Fast principle with comprehensive validation
// =====================================================================================

const BirthInfoSchema = z.object({
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Birth date must be in YYYY-MM-DD format'),
  city: z.string().min(1).max(100, 'City name too long'),
  time: z.string().min(1).max(20, 'Time format too long'), // More flexible time validation
  latitude: z.number().optional(),
  longitude: z.number().optional()
});

const QuestionnaireResultSchema = z.object({
  question: z.string().min(1).max(500, 'Question too long'),
  answer: z.string().min(1).max(1000, 'Answer too long'),
  questionId: z.string().optional(),
  category: z.string().optional()
});

const ProfileSetupDataSchema = z.object({
  gender: z.string().min(1).max(20, 'Gender field too long'),
  age: z.number().min(18).max(120, 'Age must be between 18 and 120'),
  educationLevel: z.string().max(50).optional().nullable(),
  politics: z.string().max(50).optional().nullable(),
  isSingle: z.boolean().optional().nullable(),
  hasKids: z.boolean().optional().nullable(),
  wantsKids: z.boolean().optional().nullable(),
  traits: z.array(z.string().max(50)).max(10, 'Too many traits').optional().nullable(),
  interests: z.array(z.string().max(50)).max(20, 'Too many interests').optional().nullable(),
});

const OnboardingPayloadSchema = z.object({
  userId: z.string().uuid('Invalid user ID format'),
  fullName: z.string().min(1).max(100, 'Name too long').optional().nullable(),
  publicImageUrl: z.string().url('Invalid image URL').optional().nullable(),
  birthInfo: BirthInfoSchema.optional().nullable(),
  questionnaireResults: z.array(QuestionnaireResultSchema).max(50, 'Too many questionnaire responses').optional().nullable(),
  profileSetupData: ProfileSetupDataSchema,
});

// =====================================================================================
// MAIN HANDLER FUNCTION
// =====================================================================================

serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  const startTime = Date.now();
  
  // Initialize performance monitoring
  const perfMonitor = performanceMonitor.startOperation('complete_onboarding_encrypted');
  
  // Initialize logger
  const logger = structuredLogger.createLogger({
    service: 'complete-onboarding-encrypted',
    requestId,
    operation: 'onboarding'
  });

  try {
    // Handle CORS preflight
    if (req.method === 'OPTIONS') {
      return new Response('ok', { headers: corsHeaders });
    }

    // Rate limiting
    const rateLimitResult = await applyRateLimit(
      req, 
      '/complete-onboarding-profile-encrypted', 
      undefined, 
      RateLimitCategory.AUTHENTICATION
    );
    
    if (rateLimitResult.blocked) {
      logger.warn('Request blocked by rate limiting');
      return rateLimitResult.response;
    }

    // Authentication validation
    const userAuthHeader = req.headers.get('Authorization');
    if (!userAuthHeader) {
      logger.warn('Missing authorization header');
      return new Response(
        JSON.stringify({ error: 'Authorization required' }), 
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

    if (!supabaseUrl || !supabaseAnonKey) {
      logger.error('Missing Supabase configuration');
      return new Response(
        JSON.stringify({ error: 'Server configuration error' }),
        {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    const supabaseClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: userAuthHeader } }
    });

    // Validate user authentication
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();

    if (userError || !user) {
      logger.warn('User authentication failed', { error: userError?.message });
      return new Response(
        JSON.stringify({ error: 'Authentication failed' }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    logger.info('User authenticated successfully', { userId: user.id });

    // Check encryption system health before processing
    const encryptionService = getEncryptionService(supabaseClient);
    const healthCheck = await encryptionService.checkEncryptionHealth();
    
    if (healthCheck.status === 'error') {
      logger.error('Encryption system unhealthy', { healthStatus: healthCheck });
      return new Response(
        JSON.stringify({ error: 'Encryption system unavailable' }),
        {
          status: 503,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Parse and validate request payload
    const body = await req.json();
    const validatedPayload = OnboardingPayloadSchema.parse({ ...body, userId: user.id });

    logger.info('Payload validated successfully', { 
      hasBirthInfo: !!validatedPayload.birthInfo,
      hasQuestionnaire: !!validatedPayload.questionnaireResults,
      questionnaireCount: validatedPayload.questionnaireResults?.length || 0
    });

    // =====================================================================================
    // PROCESS BIRTH DATA WITH ENCRYPTION
    // =====================================================================================

    let calculatedZodiacSign: string | null = null;
    let birthDataProcessed = false;

    if (validatedPayload.birthInfo) {
      logger.info('Processing birth data for encryption');
      
      // TODO: Integrate unified natal chart service here
      // Calculate basic zodiac sign (used as fallback)
      calculatedZodiacSign = calculateZodiacFromBirthInfo(validatedPayload.birthInfo);
      
      // Prepare birth data for database storage
      const birthDataForStorage = {
        birth_date: validatedPayload.birthInfo.date,
        birth_time: validatedPayload.birthInfo.time,
        birth_location: validatedPayload.birthInfo.city,
        birth_lat: validatedPayload.birthInfo.latitude || null,
        birth_lng: validatedPayload.birthInfo.longitude || null,
      };

      // Store birth data in users table (will be encrypted automatically)
      const { error: birthDataError } = await supabaseClient
        .from('users')
        .upsert({
          id: user.id,
          auth_user_id: user.id,
          email: user.email,
          ...birthDataForStorage,
          updated_at: new Date().toISOString()
        });

      if (birthDataError) {
        logger.error('Failed to store birth data', { error: birthDataError.message });
        throw new Error(`Birth data storage failed: ${birthDataError.message}`);
      }

      birthDataProcessed = true;

      // Generate natal chart using UnifiedNatalChartService
      try {
        // Resolve coordinates
        let lat = birthDataForStorage.birth_lat as number | null;
        let lng = birthDataForStorage.birth_lng as number | null;
        let tz: string | undefined = undefined;
        if (lat == null || lng == null) {
          const coords = await convertCityToCoordinates(validatedPayload.birthInfo.city);
          lat = coords.lat;
          lng = coords.lng;
          tz = coords.tz || undefined;
        }

        // Parse birth date/time
        const [y, m, d] = validatedPayload.birthInfo.date.split('-').map((s) => parseInt(s, 10));
        const timeParts = UnifiedNatalChartService.parseTimeString(validatedPayload.birthInfo.time || '12:00');
        if (!timeParts) {
          throw new Error(`Invalid time format: ${validatedPayload.birthInfo.time}`);
        }

        const chartInput = {
          birthYear: y,
          birthMonth: m,
          birthDay: d,
          birthHour: timeParts.hour,
          birthMinute: timeParts.minute,
          latitude: lat!,
          longitude: lng!,
          timezone: tz,
          userId: user.id,
        };

        const chartResult = await UnifiedNatalChartService.generateNatalChart(chartInput);
        if (!chartResult.success || !chartResult.data) {
          logger.warn('UnifiedNatalChartService failed', { error: chartResult.error, validationErrors: chartResult.validationErrors });
        } else {
          const natalChart = chartResult.data as any;
          let sunSign: string | null = null;
          let moonSign: string | null = null;
          let risingSign: string | null = null;

          if (natalChart.CorePlacements?.Sun) sunSign = natalChart.CorePlacements.Sun.Sign;
          if (natalChart.CorePlacements?.Moon) moonSign = natalChart.CorePlacements.Moon.Sign;
          if (natalChart.CorePlacements?.Ascendant) risingSign = natalChart.CorePlacements.Ascendant.Sign;

          // Build UI-friendly planets array
          const core = natalChart.CorePlacements || {} as Record<string, any>;
          const order = ['Sun','Moon','Mercury','Venus','Mars','Jupiter','Saturn','Uranus','Neptune','Pluto'];
          const planets = order
            .map((name) => {
              const p = core[name];
              if (!p) return null;
              return { name, sign: p.Sign, degree: typeof p.Degree === 'number' ? p.Degree : 0 };
            })
            .filter(Boolean);

          // Persist full chart to users, sanitized to profiles
          const natalChartData = {
            corePlacements: natalChart.CorePlacements,
            birthData: natalChart.BirthData,
            chartData: { planets },
            calculatedAt: new Date().toISOString(),
            version: '2.0'
          };

          // Update users with full chart + quick signs
          const { error: userChartErr } = await supabaseClient
            .from('users')
            .update({
              natal_chart_data: natalChartData,
              sun_sign: sunSign,
              moon_sign: moonSign,
              rising_sign: risingSign,
              birth_lat: lat,
              birth_lng: lng,
              updated_at: new Date().toISOString(),
            })
            .eq('id', user.id);

          if (userChartErr) {
            logger.warn('Failed to update users with natal chart', { error: userChartErr.message });
          }

          // Attach sanitized subset to profile upsert below
          (sanitizedProfileData as any).natal_chart_data = { chartData: { planets } };

          // Prefer accurate sun sign if calculated
          if (sunSign) {
            sanitizedProfileData.zodiac_sign = sunSign;
          }
        }
      } catch (err) {
        logger.warn('Natal chart generation failed (encrypted flow)', { error: err instanceof Error ? err.message : String(err) });
      }
    }

    // =====================================================================================
    // PROCESS QUESTIONNAIRE DATA WITH ENCRYPTION
    // =====================================================================================

    if (validatedPayload.questionnaireResults) {
      logger.info('Processing questionnaire responses for encryption');
      
      // Sanitize questionnaire responses
      const sanitizedResponses = sanitizeJSONB(validatedPayload.questionnaireResults, {
        maxDepth: 3,
        maxKeys: 50,
        maxStringLength: 1000
      });

      // Store questionnaire responses (will be encrypted automatically)
      const { error: questionnaireError } = await supabaseClient
        .from('users')
        .update({
          questionnaire_responses: sanitizedResponses,
          updated_at: new Date().toISOString()
        })
        .eq('id', user.id);

      if (questionnaireError) {
        logger.error('Failed to store questionnaire data', { error: questionnaireError.message });
        throw new Error(`Questionnaire storage failed: ${questionnaireError.message}`);
      }
    }

    // =====================================================================================
    // ENCRYPT SENSITIVE DATA
    // =====================================================================================

    if (birthDataProcessed || validatedPayload.questionnaireResults) {
      logger.info('Starting field-level encryption');
      
      const encryptionSuccess = await encryptionService.encryptUserBirthData(user.id);
      
      if (!encryptionSuccess) {
        logger.error('Birth data encryption failed');
        throw new Error('Failed to encrypt sensitive data');
      }

      logger.info('Field-level encryption completed successfully');
    }

    // =====================================================================================
    // UPDATE PROFILE DATA
    // =====================================================================================

    // Sanitize profile data
    const sanitizedProfileData = {
      display_name: validatedPayload.fullName ? 
        sanitizeForSQL(validatedPayload.fullName, { maxLength: 100, preserveSpaces: true }) : 
        null,
      avatar_url: validatedPayload.publicImageUrl,
      zodiac_sign: calculatedZodiacSign,
      age: validatedPayload.profileSetupData.age,
      gender: sanitizeForSQL(validatedPayload.profileSetupData.gender, { maxLength: 20 }),
      onboarding_completed: true,
      updated_at: new Date().toISOString()
    };

    // Update profile
    const { error: profileError } = await supabaseClient
      .from('profiles')
      .upsert({
        id: user.id,
        ...sanitizedProfileData
      });

    if (profileError) {
      logger.error('Failed to update profile', { error: profileError.message });
      throw new Error(`Profile update failed: ${profileError.message}`);
    }

    // =====================================================================================
    // PERFORMANCE METRICS AND LOGGING
    // =====================================================================================

    const operationDuration = Date.now() - startTime;
    perfMonitor.recordSuccess(operationDuration);

    logger.info('Onboarding completed successfully', {
      userId: user.id,
      duration: operationDuration,
      encryptionEnabled: birthDataProcessed || !!validatedPayload.questionnaireResults,
      zodiacCalculated: !!calculatedZodiacSign
    });

    // Return success response
    return new Response(
      JSON.stringify({
        success: true,
        message: 'Onboarding completed successfully',
        data: {
          userId: user.id,
          encryptionEnabled: birthDataProcessed || !!validatedPayload.questionnaireResults,
          zodiacSign: calculatedZodiacSign,
          profileComplete: true
        },
        performance: {
          duration: operationDuration,
          encryptionStatus: healthCheck.status
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    const operationDuration = Date.now() - startTime;
    perfMonitor.recordError(error as Error, operationDuration);

    logger.error('Onboarding process failed', {
      error: error instanceof Error ? error.message : 'Unknown error',
      stack: error instanceof Error ? error.stack : undefined,
      duration: operationDuration
    });

    // Return error response
    const statusCode = error instanceof z.ZodError ? 400 : 500;
    const errorMessage = error instanceof z.ZodError ? 'Validation failed' : 'Internal server error';

    return new Response(
      JSON.stringify({
        success: false,
        error: errorMessage,
        details: error instanceof z.ZodError ? error.errors : undefined,
        requestId
      }),
      {
        status: statusCode,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});

export { serve };
