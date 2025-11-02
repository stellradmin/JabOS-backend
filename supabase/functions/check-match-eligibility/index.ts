import { serve } from 'std/http/server.ts';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts';


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
// Zod Schema for Input Validation
const EligibilityCheckSchema = z.object({
  user_a_id: z.string().uuid(),
  user_b_id: z.string().uuid(),
});

// CORS Headers
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Calculate distance between two points using Haversine formula
function calculateDistance(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const earthRadiusKm = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  
  const a = 
    Math.sin(dLat/2) * Math.sin(dLat/2) +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * 
    Math.sin(dLon/2) * Math.sin(dLon/2);
  
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
  return earthRadiusKm * c;
}

// Calculate age from birthdate
function calculateAge(birthDate: string): number {
  const today = new Date();
  const birth = new Date(birthDate);
  let age = today.getFullYear() - birth.getFullYear();
  const monthDiff = today.getMonth() - birth.getMonth();
  
  if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < birth.getDate())) {
    age--;
  }
  
  return age;
}

serve(async (req: Request) => {
  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/check-match-eligibility', undefined, RateLimitCategory.MATCHING);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }


  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  // Initialize Supabase client

  // CRITICAL SECURITY: Secure JWT validation to prevent Algorithm Confusion Attack
  const userAuthHeader = req.headers.get('Authorization');
  if (!userAuthHeader) {
    logSecurityEvent('missing_auth_header', undefined, {
      endpoint: 'check-match-eligibility',
      userAgent: req.headers.get('User-Agent')
    });
    return createErrorResponse(
      { code: 'invalid_grant', message: 'Missing authorization' },
      { endpoint: 'check-match-eligibility' },
      corsHeaders
    );
  }

  // CRITICAL SECURITY: Validate JWT to prevent "none" algorithm attacks
  const jwtValidation = validateJWTHeader(userAuthHeader);
  if (!jwtValidation.valid) {
    logSecurityEvent('jwt_validation_failed', undefined, {
      endpoint: 'check-match-eligibility',
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
        endpoint: 'check-match-eligibility',
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
      { endpoint: 'check-match-eligibility', issue: 'missing_env_vars' },
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
      endpoint: 'check-match-eligibility',
      error: secureClientResult.error,
      securityDetails: secureClientResult.securityDetails
    });
    
    return createErrorResponse(
      { code: 'server_error', message: 'Failed to create secure database connection' },
      { endpoint: 'check-match-eligibility', phase: 'secure_client_init' },
      corsHeaders
    );
  }

  const supabaseClient = secureClientResult.client;


  const { data: { user }, error: userError } = await supabaseClient.auth.getUser();

  if (userError || !user) {
    return new Response(JSON.stringify({ error: 'User not authenticated or token invalid' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401,
    });
  }

  try {
    const body = await req.json();
    const { user_a_id, user_b_id } = EligibilityCheckSchema.parse(body);

    // Fetch profile data for both users
    const { data: profileA, error: profileErrorA } = await supabaseClient
      .from('profiles')
      .select('age, app_settings, location')
      .eq('id', user_a_id)
      .single();

    const { data: profileB, error: profileErrorB } = await supabaseClient
      .from('profiles')
      .select('age, app_settings, location')
      .eq('id', user_b_id)
      .single();

    if (profileErrorA || profileErrorB) {
      return new Response(JSON.stringify({ 
        error: 'Could not fetch profile data',
        details: { profileErrorA, profileErrorB }
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400,
      });
    }

    // Extract settings with defaults
    const settingsA = profileA.app_settings || {};
    const settingsB = profileB.app_settings || {};
    
    const userASettings = {
      minAge: settingsA.min_age_preference || 18,
      maxAge: settingsA.max_age_preference || 100,
      maxDistance: settingsA.distance || 50, // Default 50 miles
    };

    const userBSettings = {
      minAge: settingsB.min_age_preference || 18,
      maxAge: settingsB.max_age_preference || 100,
      maxDistance: settingsB.distance || 50, // Default 50 miles
    };

    const eligibilityResult = {
      eligible: true,
      reasons: [] as string[],
      checks: {
        ageCompatible: true,
        distanceCompatible: true,
      }
    };

    // Age eligibility check
    if (profileA.age && profileB.age) {
      // Check if user A's age fits user B's preferences
      if (profileA.age < userBSettings.minAge || profileA.age > userBSettings.maxAge) {
        eligibilityResult.eligible = false;
        eligibilityResult.checks.ageCompatible = false;
        eligibilityResult.reasons.push(
          `User A's age (${profileA.age}) is outside User B's age preferences (${userBSettings.minAge}-${userBSettings.maxAge})`
        );
      }

      // Check if user B's age fits user A's preferences
      if (profileB.age < userASettings.minAge || profileB.age > userASettings.maxAge) {
        eligibilityResult.eligible = false;
        eligibilityResult.checks.ageCompatible = false;
        eligibilityResult.reasons.push(
          `User B's age (${profileB.age}) is outside User A's age preferences (${userASettings.minAge}-${userASettings.maxAge})`
        );
      }
    }

    // Distance eligibility check
    if (profileA.location && profileB.location) {
      // Assuming location is stored as a point or has lat/lng properties
      // You may need to adjust this based on your actual location storage format
      let locationA, locationB;
      
      try {
        // Handle different possible location formats
        if (typeof profileA.location === 'string') {
          locationA = JSON.parse(profileA.location);
        } else {
          locationA = profileA.location;
        }
        
        if (typeof profileB.location === 'string') {
          locationB = JSON.parse(profileB.location);
        } else {
          locationB = profileB.location;
        }

        // Calculate distance if we have valid coordinates
        if (locationA?.lat && locationA?.lng && locationB?.lat && locationB?.lng) {
          const distanceKm = calculateDistance(
            locationA.lat, locationA.lng,
            locationB.lat, locationB.lng
          );
          
          const distanceMiles = distanceKm * 0.621371; // Convert km to miles

          // Check against both users' distance preferences
          if (distanceMiles > userASettings.maxDistance) {
            eligibilityResult.eligible = false;
            eligibilityResult.checks.distanceCompatible = false;
            eligibilityResult.reasons.push(
              `Distance (${Math.round(distanceMiles)} miles) exceeds User A's maximum distance preference (${userASettings.maxDistance} miles)`
            );
          }

          if (distanceMiles > userBSettings.maxDistance) {
            eligibilityResult.eligible = false;
            eligibilityResult.checks.distanceCompatible = false;
            eligibilityResult.reasons.push(
              `Distance (${Math.round(distanceMiles)} miles) exceeds User B's maximum distance preference (${userBSettings.maxDistance} miles)`
            );
          }
        }
      } catch (locationError) {
// Don't fail eligibility for location parsing errors, just log it
      }
    }

    return new Response(JSON.stringify(eligibilityResult), {
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
