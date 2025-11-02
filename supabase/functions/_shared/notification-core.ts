/**
 * Notification Core - Lightweight shared module for notification Edge Functions
 * Contains only essential functionality to minimize boot dependencies
 */

import { createClient } from '@supabase/supabase-js';

// CORS Headers
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
};

// Environment check
const isProduction = Deno.env.get('SENTRY_ENVIRONMENT') === 'production';

// Enhanced CORS headers with security
export function getCorsHeaders(origin?: string | null): Record<string, string> {
  const isDevelopment = !isProduction;
  const isLocalhost = origin && (
    origin.startsWith('http://localhost') ||
    origin.startsWith('http://127.0.0.1') ||
    origin.startsWith('exp://') ||
    origin.includes('192.168.') ||
    origin.includes('expo.dev')
  );

  let allowedOrigin = '*';
  if (isProduction && origin) {
    const allowedOrigins = [
      'https://stellr.dating',
      'https://www.stellr.dating',
      'https://api.stellr.dating',
      'https://app.stellr.dating',
    ];
    allowedOrigin = allowedOrigins.includes(origin) ? origin : 'null';
  } else if (isDevelopment && (isLocalhost || !origin)) {
    allowedOrigin = origin || '*';
  }

  return {
    'Access-Control-Allow-Origin': allowedOrigin,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-request-id',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Max-Age': '86400',
    'Content-Type': 'application/json',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
  };
}

// JWT Validation
export async function validateJWTHeader(authHeader: string | null): Promise<{
  valid: boolean;
  payload?: any;
  token?: string;
  error?: string;
}> {
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return { valid: false, error: 'Missing or invalid authorization header' };
  }

  const token = authHeader.substring(7); // Remove 'Bearer ' prefix
  
  try {
    // For development, we'll do basic validation
    // In production, this should integrate with Supabase JWT validation
    const parts = token.split('.');
    if (parts.length !== 3) {
      return { valid: false, error: 'Invalid token format' };
    }

    // Basic payload extraction (simplified)
    const payload = JSON.parse(atob(parts[1]));
    
    // Check expiration
    if (payload.exp && payload.exp < Date.now() / 1000) {
      return { valid: false, error: 'Token expired' };
    }

    return {
      valid: true,
      payload,
      token,
    };
  } catch (error) {
    return { valid: false, error: 'Token validation failed' };
  }
}

// Create secure Supabase client
export function createSecureSupabaseClient(token?: string) {
  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  
  const headers: Record<string, string> = {};
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  return createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers },
  });
}

// Simple rate limiting (in-memory)
const rateLimitStore = new Map<string, { count: number; resetTime: number }>();

export function checkRateLimit(
  identifier: string,
  limit: number = 100,
  windowMs: number = 60000
): { allowed: boolean; remaining: number } {
  const now = Date.now();
  const key = `${identifier}:${Math.floor(now / windowMs)}`;
  
  const current = rateLimitStore.get(key) || { count: 0, resetTime: now + windowMs };
  
  if (now > current.resetTime) {
    current.count = 0;
    current.resetTime = now + windowMs;
  }
  
  current.count++;
  rateLimitStore.set(key, current);
  
  // Cleanup old entries periodically
  if (Math.random() < 0.01) {
    const cutoff = now - windowMs;
    for (const [k, v] of rateLimitStore.entries()) {
      if (v.resetTime < cutoff) {
        rateLimitStore.delete(k);
      }
    }
  }
  
  return {
    allowed: current.count <= limit,
    remaining: Math.max(0, limit - current.count),
  };
}

// Response helpers
export function createErrorResponse(
  error: { code: string; message: string },
  status: number = 400,
  headers: Record<string, string> = {}
): Response {
  const responseHeaders = { ...getCorsHeaders(), ...headers };
  
  return new Response(
    JSON.stringify({
      error: error.code,
      message: error.message,
      timestamp: new Date().toISOString(),
    }),
    {
      status,
      headers: responseHeaders,
    }
  );
}

export function createSuccessResponse(
  data: any,
  headers: Record<string, string> = {}
): Response {
  const responseHeaders = { ...getCorsHeaders(), ...headers };
  
  return new Response(
    JSON.stringify(data),
    {
      status: 200,
      headers: responseHeaders,
    }
  );
}

// Basic input validation
export function validateUUID(value: string): boolean {
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  return uuidRegex.test(value);
}

export function validateTextInput(
  text: string,
  options: { minLength?: number; maxLength?: number; allowSpecialChars?: boolean } = {}
): { isValid: boolean; error?: string } {
  const { minLength = 0, maxLength = 1000, allowSpecialChars = false } = options;
  
  if (text.length < minLength) {
    return { isValid: false, error: `Text must be at least ${minLength} characters` };
  }
  
  if (text.length > maxLength) {
    return { isValid: false, error: `Text must not exceed ${maxLength} characters` };
  }
  
  if (!allowSpecialChars) {
    const hasUnsafeChars = /<script|javascript:|on\w+\s*=/i.test(text);
    if (hasUnsafeChars) {
      return { isValid: false, error: 'Text contains unsafe characters' };
    }
  }
  
  return { isValid: true };
}

// Basic logging
export function getLogger(context: { functionName: string; requestId?: string }) {
  const prefix = `[${context.functionName}${context.requestId ? ':' + context.requestId.substring(0, 8) : ''}]`;
  
  return {
    info: (message: string, data?: any) => {
      console.log(`${prefix} INFO:`, message, data ? JSON.stringify(data) : '');
    },
    warn: (message: string, data?: any) => {
      console.warn(`${prefix} WARN:`, message, data ? JSON.stringify(data) : '');
    },
    error: (message: string, error?: Error, data?: any) => {
      console.error(`${prefix} ERROR:`, message, error?.message || error, data ? JSON.stringify(data) : '');
    },
  };
}

// Security logging
export function logSecurityEvent(
  event: string,
  userId?: string,
  data?: any
): void {
  console.warn(`SECURITY EVENT: ${event}`, {
    userId,
    timestamp: new Date().toISOString(),
    ...data,
  });
}

// CSRF protection (simplified)
export function validateCSRF(request: Request): { valid: boolean; error?: string } {
  // In development or for mobile apps, we can be more lenient
  const origin = request.headers.get('origin');
  const userAgent = request.headers.get('user-agent') || '';
  
  // Skip CSRF for mobile apps
  if (userAgent.includes('Mobile') || userAgent.includes('Android') || userAgent.includes('iPhone')) {
    return { valid: true };
  }
  
  // Skip CSRF for development localhost
  if (!isProduction && origin && origin.includes('localhost')) {
    return { valid: true };
  }
  
  // For production web requests, require proper origin
  if (isProduction && (!origin || origin === 'null')) {
    return { valid: false, error: 'CSRF protection: Invalid origin' };
  }
  
  return { valid: true };
}

export { corsHeaders };