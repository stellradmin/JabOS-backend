import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { getCorsHeaders, checkRateLimit, RATE_LIMITS } from '../_shared/cors.ts';
import { sendPushNotification } from '../_shared/sendPushNotification.ts';

// Use enhanced rate limiting (supports explicit category parameter)
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';
// Input validation schema
const PushNotificationSchema = z.object({
  recipient_id: z.string().uuid(),
  title: z.string().min(1).max(100),
  body: z.string().min(1).max(200),
  data: z.record(z.string()).optional(),
});

serve(async (req: Request) => {
  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/send-push-notification', undefined, RateLimitCategory.PROFILE_UPDATES);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }


  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  // Initialize Supabase client with authentication

  // CRITICAL SECURITY: Secure JWT validation to prevent Algorithm Confusion Attack
  const userAuthHeader = req.headers.get('Authorization');
  if (!userAuthHeader) {
    logSecurityEvent('missing_auth_header', undefined, {
      endpoint: 'send-push-notification',
      userAgent: req.headers.get('User-Agent')
    });
    return createErrorResponse(
      { code: 'invalid_grant', message: 'Missing authorization' },
      { endpoint: 'send-push-notification' },
      corsHeaders
    );
  }

  // CRITICAL SECURITY: Validate JWT to prevent "none" algorithm attacks
  const jwtValidation = validateJWTHeader(userAuthHeader);
  if (!jwtValidation.valid) {
    logSecurityEvent('jwt_validation_failed', undefined, {
      endpoint: 'send-push-notification',
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
        endpoint: 'send-push-notification',
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
      { endpoint: 'send-push-notification', issue: 'missing_env_vars' },
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
      endpoint: 'send-push-notification',
      error: secureClientResult.error,
      securityDetails: secureClientResult.securityDetails
    });
    
    return createErrorResponse(
      { code: 'server_error', message: 'Failed to create secure database connection' },
      { endpoint: 'send-push-notification', phase: 'secure_client_init' },
      corsHeaders
    );
  }

  const supabaseClient = secureClientResult.client;


  // Authenticate user
  const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
  if (userError || !user) {
    return new Response(JSON.stringify({ error: 'User not authenticated' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 401,
    });
  }

  try {
    // Rate limiting
    const rateLimitKey = `push_notification:${user.id}`;
    const rateLimit = checkRateLimit(rateLimitKey, RATE_LIMITS.MESSAGES);
    
    if (!rateLimit.allowed) {
      return new Response(JSON.stringify({ 
        error: 'Rate limit exceeded',
        remaining: rateLimit.remaining,
        resetTime: rateLimit.resetTime
      }), {
        headers: { 
          ...corsHeaders, 
          'Content-Type': 'application/json',
          'X-RateLimit-Limit': RATE_LIMITS.MESSAGES.toString(),
          'X-RateLimit-Remaining': rateLimit.remaining.toString(),
          'X-RateLimit-Reset': Math.ceil(rateLimit.resetTime / 1000).toString(),
        },
        status: 429,
      });
    }

    // Validate input
    const body = await req.json();
    const validatedData = PushNotificationSchema.parse(body);

    // SECURITY FIX: Verify sender has permission to send to recipient using separate queries
    // Check if users are in a conversation together
    const { data: conversation1 } = await supabaseClient
      .from('conversations')
      .select('id')
      .eq('user1_id', user.id)
      .eq('user2_id', validatedData.recipient_id)
      .limit(1)
      .maybeSingle();
      
    const { data: conversation2 } = await supabaseClient
      .from('conversations')
      .select('id')
      .eq('user1_id', validatedData.recipient_id)
      .eq('user2_id', user.id)
      .limit(1)
      .maybeSingle();
      
    const conversation = conversation1 || conversation2;
    const convError = !conversation;

    if (convError || !conversation) {
      return new Response(JSON.stringify({ error: 'Not authorized to send notifications to this user' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 403,
      });
    }

    // Get recipient's push token
    const { data: recipientProfile, error: profileError } = await supabaseClient
      .from('profiles')
      .select('push_token')
      .eq('id', validatedData.recipient_id)
      .single();

    if (profileError || !recipientProfile?.push_token) {
      return new Response(JSON.stringify({ error: 'Recipient push token not found' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 404,
      });
    }

    // Send push notification (implement with your preferred service)
    // This is a placeholder - replace with actual push notification service
    const notificationPayload = {
      to: recipientProfile.push_token,
      title: validatedData.title,
      body: validatedData.body,
      data: validatedData.data || {},
    };

    // Send actual push notification using the shared function
    if (recipientProfile.push_token) {
      await sendPushNotification(
        recipientProfile.push_token,
        validatedData.title,
        validatedData.body,
        validatedData.data || {}
      );
      // Debug logging removed for security
} else {
      // Debug logging removed for security
}

    return new Response(JSON.stringify({ 
      success: true,
      message: 'Push notification sent successfully'
    }), {
      headers: { 
        ...corsHeaders, 
        'Content-Type': 'application/json',
        'X-RateLimit-Remaining': rateLimit.remaining.toString(),
      },
      status: 200,
    });

  } catch (error: any) {
if (error instanceof z.ZodError) {
      return new Response(JSON.stringify({
        error: 'Invalid request data',
        details: error.errors
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      });
    }

    return new Response(JSON.stringify({
      error: 'Internal server error',
      message: error.message
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }
});
