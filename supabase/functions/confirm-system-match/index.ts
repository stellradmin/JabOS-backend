import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';

// deno-lint-ignore-file no-explicit-any
import { serve } from 'std/http/server.ts'; // Using import map
import { createClient, SupabaseClient } from '@supabase/supabase-js'; // Using import map
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts'; // Zod often used directly
import { sendPushNotification } from '../_shared/sendPushNotification.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
import {
  EnhancedErrorHandler,
  RetryableOperation,
  FallbackStrategy,
  GracefulDegradationManager
} from '../_shared/enhanced-error-handler.ts';

// Zod Schema for Input Validation
const ConfirmSystemMatchPayloadSchema = z.object({
  target_user_id: z.string().uuid(), // The ID of the user suggested by the system and accepted by the current user
  source_match_request_id: z.string().uuid().optional(), // Optional: ID of the current user's "Date Night" request
});

// CORS Headers
const corsHeaders = {
  'Access-Control-Allow-Origin': '*', // Adjust for production
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Initialize enhanced error handler
const errorHandler = new EnhancedErrorHandler({
  serviceName: 'confirm-system-match',
  enableCircuitBreaker: true,
  enableRetryMechanism: true,
  enableGracefulDegradation: true,
  enableFallbackStrategies: true,
  enablePerformanceTracking: true,
  circuitBreakerConfig: {
    threshold: 5,
    timeout: 60000,
    halfOpenMaxCalls: 3
  },
  retryConfig: {
    maxAttempts: 3,
    baseDelay: 1000,
    maxDelay: 10000,
    backoffMultiplier: 2
  }
});

serve(async (req: Request) => {
  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/confirm-system-match', undefined, RateLimitCategory.MATCHING);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }


  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  return await errorHandler.handleRequest(async () => {
    // Validate authorization header

  // CRITICAL SECURITY: Secure JWT validation to prevent Algorithm Confusion Attack
  const userAuthHeader = req.headers.get('Authorization');
  if (!userAuthHeader) {
    logSecurityEvent('missing_auth_header', undefined, {
      endpoint: 'confirm-system-match',
      userAgent: req.headers.get('User-Agent')
    });
    return createErrorResponse(
      { code: 'invalid_grant', message: 'Missing authorization' },
      { endpoint: 'confirm-system-match' },
      corsHeaders
    );
  }

  // CRITICAL SECURITY: Validate JWT to prevent "none" algorithm attacks
  const jwtValidation = validateJWTHeader(userAuthHeader);
  if (!jwtValidation.valid) {
    logSecurityEvent('jwt_validation_failed', undefined, {
      endpoint: 'confirm-system-match',
      error: jwtValidation.error,
      securityRisk: jwtValidation.securityRisk,
      userAgent: req.headers.get('User-Agent')
    });
    
    return createErrorResponse(
      { 
        code: 'invalid_grant', 
        message: jwtValidation.securityRisk === 'high' 
          ? 'Security violation detected' 
          : 'Invalid authorization token'
      },
      { 
        endpoint: 'confirm-system-match',
        securityViolation: jwtValidation.securityRisk === 'high',
        jwtError: jwtValidation.error
      },
      corsHeaders
    );
  }

  // Create secure Supabase client after JWT validation
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

  if (!supabaseUrl || !supabaseAnonKey) {
    return createErrorResponse(
      { code: 'server_error', message: 'Server configuration error' },
      { endpoint: 'confirm-system-match', issue: 'missing_env_vars' },
      corsHeaders
    );
  }

  const secureClientResult = await createSecureSupabaseClient(
    userAuthHeader,
    supabaseUrl,
    supabaseAnonKey
  );

  if (secureClientResult.error || !secureClientResult.client) {
    logSecurityEvent('secure_client_creation_failed', undefined, {
      endpoint: 'confirm-system-match',
      error: secureClientResult.error,
      securityDetails: secureClientResult.securityDetails
    });
    
    return createErrorResponse(
      { code: 'server_error', message: 'Failed to create secure database connection' },
      { endpoint: 'confirm-system-match', phase: 'secure_client_init' },
      corsHeaders
    );
  }

  const supabaseClient = secureClientResult.client;

    // Authenticate user with retry mechanism
    const authenticateUser = async () => {
      const { data: { user: authUser }, error: authUserError } = await supabaseClient.auth.getUser();
      
      if (authUserError || !authUser) {
        throw errorHandler.createError('AUTH_TOKEN_INVALID', 'User not authenticated or token invalid', {
          context: { 
            authError: authUserError?.message,
            hasUser: !!authUser 
          }
        });
      }
      
      return authUser;
    };

    const authUser = await errorHandler.executeWithRetry(
      authenticateUser,
      { 
        operationType: 'authentication',
        maxAttempts: 2,
        baseDelay: 1000
      }
    );

    // Parse and validate request body
    const parseRequestBody = async () => {
      const body = await req.json();
      return ConfirmSystemMatchPayloadSchema.parse(body);
    };

    const validatedPayload = await errorHandler.executeWithFallback(
      parseRequestBody,
      async () => {
        throw errorHandler.createError('VALIDATION_INVALID_FORMAT', 'Invalid request body format', {
          context: { requestHasBody: true }
        });
      },
      'request-body-parsing'
    );

    const currentUserMakingConfirmationId = authUser.id;
    const { target_user_id, source_match_request_id } = validatedPayload;

    // Validate business logic
    if (currentUserMakingConfirmationId === target_user_id) {
      throw errorHandler.createError('VALIDATION_INVALID_INPUT', 'Cannot match with oneself', {
        context: {
          currentUserId: currentUserMakingConfirmationId,
          targetUserId: target_user_id
        }
      });
    }

    // CRITICAL: Check and consume invite atomically before creating match request
    const consumeInviteOp = async () => {
      const { data: inviteData, error: inviteError } = await supabaseClient.rpc('consume_invite', {
        user_uuid: currentUserMakingConfirmationId
      });

      if (inviteError) {
        throw errorHandler.createError('DATABASE_QUERY_FAILED', 'Failed to check invite status', {
          context: {
            inviteError: inviteError.message,
            userId: currentUserMakingConfirmationId
          }
        });
      }

      if (!inviteData || inviteData.length === 0 || !inviteData[0].success) {
        throw errorHandler.createError('RATE_LIMIT_EXCEEDED', 'No invites remaining', {
          context: {
            userId: currentUserMakingConfirmationId,
            remaining: inviteData?.[0]?.remaining_after || 0
          }
        });
      }

      return inviteData[0];
    };

    const inviteResult = await errorHandler.executeWithRetry(
      consumeInviteOp,
      {
        operationType: 'invite-consumption',
        maxAttempts: 2,
        baseDelay: 500
      }
    );

    // Log invite usage for analytics
    try {
      await supabaseClient.from('invite_usage_log').insert({
        user_id: currentUserMakingConfirmationId,
        invited_user_id: target_user_id,
        subscription_status: inviteResult.subscription_status,
        metadata: {
          remaining_after: inviteResult.remaining_after,
          timestamp: new Date().toISOString()
        }
      });
    } catch (logError) {
      // Non-critical: log failure but don't block match request
      console.error('Failed to log invite usage:', logError);
    }

    // Execute RPC with enhanced error handling and circuit breaker protection
    const executeMatchConfirmation = async () => {
      const { data: rpcData, error: rpcError } = await supabaseClient.rpc('confirm_system_match', {
        p_current_user_id: currentUserMakingConfirmationId,
        p_target_user_id: target_user_id,
        p_source_match_request_id: source_match_request_id,
      });

      if (rpcError) {
        throw errorHandler.createError('DATABASE_QUERY_FAILED', 
          'Failed to confirm system match via RPC', {
          context: { 
            rpcError: rpcError.message,
            rpcCode: rpcError.code,
            currentUserId: currentUserMakingConfirmationId,
            targetUserId: target_user_id
          }
        });
      }

      return rpcData;
    };

    // Use fallback strategy for degraded service
    const fallbackMatchConfirmation = async () => {
      // Debug logging removed for security
// In degraded mode, we could create a simpler match without full RPC functionality
      // This would require separate table operations with reduced features
      throw errorHandler.createError('EXTERNAL_SERVICE_DEGRADED', 
        'Match confirmation service is temporarily degraded. Please try again later.', {
        context: { 
          fallbackAttempted: true,
          degradationLevel: 'partial'
        }
      });
    };

    const rpcData = await errorHandler.executeWithCircuitBreaker(
      executeMatchConfirmation,
      'match-confirmation-rpc',
      fallbackMatchConfirmation
    );
    
    const result = Array.isArray(rpcData) ? rpcData[0] : rpcData;

    // Validate RPC result with comprehensive error context
    if (!result || !result.match_id || !result.conversation_id) {
      throw errorHandler.createError('DATABASE_CONSTRAINT_VIOLATION', 
        'Match confirmation failed or returned incomplete data', {
        context: { 
          hasResult: !!result,
          hasMatchId: !!(result?.match_id),
          hasConversationId: !!(result?.conversation_id),
          resultData: result
        }
      });
    }
    
    const confirmed_match_id = result.match_id;
    const confirmed_conversation_id = result.conversation_id;

    // Send notifications with enhanced error handling and graceful degradation
    const sendNotifications = async () => {
      const usersToNotify = [currentUserMakingConfirmationId, target_user_id];
      const notificationResults = [];

      for (const userId of usersToNotify) {
        const otherUserId = userId === currentUserMakingConfirmationId ? target_user_id : currentUserMakingConfirmationId;
        
        const sendSingleNotification = async () => {
          // Get user profiles with retry
          const getUserProfiles = async () => {
            const [userProfileResult, otherProfileResult] = await Promise.all([
              supabaseClient.from('profiles')
                .select('push_token, display_name')
                .eq('id', userId)
                .single(),
              supabaseClient.from('profiles')
                .select('display_name')
                .eq('id', otherUserId)
                .single()
            ]);

            return {
              userProfile: userProfileResult.data,
              otherProfile: otherProfileResult.data,
              userError: userProfileResult.error,
              otherError: otherProfileResult.error
            };
          };

          const profiles = await errorHandler.executeWithRetry(
            getUserProfiles,
            { 
              operationType: 'database-read',
              maxAttempts: 2,
              baseDelay: 500
            }
          );

          if (profiles.userProfile?.push_token) {
            await sendPushNotification(
              profiles.userProfile.push_token,
              "You have a new Match! 🎉",
              `You've matched with ${profiles.otherProfile?.display_name || 'someone'}. Start chatting!`,
              { 
                type: 'new_match_confirmed', 
                matchId: confirmed_match_id, 
                conversationId: confirmed_conversation_id, 
                otherUserId: otherUserId 
              }
            );
          }

          return { userId, success: true };
        };

        // Use fallback for notification failures (graceful degradation)
        const notificationFallback = async () => {
          // Debug logging removed for security
return { userId, success: false, fallback: true };
        };

        try {
          const result = await errorHandler.executeWithFallback(
            sendSingleNotification,
            notificationFallback,
            `notification-${userId}`
          );
          notificationResults.push(result);
        } catch (notificationError: any) {
          // Non-critical error - notification failure shouldn't fail the entire operation
          console.error(`🚨 Notification error for user ${userId}:`, notificationError);
          notificationResults.push({ userId, success: false, error: notificationError.message });
        }
      }

      return notificationResults;
    };

    // Send notifications asynchronously (non-blocking)
    const notificationResults = await sendNotifications();
    const successfulNotifications = notificationResults.filter(r => r.success).length;

    // Return success response with comprehensive context
    return errorHandler.createSuccessResponse({
      message: "Match confirmed and conversation created successfully via RPC.",
      match_id: confirmed_match_id,
      conversation_id: confirmed_conversation_id,
      notifications: {
        sent: successfulNotifications,
        total: notificationResults.length,
        details: notificationResults
      }
    }, 201);

  }, corsHeaders); // Pass CORS headers to the error handler
});
