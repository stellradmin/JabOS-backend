/**
 * STELLR MATCH REQUEST RESPONSE ENDPOINT
 * 
 * Handles acceptance and rejection of match requests with real-time notifications
 * 
 * Security Features:
 * - User authentication validation
 * - Rate limiting protection
 * - Input validation and sanitization
 * - Comprehensive audit logging
 * - Real-time notification delivery
 */

import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { corsHeaders } from '../_shared/cors.ts';
import { validateInput } from '../_shared/comprehensive-input-validator.ts';
import { sanitizeInput } from '../_shared/comprehensive-input-sanitization.ts';
import { structuredLogger } from '../_shared/structured-logging.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { csrfMiddleware } from '../_shared/csrf-protection.ts';
import type { MatchRequest, MatchRequestStatus } from '../../types/match-db.ts';

// =====================================================================================
// INPUT VALIDATION AND TYPE DEFINITIONS
// =====================================================================================

const MatchResponseSchema = z.object({
  match_request_id: z.string().uuid('Invalid match request ID'),
  response: z.enum(['accept', 'reject'], {
    errorMap: () => ({ message: 'Response must be "accept" or "reject"' })
  }),
  message: z.string().max(500).optional() // Optional message from responder
});

interface MatchRequestResponse {
  success: boolean;
  match_request_updated: boolean;
  match_created?: boolean;
  match_id?: string;
  conversation_id?: string;
  message: string;
  notification_sent?: boolean;
}

// =====================================================================================
// MAIN HANDLER FUNCTION
// =====================================================================================

serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  const startTime = Date.now();
  
  // Initialize logger
  const logger = structuredLogger.createLogger({
    service: 'respond-to-match-request',
    requestId,
    operation: 'match_request_response'
  });

  try {
    // Handle CORS preflight
    if (req.method === 'OPTIONS') {
      return new Response('ok', { headers: corsHeaders });
    }

    // Only allow POST method
    if (req.method !== 'POST') {
      return new Response(
        JSON.stringify({ error: 'Method not allowed' }),
        {
          status: 405,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Rate limiting
    const rateLimitResult = await applyRateLimit(
      req, 
      '/respond-to-match-request',
      undefined, 
      RateLimitCategory.USER_ACTION
    );
    
    if (rateLimitResult.blocked) {
      logger.warn('Match response request blocked by rate limiting');
      return rateLimitResult.response;
    }

    // CSRF Protection for state-changing operations
    const csrfValidation = await csrfMiddleware.validateCSRF(req);
    if (!csrfValidation.valid) {
      logger.warn('Match response request blocked by CSRF validation');
      return csrfValidation.response;
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
    const sanitizedBody = sanitizeInput(body);
    const validatedRequest = MatchResponseSchema.parse(sanitizedBody);

    // Additional input validation
    const inputValidation = await validateInput(sanitizedBody, {
      requireAuth: true,
      maxDepth: 2,
      allowedFields: ['match_request_id', 'response', 'message']
    });

    if (!inputValidation.isValid) {
      logger.warn('Input validation failed', { errors: inputValidation.errors });
      return new Response(
        JSON.stringify({ 
          error: 'Invalid input data',
          details: inputValidation.errors 
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    logger.info('Match response request validated', {
      responderId: user.id,
      matchRequestId: validatedRequest.match_request_id,
      response: validatedRequest.response
    });

    // =====================================================================================
    // PROCESS MATCH REQUEST RESPONSE
    // =====================================================================================

    const responseResult = await processMatchRequestResponse(
      user.id,
      validatedRequest.match_request_id,
      validatedRequest.response,
      validatedRequest.message,
      supabaseClient,
      logger
    );

    const operationDuration = Date.now() - startTime;

    logger.info('Match response processed successfully', {
      matchRequestUpdated: responseResult.match_request_updated,
      matchCreated: responseResult.match_created,
      matchId: responseResult.match_id,
      conversationId: responseResult.conversation_id,
      duration: operationDuration
    });

    return new Response(
      JSON.stringify({
        success: true,
        data: responseResult,
        performance: {
          duration: operationDuration
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    const operationDuration = Date.now() - startTime;
    
    logger.error('Match response processing failed', {
      error: error instanceof Error ? error.message : 'Unknown error',
      stack: error instanceof Error ? error.stack : undefined,
      duration: operationDuration
    });

    const statusCode = error instanceof z.ZodError ? 400 : 500;
    const errorMessage = error instanceof z.ZodError ? 'Invalid request data' : 'Match response processing failed';

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
 * Processes match request response (accept/reject)
 * Implements atomic transaction for consistency
 */
async function processMatchRequestResponse(
  responderId: string,
  matchRequestId: string,
  response: 'accept' | 'reject',
  message: string | undefined,
  supabaseClient: any,
  logger: any
): Promise<MatchRequestResponse> {
  
  try {
    // First, verify the match request exists and the user is authorized to respond
    const { data: matchRequest, error: fetchError } = await supabaseClient
      .from('match_requests')
      .select('*')
      .eq('id', matchRequestId)
      .single();

    if (fetchError) {
      throw new Error(`Failed to fetch match request: ${fetchError.message}`);
    }

    if (!matchRequest) {
      return {
        success: false,
        match_request_updated: false,
        message: 'Match request not found'
      };
    }

    // Verify the user is authorized to respond (they are the matched_user)
    if (matchRequest.matched_user_id !== responderId) {
      logger.warn('Unauthorized match response attempt', {
        matchRequestId,
        actualMatchedUserId: matchRequest.matched_user_id,
        attemptedResponderId: responderId
      });
      
      return {
        success: false,
        match_request_updated: false,
        message: 'Not authorized to respond to this match request'
      };
    }

    // Check if already responded
    if (matchRequest.status !== 'pending') {
      return {
        success: false,
        match_request_updated: false,
        message: `Match request already ${matchRequest.status}`
      };
    }

    // Update match request status
    const newStatus: MatchRequestStatus = response === 'accept' ? 'confirmed' : 'rejected';
    const { data: updatedRequest, error: updateError } = await supabaseClient
      .from('match_requests')
      .update({
        status: newStatus,
        updated_at: new Date().toISOString(),
        response_message: message || null
      })
      .eq('id', matchRequestId)
      .select()
      .single();

    if (updateError) {
      throw new Error(`Failed to update match request: ${updateError.message}`);
    }

    logger.info('Match request status updated', {
      matchRequestId,
      newStatus,
      hasMessage: !!message
    });

    // Send notification to the requester
    const notificationSent = await sendResponseNotification(
      supabaseClient,
      matchRequest.requester_id,
      responderId,
      response,
      message,
      logger
    );

    // If accepted, create a match
    if (response === 'accept') {
      const matchResult = await createMatchFromRequest(
        supabaseClient,
        matchRequest.requester_id,
        matchRequest.matched_user_id,
        matchRequest.id,
        matchRequest.compatibility_score,
        logger
      );

      return {
        success: true,
        match_request_updated: true,
        match_created: matchResult.created,
        match_id: matchResult.match_id,
        conversation_id: matchResult.conversation_id,
        message: matchResult.created ? 'Match request accepted and match created!' : 'Match request accepted',
        notification_sent: notificationSent
      };
    }

    return {
      success: true,
      match_request_updated: true,
      match_created: false,
      message: 'Match request rejected',
      notification_sent: notificationSent
    };

  } catch (error) {
    logger.error('Error processing match request response', { error });
    throw error;
  }
}

/**
 * Creates a match from an accepted match request
 */
async function createMatchFromRequest(
  supabaseClient: any,
  requesterId: string,
  matchedUserId: string,
  matchRequestId: string,
  compatibilityScore: number | null,
  logger: any
): Promise<{ created: boolean; match_id?: string; conversation_id?: string }> {
  
  try {
    // Ensure consistent user ordering (user1_id < user2_id)
    const [user1Id, user2Id] = requesterId < matchedUserId ? [requesterId, matchedUserId] : [matchedUserId, requesterId];

    // Check if match already exists
    const { data: existingMatch, error: checkError } = await supabaseClient
      .from('matches')
      .select('id, conversation_id')
      .eq('user1_id', user1Id)
      .eq('user2_id', user2Id)
      .single();

    if (checkError && checkError.code !== 'PGRST116') {
      throw checkError;
    }

    if (existingMatch) {
      logger.warn('Match already exists', { matchId: existingMatch.id });
      return { 
        created: false, 
        match_id: existingMatch.id,
        conversation_id: existingMatch.conversation_id 
      };
    }

    // Create the match
    const { data: newMatch, error: matchError } = await supabaseClient
      .from('matches')
      .insert({
        user1_id: user1Id,
        user2_id: user2Id,
        match_request_id: matchRequestId,
        matched_at: new Date().toISOString(),
        status: 'active',
        compatibility_score: compatibilityScore,
        astro_compatibility: {},
        questionnaire_compatibility: {},
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      })
      .select()
      .single();

    if (matchError) {
      throw matchError;
    }

    logger.info('Match created from request', { 
      matchId: newMatch.id,
      matchRequestId,
      user1Id,
      user2Id
    });

    // Create conversation for the match
    const { data: conversation, error: conversationError } = await supabaseClient
      .from('conversations')
      .insert({
        user1_id: user1Id,
        user2_id: user2Id,
        match_id: newMatch.id,
        created_at: new Date().toISOString()
      })
      .select('id')
      .single();

    let conversationId: string | undefined;
    
    if (conversationError) {
      logger.error('Failed to create conversation', { error: conversationError });
    } else {
      conversationId = conversation.id;
      
      // Update match with conversation ID
      const { error: updateMatchError } = await supabaseClient
        .from('matches')
        .update({ conversation_id: conversationId })
        .eq('id', newMatch.id);

      if (updateMatchError) {
        logger.error('Failed to link conversation to match', { error: updateMatchError });
      }
    }

    // Send match notification to both users
    await sendMatchCreatedNotifications(
      supabaseClient,
      user1Id,
      user2Id,
      newMatch.id,
      conversationId,
      logger
    );

    return {
      created: true,
      match_id: newMatch.id,
      conversation_id: conversationId
    };

  } catch (error) {
    logger.error('Error creating match from request', { error });
    return { created: false };
  }
}

/**
 * Sends notification to requester about response
 */
async function sendResponseNotification(
  supabaseClient: any,
  requesterId: string,
  responderId: string,
  response: 'accept' | 'reject',
  message: string | undefined,
  logger: any
): Promise<boolean> {
  
  try {
    // Get requester's push token and responder's name
    const [requesterProfile, responderProfile] = await Promise.all([
      supabaseClient
        .from('profiles')
        .select('push_token, notification_preferences')
        .eq('id', requesterId)
        .single(),
      supabaseClient
        .from('profiles')
        .select('display_name')
        .eq('id', responderId)
        .single()
    ]);

    if (!requesterProfile?.data?.push_token || !responderProfile?.data?.display_name) {
      logger.warn('Missing data for response notification', {
        hasPushToken: !!requesterProfile?.data?.push_token,
        hasDisplayName: !!responderProfile?.data?.display_name
      });
      return false;
    }

    const title = response === 'accept' ? "🎉 Match Request Accepted!" : "💔 Match Request Declined";
    const body = response === 'accept' 
      ? `${responderProfile.data.display_name} accepted your match request!`
      : `${responderProfile.data.display_name} declined your match request.`;

    const notificationData = {
      type: `match_request_${response}`,
      from_user_id: responderId,
      response_message: message || null
    };

    // Import push notification service
    const { sendPushNotification } = await import('../_shared/sendPushNotification.ts');
    
    await sendPushNotification(
      requesterProfile.data.push_token,
      title,
      body,
      notificationData
    );

    logger.info('Response notification sent', {
      requesterId,
      response,
      hasCustomMessage: !!message
    });

    return true;

  } catch (error) {
    logger.error('Failed to send response notification', { error });
    return false;
  }
}

/**
 * Sends match created notifications to both users
 */
async function sendMatchCreatedNotifications(
  supabaseClient: any,
  user1Id: string,
  user2Id: string,
  matchId: string,
  conversationId: string | undefined,
  logger: any
): Promise<void> {
  
  try {
    const [user1Profile, user2Profile] = await Promise.all([
      supabaseClient
        .from('profiles')
        .select('push_token, display_name, notification_preferences')
        .eq('id', user1Id)
        .single(),
      supabaseClient
        .from('profiles')
        .select('push_token, display_name, notification_preferences')
        .eq('id', user2Id)
        .single()
    ]);

    const { sendPushNotification } = await import('../_shared/sendPushNotification.ts');
    const notificationPromises: Promise<void>[] = [];

    // Send to user1
    if (user1Profile?.data?.push_token && user2Profile?.data?.display_name) {
      const notification1 = sendPushNotification(
        user1Profile.data.push_token,
        "🎉 It's a Match!",
        `You and ${user2Profile.data.display_name} are now matched!`,
        {
          type: 'match_created',
          match_id: matchId,
          conversation_id: conversationId,
          other_user_id: user2Id
        }
      );
      notificationPromises.push(notification1);
    }

    // Send to user2
    if (user2Profile?.data?.push_token && user1Profile?.data?.display_name) {
      const notification2 = sendPushNotification(
        user2Profile.data.push_token,
        "🎉 It's a Match!",
        `You and ${user1Profile.data.display_name} are now matched!`,
        {
          type: 'match_created',
          match_id: matchId,
          conversation_id: conversationId,
          other_user_id: user1Id
        }
      );
      notificationPromises.push(notification2);
    }

    await Promise.allSettled(notificationPromises);

    logger.info('Match created notifications sent', {
      matchId,
      user1Id,
      user2Id,
      conversationId
    });

  } catch (error) {
    logger.error('Failed to send match created notifications', { error });
    // Don't throw - notifications are non-critical
  }
}

export { serve };
