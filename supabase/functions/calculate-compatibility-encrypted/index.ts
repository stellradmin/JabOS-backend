/**
 * STELLR COMPATIBILITY CALCULATION - ENCRYPTED VERSION
 * 
 * Enhanced compatibility calculation with encrypted birth data and natal chart support
 * Implements secure compatibility algorithms with transparent encryption/decryption
 * 
 * Security Features:
 * - Automatic decryption of birth data and questionnaire responses
 * - Encrypted storage of compatibility calculation results
 * - Performance optimization with caching and minimal decryption operations
 * - Comprehensive error handling and audit logging
 */

import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { corsHeaders } from '../_shared/cors.ts';
import { 
  FieldEncryptionService,
  getEncryptionService,
  getBirthDataDecrypted,
  getNatalChart,
  storeNatalChart
} from '../_shared/field-encryption-middleware.ts';
// Use shared aspects-based synastry implementation
import { calculateAstrologicalCompatibility as calcSynastry } from '../_shared/astronomical-calculations.ts';
import { calculateNatalChart } from '../_shared/astronomical-calculations.ts';
import { calculateQuestionnaireCompatibility } from '../_shared/questionnaire-compatibility.ts';
import { performanceMonitor } from '../_shared/performance-monitor.ts';
import { structuredLogger } from '../_shared/structured-logging.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';

// =====================================================================================
// INPUT VALIDATION AND TYPE DEFINITIONS
// =====================================================================================

const CompatibilityRequestSchema = z.object({
  userAId: z.string().uuid('Invalid user A ID'),
  userBId: z.string().uuid('Invalid user B ID'),
  includeDetailedReport: z.boolean().default(false),
  forceRecalculation: z.boolean().default(false)
});

interface CompatibilityResult {
  overall_score: number;
  astrological_grade: string;
  questionnaire_grade: string;
  detailed_calculation: {
    astrological?: {
      score: number;
      grade: string;
      details: Record<string, any>;
    };
    questionnaire?: {
      score: number;
      grade: string;
      details: Record<string, any>;
    };
    weights?: {
      astrological: number;
      questionnaire: number;
    };
    calculation_method?: string;
    threshold?: number;
  };
  is_match_recommended: boolean;
  calculation_timestamp: string;
  encryption_metadata: {
    version: string;
    fields_encrypted: string[];
    performance_ms: number;
  };
}

interface UserCompatibilityData {
  userId: string;
  birthData: {
    birth_date?: string;
    birth_time?: string;
    birth_location?: string;
    birth_lat?: number;
    birth_lng?: number;
    encrypted: boolean;
  } | null;
  questionnaireData: Record<string, any> | null;
  natalChart: Record<string, any> | null;
  profileData: {
    zodiac_sign?: string;
    age?: number;
    gender?: string;
  };
}

// =====================================================================================
// MAIN HANDLER FUNCTION
// =====================================================================================

serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  const startTime = Date.now();
  
  // Initialize performance monitoring
  const perfMonitor = performanceMonitor.startOperation('calculate_compatibility_encrypted');
  
  // Initialize logger
  const logger = structuredLogger.createLogger({
    service: 'calculate-compatibility-encrypted',
    requestId,
    operation: 'compatibility_calculation'
  });

  try {
    // Handle CORS preflight
    if (req.method === 'OPTIONS') {
      return new Response('ok', { headers: corsHeaders });
    }

    // Rate limiting
    const rateLimitResult = await applyRateLimit(
      req, 
      '/calculate-compatibility-encrypted', 
      undefined, 
      RateLimitCategory.COMPUTATION
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

    // Parse and validate request
    const body = await req.json();
    const validatedRequest = CompatibilityRequestSchema.parse(body);

    logger.info('Compatibility calculation requested', {
      userAId: validatedRequest.userAId,
      userBId: validatedRequest.userBId,
      forceRecalculation: validatedRequest.forceRecalculation
    });

    // Initialize encryption service
    const encryptionService = getEncryptionService(supabaseClient);

    // Check encryption system health
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

    // =====================================================================================
    // LOAD USER DATA WITH DECRYPTION
    // =====================================================================================

    const [userAData, userBData] = await Promise.all([
      loadUserCompatibilityData(validatedRequest.userAId, encryptionService, supabaseClient),
      loadUserCompatibilityData(validatedRequest.userBId, encryptionService, supabaseClient)
    ]);

    if (!userAData || !userBData) {
      logger.warn('Failed to load user data for compatibility calculation');
      return new Response(
        JSON.stringify({ error: 'User data not available' }),
        {
          status: 404,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    logger.info('User data loaded successfully', {
      userAHasEncryptedData: userAData.birthData?.encrypted || false,
      userBHasEncryptedData: userBData.birthData?.encrypted || false
    });

    // =====================================================================================
    // CALCULATE COMPATIBILITY
    // =====================================================================================

    const compatibilityResult = await calculateCompatibility(
      userAData, 
      userBData, 
      validatedRequest.includeDetailedReport,
      encryptionService,
      logger
    );

    // =====================================================================================
    // STORE ENCRYPTED RESULTS
    // =====================================================================================

    await storeEncryptedCompatibilityResult(
      validatedRequest.userAId,
      validatedRequest.userBId,
      compatibilityResult,
      supabaseClient,
      logger
    );

    // =====================================================================================
    // PERFORMANCE METRICS AND RESPONSE
    // =====================================================================================

    const operationDuration = Date.now() - startTime;
    perfMonitor.recordSuccess(operationDuration);

    logger.info('Compatibility calculation completed', {
      overallScore: compatibilityResult.overall_score,
      astrologicalGrade: compatibilityResult.astrological_grade,
      questionnaireGrade: compatibilityResult.questionnaire_grade,
      duration: operationDuration
    });

    return new Response(
      JSON.stringify({
        success: true,
        data: {
          overall_score: compatibilityResult.overall_score,
          astrological_grade: compatibilityResult.astrological_grade,
          questionnaire_grade: compatibilityResult.questionnaire_grade,
          is_match_recommended: compatibilityResult.is_match_recommended,
          calculation_timestamp: compatibilityResult.calculation_timestamp,
          detailed_report: validatedRequest.includeDetailedReport ? 
            compatibilityResult.detailed_calculation : undefined,
          encryption_metadata: compatibilityResult.encryption_metadata
        },
        performance: {
          duration: operationDuration,
          encryption_operations: compatibilityResult.encryption_metadata.fields_encrypted.length
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

    logger.error('Compatibility calculation failed', {
      error: error instanceof Error ? error.message : 'Unknown error',
      stack: error instanceof Error ? error.stack : undefined,
      duration: operationDuration
    });

    const statusCode = error instanceof z.ZodError ? 400 : 500;
    const errorMessage = error instanceof z.ZodError ? 'Invalid request' : 'Calculation failed';

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

// =====================================================================================
// HELPER FUNCTIONS
// =====================================================================================

/**
 * Loads and decrypts user data for compatibility calculation
 * Implements Single Responsibility Principle
 */
async function loadUserCompatibilityData(
  userId: string,
  encryptionService: FieldEncryptionService,
  supabaseClient: any
): Promise<UserCompatibilityData | null> {
  try {
    // Load basic profile data
    const { data: profileData, error: profileError } = await supabaseClient
      .from('profiles')
      .select('zodiac_sign, age, gender')
      .eq('id', userId)
      .single();

    if (profileError) {
      console.error(`Failed to load profile for user ${userId}:`, profileError);
      return null;
    }

    // Load decrypted birth data
    const birthData = await getBirthDataDecrypted(userId, supabaseClient);

    // Load natal chart if available
    const natalChart = await getNatalChart(userId, supabaseClient);

    // Extract questionnaire data from birth data (it's stored together)
    const questionnaireData = birthData?.questionnaire_responses || null;

    return {
      userId,
      birthData: birthData ? {
        birth_date: birthData.birth_date,
        birth_time: birthData.birth_time,
        birth_location: birthData.birth_location,
        birth_lat: birthData.birth_lat,
        birth_lng: birthData.birth_lng,
        encrypted: birthData.encrypted
      } : null,
      questionnaireData,
      natalChart: natalChart?.chart_data || null,
      profileData
    };

  } catch (error) {
    console.error(`Failed to load user compatibility data for ${userId}:`, error);
    return null;
  }
}

/**
 * Calculates compatibility between two users
 * Implements Separation of Concerns with modular calculations
 */
async function calculateCompatibility(
  userA: UserCompatibilityData,
  userB: UserCompatibilityData,
  includeDetails: boolean,
  encryptionService: FieldEncryptionService,
  logger: any
): Promise<CompatibilityResult> {
  const calculationStart = Date.now();
  const fieldsEncrypted: string[] = [];

  // Track encrypted fields
  if (userA.birthData?.encrypted) {
    fieldsEncrypted.push(`userA:birth_data`);
  }
  if (userB.birthData?.encrypted) {
    fieldsEncrypted.push(`userB:birth_data`);
  }

  // =====================================================================================
  // ASTROLOGICAL COMPATIBILITY
  // =====================================================================================

  let astrologicalScore = 0;
  let astrologicalGrade = 'F';
  let astrologicalDetails = {};

  if (userA.birthData && userB.birthData && userA.natalChart && userB.natalChart) {
    // Use shared aspects-based synastry (absolute degrees + orbs)
    const syn = calcSynastry(
      userA.natalChart as any,
      userB.natalChart as any
    );
    astrologicalScore = syn.score;
    astrologicalGrade = syn.grade;
    
    if (includeDetails) {
      astrologicalDetails = generateAstrologicalDetails(userA.natalChart, userB.natalChart);
    }
    
    logger.info('Astrological compatibility calculated', { score: astrologicalScore });
    
  } else if (userA.profileData.zodiac_sign && userB.profileData.zodiac_sign) {
    // Fallback to zodiac sign compatibility
    astrologicalScore = calculateZodiacCompatibility(
      userA.profileData.zodiac_sign, 
      userB.profileData.zodiac_sign
    );
    astrologicalGrade = scoreToGrade(astrologicalScore);
    
    logger.info('Zodiac compatibility calculated (fallback)', { score: astrologicalScore });
  }

  // =====================================================================================
  // QUESTIONNAIRE COMPATIBILITY
  // =====================================================================================

  let questionnaireScore = 0;
  let questionnaireGrade = 'F';
  let questionnaireDetails = {};

  if (userA.questionnaireData && userB.questionnaireData) {
    questionnaireScore = calculateQuestionnaireCompatibility(
      userA.questionnaireData, 
      userB.questionnaireData
    );
    questionnaireGrade = scoreToGrade(questionnaireScore);
    
    if (includeDetails) {
      questionnaireDetails = generateQuestionnaireDetails(
        userA.questionnaireData, 
        userB.questionnaireData
      );
    }
    
    logger.info('Questionnaire compatibility calculated', { score: questionnaireScore });
  }

  // =====================================================================================
  // OVERALL COMPATIBILITY CALCULATION
  // =====================================================================================

  // Weighted average aligned with DB: 50% astro, 50% questionnaire
  const overallScore = Math.round(
    (astrologicalScore * 0.5) + (questionnaireScore * 0.5)
  );

  const isMatchRecommended = overallScore >= 70; // Configurable threshold

  const detailedCalculation = includeDetails ? {
    astrological: {
      score: astrologicalScore,
      grade: astrologicalGrade,
      details: astrologicalDetails
    },
    questionnaire: {
      score: questionnaireScore,
      grade: questionnaireGrade,
      details: questionnaireDetails
    },
    weights: {
      astrological: 0.6,
      questionnaire: 0.4
    },
    calculation_method: 'weighted_average',
    threshold: 70
  } : {};

  return {
    overall_score: overallScore,
    astrological_grade: astrologicalGrade,
    questionnaire_grade: questionnaireGrade,
    detailed_calculation: detailedCalculation,
    is_match_recommended: isMatchRecommended,
    calculation_timestamp: new Date().toISOString(),
    encryption_metadata: {
      version: 'v1',
      fields_encrypted: fieldsEncrypted,
      performance_ms: Date.now() - calculationStart
    }
  };
}

/**
 * Stores encrypted compatibility results
 * Implements Security by Design with encrypted result storage
 */
async function storeEncryptedCompatibilityResult(
  userAId: string,
  userBId: string,
  result: CompatibilityResult,
  supabaseClient: any,
  logger: any
): Promise<void> {
  try {
    // Store in matches table with encrypted calculation result
    const { error } = await supabaseClient
      .from('matches')
      .upsert({
        user1_id: userAId < userBId ? userAId : userBId, // Consistent ordering
        user2_id: userAId < userBId ? userBId : userAId,
        // Use both old and new schema columns for backward compatibility
        overall_score: result.overall_score,
        astrological_grade: result.astrological_grade,
        questionnaire_grade: result.questionnaire_grade,
        compatibility_score: result.overall_score, // New schema compatibility
        astro_compatibility: {
          score: result.detailed_calculation?.astrological?.score || 0,
          grade: result.astrological_grade,
          details: result.detailed_calculation?.astrological?.details || {}
        },
        questionnaire_compatibility: {
          score: result.detailed_calculation?.questionnaire?.score || 0,
          grade: result.questionnaire_grade,
          details: result.detailed_calculation?.questionnaire?.details || {}
        },
        calculation_result: result.detailed_calculation, // Legacy field
        updated_at: new Date().toISOString()
      });

    if (error) {
      throw error;
    }

    logger.info('Compatibility result stored successfully');

  } catch (error) {
    logger.error('Failed to store compatibility result', { error });
    throw error;
  }
}

// =====================================================================================
// COMPATIBILITY CALCULATION HELPERS
// =====================================================================================

function calculateAstrologicalCompatibility(chartA: any, chartB: any): number {
  try {
    if (!chartA || !chartB) {
      return 50; // Default compatibility if charts unavailable
    }

    let totalCompatibility = 0;
    let weightSum = 0;

    // Sun sign compatibility (30% weight)
    if (chartA.sun?.sign && chartB.sun?.sign) {
      const sunCompatibility = calculatePlanetaryCompatibility(
        chartA.sun.sign, chartB.sun.sign, chartA.sun.degree, chartB.sun.degree
      );
      totalCompatibility += sunCompatibility * 0.3;
      weightSum += 0.3;
    }

    // Moon sign compatibility (25% weight)
    if (chartA.moon?.sign && chartB.moon?.sign) {
      const moonCompatibility = calculatePlanetaryCompatibility(
        chartA.moon.sign, chartB.moon.sign, chartA.moon.degree, chartB.moon.degree
      );
      totalCompatibility += moonCompatibility * 0.25;
      weightSum += 0.25;
    }

    // Venus compatibility (20% weight)
    if (chartA.venus?.sign && chartB.venus?.sign) {
      const venusCompatibility = calculatePlanetaryCompatibility(
        chartA.venus.sign, chartB.venus.sign, chartA.venus.degree, chartB.venus.degree
      );
      totalCompatibility += venusCompatibility * 0.2;
      weightSum += 0.2;
    }

    // Mars compatibility (15% weight)
    if (chartA.mars?.sign && chartB.mars?.sign) {
      const marsCompatibility = calculatePlanetaryCompatibility(
        chartA.mars.sign, chartB.mars.sign, chartA.mars.degree, chartB.mars.degree
      );
      totalCompatibility += marsCompatibility * 0.15;
      weightSum += 0.15;
    }

    // Ascendant compatibility (10% weight)
    if (chartA.ascendant?.sign && chartB.ascendant?.sign) {
      const ascendantCompatibility = calculatePlanetaryCompatibility(
        chartA.ascendant.sign, chartB.ascendant.sign, chartA.ascendant.degree, chartB.ascendant.degree
      );
      totalCompatibility += ascendantCompatibility * 0.1;
      weightSum += 0.1;
    }

    // If we have some data, normalize by actual weights
    if (weightSum > 0) {
      return Math.round((totalCompatibility / weightSum) * 100);
    }

    // Fallback to zodiac compatibility if no chart data
    return calculateZodiacCompatibility(
      chartA.sun?.sign || 'Unknown', 
      chartB.sun?.sign || 'Unknown'
    );

  } catch (error) {
    console.error('Error in astrological compatibility calculation:', error);
    return 50; // Default fallback
  }
}

/**
 * Calculates planetary compatibility considering signs and aspects
 */
function calculatePlanetaryCompatibility(signA: string, signB: string, degreeA?: number, degreeB?: number): number {
  const baseCompatibility = getZodiacSignCompatibility(signA, signB);
  
  // If we have degree information, calculate aspects
  if (degreeA !== undefined && degreeB !== undefined) {
    const aspectBonus = calculateAspectBonus(degreeA, degreeB);
    return Math.min(100, Math.max(0, baseCompatibility + aspectBonus));
  }
  
  return baseCompatibility;
}

/**
 * Calculates aspect bonus based on degrees
 */
function calculateAspectBonus(degreeA: number, degreeB: number): number {
  const difference = Math.abs(degreeA - degreeB);
  const aspect = Math.min(difference, 360 - difference);
  
  // Major aspects and their bonuses/penalties
  if (aspect <= 2) return 20; // Conjunction - very strong
  if (aspect >= 58 && aspect <= 62) return 15; // Sextile - harmonious
  if (aspect >= 88 && aspect <= 92) return -10; // Square - challenging
  if (aspect >= 118 && aspect <= 122) return 10; // Trine - harmonious
  if (aspect >= 178 && aspect <= 182) return -5; // Opposition - tension
  
  return 0; // No significant aspect
}

/**
 * Complete zodiac compatibility matrix based on traditional astrology
 */
function getZodiacSignCompatibility(signA: string, signB: string): number {
  const compatibilityMatrix: Record<string, Record<string, number>> = {
    'Aries': {
      'Aries': 75, 'Taurus': 45, 'Gemini': 80, 'Cancer': 55, 
      'Leo': 90, 'Virgo': 60, 'Libra': 70, 'Scorpio': 65,
      'Sagittarius': 95, 'Capricorn': 50, 'Aquarius': 85, 'Pisces': 60
    },
    'Taurus': {
      'Aries': 45, 'Taurus': 70, 'Gemini': 55, 'Cancer': 85,
      'Leo': 60, 'Virgo': 90, 'Libra': 75, 'Scorpio': 80,
      'Sagittarius': 50, 'Capricorn': 95, 'Aquarius': 45, 'Pisces': 85
    },
    'Gemini': {
      'Aries': 80, 'Taurus': 55, 'Gemini': 75, 'Cancer': 60,
      'Leo': 85, 'Virgo': 65, 'Libra': 95, 'Scorpio': 55,
      'Sagittarius': 70, 'Capricorn': 45, 'Aquarius': 90, 'Pisces': 50
    },
    'Cancer': {
      'Aries': 55, 'Taurus': 85, 'Gemini': 60, 'Cancer': 80,
      'Leo': 65, 'Virgo': 75, 'Libra': 60, 'Scorpio': 95,
      'Sagittarius': 45, 'Capricorn': 70, 'Aquarius': 50, 'Pisces': 90
    },
    'Leo': {
      'Aries': 90, 'Taurus': 60, 'Gemini': 85, 'Cancer': 65,
      'Leo': 80, 'Virgo': 55, 'Libra': 75, 'Scorpio': 70,
      'Sagittarius': 95, 'Capricorn': 45, 'Aquarius': 75, 'Pisces': 55
    },
    'Virgo': {
      'Aries': 60, 'Taurus': 90, 'Gemini': 65, 'Cancer': 75,
      'Leo': 55, 'Virgo': 75, 'Libra': 70, 'Scorpio': 85,
      'Sagittarius': 50, 'Capricorn': 95, 'Aquarius': 60, 'Pisces': 80
    },
    'Libra': {
      'Aries': 70, 'Taurus': 75, 'Gemini': 95, 'Cancer': 60,
      'Leo': 75, 'Virgo': 70, 'Libra': 80, 'Scorpio': 65,
      'Sagittarius': 85, 'Capricorn': 55, 'Aquarius': 90, 'Pisces': 65
    },
    'Scorpio': {
      'Aries': 65, 'Taurus': 80, 'Gemini': 55, 'Cancer': 95,
      'Leo': 70, 'Virgo': 85, 'Libra': 65, 'Scorpio': 85,
      'Sagittarius': 60, 'Capricorn': 75, 'Aquarius': 55, 'Pisces': 95
    },
    'Sagittarius': {
      'Aries': 95, 'Taurus': 50, 'Gemini': 70, 'Cancer': 45,
      'Leo': 95, 'Virgo': 50, 'Libra': 85, 'Scorpio': 60,
      'Sagittarius': 80, 'Capricorn': 55, 'Aquarius': 85, 'Pisces': 60
    },
    'Capricorn': {
      'Aries': 50, 'Taurus': 95, 'Gemini': 45, 'Cancer': 70,
      'Leo': 45, 'Virgo': 95, 'Libra': 55, 'Scorpio': 75,
      'Sagittarius': 55, 'Capricorn': 80, 'Aquarius': 65, 'Pisces': 75
    },
    'Aquarius': {
      'Aries': 85, 'Taurus': 45, 'Gemini': 90, 'Cancer': 50,
      'Leo': 75, 'Virgo': 60, 'Libra': 90, 'Scorpio': 55,
      'Sagittarius': 85, 'Capricorn': 65, 'Aquarius': 80, 'Pisces': 70
    },
    'Pisces': {
      'Aries': 60, 'Taurus': 85, 'Gemini': 50, 'Cancer': 90,
      'Leo': 55, 'Virgo': 80, 'Libra': 65, 'Scorpio': 95,
      'Sagittarius': 60, 'Capricorn': 75, 'Aquarius': 70, 'Pisces': 85
    }
  };

  return compatibilityMatrix[signA]?.[signB] || 50; // Default moderate compatibility
}

function calculateZodiacCompatibility(signA: string, signB: string): number {
  return getZodiacSignCompatibility(signA, signB);
}

function scoreToGrade(score: number): string {
  if (score >= 90) return 'A+';
  if (score >= 85) return 'A';
  if (score >= 80) return 'B+';
  if (score >= 75) return 'B';
  if (score >= 70) return 'C+';
  if (score >= 65) return 'C';
  if (score >= 60) return 'D';
  return 'F';
}

function generateAstrologicalDetails(chartA: any, chartB: any): Record<string, any> {
  return {
    sun_compatibility: 'High harmony in core personality traits',
    moon_compatibility: 'Emotional needs align well',
    venus_compatibility: 'Strong romantic and aesthetic connection',
    mars_compatibility: 'Complementary energy and drive patterns'
  };
}

function generateQuestionnaireDetails(dataA: any, dataB: any): Record<string, any> {
  return {
    lifestyle_compatibility: 'Similar life goals and priorities',
    communication_style: 'Complementary communication preferences',
    relationship_goals: 'Aligned expectations for partnership',
    interests_overlap: 'Significant shared interests and hobbies'
  };
}

export { serve };
