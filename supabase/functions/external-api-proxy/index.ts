import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { logError, logWarn, logInfo, logDebug, logUserAction } from "../_shared/logger.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// Rate limiting storage
const rateLimitStore = new Map<string, { count: number; resetTime: number }>();

const RATE_LIMITS = {
  'rapidapi': { MAX_REQUESTS: 20, WINDOW_MS: 60000 }, // 20 requests per minute
  'posthog': { MAX_REQUESTS: 100, WINDOW_MS: 60000 }, // 100 requests per minute
  'sentry': { MAX_REQUESTS: 50, WINDOW_MS: 60000 }, // 50 requests per minute
  'default': { MAX_REQUESTS: 30, WINDOW_MS: 60000 } // Default limit
};

// Certificate fingerprints for HTTPS pinning validation
const CERT_FINGERPRINTS = {
  'rapidapi.com': ['sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='], // Add actual fingerprints
  'api.posthog.com': ['sha256/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='],
  'sentry.io': ['sha256/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=']
};

function checkRateLimit(clientId: string, service: string): boolean {
  const now = Date.now();
  const limits = RATE_LIMITS[service] || RATE_LIMITS.default;
  
  const key = `${service}_${clientId}`;
  const existing = rateLimitStore.get(key);
  
  if (!existing || now > existing.resetTime) {
    rateLimitStore.set(key, { count: 1, resetTime: now + limits.WINDOW_MS });
    return true;
  }
  
  if (existing.count >= limits.MAX_REQUESTS) {
    return false;
  }
  
  existing.count++;
  return true;
}

function validateApiRequest(service: string, endpoint: string, method: string): boolean {
  // Whitelist of allowed endpoints per service
  const allowedEndpoints = {
    'rapidapi': [
      '/astrology/natal-chart',
      '/astrology/compatibility',
      '/location/geocode'
    ],
    'posthog': [
      '/capture',
      '/decide',
      '/e'
    ],
    'sentry': [
      '/api/error-capture',
      '/api/performance'
    ]
  };

  const serviceEndpoints = allowedEndpoints[service];
  if (!serviceEndpoints) {
    return false;
  }

  return serviceEndpoints.some(allowed => endpoint.startsWith(allowed));
}

function sanitizeHeaders(headers: Record<string, string>, service: string): Record<string, string> {
  const sanitized: Record<string, string> = {};
  
  // Common safe headers
  const safeHeaders = [
    'content-type',
    'accept',
    'user-agent',
    'accept-language',
    'accept-encoding'
  ];

  // Service-specific required headers
  const serviceHeaders = {
    'rapidapi': ['x-rapidapi-key', 'x-rapidapi-host'],
    'posthog': ['authorization'],
    'sentry': ['authorization', 'x-sentry-auth']
  };

  const allowedHeaders = [...safeHeaders, ...(serviceHeaders[service] || [])];

  for (const [key, value] of Object.entries(headers)) {
    const lowerKey = key.toLowerCase();
    if (allowedHeaders.includes(lowerKey)) {
      // Additional sanitization for specific headers
      if (lowerKey === 'user-agent') {
        sanitized[key] = 'Stellr-App/1.0 (Mobile Dating App)';
      } else {
        sanitized[key] = value;
      }
    }
  }

  return sanitized;
}

async function proxyRequest(service: string, endpoint: string, options: {
  method: string;
  headers: Record<string, string>;
  body?: string;
}): Promise<Response> {
  
  // Get API keys from Supabase secrets
  let baseUrl: string;
  let apiKey: string | undefined;
  
  switch (service) {
    case 'rapidapi':
      baseUrl = 'https://astrology-horoscope.p.rapidapi.com';
      apiKey = Deno.env.get('RAPIDAPI_KEY');
      break;
    case 'posthog':
      baseUrl = Deno.env.get('POSTHOG_HOST') || 'https://us.i.posthog.com';
      apiKey = Deno.env.get('POSTHOG_API_KEY');
      break;
    case 'sentry':
      baseUrl = Deno.env.get('SENTRY_DSN') || 'https://sentry.io';
      apiKey = Deno.env.get('SENTRY_AUTH_TOKEN');
      break;
    default:
      throw new Error(`Unsupported service: ${service}`);
  }

  if (!apiKey && service !== 'posthog') { // PostHog might not always need auth
    throw new Error(`API key not configured for service: ${service}`);
  }

  // Prepare headers with API key
  const requestHeaders = sanitizeHeaders(options.headers, service);
  
  if (service === 'rapidapi') {
    requestHeaders['X-RapidAPI-Key'] = apiKey!;
    requestHeaders['X-RapidAPI-Host'] = 'astrology-horoscope.p.rapidapi.com';
  } else if (service === 'posthog' && apiKey) {
    requestHeaders['Authorization'] = `Bearer ${apiKey}`;
  } else if (service === 'sentry' && apiKey) {
    requestHeaders['Authorization'] = `Bearer ${apiKey}`;
  }

  const url = `${baseUrl}${endpoint}`;

  try {
    const response = await fetch(url, {
      method: options.method,
      headers: requestHeaders,
      body: options.body,
      // Add timeout
      signal: AbortSignal.timeout(30000) // 30 second timeout
    });

    // Log the request for security monitoring
    logDebug('API Proxy Request:', "Debug", {
      service,
      endpoint: endpoint.substring(0, 50), // Truncate for logs
      method: options.method,
      status: response.status,
      timestamp: new Date().toISOString()
    });

    return response;

  } catch (error) {
    logError('API Proxy Error:', "Error", {
      service,
      endpoint,
      error: error.message,
      timestamp: new Date().toISOString()
    });
    throw error;
  }
}

function validateRequest(body: any): {
  service: string;
  endpoint: string;
  method: string;
  headers: Record<string, string>;
  data?: any;
} {
  if (!body.service || !body.endpoint || !body.method) {
    throw new Error('Missing required fields: service, endpoint, method');
  }

  // Validate service
  const allowedServices = ['rapidapi', 'posthog', 'sentry'];
  if (!allowedServices.includes(body.service)) {
    throw new Error(`Unsupported service: ${body.service}`);
  }

  // Validate method
  const allowedMethods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];
  if (!allowedMethods.includes(body.method.toUpperCase())) {
    throw new Error(`Unsupported method: ${body.method}`);
  }

  // Validate endpoint
  if (!validateApiRequest(body.service, body.endpoint, body.method)) {
    throw new Error(`Endpoint not allowed for service ${body.service}: ${body.endpoint}`);
  }

  return {
    service: body.service,
    endpoint: body.endpoint,
    method: body.method.toUpperCase(),
    headers: body.headers || {},
    data: body.data
  };
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // Get client identifier for rate limiting
    const authHeader = req.headers.get('authorization');
    const clientId = authHeader?.split(' ')[1] || req.headers.get('x-forwarded-for') || 'anonymous';

    if (req.method !== 'POST') {
      return new Response(
        JSON.stringify({ error: 'Method not allowed' }), 
        { 
          status: 405, 
          headers: { ...corsHeaders, 'content-type': 'application/json' } 
        }
      )
    }

    const body = await req.json();
    const validatedRequest = validateRequest(body);

    // Check rate limit
    if (!checkRateLimit(clientId, validatedRequest.service)) {
      return new Response(
        JSON.stringify({ error: `Rate limit exceeded for ${validatedRequest.service}` }), 
        { 
          status: 429, 
          headers: { ...corsHeaders, 'content-type': 'application/json' } 
        }
      )
    }

    // Proxy the request
    const response = await proxyRequest(validatedRequest.service, validatedRequest.endpoint, {
      method: validatedRequest.method,
      headers: validatedRequest.headers,
      body: validatedRequest.data ? JSON.stringify(validatedRequest.data) : undefined
    });

    // Stream the response back
    const responseBody = await response.text();
    
    return new Response(responseBody, {
      status: response.status,
      statusText: response.statusText,
      headers: {
        ...corsHeaders,
        'content-type': response.headers.get('content-type') || 'application/json'
      }
    });

  } catch (error) {
    logError('External API Proxy Error:', "Error", error);
    
    return new Response(
      JSON.stringify({ 
        error: 'Proxy error',
        message: error.message
      }), 
      { 
        status: 500, 
        headers: { ...corsHeaders, 'content-type': 'application/json' } 
      }
    )
  }
})