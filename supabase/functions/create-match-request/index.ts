import { serve } from 'std/http/server.ts';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { sendPushNotification } from '../_shared/sendPushNotification.ts';
import { 
  handleError, 
  createErrorContext, 
  EdgeFunctionError, 
  ErrorCode,
  validateEnvironment,
  withRetry
} from '../_shared/error-handler.ts';

// Zod Schema for Input Validation - aligned with database schema
const CreateMatchRequestSchema = z.object({
  matched_user_id: z.string().uuid('Invalid user ID format'),
  compatibility_score: z.number().int().min(0).max(100).optional(),
  compatibility_details: z.object({
    astro_compatibility: z.record(z.unknown()).optional(),
    questionnaire_compatibility: z.record(z.unknown()).optional()
  }).optional()
});

type CreateMatchRequestInput = z.infer<typeof CreateMatchRequestSchema>;

// Import CORS headers from shared module
import { corsHeaders } from '../_shared/cors.ts';

import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';
serve(async (req: Request) => {
  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/create-match-request', undefined, RateLimitCategory.MATCHING);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }


  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  // Validate environment variables
  validateEnvironment(['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY']);

  let supabaseClient: SupabaseClient;
  
  try {
    // Initialize Supabase client with auth header
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }, 
        status: 401,
      });
    }
    
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

    if (!supabaseUrl || !supabaseAnonKey) {
      // Structured error logging for missing environment variables
      console.error('CRITICAL: Missing Supabase environment variables', {
        supabaseUrl: !!supabaseUrl,
        supabaseAnonKey: !!supabaseAnonKey,
        timestamp: new Date().toISOString(),
        endpoint: 'create-match-request'
      });
return new Response(JSON.stringify({ error: 'Server configuration error' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }, 
        status: 500,
      });
    }
    
    supabaseClient = createClient(
      supabaseUrl,
      supabaseAnonKey,
      { global: { headers: { Authorization: authHeader } } }
    );

    // Authenticate user
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !user) {
      // Structured error logging for authentication failure
      console.error('Authentication failed in create-match-request', {
        error: userError?.message || 'No user found',
        timestamp: new Date().toISOString(),
        endpoint: 'create-match-request'
      });
return new Response(JSON.stringify({ 
        error: 'User not authenticated',
        details: userError?.message
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }, 
        status: 401,
      });
    }

    // Parse and validate request body
    const body = await req.json();
    const validatedData = CreateMatchRequestSchema.parse(body);

    // Debug logging removed for security

    // SECURITY FIX: Check if users are already matched using separate queries
    const { data: existingMatch1 } = await supabaseClient
      .from('matches')
      .select('id')
      .eq('user1_id', user.id)
      .eq('user2_id', validatedData.matched_user_id)
      .maybeSingle();
      
    const { data: existingMatch2 } = await supabaseClient
      .from('matches')
      .select('id')
      .eq('user1_id', validatedData.matched_user_id)
      .eq('user2_id', user.id)
      .maybeSingle();
      
    const existingMatch = existingMatch1 || existingMatch2;

    if (existingMatch) {
      return new Response(JSON.stringify({ 
        error: 'Users are already matched',
        match_id: existingMatch.id
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }, 
        status: 409,
      });
    }

    // Check for existing pending request
    const { data: existingRequest } = await supabaseClient
      .from('match_requests')
      .select('id, status')
      .eq('requester_id', user.id)
      .eq('matched_user_id', validatedData.matched_user_id)
      .in('status', ['pending', 'active'])
      .single();

    if (existingRequest) {
      return new Response(JSON.stringify({ 
        error: 'An active match request already exists',
        request_id: existingRequest.id,
        status: existingRequest.status
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }, 
        status: 409,
      });
    }

    // Check if the other user has already requested a match with this user
    const { data: reverseRequest } = await supabaseClient
      .from('match_requests')
      .select('id')
      .eq('requester_id', validatedData.matched_user_id)
      .eq('matched_user_id', user.id)
      .eq('status', 'pending')
      .single();

    if (reverseRequest) {
      // Auto-confirm the match since both users want to match
      // Debug logging removed for security
// Update the reverse request to confirmed
      await supabaseClient
        .from('match_requests')
        .update({ status: 'confirmed', updated_at: new Date().toISOString() })
        .eq('id', reverseRequest.id);

      // Create the match
      const { data: newMatch, error: matchError } = await supabaseClient
        .rpc('create_match_from_request', { p_match_request_id: reverseRequest.id });

      if (matchError) {
        // Structured error logging for match creation failure
        console.error('Failed to create match from match request', {
          error: matchError.message,
          matchRequestId: reverseRequest.id,
          timestamp: new Date().toISOString(),
          endpoint: 'create-match-request'
        });
throw matchError;
      }

      // Send push notifications to both users
      try {
        await sendPushNotification(user.id, {
          title: 'It\'s a match!',
          body: 'You have a new match!'
        });
        await sendPushNotification(validatedData.matched_user_id, {
          title: 'It\'s a match!',
          body: 'You have a new match!'
        });
      } catch (notifError) {
        // Structured error logging for notification failure (non-blocking)
        console.warn('Failed to send match notifications', {
          error: notifError instanceof Error ? notifError.message : 'Unknown error',
          timestamp: new Date().toISOString(),
          endpoint: 'create-match-request'
        });
}

      return new Response(JSON.stringify({
        success: true,
        match_id: newMatch,
        message: 'Match confirmed!'
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      });
    }

    // Create new match request
    const { data: newRequest, error: createError } = await supabaseClient
      .from('match_requests')
      .insert({
        requester_id: user.id,
        matched_user_id: validatedData.matched_user_id,
        status: 'pending',
        compatibility_score: validatedData.compatibility_score,
        compatibility_details: validatedData.compatibility_details || {}
      })
      .select()
      .single();

    if (createError) {
      // Structured error logging for match request creation failure
      console.error('Failed to create match request', {
        error: createError.message,
        requesterId: user.id,
        matchedUserId: validatedInput.matched_user_id,
        timestamp: new Date().toISOString(),
        endpoint: 'create-match-request'
      });
throw createError;
    }

    // Send push notification to the matched user
    try {
      await sendPushNotification(validatedData.matched_user_id, {
        title: 'New match request!',
        body: 'Someone wants to match with you'
      });
    } catch (notifError) {
      // Structured error logging for notification failure (non-blocking)
      console.warn('Failed to send match request notification', {
        error: notifError instanceof Error ? notifError.message : 'Unknown error',
        timestamp: new Date().toISOString(),
        endpoint: 'create-match-request'
      });
}

    // Debug logging removed for security
return new Response(JSON.stringify({
      success: true,
      request: newRequest
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 201,
    });

  } catch (error) {
    // Comprehensive error logging for unhandled errors
    console.error('Critical error in create-match-request endpoint', {
      error: error instanceof Error ? error.message : 'Unknown error',
      stack: error instanceof Error ? error.stack : undefined,
      errorType: error?.constructor?.name || 'UnknownError',
      timestamp: new Date().toISOString(),
      endpoint: 'create-match-request'
    });
    
    if (error instanceof ZodError) {
      return new Response(JSON.stringify({ 
        error: 'Invalid request data',
        details: error.flatten()
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      });
    }
    
    return new Response(JSON.stringify({ 
      error: error instanceof Error ? error.message : 'An unexpected error occurred'
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }
});
