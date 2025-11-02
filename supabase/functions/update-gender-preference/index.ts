import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';


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
const UpdateGenderPreferenceSchema = z.object({
  preference: z.enum(['male', 'female', 'both', 'any', 'non-binary', 'transgender'])
});

// CORS headers
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

serve(async (req: Request) => {
  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/update-gender-preference', undefined, RateLimitCategory.PROFILE_UPDATES);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }


  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {

  // CRITICAL SECURITY: Secure JWT validation to prevent Algorithm Confusion Attack
  const userAuthHeader = req.headers.get('Authorization');
  if (!userAuthHeader) {
    logSecurityEvent('missing_auth_header', undefined, {
      endpoint: 'update-gender-preference',
      userAgent: req.headers.get('User-Agent')
    });
    return createErrorResponse(
      { code: 'invalid_grant', message: 'Missing authorization' },
      { endpoint: 'update-gender-preference' },
      corsHeaders
    );
  }

  // CRITICAL SECURITY: Validate JWT to prevent "none" algorithm attacks
  const jwtValidation = validateJWTHeader(userAuthHeader);
  if (!jwtValidation.valid) {
    logSecurityEvent('jwt_validation_failed', undefined, {
      endpoint: 'update-gender-preference',
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
        endpoint: 'update-gender-preference',
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
      { endpoint: 'update-gender-preference', issue: 'missing_env_vars' },
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
      endpoint: 'update-gender-preference',
      error: secureClientResult.error,
      securityDetails: secureClientResult.securityDetails
    });
    
    return createErrorResponse(
      { code: 'server_error', message: 'Failed to create secure database connection' },
      { endpoint: 'update-gender-preference', phase: 'secure_client_init' },
      corsHeaders
    );
  }

  const supabaseClient = secureClientResult.client;


    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();

    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'User not authenticated' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      });
    }

    const body = await req.json();
    const { preference } = UpdateGenderPreferenceSchema.parse(body);

    // Use the database function to update the preference
    const { data, error } = await supabaseClient.rpc('update_user_looking_for', {
      user_id: user.id,
      preference: preference
    });

    if (error) {
return new Response(JSON.stringify({ error: 'Failed to update preference' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      });
    }

    return new Response(JSON.stringify({ 
      success: true, 
      message: 'Gender preference updated successfully',
      preference: preference 
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error) {
return new Response(JSON.stringify({ error: 'Internal server error' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }
});
