import { serve } from 'std/http/server.ts';
import { corsHeaders } from '../_shared/cors.ts';
import { supabaseAdmin } from '../_shared/supabaseAdmin.ts';
import { getCachedData } from '../_shared/redis-enhanced.ts';
import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';
import { 
  handleError, 
  createErrorContext, 
  EdgeFunctionError, 
  ErrorCode,
  validateEnvironment 
} from '../_shared/error-handler.ts';
import { applyRateLimit } from '../_shared/rate-limit-enhancements.ts';
import { getRateLimitHeaders } from '../_shared/rate-limit-middleware.ts';
import { withDatabaseCircuitBreaker } from '../_shared/circuit-breaker.ts';

const CACHE_TTL = 24 * 60 * 60; // 24 hours for compatibility data

// This interface should align with what CompatibilityScreenContent expects
interface CompatibilityDetails {
  astrologicalGrade?: string;
  astrologicalDesc?: string;
  questionnaireGrade?: string;
  questionnaireDesc?: string;
  overallScore?: string; // e.g., "82%"
  overallDesc?: string;
}

// Helper to map grades to descriptions (example)
function getGradeDescription(grade?: string): string | undefined {
  if (!grade) return undefined;
  // Normalize grade by removing '+' or '-' if present for broader matching
  const normalizedGrade = grade.toUpperCase().replace('+', '').replace('-', '');
  switch (normalizedGrade) {
    case 'A': return 'Excellent';
    case 'B': return 'Good';
    case 'C': return 'Average';
    case 'D': return 'Below Average';
    case 'F': return 'Poor';
    default: return 'Notable'; // Fallback for unexpected grades
  }
}

// Function to fetch and calculate real compatibility data
async function fetchCompatibilityFromDB(
  currentUserId: string, 
  matchUserId: string
): Promise<CompatibilityDetails> {
  // Validate and sanitize input parameters
  if (!validateUUID(currentUserId) || !validateUUID(matchUserId)) {
    throw new EdgeFunctionError(
      ErrorCode.INVALID_INPUT,
      'Invalid user ID format',
      createErrorContext('fetchCompatibilityFromDB', null),
      400
    );
  }

  // SECURITY: Check if users are authorized to view each other's compatibility
  // Only allow if users have matched or have mutual interaction
  const { data: authCheck, error: authError } = await withDatabaseCircuitBreaker(() =>
    supabaseAdmin
      .from('matches')
      .select('id, status')
      .eq('user1_id', currentUserId)
      .eq('user2_id', matchUserId)
      .eq('status', 'active')
      .limit(1)
      .maybeSingle()
  );

  const { data: authCheck2, error: authError2 } = await withDatabaseCircuitBreaker(() =>
    supabaseAdmin
      .from('matches')
      .select('id, status')
      .eq('user1_id', matchUserId)
      .eq('user2_id', currentUserId)
      .eq('status', 'active')
      .limit(1)
      .maybeSingle()
  );

  // If no match relationship exists, deny access
  if ((!authCheck || !authCheck.id) && (!authCheck2 || !authCheck2.id)) {
    throw new EdgeFunctionError(
      ErrorCode.UNAUTHORIZED,
      'Not authorized to view compatibility data for these users',
      createErrorContext('fetchCompatibilityFromDB', null),
      403
    );
  }

  // First try to get existing calculated data from matches table using secure query
  const { data: matchData, error: dbError } = await withDatabaseCircuitBreaker(() =>
    supabaseAdmin
      .from('matches')
      .select('calculation_result, overall_score, questionnaire_grade, astrological_grade')
      .eq('user1_id', currentUserId)
      .eq('user2_id', matchUserId)
      .limit(1)
      .maybeSingle()
  );

  // Also check the reverse relationship
  let reverseMatchData = null;
  if (!matchData || !matchData.calculation_result) {
    const { data: reverseData, error: reverseError } = await withDatabaseCircuitBreaker(() =>
      supabaseAdmin
        .from('matches')
        .select('calculation_result, overall_score, questionnaire_grade, astrological_grade')
        .eq('user1_id', matchUserId)
        .eq('user2_id', currentUserId)
        .limit(1)
        .maybeSingle()
    );
    reverseMatchData = reverseData;
  }

  const finalMatchData = matchData || reverseMatchData;

  // If we have cached results, use them (but fall back to calculation if needed)
  if (finalMatchData && finalMatchData.calculation_result) {
    const calcResult = finalMatchData.calculation_result as any;

    // Robustly extract grades across historical shapes
    const extractLetter = (val: any): string | undefined => {
      if (!val) return undefined;
      const s = String(val).toUpperCase();
      // Accept single-letter grades optionally with +/-; normalize to base letter
      // UI expects base letter grade; trim whitespace just in case
      return s.trim();
    };

    const astroGrade = extractLetter(
      calcResult.AstrologicalGrade ||
      calcResult.astrological_grade ||
      calcResult.astrology_grade ||
      calcResult?.astrological_details?.grade ||
      calcResult?.astrological_details?.Grade
    ) || 'N/A';

    const questGrade = extractLetter(
      calcResult.QuestionnaireGrade ||
      calcResult.questionnaire_grade ||
      calcResult?.questionnaire_details?.grade ||
      calcResult?.questionnaire_details?.Grade
    ) || 'N/A';

    const overall = (
      typeof calcResult.overallScore === 'number' ? calcResult.overallScore :
      typeof calcResult.overall_score === 'number' ? calcResult.overall_score :
      undefined
    );

    return {
      astrologicalGrade: astroGrade,
      astrologicalDesc: getGradeDescription(astroGrade),
      questionnaireGrade: questGrade,
      questionnaireDesc: getGradeDescription(questGrade),
      overallScore: typeof overall === 'number' ? `${Math.round(overall)}%` : 'N/A',
      overallDesc: calcResult.IsMatchRecommended ? 'Recommended' : getGradeDescription(
        typeof overall === 'number' ? (overall > 80 ? 'A' : (overall > 60 ? 'B' : 'C')) : undefined
      )
    };
  }
  
  // No cached data or database error - calculate compatibility in real-time
  return await calculateRealTimeCompatibility(currentUserId, matchUserId);
}

// Function to calculate compatibility in real-time using the new algorithms
async function calculateRealTimeCompatibility(
  currentUserId: string, 
  matchUserId: string
): Promise<CompatibilityDetails> {
  // Import the compatibility functions
  const { calculateUserCompatibility, createUserProfileFromDbData, calculateCombinedScore, gradeToScore } = await import('../_shared/compatibility-orchestrator.ts');
  
  // Fetch user data for both users
  const { data: userData, error: userError } = await withDatabaseCircuitBreaker(() =>
    supabaseAdmin
      .from('users')
      .select(`
        id, display_name, name, birth_date, birth_location, birth_time, 
        natal_chart_data, questionnaire_responses, preferences,
        sun_sign, moon_sign, rising_sign
      `)
      .in('id', [currentUserId, matchUserId])
  );

  if (userError || !userData || userData.length !== 2) {
    // Fallback to mock data if user data is unavailable
    return {
      astrologicalGrade: 'N/A',
      astrologicalDesc: 'Data Unavailable',
      questionnaireGrade: 'N/A', 
      questionnaireDesc: 'Data Unavailable',
      overallScore: 'N/A',
      overallDesc: 'Unable to Calculate'
    };
  }

  // Create user profiles
  const user1Data = userData.find(u => u.id === currentUserId);
  const user2Data = userData.find(u => u.id === matchUserId);
  
  if (!user1Data || !user2Data) {
    return {
      astrologicalGrade: 'N/A',
      astrologicalDesc: 'User Data Missing',
      questionnaireGrade: 'N/A',
      questionnaireDesc: 'User Data Missing',
      overallScore: 'N/A',
      overallDesc: 'Unable to Calculate'
    };
  }

  const user1Profile = createUserProfileFromDbData(user1Data);
  const user2Profile = createUserProfileFromDbData(user2Data);

  // Calculate compatibility using the new algorithms
  const matchResult = calculateUserCompatibility(user1Profile, user2Profile);
  
  // Calculate combined score (40% astro + 60% questionnaire)
  const astroScore = gradeToScore(matchResult.astrologicalGrade);
  const questScore = gradeToScore(matchResult.questionnaireGrade);
  const combinedScore = calculateCombinedScore(astroScore, questScore);
  
  return {
    astrologicalGrade: matchResult.astrologicalGrade,
    astrologicalDesc: getGradeDescription(matchResult.astrologicalGrade),
    questionnaireGrade: matchResult.questionnaireGrade,
    questionnaireDesc: getGradeDescription(matchResult.questionnaireGrade),
    overallScore: `${Math.round(combinedScore)}%`,
    overallDesc: matchResult.isMatchRecommended ? 'Recommended' : getGradeDescription(combinedScore > 80 ? 'A' : (combinedScore > 60 ? 'B' : 'C'))
  };
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  // Validate required environment variables
  validateEnvironment(['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY']);

  try {
    // 1. Authenticate the user and get currentUserId from JWT
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      throw new EdgeFunctionError(
        ErrorCode.UNAUTHORIZED,
        'Missing Authorization header',
        createErrorContext('get-compatibility-details', req),
        401
      );
    }
    
    const { data: { user }, error: userError } = await withDatabaseCircuitBreaker(() =>
      supabaseAdmin.auth.getUser(authHeader.replace('Bearer ', ''))
    );
    
    if (userError || !user) {
      throw new EdgeFunctionError(
        ErrorCode.UNAUTHORIZED,
        'Invalid or missing authentication token',
        createErrorContext('get-compatibility-details', req),
        401,
        userError
      );
    }
    
    const currentUserId = user.id;

    // COMPREHENSIVE RATE LIMITING
    const rateLimitResult = await applyRateLimit(req, '/get-compatibility-details', currentUserId);
    
    if (!rateLimitResult.allowed) {
      return rateLimitResult.response;
    }

    // 2. Get matchUserId from request body with validation
    const requestBody = await req.json();
    const { matchUserId } = requestBody;
    
    if (!matchUserId) {
      throw new EdgeFunctionError(
        ErrorCode.MISSING_REQUIRED_FIELD,
        'matchUserId is required in request body',
        createErrorContext('get-compatibility-details', req, currentUserId),
        400
      );
    }

    // SECURITY: Validate UUID format to prevent SQL injection
    if (!validateUUID(matchUserId)) {
      throw new EdgeFunctionError(
        ErrorCode.INVALID_INPUT,
        'Invalid matchUserId format',
        createErrorContext('get-compatibility-details', req, currentUserId),
        400
      );
    }

    // SECURITY: Prevent users from requesting their own compatibility
    if (currentUserId === matchUserId) {
      throw new EdgeFunctionError(
        ErrorCode.INVALID_INPUT,
        'Cannot request compatibility with yourself',
        createErrorContext('get-compatibility-details', req, currentUserId),
        400
      );
    }

    // 3. Create consistent cache key (sorted user IDs for consistency)
    const cacheKey = `compatibility:${[currentUserId, matchUserId].sort().join(':')}`;

    // 4. Get compatibility data with Redis caching
    const compatibilityData = await getCachedData(
      cacheKey,
      CACHE_TTL,
      () => fetchCompatibilityFromDB(currentUserId, matchUserId),
      ['compatibility', 'user-data']
    );

    return new Response(JSON.stringify(compatibilityData), {
      headers: { 
        ...corsHeaders, 
        'Content-Type': 'application/json',
        'X-Cache-Key': cacheKey.split(':')[0], // For debugging
        ...(rateLimitResult.rateLimitInfo ? getRateLimitHeaders(rateLimitResult.rateLimitInfo) : {})
      },
      status: 200,
    });

  } catch (error) {
    return handleError(
      error,
      createErrorContext('get-compatibility-details', req)
    );
  }
});
