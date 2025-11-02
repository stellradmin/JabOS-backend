/**
 * Mark Messages as Read Edge Function
 * 
 * Handles marking messages as read with comprehensive read receipt
 * functionality based on user privacy preferences.
 * 
 * Features:
 * - Respects user privacy settings for read receipts
 * - Mutual consent read receipt sharing
 * - Bulk message marking for performance
 * - Comprehensive security and validation
 * - Real-time notification integration
 * - Audit trail for read receipt events
 * 
 * Author: Claude Code Assistant
 * Version: 1.0.0
 * Created: 2024-09-04
 */

import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

// Import security and performance modules
import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse,
  validateUUID
} from '../_shared/security-validation.ts';

import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { csrfMiddleware } from '../_shared/csrf-protection.ts';
import { getCorsHeaders } from '../_shared/cors.ts';
import { 
  createErrorResponse, 
  createSuccessResponse,
  logSecurityEvent 
} from '../_shared/error-handler.ts';
import { logger } from '../_shared/logger.ts';

// Zod schema for request validation
const MarkMessagesReadSchema = z.object({
  conversation_id: z.string().uuid('Invalid conversation ID format'),
  message_ids: z.array(z.string().uuid('Invalid message ID format')).optional(),
  mark_all: z.boolean().default(false)
}).refine((data) => {
  // Either provide specific message IDs or mark_all flag, but not both
  if (data.mark_all && data.message_ids && data.message_ids.length > 0) {
    return false;
  }
  if (!data.mark_all && (!data.message_ids || data.message_ids.length === 0)) {
    return false;
  }
  return true;
}, {
  message: "Either provide message_ids array or set mark_all to true, but not both"
});

serve(async (req: Request) => {
  const startTime = Date.now();
  const requestId = `mark_read_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

  try {
    // =====================================================
    // 1. SECURITY VALIDATION
    // =====================================================
    
    // CSRF Protection
    const csrfValidation = await csrfMiddleware.validateCSRF(req);
    if (!csrfValidation.valid) {
      return csrfValidation.response;
    }

    // Rate limiting
    const rateLimitResult = await applyRateLimit(
      req, 
      '/mark-messages-read', 
      undefined, 
      RateLimitCategory.MESSAGING
    );
    if (rateLimitResult.blocked) {
      return rateLimitResult.response;
    }

    // CORS headers
    const origin = req.headers.get('Origin');
    const corsHeaders = getCorsHeaders(origin);

    if (req.method === 'OPTIONS') {
      return new Response('ok', { headers: corsHeaders });
    }

    // Request validation
    const validation = await validateSensitiveRequest(req, {
      maxSize: REQUEST_SIZE_LIMITS.MEDIUM,
      requireAuth: true,
      allowedMethods: ['POST', 'PUT', 'PATCH', 'OPTIONS'],
      requireJSON: true
    });
    
    if (!validation.valid) {
      return createValidationErrorResponse([{
        field: 'request',
        error: validation.error || 'Request validation failed'
      }], 400);
    }

    // JWT Authentication
    const userAuthHeader = req.headers.get('Authorization');
    if (!userAuthHeader) {
      logSecurityEvent('missing_auth_header', undefined, {
        endpoint: 'mark-messages-read',
        requestId
      });
      
      return createErrorResponse(
        { code: 'invalid_grant', message: 'Missing authorization' },
        { endpoint: 'mark-messages-read', requestId },
        corsHeaders
      );
    }

    const jwtValidation = validateJWTHeader(userAuthHeader);
    if (!jwtValidation.valid) {
      logSecurityEvent('jwt_validation_failed', undefined, {
        endpoint: 'mark-messages-read',
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
        { 
          endpoint: 'mark-messages-read',
          securityViolation: jwtValidation.securityRisk === 'high',
          requestId
        },
        corsHeaders
      );
    }

    // =====================================================
    // 2. SUPABASE CLIENT INITIALIZATION
    // =====================================================
    
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

    if (!supabaseUrl || !supabaseAnonKey) {
      return createErrorResponse(
        { code: 'server_error', message: 'Server configuration error' },
        { endpoint: 'mark-messages-read', requestId },
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
        endpoint: 'mark-messages-read',
        error: secureClientResult.error,
        requestId
      });
      
      return createErrorResponse(
        { code: 'server_error', message: 'Failed to create secure database connection' },
        { endpoint: 'mark-messages-read', requestId },
        corsHeaders
      );
    }

    const supabaseClient = secureClientResult.client;

    // =====================================================
    // 3. USER AUTHENTICATION
    // =====================================================
    
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();

    if (userError || !user) {
      logSecurityEvent('invalid_auth_token', undefined, {
        endpoint: 'mark-messages-read',
        error: userError?.message,
        requestId
      });
      
      return createErrorResponse(
        userError || { code: 'invalid_grant', message: 'Invalid authentication token' },
        { endpoint: 'mark-messages-read', requestId },
        corsHeaders
      );
    }

    const userId = user.id;

    // =====================================================
    // 4. INPUT VALIDATION
    // =====================================================
    
    let requestBody: any;
    try {
      requestBody = await req.json();
    } catch (jsonError) {
      return createErrorResponse(
        { code: 'invalid_json', message: 'Invalid JSON in request body' },
        { endpoint: 'mark-messages-read', requestId },
        corsHeaders
      );
    }

    let validatedData;
    try {
      validatedData = MarkMessagesReadSchema.parse(requestBody);
    } catch (error) {
      if (error instanceof ZodError) {
        logger.warn('Message read validation failed', {
          userId,
          validationErrors: error.flatten(),
          requestId
        });
        
        return createErrorResponse(
          { code: 'validation_error', message: 'Invalid request data', details: error.flatten() },
          { endpoint: 'mark-messages-read', requestId },
          corsHeaders
        );
      }
      throw error;
    }

    const { conversation_id, message_ids, mark_all } = validatedData;

    // =====================================================
    // 5. VERIFY CONVERSATION ACCESS
    // =====================================================
    
    const { data: conversationCheck, error: conversationError } = await supabaseClient
      .from('conversations')
      .select('user1_id, user2_id')
      .eq('id', conversation_id)
      .single();

    if (conversationError || !conversationCheck) {
      logSecurityEvent('conversation_access_denied', userId, {
        endpoint: 'mark-messages-read',
        conversationId: conversation_id,
        requestId
      });
      
      return createErrorResponse(
        { code: 'access_denied', message: 'Conversation not found or access denied' },
        { endpoint: 'mark-messages-read', conversationId: conversation_id, requestId },
        corsHeaders
      );
    }

    // Verify user is part of the conversation
    if (conversationCheck.user1_id !== userId && conversationCheck.user2_id !== userId) {
      logSecurityEvent('unauthorized_message_read_attempt', userId, {
        endpoint: 'mark-messages-read',
        conversationId: conversation_id,
        requestId
      });
      
      return createErrorResponse(
        { code: 'unauthorized', message: 'User not authorized to access this conversation' },
        { endpoint: 'mark-messages-read', conversationId: conversation_id, requestId },
        corsHeaders
      );
    }

    // =====================================================
    // 6. MARK MESSAGES AS READ
    // =====================================================
    
    try {
      const { data: readResult, error: readError } = await supabaseClient
        .rpc('api_mark_messages_read', {
          p_conversation_id: conversation_id,
          p_reader_id: userId,
          p_message_ids: message_ids ? JSON.stringify(message_ids) : null
        });

      if (readError) {
        logger.error('Failed to mark messages as read', {
          userId,
          conversationId: conversation_id,
          messageIds: message_ids,
          error: readError.message,
          requestId
        });

        return createErrorResponse(
          { code: 'database_error', message: 'Failed to mark messages as read' },
          { 
            endpoint: 'mark-messages-read',
            conversationId: conversation_id,
            requestId 
          },
          corsHeaders
        );
      }

      // =====================================================
      // 7. LOG SUCCESS AND RETURN RESPONSE
      // =====================================================
      
      const responseTime = Date.now() - startTime;
      
      logger.info('Messages marked as read successfully', {
        userId,
        conversationId: conversation_id,
        messagesMarked: readResult?.total_messages_marked || 0,
        receiptsShared: readResult?.total_receipts_sent || 0,
        markAll: mark_all,
        specificMessages: message_ids?.length || 0,
        responseTimeMs: responseTime,
        requestId
      });

      const responseData = {
        success: true,
        conversation_id: conversation_id,
        reader_id: userId,
        messages_marked: readResult?.total_messages_marked || 0,
        read_receipts_sent: readResult?.total_receipts_sent || 0,
        processed_at: new Date().toISOString(),
        metadata: {
          mark_all: mark_all,
          specific_message_count: message_ids?.length || 0,
          response_time_ms: responseTime,
          request_id: requestId
        }
      };

      // Add detailed results if available
      if (readResult?.individual_results && readResult.individual_results.length > 0) {
        responseData.detailed_results = readResult.individual_results;
      }

      const securityHeaders = {
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY', 
        'X-XSS-Protection': '1; mode=block',
        'Referrer-Policy': 'strict-origin-when-cross-origin',
        'Cache-Control': 'private, no-cache'
      };

      return createSuccessResponse(
        responseData,
        { ...corsHeaders, ...securityHeaders },
        200
      );

    } catch (dbError) {
      logger.error('Database error while marking messages as read', {
        userId,
        conversationId: conversation_id,
        error: dbError.message,
        stack: dbError.stack,
        requestId
      });

      return createErrorResponse(
        { code: 'internal_error', message: 'An unexpected error occurred' },
        { endpoint: 'mark-messages-read', requestId },
        corsHeaders
      );
    }

  } catch (error) {
    // =====================================================
    // 8. ERROR HANDLING
    // =====================================================
    
    const responseTime = Date.now() - startTime;
    
    logger.error('Critical error in mark-messages-read', {
      error: error instanceof Error ? error.message : 'Unknown error',
      stack: error instanceof Error ? error.stack : undefined,
      errorType: error?.constructor?.name || 'UnknownError',
      userId: user?.id || 'anonymous',
      requestId,
      responseTimeMs: responseTime
    });
    
    const corsHeaders = getCorsHeaders(req.headers.get('Origin'));
    
    return createErrorResponse(
      error instanceof Error ? error : new Error('Unknown error'),
      500,
      req,
      {
        requestId,
        endpoint: 'mark-messages-read',
        timestamp: new Date().toISOString()
      }
    );
  }
});

/**
 * Mark Messages Read Function Summary:
 * 
 * 🔒 Security Features:
 * - CSRF protection and JWT validation
 * - Conversation access verification
 * - Rate limiting for message operations
 * - Comprehensive security event logging
 * 
 * 📱 Privacy Features:
 * - Mutual consent read receipts
 * - User-controlled privacy settings
 * - Granular read receipt preferences
 * - Audit trail for read events
 * 
 * ⚡ Performance Features:
 * - Bulk message marking support
 * - Optimized database operations
 * - Comprehensive error handling
 * - Real-time notification integration
 * 
 * 🎯 Functionality:
 * - Mark specific messages or all unread messages
 * - Respects user privacy preferences for read receipts
 * - Provides detailed response with metadata
 * - Integrates with notification system
 * - Comprehensive logging and monitoring
 */
