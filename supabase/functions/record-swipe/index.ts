import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';

// ENHANCED SECURITY: Import additional security layers
import { 
  applyAdvancedSecurityMiddleware,
  validateAdvancedInput,
  safeTimeComparison,
  getAdvancedSecurityHeaders
} from '../_shared/security-enhancements-v2.ts';

import { serve } from 'std/http/server.ts'; // Using import map
import { createClient, SupabaseClient } from '@supabase/supabase-js'; // Using import map
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts'; 
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
import { sendPushNotification } from '../_shared/sendPushNotification.ts';
import { logSecurityEvent, SecurityEventType, SecuritySeverity } from '../_shared/security-monitoring.ts';
import { createErrorResponse, createSecureErrorResponse, EnhancedErrorContext } from '../_shared/enhanced-error-handler.ts';
import { csrfMiddleware } from '../_shared/csrf-protection.ts';

// ENHANCED SECURITY: Comprehensive Zod Schema with advanced validation
const SwipePayloadSchema = z.object({
  swiped_id: z.string()
    .uuid('Invalid UUID format for swiped_id')
    .refine((id) => {
      // Additional UUID security validation
      const validation = validateAdvancedInput(id, 'swiped_id', 'uuid');
      return validation.valid && validation.riskLevel < 3;
    }, 'swiped_id failed security validation'),
    
  swipe_type: z.enum(['like', 'pass'], {
    required_error: 'swipe_type is required',
    invalid_type_error: 'swipe_type must be either "like" or "pass"'
  }),
  
  // Optional metadata for enhanced security tracking
  client_timestamp: z.number().optional(),
  device_info: z.string().max(100).optional(),
}).strict(); // Reject unknown fields

// CORS Headers
const corsHeaders = {
  'Access-Control-Allow-Origin': '*', // Adjust for production
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Match record structure aligned with database schema
interface Match {
  id: string;
  user1_id: string;
  user2_id: string;
  match_request_id?: string | null;
  conversation_id?: string | null;
  matched_at: string;
  status: 'active' | 'inactive' | 'blocked';
  /** Integer compatibility score (0-100) - matches PostgreSQL INTEGER type */
  compatibility_score?: number | null;
  created_at: string;
  updated_at: string;
}

// Helper functions following Single Responsibility Principle

/**
 * Create match request for mutual likes
 * Follows: Single Responsibility, Fail Fast principles
 */
async function createMatchRequest(
  supabaseClient: SupabaseClient,
  swiperId: string,
  swipedId: string
): Promise<{ id: string } | null> {
  try {
    const { data: matchRequest, error } = await supabaseClient
      .from('match_requests')
      .insert({
        requester_id: swiperId,
        matched_user_id: swipedId,
        status: 'confirmed',
        compatibility_score: 75,
        compatibility_details: {}
      })
      .select('id')
      .single();

    if (error) throw error;
    return matchRequest;
  } catch (error) {
    console.error('Failed to create match request:', error);
    return null;
  }
}

/**
 * Create new match record
 * Follows: Single Responsibility, Dependency Injection principles
 */
async function createMatch(
  supabaseClient: SupabaseClient,
  user1Id: string,
  user2Id: string,
  matchRequestId?: string
): Promise<Match | null> {
  try {
    const { data: newMatch, error } = await supabaseClient
      .from('matches')
      .insert({ 
        user1_id: user1Id, 
        user2_id: user2Id, 
        status: 'active',
        match_request_id: matchRequestId || null,
        compatibility_score: 75,
        astro_compatibility: {},
        questionnaire_compatibility: {}
      }) 
      .select('id, user1_id, user2_id, matched_at, conversation_id') 
      .single();

    if (error) throw error;
    return newMatch as Match;
  } catch (error) {
    console.error('Failed to create match:', error);
    return null;
  }
}

/**
 * Send match notifications to both users
 * Follows: Single Responsibility, Least Surprise principles
 */
async function sendMatchNotifications(
  supabaseClient: SupabaseClient,
  user1Id: string,
  user2Id: string,
  matchId: string,
  conversationId: string
): Promise<void> {
  try {
    const [{ data: user1Profile }, { data: user2Profile }] = await Promise.all([
      supabaseClient
        .from('profiles')
        .select('push_token, display_name')
        .eq('id', user1Id)
        .single(),
      supabaseClient
        .from('profiles')
        .select('push_token, display_name')
        .eq('id', user2Id)
        .single()
    ]);
    
    const notificationPromises = [];
    
    if (user1Profile?.push_token && user2Profile?.display_name) {
      notificationPromises.push(
        sendPushNotification(
          user1Profile.push_token,
          "🎉 It's a Match!",
          `You and ${user2Profile.display_name} liked each other!`,
          {
            type: 'match_created',
            match_id: matchId,
            conversation_id: conversationId,
            other_user_id: user2Id
          }
        )
      );
    }
    
    if (user2Profile?.push_token && user1Profile?.display_name) {
      notificationPromises.push(
        sendPushNotification(
          user2Profile.push_token,
          "🎉 It's a Match!",
          `You and ${user1Profile.display_name} liked each other!`,
          {
            type: 'match_created',
            match_id: matchId,
            conversation_id: conversationId,
            other_user_id: user1Id
          }
        )
      );
    }
    
    await Promise.allSettled(notificationPromises);
  } catch (error) {
    console.error('Failed to send match notifications:', error);
    // Non-blocking - don't throw
  }
}

serve(async (req: Request) => {
  // ENHANCED SECURITY: Apply advanced security middleware first
  const securityCheck = await applyAdvancedSecurityMiddleware(req, undefined, {
    requireFingerprinting: true,
    enableBehaviorAnalysis: true,
    enforceCSP: true,
    preventTimingAttacks: true
  });
  
  if (!securityCheck.allowed) {
    return securityCheck.response!;
  }

  // Apply enhanced rate limiting with behavioral analysis
  const rateLimitResult = await applyRateLimit(req, '/record-swipe', undefined, RateLimitCategory.MATCHING);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response!;
  }

  // PHASE 4 SECURITY: CSRF Protection for state-changing operations
  const csrfValidation = await csrfMiddleware.validateCSRF(req);
  if (!csrfValidation.valid) {
    await logSecurityEvent(
      SecurityEventType.SUSPICIOUS_PATTERN,
      SecuritySeverity.HIGH,
      {
        endpoint: 'record-swipe',
        reason: 'CSRF validation failed',
        csrfFailure: true
      },
      {
        ip: req.headers.get('x-forwarded-for') || req.headers.get('x-real-ip'),
        userAgent: req.headers.get('User-Agent'),
        endpoint: 'record-swipe'
      }
    );
    return csrfValidation.response;
  }

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  // Create enhanced error context for better error handling
  const errorContext: EnhancedErrorContext = {
    requestId: crypto.randomUUID(),
    endpoint: '/record-swipe',
    startTime: Date.now(),
    retryCount: 0,
    userAgent: req.headers.get('User-Agent') || undefined,
    ip: req.headers.get('x-forwarded-for') || req.headers.get('x-real-ip') || undefined,
  };

  let supabaseClient: SupabaseClient;
  
  try {
    // CRITICAL SECURITY: Secure JWT validation to prevent Algorithm Confusion Attack
    const userAuthHeader = req.headers.get('Authorization');
    if (!userAuthHeader) {
      await logSecurityEvent(
        SecurityEventType.UNAUTHORIZED_ACCESS,
        SecuritySeverity.MEDIUM,
        {
          endpoint: 'record-swipe',
          reason: 'missing_auth_header',
          userAgent: req.headers.get('User-Agent')
        },
        {
          ip: errorContext.ip,
          userAgent: errorContext.userAgent,
          endpoint: errorContext.endpoint,
          requestId: errorContext.requestId
        }
      );
      
      return createSecureErrorResponse(
        { code: 'invalid_grant', message: 'Missing authorization' },
        errorContext,
        corsHeaders
      );
    }

    // CRITICAL SECURITY: Validate JWT to prevent "none" algorithm attacks
    const jwtValidation = validateJWTHeader(userAuthHeader);
    if (!jwtValidation.valid) {
      await logSecurityEvent(
        SecurityEventType.UNAUTHORIZED_ACCESS,
        jwtValidation.securityRisk === 'high' ? SecuritySeverity.CRITICAL : SecuritySeverity.HIGH,
        {
          endpoint: 'record-swipe',
          error: jwtValidation.error,
          securityRisk: jwtValidation.securityRisk,
          userAgent: req.headers.get('User-Agent')
        },
        {
          ip: errorContext.ip,
          userAgent: errorContext.userAgent,
          endpoint: errorContext.endpoint,
          requestId: errorContext.requestId
        }
      );
      
      return createSecureErrorResponse(
        { 
          code: 'invalid_grant', 
          message: jwtValidation.securityRisk === 'high' 
            ? 'Security violation detected' 
            : 'Invalid authorization token'
        },
        errorContext,
        corsHeaders
      );
    }

    // Create secure Supabase client after JWT validation
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

    if (!supabaseUrl || !supabaseAnonKey) {
      await logSecurityEvent(
        SecurityEventType.SUSPICIOUS_PATTERN,
        SecuritySeverity.CRITICAL,
        {
          endpoint: 'record-swipe',
          issue: 'missing_env_vars',
          error: 'Server configuration error'
        },
        {
          endpoint: errorContext.endpoint,
          requestId: errorContext.requestId
        }
      );
      
      return createSecureErrorResponse(
        { code: 'server_error', message: 'Server configuration error' },
        errorContext,
        corsHeaders
      );
    }

    const secureClientResult = await createSecureSupabaseClient(
      userAuthHeader,
      supabaseUrl,
      supabaseAnonKey
    );

    if (secureClientResult.error || !secureClientResult.client) {
      await logSecurityEvent(
        SecurityEventType.SUSPICIOUS_PATTERN,
        SecuritySeverity.HIGH,
        {
          endpoint: 'record-swipe',
          error: secureClientResult.error,
          securityDetails: secureClientResult.securityDetails,
          phase: 'secure_client_creation_failed'
        },
        {
          endpoint: errorContext.endpoint,
          requestId: errorContext.requestId
        }
      );
      
      return createSecureErrorResponse(
        { code: 'server_error', message: 'Failed to create secure database connection' },
        errorContext,
        corsHeaders
      );
    }

    supabaseClient = secureClientResult.client;
    
  } catch (e: any) {
    await logSecurityEvent(
      SecurityEventType.SUSPICIOUS_PATTERN,
      SecuritySeverity.CRITICAL,
      {
        endpoint: 'record-swipe',
        error: e.message,
        stack: e.stack,
        phase: 'initialization_error'
      },
      {
        endpoint: errorContext.endpoint,
        requestId: errorContext.requestId
      }
    );
    
    return createSecureErrorResponse(
      { code: 'server_error', message: 'Failed to initialize secure connection' },
      errorContext,
      corsHeaders
    );
  }
  
  const { data: { user }, error: userError } = await supabaseClient.auth.getUser();

  if (userError || !user) {
    await logSecurityEvent(
      SecurityEventType.UNAUTHORIZED_ACCESS,
      SecuritySeverity.HIGH,
      {
        endpoint: 'record-swipe',
        error: userError?.message || 'No user found in token',
        phase: 'user_authentication'
      },
      {
        endpoint: errorContext.endpoint,
        requestId: errorContext.requestId
      }
    );
    
    return createSecureErrorResponse(
      { code: 'invalid_grant', message: 'User not authenticated or token invalid' },
      errorContext,
      corsHeaders
    );
  }
  
  // Update error context with user information
  errorContext.userId = user.id;

  try {
    // ENHANCED SECURITY: Parse and validate request body with timing protection
    const { body, validatedPayload } = await safeTimeComparison(async () => {
      const body = await req.json();
      
      // Apply advanced security validation to the entire payload
      const securityValidation = await applyAdvancedSecurityMiddleware(req, body);
      if (!securityValidation.allowed) {
        throw new Error('Payload security validation failed');
      }
      
      const validatedPayload = SwipePayloadSchema.parse(body);
      return { body, validatedPayload };
    }, 50); // Minimum 50ms to prevent timing attacks

    const swiper_id = user.id;
    const { swiped_id, swipe_type } = validatedPayload;

    // ENHANCED SECURITY: Comprehensive validation with enhanced headers
    if (swiper_id === swiped_id) {
      const securityHeaders = getAdvancedSecurityHeaders('json', false);
      
      return new Response(JSON.stringify({ 
        error: 'Invalid swipe request',
        message: 'User cannot swipe on themselves',
        timestamp: new Date().toISOString(),
        requestId: errorContext.requestId
      }), {
        headers: { 
          ...corsHeaders, 
          ...securityHeaders,
          'Content-Type': 'application/json' 
        }, 
        status: 400,
      });
    }

    // Verify that the swiped user exists
    const { data: swipedUser, error: swipedUserError } = await supabaseClient
      .from('profiles')
      .select('id')
      .eq('id', swiped_id)
      .single();

    if (swipedUserError || !swipedUser) {
      return new Response(JSON.stringify({ error: 'Target user not found.' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 404,
      });
    }

    const { data: swipeData, error: swipeError } = await supabaseClient
      .from('swipes')
      .insert({ swiper_id, swiped_id, swipe_type })
      .select()
      .single();

    if (swipeError) {
      await logSecurityEvent(
        SecurityEventType.SUSPICIOUS_PATTERN,
        swipeError.code === '23505' ? SecuritySeverity.LOW : SecuritySeverity.MEDIUM,
        {
          endpoint: 'record-swipe',
          operation: 'insert_swipe',
          error: swipeError.message,
          code: swipeError.code,
          swiper_id,
          swiped_id
        },
        {
          userId: user.id,
          endpoint: errorContext.endpoint,
          requestId: errorContext.requestId
        }
      );

      if (swipeError.code === '23505') { 
        return createSecureErrorResponse(
          { code: 'duplicate_swipe', message: 'User has already swiped on this profile.' },
          errorContext,
          corsHeaders
        );
      }
      
      return createSecureErrorResponse(
        { 
          code: 'swipe_record_failed', 
          message: 'Failed to record swipe',
          details: swipeError.message 
        },
        errorContext,
        corsHeaders
      );
    }
    if (!swipeData) {
      await logSecurityEvent(
        SecurityEventType.SUSPICIOUS_PATTERN,
        SecuritySeverity.MEDIUM,
        {
          endpoint: 'record-swipe',
          operation: 'insert_swipe',
          error: 'No data returned from swipe insertion',
          swiper_id,
          swiped_id
        },
        {
          userId: user.id,
          endpoint: errorContext.endpoint,
          requestId: errorContext.requestId
        }
      );
      
      return createSecureErrorResponse(
        { code: 'swipe_data_missing', message: 'Failed to record swipe: No data returned from database.' },
        errorContext,
        corsHeaders
      );
    }

    let matchResult: { match_created: boolean; match_details: Match | null } = {
      match_created: false,
      match_details: null,
    };

    if (swipe_type === 'like') {
      const { data: mutualLike, error: mutualLikeError } = await supabaseClient
        .from('swipes')
        .select('id')
        .eq('swiper_id', swiped_id)
        .eq('swiped_id', swiper_id)
        .eq('swipe_type', 'like')
        .maybeSingle(); 

      if (mutualLikeError) {
        await logSecurityEvent(
          SecurityEventType.SUSPICIOUS_PATTERN,
          SecuritySeverity.LOW,
          {
            endpoint: 'record-swipe',
            operation: 'check_mutual_like',
            error: mutualLikeError.message,
            swiper_id,
            swiped_id
          },
          {
            userId: user.id,
            endpoint: errorContext.endpoint,
            requestId: errorContext.requestId
          }
        );
        // Continue without creating match if mutual like check fails
        // The swipe was still recorded successfully
      }

      if (mutualLike && !mutualLikeError) {
        const user1 = swiper_id < swiped_id ? swiper_id : swiped_id;
        const user2 = swiper_id < swiped_id ? swiped_id : swiper_id;

        // Optionally create a match request record (best-effort)
        const matchRequest = await createMatchRequest(supabaseClient, swiper_id, swiped_id);

        // Atomically confirm match and create/fetch conversation via RPC
        const { data: confirmData, error: confirmError } = await supabaseClient
          .rpc('confirm_system_match', {
            p_current_user_id: swiper_id,
            p_target_user_id: swiped_id,
            p_source_match_request_id: matchRequest?.id || null
          });

        if (confirmError) {
          await logSecurityEvent(
            SecurityEventType.SUSPICIOUS_PATTERN,
            SecuritySeverity.MEDIUM,
            {
              endpoint: 'record-swipe',
              operation: 'confirm_system_match',
              error: confirmError.message,
              user1,
              user2
            },
            {
              userId: user.id,
              endpoint: errorContext.endpoint,
              requestId: errorContext.requestId
            }
          );
        } else if (confirmData && Array.isArray(confirmData) && confirmData.length > 0) {
          const { match_id, conversation_id } = confirmData[0] as { match_id: string; conversation_id: string | null };
          matchResult = {
            match_created: true,
            match_details: {
              id: match_id,
              user1_id: user1,
              user2_id: user2,
              conversation_id: conversation_id || null,
              matched_at: new Date().toISOString(),
              status: 'active',
              created_at: new Date().toISOString(),
              updated_at: new Date().toISOString()
            } as Match
          };

          // Send match notifications (non-blocking)
          if (conversation_id) {
            await sendMatchNotifications(
              supabaseClient,
              user1,
              user2,
              match_id,
              conversation_id
            );
          }
        }
      } else {
        // No mutual like found - send notification for a regular like (non-mutual)
        try {
          const { data: swipedUserProfile } = await supabaseClient
            .from('profiles')
            .select('push_token, display_name')
            .eq('id', swiped_id)
            .single();
            
          const { data: swiperProfile } = await supabaseClient
            .from('profiles')
            .select('display_name')
            .eq('id', swiper_id)
            .single();
          
          if (swipedUserProfile?.push_token && swiperProfile?.display_name) {
            await sendPushNotification(
              swipedUserProfile.push_token,
              "💝 Someone likes you!",
              `${swiperProfile.display_name} sent you a like!`,
              {
                type: 'like_received',
                from_user_id: swiper_id,
                swipe_id: swipeData.id
              }
            );
          }
        } catch (likeNotificationError) {
          await logSecurityEvent(
            SecurityEventType.SUSPICIOUS_PATTERN,
            SecuritySeverity.LOW,
            {
              endpoint: 'record-swipe',
              operation: 'send_like_notification',
              error: likeNotificationError.message,
              swiper_id,
              swiped_id
            },
            {
              userId: user.id,
              endpoint: errorContext.endpoint,
              requestId: errorContext.requestId
            }
          );
        }
      }
    }

    // ENHANCED SECURITY: Return response with comprehensive security headers
    const securityHeaders = getAdvancedSecurityHeaders('json', true); // Has user data
    
    return new Response(JSON.stringify({ 
      swipe: swipeData, 
      match: matchResult,
      metadata: {
        timestamp: new Date().toISOString(),
        requestId: errorContext.requestId
      }
    }), {
      headers: { 
        ...corsHeaders, 
        ...securityHeaders,
        'Content-Type': 'application/json' 
      },
      status: 201, 
    });

  } catch (e) {
    await logSecurityEvent(
      SecurityEventType.SUSPICIOUS_PATTERN,
      SecuritySeverity.HIGH,
      {
        endpoint: 'record-swipe',
        operation: 'main_function_error',
        error: e instanceof Error ? e.message : 'Unknown error',
        stack: e instanceof Error ? e.stack : undefined,
        type: e instanceof Error ? e.constructor.name : typeof e,
        isZodError: e instanceof ZodError
      },
      {
        userId: errorContext.userId,
        endpoint: errorContext.endpoint,
        requestId: errorContext.requestId
      }
    );

    const errorMessage = e instanceof Error ? e.message : 'An unexpected error occurred.';
    const errorDetails = e instanceof ZodError ? e.flatten() : undefined;
    
    return createSecureErrorResponse(
      {
        code: e instanceof ZodError ? 'validation_error' : 'server_error',
        message: errorMessage,
        details: errorDetails
      },
      errorContext,
      corsHeaders
    );
  }
});
