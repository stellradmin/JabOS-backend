/**
 * Unmatch Users Edge Function
 * 
 * Handles user unmatching with comprehensive security, audit logging,
 * and proper conversation cleanup. Integrates with the existing 
 * unmatch_users SQL function that provides atomic transactions
 * and soft delete functionality.
 * 
 * Features:
 * - Secure user authentication and authorization
 * - Rate limiting and CSRF protection
 * - Comprehensive input validation
 * - Atomic unmatch operations via SQL function
 * - Audit trail logging
 * - Push notifications for unmatch events
 * - Proper error handling and logging
 */

import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

// Import security and validation modules
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
import { csrfMiddleware } from '../_shared/csrf-protection.ts';
import { getCorsHeaders } from '../_shared/cors.ts';
import { 
  createErrorResponse, 
  createSuccessResponse,
  logSecurityEvent 
} from '../_shared/error-handler.ts';
import { logger } from '../_shared/logger.ts';

// Zod schema for unmatch request
const UnmatchRequestSchema = z.object({
  other_user_id: z.string().uuid('Invalid user ID format'),
  reason: z.enum(['user_unmatch', 'user_block', 'policy_violation'], {
    errorMap: () => ({ message: 'Reason must be user_unmatch, user_block, or policy_violation' })
  }).default('user_unmatch'),
  metadata: z.record(z.unknown()).optional()
});

serve(async (req: Request) => {
  const startTime = Date.now();
  const requestId = `unmatch_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

  try {
    // Handle CORS preflight
    const origin = req.headers.get('Origin');
    const corsHeaders = getCorsHeaders(origin);
    
    if (req.method === 'OPTIONS') {
      return new Response('ok', { headers: corsHeaders });
    }

    // Only allow POST method
    if (req.method !== 'POST') {
      return createErrorResponse(
        { code: 'method_not_allowed', message: 'Method not allowed' },
        { endpoint: 'unmatch-users', requestId },
        corsHeaders
      );
    }

    // Rate limiting
    const rateLimitResult = await applyRateLimit(
      req, 
      '/unmatch-users', 
      undefined, 
      RateLimitCategory.USER_ACTION
    );
    if (rateLimitResult.blocked) {
      return rateLimitResult.response;
    }

    // CSRF Protection
    const csrfValidation = await csrfMiddleware.validateCSRF(req);
    if (!csrfValidation.valid) {
      return csrfValidation.response;
    }

    // JWT Authentication
    const userAuthHeader = req.headers.get('Authorization');
    if (!userAuthHeader) {
      logSecurityEvent('missing_auth_header', undefined, {
        endpoint: 'unmatch-users',
        requestId
      });
      return createErrorResponse(
        { code: 'invalid_grant', message: 'Missing authorization' },
        { endpoint: 'unmatch-users', requestId },
        corsHeaders
      );
    }

    const jwtValidation = validateJWTHeader(userAuthHeader);
    if (!jwtValidation.valid) {
      logSecurityEvent('jwt_validation_failed', undefined, {
        endpoint: 'unmatch-users',
        error: jwtValidation.error,
        securityRisk: jwtValidation.securityRisk,
        requestId
      });
      return createErrorResponse(
        { 
          code: 'invalid_grant', 
          message: jwtValidation.securityRisk === 'high' 
            ? 'Security violation detected' 
            : 'Invalid authorization token'
        },
        { endpoint: 'unmatch-users', requestId },
        corsHeaders
      );
    }

    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

    if (!supabaseUrl || !supabaseAnonKey) {
      return createErrorResponse(
        { code: 'server_error', message: 'Server configuration error' },
        { endpoint: 'unmatch-users', requestId },
        corsHeaders
      );
    }

    const secureClientResult = await createSecureSupabaseClient(
      userAuthHeader,
      supabaseUrl,
      supabaseAnonKey
    );

    if (secureClientResult.error || !secureClientResult.client) {
      return createErrorResponse(
        { code: 'server_error', message: 'Failed to create secure database connection' },
        { endpoint: 'unmatch-users', requestId },
        corsHeaders
      );
    }

    const supabaseClient = secureClientResult.client;

    // Get authenticated user
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !user) {
      return createErrorResponse(
        { code: 'invalid_grant', message: 'Invalid authentication token' },
        { endpoint: 'unmatch-users', requestId },
        corsHeaders
      );
    }

    // Parse and validate request body
    const body = await req.json();
    const validatedRequest = UnmatchRequestSchema.parse(body);

    const { other_user_id, reason, metadata } = validatedRequest;

    logger.info('Processing unmatch request', {
      userId: user.id,
      otherUserId: other_user_id,
      reason,
      requestId
    });

    // Call the SQL function to handle unmatch atomically
    const { data: unmatchResult, error: unmatchError } = await supabaseClient
      .rpc('unmatch_users', {
        p_user_id: user.id,
        p_other_user_id: other_user_id,
        p_reason: reason,
        p_metadata: metadata || {}
      });

    if (unmatchError) {
      logger.error('Unmatch operation failed', {
        userId: user.id,
        otherUserId: other_user_id,
        error: unmatchError.message,
        requestId
      });

      // Handle specific error cases
      if (unmatchError.message.includes('not found')) {
        return createErrorResponse(
          { code: 'match_not_found', message: 'Match not found or already deleted' },
          { endpoint: 'unmatch-users', requestId },
          corsHeaders
        );
      }

      if (unmatchError.message.includes('Unauthorized')) {
        return createErrorResponse(
          { code: 'unauthorized', message: 'Not authorized to unmatch this user' },
          { endpoint: 'unmatch-users', requestId },
          corsHeaders
        );
      }

      return createErrorResponse(
        { code: 'unmatch_failed', message: 'Failed to unmatch users' },
        { endpoint: 'unmatch-users', requestId },
        corsHeaders
      );
    }

    // Send notifications about the unmatch (non-blocking)
    try {
      const { data: otherUserProfile } = await supabaseClient
        .from('profiles')
        .select('push_token, display_name')
        .eq('id', other_user_id)
        .single();

      const { data: userProfile } = await supabaseClient
        .from('profiles')
        .select('display_name')
        .eq('id', user.id)
        .single();

      if (otherUserProfile?.push_token && userProfile?.display_name) {
        const { sendPushNotification } = await import('../_shared/sendPushNotification.ts');
        
        await sendPushNotification(
          otherUserProfile.push_token,
          "Match Ended",
          `${userProfile.display_name} unmatched with you`,
          {
            type: 'unmatch',
            from_user_id: user.id,
            reason: reason
          }
        );
      }
    } catch (notificationError) {
      logger.warn('Failed to send unmatch notification', {
        error: notificationError.message,
        requestId
      });
      // Don't fail the request for notification issues
    }

    logger.info('Unmatch completed successfully', {
      userId: user.id,
      otherUserId: other_user_id,
      matchId: unmatchResult.match_id,
      conversationId: unmatchResult.conversation_id,
      requestId
    });

    return createSuccessResponse(
      {
        success: true,
        message: 'Users unmatched successfully',
        unmatch_result: unmatchResult,
        metadata: {
          timestamp: new Date().toISOString(),
          request_id: requestId,
          processing_time_ms: Date.now() - startTime
        }
      },
      corsHeaders,
      200
    );

  } catch (error) {
    logger.error('Critical error in unmatch-users', {
      error: error instanceof Error ? error.message : 'Unknown error',
      stack: error instanceof Error ? error.stack : undefined,
      requestId
    });

    const statusCode = error instanceof z.ZodError ? 400 : 500;
    const errorMessage = error instanceof z.ZodError 
      ? 'Invalid request data' 
      : 'Unmatch operation failed';

    return createErrorResponse(
      {
        code: error instanceof z.ZodError ? 'validation_error' : 'server_error',
        message: errorMessage,
        details: error instanceof z.ZodError ? error.errors : undefined
      },
      { endpoint: 'unmatch-users', requestId },
      getCorsHeaders(req.headers.get('Origin'))
    );
  }
});
