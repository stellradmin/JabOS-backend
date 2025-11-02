import { serve } from 'std/http/server.ts';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { sendPushNotification } from '../_shared/sendPushNotification.ts';
import { getCorsHeaders, checkRateLimit, RATE_LIMITS } from '../_shared/cors.ts';
import { 
  createErrorResponse, 
  createValidationErrorResponse, 
  createRateLimitErrorResponse,
  createSuccessResponse,
  logSecurityEvent 
} from '../_shared/error-handler.ts';
import { monitor, logger } from '../_shared/monitoring.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse as createSecurityValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';
import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
import { logger } from '../_shared/logger.ts';

// CSRF Protection for messaging endpoints
import { csrfMiddleware } from '../_shared/csrf-protection.ts';

// Photo Message Schema with Enhanced Validation
const SendPhotoMessagePayloadSchema = z.object({
  conversation_id: z.string().uuid('Invalid conversation ID format'),
  photo_url: z.string().url('Invalid photo URL'),
  caption: z.string()
    .max(500, 'Caption too long (max 500 characters)')
    .optional(),
  width: z.number()
    .min(1, 'Invalid image width')
    .max(4096, 'Image too large')
    .optional(),
  height: z.number()
    .min(1, 'Invalid image height')
    .max(4096, 'Image too large')
    .optional(),
  file_size: z.number()
    .min(1, 'Invalid file size')
    .max(25 * 1024 * 1024, 'Photo file too large (max 25MB)'),
  content_type: z.enum(['image/jpeg', 'image/png', 'image/webp', 'image/gif'], {
    errorMap: () => ({ message: 'Invalid image format' })
  })
});

serve(async (req: Request) => {
  // CSRF Protection
  const csrfValidation = await csrfMiddleware.validateCSRF(req);
  if (!csrfValidation.valid) {
    return csrfValidation.response;
  }

  const corsHeaders = getCorsHeaders();

  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return createErrorResponse('Method not allowed', 405, corsHeaders);
  }

  const startTime = Date.now();
  
  try {
    // JWT Validation
    const jwtValidation = await validateJWTHeader(req);
    if (!jwtValidation.valid) {
      logSecurityEvent('JWT_VALIDATION_FAILED', {
        function: 'send-photo-message',
        error: jwtValidation.error,
        timestamp: new Date().toISOString()
      });
      return createErrorResponse('Unauthorized', 401, corsHeaders);
    }

    const { user, supabase } = jwtValidation;

    // Rate Limiting - Photo messages have reasonable limits
    const rateLimitResult = await applyRateLimit(
      user.id,
      'send_photo_message',
      RateLimitCategory.MESSAGING,
      supabase,
      { maxRequests: 30, windowMs: 60000 } // 30 photos per minute
    );

    if (!rateLimitResult.allowed) {
      return createRateLimitErrorResponse(rateLimitResult, corsHeaders);
    }

    // Request Size Validation (photos can be large)
    const validationResult = await validateSensitiveRequest(
      req, 
      user.id,
      { maxSizeBytes: 25 * 1024 * 1024 } // 25MB limit for photos
    );

    if (!validationResult.isValid) {
      logSecurityEvent('REQUEST_VALIDATION_FAILED', {
        function: 'send-photo-message',
        userId: user.id,
        errors: validationResult.errors,
        timestamp: new Date().toISOString()
      });
      return createSecurityValidationErrorResponse(validationResult, corsHeaders);
    }

    // Parse and validate payload
    const body = await req.json();
    const payload = SendPhotoMessagePayloadSchema.parse(body);

    // Validate conversation access
    const { data: conversation, error: convError } = await supabase
      .from('conversations')
      .select('id, participants')
      .eq('id', payload.conversation_id)
      .single();

    if (convError || !conversation) {
      return createErrorResponse('Conversation not found', 404, corsHeaders);
    }

    // Check if user is participant
    if (!conversation.participants.includes(user.id)) {
      logSecurityEvent('UNAUTHORIZED_CONVERSATION_ACCESS', {
        userId: user.id,
        conversationId: payload.conversation_id,
        function: 'send-photo-message',
        timestamp: new Date().toISOString()
      });
      return createErrorResponse('Access denied', 403, corsHeaders);
    }

    // Prepare message content
    const messageContent = payload.caption ? 
      `📷 ${payload.caption}` : 
      '📷 Photo';

    // Insert photo message
    const { data: message, error: messageError } = await supabase
      .from('messages')
      .insert({
        conversation_id: payload.conversation_id,
        sender_id: user.id,
        content: messageContent,
        media_url: payload.photo_url,
        media_type: 'image',
        message_type: 'photo',
        metadata: {
          width: payload.width,
          height: payload.height,
          file_size: payload.file_size,
          content_type: payload.content_type,
          has_caption: !!payload.caption
        }
      })
      .select()
      .single();

    if (messageError) {
      logger.error('Failed to send photo message:', messageError);
      return createErrorResponse('Failed to send photo message', 500, corsHeaders);
    }

    // Send push notification to other participants
    const otherParticipants = conversation.participants.filter(id => id !== user.id);
    
    if (otherParticipants.length > 0) {
      try {
        await sendPushNotification(otherParticipants, {
          title: '📷 Photo Message',
          body: payload.caption ? payload.caption : 'New photo',
          data: {
            type: 'photo_message',
            conversationId: payload.conversation_id,
            messageId: message.id,
            senderId: user.id
          }
        });
      } catch (pushError) {
        logger.error('Failed to send push notification:', pushError);
        // Don't fail the request if push notification fails
      }
    }

    // Performance monitoring
    monitor.recordDuration('send_photo_message_duration', Date.now() - startTime);
    monitor.increment('send_photo_message_success');

    logger.info('Photo message sent successfully', {
      messageId: message.id,
      conversationId: payload.conversation_id,
      senderId: user.id,
      hasCaption: !!payload.caption,
      fileSize: payload.file_size
    });

    return createSuccessResponse({ message }, corsHeaders);

  } catch (error) {
    monitor.increment('send_photo_message_error');
    
    if (error instanceof ZodError) {
      logger.warn('Photo message validation failed:', error.errors);
      return createValidationErrorResponse(error, corsHeaders);
    }

    if (error instanceof ValidationError) {
      logger.warn('Security validation failed:', error.message);
      return createSecurityValidationErrorResponse({ 
        isValid: false, 
        errors: [error.message] 
      }, corsHeaders);
    }

    logger.error('Unexpected error in send-photo-message:', error);
    return createErrorResponse('Internal server error', 500, corsHeaders);
  }
});