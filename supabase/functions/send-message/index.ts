import { serve } from 'std/http/server.ts'; // Using import map
import { createClient, SupabaseClient } from '@supabase/supabase-js'; // Using import map
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts'; // Zod often used directly
import { sendPushNotification } from '../_shared/sendPushNotification.ts'; // Fixed relative import
import { getCorsHeaders, checkRateLimit, RATE_LIMITS } from '../_shared/cors.ts';
import { 
  createErrorResponse, 
  createValidationErrorResponse, 
  createRateLimitErrorResponse,
  createSuccessResponse,
  logSecurityEvent 
} from '../_shared/error-handler.ts';
import { monitor } from '../_shared/monitoring.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse as createSecurityValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';
import { validateMessageContent, sanitizeMessage } from '../_shared/message-sanitizer.ts';
import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
import { logger } from '../_shared/logger.ts';

// PHASE 4 SECURITY: CSRF Protection for messaging endpoints
import { csrfMiddleware } from '../_shared/csrf-protection.ts';

// Enhanced Zod Schema for Input Validation with XSS Protection
const SendMessagePayloadSchema = z.object({
  conversation_id: z.string().uuid('Invalid conversation ID format'),
  content: z.string()
    .min(1, 'Message cannot be empty')
    .max(2000, 'Message too long (max 2000 characters)')
    .refine(
      (content) => {
        const validation = validateMessageContent(content, {
          allowRichText: false,
          allowLinks: true,
          checkSpam: true,
          maxLength: 2000,
        });
        return validation.isValid;
      },
      (content) => {
        const validation = validateMessageContent(content, {
          allowRichText: false,
          allowLinks: true,
          checkSpam: true,
          maxLength: 2000,
        });
        return { message: validation.errors.join(', ') || 'Invalid message content' };
      }
    ),
  media_url: z.string().url('Invalid media URL').optional().nullable(),
  media_type: z.enum(['image', 'video', 'audio', 'gif'], {
    errorMap: () => ({ message: 'Media type must be image, video, audio, or gif' })
  }).optional().nullable(),
}).refine(
  (data) => {
    // If media_url is provided, media_type must also be provided
    if (data.media_url && !data.media_type) {
      return false;
    }
    return true;
  },
  {
    message: 'Media type is required when media URL is provided',
    path: ['media_type']
  }
);

serve(async (req: Request) => {
  // PHASE 4 SECURITY: CSRF Protection for messaging endpoints
  // Skip CSRF validation in development/test environments to enable automated testing
  const environment = Deno.env.get('SENTRY_ENVIRONMENT') || Deno.env.get('ENVIRONMENT') || 'development';
  const skipCSRF = environment !== 'production';

  if (!skipCSRF) {
    const csrfValidation = await csrfMiddleware.validateCSRF(req);
    if (!csrfValidation.valid) {
      return csrfValidation.response;
    }
  } else {
    logger.debug('CSRF validation skipped for non-production environment', {
      environment,
      endpoint: 'send-message'
    });
  }

  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/send-message', undefined, RateLimitCategory.MESSAGING);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }

  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  // Initialize API monitoring
  const apiMonitor = monitor.api.createAPIMonitoringMiddleware('send-message');
  const requestData = apiMonitor.startRequest(req);
  const requestId = `send_msg_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

  if (req.method === 'OPTIONS') {
    const response = new Response('ok', { headers: corsHeaders });
    apiMonitor.endRequest(requestData, response);
    return response;
  }

  // CRITICAL SECURITY: Validate request size and authentication
  const validation = await validateSensitiveRequest(req, {
    maxSize: REQUEST_SIZE_LIMITS.MEDIUM,
    requireAuth: true,
    allowedMethods: ['POST', 'OPTIONS'],
    requireJSON: true
  });
  
  if (!validation.valid) {
    return createSecurityValidationErrorResponse([{
      field: 'request',
      error: validation.error || 'Request validation failed'
    }], 400);
  }
  
  const requestSize = validation.size || 0;

  // CRITICAL SECURITY: Secure JWT validation to prevent Algorithm Confusion Attack
  const userAuthHeader = req.headers.get('Authorization');
  if (!userAuthHeader) {
    logSecurityEvent('missing_auth_header', undefined, {
      endpoint: 'send-message',
      userAgent: req.headers.get('User-Agent')
    });
    return createErrorResponse(
      { code: 'invalid_grant', message: 'Missing authorization' },
      { endpoint: 'send-message' },
      corsHeaders
    );
  }

  // CRITICAL SECURITY: Validate JWT to prevent "none" algorithm attacks
  const jwtValidation = validateJWTHeader(userAuthHeader);
  if (!jwtValidation.valid) {
    logSecurityEvent('jwt_validation_failed', undefined, {
      endpoint: 'send-message',
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
        endpoint: 'send-message',
        securityViolation: jwtValidation.securityRisk === 'high',
        jwtError: jwtValidation.error
      },
      corsHeaders
    );
  }

  // Create secure Supabase client after JWT validation
  let supabaseClient: SupabaseClient;
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

    if (!supabaseUrl || !supabaseAnonKey) {
      return createErrorResponse(
        { code: 'server_error', message: 'Server configuration error' },
        { endpoint: 'send-message', issue: 'missing_env_vars' },
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
        endpoint: 'send-message',
        error: secureClientResult.error,
        securityDetails: secureClientResult.securityDetails
      });
      
      return createErrorResponse(
        { code: 'server_error', message: 'Failed to create secure database connection' },
        { endpoint: 'send-message', phase: 'secure_client_init' },
        corsHeaders
      );
    }

    supabaseClient = secureClientResult.client;
  } catch (e: any) {
    return createErrorResponse(
      e,
      { endpoint: 'send-message', phase: 'client_init' },
      corsHeaders
    );
  }
  
  const { data: { user }, error: userError } = await supabaseClient.auth.getUser();

  if (userError || !user) {
    logSecurityEvent('invalid_auth_token', undefined, {
      endpoint: 'send-message',
      error: userError?.message
    });
    return createErrorResponse(
      userError || { code: 'invalid_grant', message: 'Invalid authentication token' },
      { endpoint: 'send-message', phase: 'auth_check' },
      corsHeaders
    );
  }

  try {
    // Rate limiting
    const rateLimitKey = `send_message:${user.id}`;
    const rateLimit = await checkRateLimit(rateLimitKey, RATE_LIMITS.MESSAGES);
    
    if (!rateLimit.allowed) {
      logSecurityEvent('rate_limit_exceeded', user.id, {
        endpoint: 'send-message',
        remaining: rateLimit.remaining
      });
      return createRateLimitErrorResponse(
        rateLimit.remaining, 
        rateLimit.resetTime, 
        corsHeaders
      );
    }

    const body = await req.json();
    const validatedPayload = SendMessagePayloadSchema.parse(body);

    const { conversation_id, content, media_url, media_type } = validatedPayload;
    const sender_id = user.id;

    // Verify user is a participant in the conversation
    const { data: conversationCheck, error: conversationError } = await monitor.db.monitorDatabaseQuery(
      'verify_conversation_participant',
      () => supabaseClient
        .from('conversations')
        .select('user1_id, user2_id')
        .eq('id', conversation_id)
        .single(),
      { conversationId: conversation_id, userId: user.id }
    );

    if (conversationError) {
      logSecurityEvent('conversation_access_denied', user.id, {
        endpoint: 'send-message',
        conversationId: conversation_id,
        error: conversationError.code
      });
      return createErrorResponse(
        conversationError,
        { endpoint: 'send-message', phase: 'conversation_check', userId: user.id },
        corsHeaders
      );
    }

    if (!conversationCheck || 
        (conversationCheck.user1_id !== sender_id && conversationCheck.user2_id !== sender_id)) {
      logSecurityEvent('unauthorized_conversation_access', user.id, {
        endpoint: 'send-message',
        conversationId: conversation_id,
        attemptedSenderId: sender_id
      });
      return createErrorResponse(
        { code: 'PGRST301', message: 'Access denied to conversation' },
        { endpoint: 'send-message', phase: 'participant_check', userId: user.id },
        corsHeaders
      );
    }

    // Comprehensive XSS protection and sanitization
    const sanitizationResult = sanitizeMessage(content, {
      allowRichText: false,
      allowLinks: true,
      allowImages: false,
      maxLength: 2000,
      stripInvisibleChars: true,
      checkSpam: true,
      preserveNewlines: true,
    });

    // Log security threats
    if (sanitizationResult.threats.length > 0) {
      logSecurityEvent('message_security_threats', user.id, {
        endpoint: 'send-message',
        conversationId: conversation_id,
        threats: sanitizationResult.threats,
        originalLength: sanitizationResult.original.length,
        sanitizedLength: sanitizationResult.sanitized.length,
        isSpam: sanitizationResult.isSpam,
      });

      // Block spam messages
      if (sanitizationResult.isSpam) {
        return createErrorResponse(
          { code: 'MESSAGE_SPAM_DETECTED', message: 'Message blocked due to spam patterns' },
          { endpoint: 'send-message', phase: 'spam_check', userId: user.id },
          corsHeaders
        );
      }

      // Block messages with too many threats
      if (sanitizationResult.threats.length > 5) {
        return createErrorResponse(
          { code: 'MESSAGE_SECURITY_THREATS', message: 'Message blocked due to security threats' },
          { endpoint: 'send-message', phase: 'security_check', userId: user.id },
          corsHeaders
        );
      }
    }

    const sanitizedContent = sanitizationResult.sanitized;

    const { data: newMessage, error: rpcError } = await monitor.db.monitorDatabaseQuery(
      'create_message_and_update_conversation',
      () => supabaseClient.rpc(
        'create_message_and_update_conversation',
        {
          p_conversation_id: conversation_id,
          p_sender_id: sender_id,
          p_content: sanitizedContent,
          p_media_url: media_url || null,
          p_media_type: media_type || null,
        }
      ),
      { conversationId: conversation_id, senderId: sender_id, contentLength: sanitizedContent.length }
    );

    if (rpcError) {
      throw rpcError;
    }
    if (!newMessage) { // RPCs might return null or an empty array on no-op/error within SQL
        throw new Error('Failed to send message: No data returned from RPC, or RPC indicated an issue.');
    }

    // --- Enhanced Push Notification Logic with User Preferences ---
    try {
      const { data: conversationData, error: convoError } = await supabaseClient
        .from('conversations')
        .select('user1_id, user2_id')
        .eq('id', conversation_id)
        .single();

      if (convoError) throw convoError;
      if (!conversationData) throw new Error('Conversation not found for notification.');

      const recipientId = conversationData.user1_id === sender_id ? conversationData.user2_id : conversationData.user1_id;

      if (recipientId) {
        // Check if recipient should receive notifications using unified settings system
        const { data: shouldNotify, error: notificationCheckError } = await supabaseClient
          .rpc('should_send_notification', {
            target_user_id: recipientId,
            notification_type: 'message'
          });
        
        if (notificationCheckError) {
          logger.warn('Failed to check notification preferences, defaulting to enabled', {
            recipientId,
            error: notificationCheckError.message,
            requestId
          });
        }
        
        // Only proceed if notifications are enabled for this user
        if (shouldNotify !== false) {
          const { data: senderProfile, error: senderProfileError } = await supabaseClient
            .from('profiles')
            .select('display_name')
            .eq('id', sender_id)
            .single();
          
          // Get recipient's notification preferences
          const { data: recipientNotificationPrefs, error: recipientPrefsError } = await supabaseClient
            .rpc('get_user_notification_preferences', { target_user_id: recipientId });
          
          const { data: recipientProfile, error: recipientProfileError } = await supabaseClient
            .from('profiles')
            .select('push_token')
            .eq('id', recipientId)
            .single();

          if (senderProfileError || recipientProfileError) {
            logger.error('Error fetching profiles for message notification', {
              senderError: senderProfileError?.message,
              recipientError: recipientProfileError?.message,
              requestId
            });
          } else if (recipientProfile?.push_token && 
                     recipientNotificationPrefs?.message_notifications_enabled &&
                     recipientNotificationPrefs?.message_notifications_push) {
            
            // Determine notification sound based on user preferences
            const notificationOptions = {
              type: 'new_message', 
              conversationId: conversation_id, 
              messageId: (newMessage as any).id || 'new_message',
              sound: recipientNotificationPrefs?.message_notifications_sound ? 'default' : undefined
            };
            
            const messageId = (newMessage as any).id || 'new_message';
            await sendPushNotification(
              recipientProfile.push_token,
              `New message from ${senderProfile?.display_name || 'Someone'}`,
              content.substring(0, 100), 
              notificationOptions
            );
            
            logger.info('Message notification sent successfully', {
              recipientId,
              senderId: sender_id,
              conversationId: conversation_id,
              notificationEnabled: true,
              pushEnabled: recipientNotificationPrefs?.message_notifications_push,
              soundEnabled: recipientNotificationPrefs?.message_notifications_sound,
              requestId
            });
          } else {
            logger.info('Message notification skipped due to user preferences', {
              recipientId,
              senderId: sender_id,
              conversationId: conversation_id,
              hasPushToken: !!recipientProfile?.push_token,
              notificationEnabled: recipientNotificationPrefs?.message_notifications_enabled,
              pushEnabled: recipientNotificationPrefs?.message_notifications_push,
              requestId
            });
          }
        } else {
          logger.info('Message notification blocked by Do Not Disturb or disabled notifications', {
            recipientId,
            senderId: sender_id,
            conversationId: conversation_id,
            shouldNotify,
            requestId
          });
        }
      }
    } catch (notificationError: any) {
      logger.error('Failed to process new message notification', {
        error: notificationError.message,
        stack: notificationError.stack,
        conversationId: conversation_id,
        senderId: sender_id,
        requestId
      });
    }
    // --- End Push Notification Logic ---

    // Track business metrics
    monitor.business.trackBusinessMetric('message_sent', 1, {
      hasMedia: media_url ? 'true' : 'false',
      contentLength: sanitizedContent.length.toString()
    });

    logger.info('Message sent successfully', {
      conversationId: conversation_id,
      senderId: sender_id,
      hasMedia: !!media_url,
      contentLength: sanitizedContent.length
    });

    // Return 200 OK for consistency (default status code)
    const response = createSuccessResponse(newMessage, corsHeaders);
    apiMonitor.endRequest(requestData, response, user.id, JSON.stringify(newMessage).length);
    return response;

  } catch (e) {
    // Handle validation errors separately
    if (e instanceof ZodError) {
      const errorResponse = createValidationErrorResponse(e, corsHeaders);
      apiMonitor.endRequest(requestData, errorResponse, user?.id);
      return errorResponse;
    }
    
    // Handle all other errors securely
    const errorResponse = createErrorResponse(
      e,
      { 
        endpoint: 'send-message', 
        userId: user?.id, 
        phase: 'message_send' 
      },
      corsHeaders
    );
    apiMonitor.endRequest(requestData, errorResponse, user?.id);
    return errorResponse;
  }
});
