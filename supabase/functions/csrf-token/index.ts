/**
 * CSRF Token Generation Endpoint
 * 
 * This endpoint generates CSRF tokens for client applications to use
 * when making state-changing requests to protected endpoints.
 * 
 * PHASE 4 SECURITY: CSRF Protection Implementation
 */

import { serve } from 'std/http/server.ts';
import { getCorsHeaders } from '../_shared/cors.ts';
import { csrfMiddleware } from '../_shared/csrf-protection.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';

serve(async (req: Request) => {
  // Apply rate limiting for token generation
  const rateLimitResult = await applyRateLimit(req, '/csrf-token', undefined, RateLimitCategory.AUTH);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }

  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  // Enhanced security headers for token endpoint
  const securityHeaders = {
    ...corsHeaders,
    'X-Frame-Options': 'DENY',
    'X-Content-Type-Options': 'nosniff',
    'X-XSS-Protection': '1; mode=block',
    'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
    'Cache-Control': 'no-cache, no-store, must-revalidate',
    'Pragma': 'no-cache',
    'Expires': '0'
  };

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: securityHeaders });
  }

  if (req.method !== 'POST') {
    return new Response(
      JSON.stringify({
        error: 'Method not allowed',
        message: 'Only POST requests are allowed'
      }),
      {
        status: 405,
        headers: {
          ...securityHeaders,
          'Content-Type': 'application/json'
        }
      }
    );
  }

  try {
    // Generate CSRF token using the middleware
    return await csrfMiddleware.generateToken(req);
  } catch (error) {
    console.error('CSRF token generation error:', error);
    
    return new Response(
      JSON.stringify({
        error: 'Token generation failed',
        message: 'Unable to generate CSRF token. Please try again.'
      }),
      {
        status: 500,
        headers: {
          ...securityHeaders,
          'Content-Type': 'application/json'
        }
      }
    );
  }
});
