import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';

// PHASE 4 SECURITY: CSRF Protection for profile updates
import { csrfMiddleware } from '../_shared/csrf-protection.ts';

// deno-lint-ignore-file no-explicit-any
import { serve } from 'std/http/server.ts'; // Using import map
import { createClient, SupabaseClient } from '@supabase/supabase-js'; // Using import map
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts'; import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
// Zod often used directly

// Zod Schema for updatable profile fields
const UpdateProfilePayloadSchema = z.object({
  display_name: z.string().min(1, "Display name cannot be empty.").max(100, "Display name too long.").optional(),
  bio: z.string().max(500, "Bio is too long.").optional().nullable(), 
  avatar_url: z.string().url("Invalid avatar URL.").optional().nullable(), 
  // TODO: Expand with other user-editable fields from your 'profiles' table schema
  // For example:
  // interests: z.array(z.string()).optional(),
  // city: z.string().optional().nullable(),
}).strict("Only specified profile fields can be updated."); 

// CORS Headers
const corsHeaders = {
  'Access-Control-Allow-Origin': '*', // Adjust for production
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS', 
};

serve(async (req: Request) => {
  // PHASE 4 SECURITY: CSRF Protection for profile updates
  const csrfValidation = await csrfMiddleware.validateCSRF(req);
  if (!csrfValidation.valid) {
    return csrfValidation.response;
  }

  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/update-my-profile', undefined, RateLimitCategory.PROFILE_UPDATES);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  let supabaseClient: SupabaseClient;
  try {

  // CRITICAL SECURITY: Secure JWT validation to prevent Algorithm Confusion Attack
  const userAuthHeader = req.headers.get('Authorization');
  if (!userAuthHeader) {
    logSecurityEvent('missing_auth_header', undefined, {
      endpoint: 'update-my-profile',
      userAgent: req.headers.get('User-Agent')
    });
    return createErrorResponse(
      { code: 'invalid_grant', message: 'Missing authorization' },
      { endpoint: 'update-my-profile' },
      corsHeaders
    );
  }

  // CRITICAL SECURITY: Validate JWT to prevent "none" algorithm attacks
  const jwtValidation = validateJWTHeader(userAuthHeader);
  if (!jwtValidation.valid) {
    logSecurityEvent('jwt_validation_failed', undefined, {
      endpoint: 'update-my-profile',
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
        endpoint: 'update-my-profile',
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
      { endpoint: 'update-my-profile', issue: 'missing_env_vars' },
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
      endpoint: 'update-my-profile',
      error: secureClientResult.error,
      securityDetails: secureClientResult.securityDetails
    });
    
    return createErrorResponse(
      { code: 'server_error', message: 'Failed to create secure database connection' },
      { endpoint: 'update-my-profile', phase: 'secure_client_init' },
      corsHeaders
    );
  }

  const supabaseClient = secureClientResult.client;

  } catch (e: any) {
return new Response(JSON.stringify({ error: 'Failed to initialize Supabase client' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500,
    });
  }
  
  const { data: { user }, error: userError } = await supabaseClient.auth.getUser();

  if (userError || !user) {
    return new Response(JSON.stringify({ error: 'User not authenticated or token invalid' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401,
    });
  }

  try {
    const body = await req.json();
    const validatedPayload = UpdateProfilePayloadSchema.parse(body);

    const updates: Record<string, any> = {};
    for (const key in validatedPayload) {
      if (validatedPayload[key as keyof typeof validatedPayload] !== undefined) {
        updates[key] = validatedPayload[key as keyof typeof validatedPayload];
      }
    }

    if (Object.keys(updates).length === 0) {
      return new Response(JSON.stringify({ error: 'No valid fields provided for update.' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400,
      });
    }
    
    updates.updated_at = new Date().toISOString();

    const { data: updatedProfile, error: updateError } = await supabaseClient
      .from('profiles')
      .update(updates)
      .eq('id', user.id) 
      .select() 
      .single();

    if (updateError) {
throw updateError;
    }
    if (!updatedProfile) {
        throw new Error('Failed to update profile or profile not found.');
    }

    return new Response(JSON.stringify(updatedProfile), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (e: any) {
const errorMessage = e instanceof Error ? e.message : 'An unexpected error occurred.';
    const errorDetails = e instanceof ZodError ? e.flatten() : undefined;
    return new Response(JSON.stringify({ error: errorMessage, details: errorDetails, type: e.name }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: e instanceof ZodError ? 400 : 500,
    });
  }
});
