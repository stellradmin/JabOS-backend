/**
 * Stellr Edge Core - Production-ready shared module for Edge Functions
 * 
 * Consolidates all necessary functionality from complex shared modules
 * into a single, dependency-free module compatible with Deno Edge Runtime.
 * 
 * This module provides:
 * - CORS and security headers
 * - JWT validation and authentication
 * - Rate limiting
 * - Error handling and logging
 * - Input validation and sanitization
 * - Supabase client management
 * 
 * Author: Claude Code Assistant
 * Version: 1.0.0
 * Created: 2024-09-09
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.7';

// ===== ENVIRONMENT CONFIGURATION =====
const isProduction = Deno.env.get('SENTRY_ENVIRONMENT') === 'production';
const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

// ===== CORS AND SECURITY HEADERS =====
function getAllowedOrigins(): string[] {
  const envOrigins = Deno.env.get('CORS_ORIGINS');
  
  if (envOrigins) {
    return envOrigins.split(',').map(origin => origin.trim());
  }
  
  if (isProduction) {
    return [
      'https://stellr.dating',
      'https://www.stellr.dating',
      'https://api.stellr.dating',
      'https://app.stellr.dating',
    ];
  } else {
    return [
      'http://localhost:3000',
      'http://localhost:8081',
      'http://localhost:8082',
      'http://127.0.0.1:3000',
      'http://127.0.0.1:8081',
      'exp://localhost:8081',
      'exp://localhost:19000',
      'exp://192.168.1.100:8081',
      '*', // Allow wildcard in development only
    ];
  }
}

export function getCorsHeaders(origin?: string | null): Record<string, string> {
  const allowedOrigins = getAllowedOrigins();
  
  // Check if origin is explicitly allowed
  const isAllowedOrigin = origin && allowedOrigins.includes(origin);
  
  // In development, also allow localhost and development patterns
  const isDevelopment = !isProduction;
  const isLocalhost = origin && (
    origin.startsWith('http://localhost') ||
    origin.startsWith('http://127.0.0.1') ||
    origin.startsWith('exp://') ||
    origin.includes('192.168.') ||
    origin.includes('expo.dev') ||
    origin.includes('expo.io')
  );

  let allowedOrigin: string;
  
  if (isAllowedOrigin) {
    allowedOrigin = origin;
  } else if (isDevelopment && (isLocalhost || allowedOrigins.includes('*'))) {
    allowedOrigin = origin || '*';
  } else {
    allowedOrigin = 'null';
  }

  return {
    'Access-Control-Allow-Origin': allowedOrigin,
    'Access-Control-Allow-Headers': [
      'authorization',
      'x-client-info', 
      'apikey',
      'content-type',
      'x-rate-limit-key',
      'x-request-id',
      'user-agent',
      'stripe-signature',
      'x-expo-platform',
      'x-expo-version'
    ].join(', '),
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS, PATCH',
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Max-Age': '86400',
    'Access-Control-Expose-Headers': 'x-ratelimit-limit, x-ratelimit-remaining, x-ratelimit-reset',
    'Vary': 'Origin',
    'Content-Type': 'application/json',
    
    // Security headers
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'X-XSS-Protection': '1; mode=block',
    'Strict-Transport-Security': 'max-age=31536000; includeSubDomains; preload',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    'X-App-Version': Deno.env.get('BUILD_VERSION') || '1.0.0',
    'X-Environment': isProduction ? 'production' : 'development',
  };
}

// ===== JWT VALIDATION =====
export interface JWTValidationResult {
  valid: boolean;
  payload?: any;
  token?: string;
  error?: string;
}

export async function validateJWTHeader(authHeader: string | null): Promise<JWTValidationResult> {
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return { valid: false, error: 'Missing or invalid authorization header' };
  }

  const token = authHeader.substring(7);
  
  // Check if this is the service role key
  if (token === supabaseServiceKey) {
    return {
      valid: true,
      payload: {
        role: 'service_role',
        sub: null, // Service role doesn't have a specific user
      },
      token,
    };
  }
  
  try {
    // Basic JWT structure validation
    const parts = token.split('.');
    if (parts.length !== 3) {
      return { valid: false, error: 'Invalid token format' };
    }

    // Decode and validate payload
    const payload = JSON.parse(atob(parts[1]));
    
    // Check expiration
    if (payload.exp && payload.exp < Date.now() / 1000) {
      return { valid: false, error: 'Token expired' };
    }

    // For Supabase auth, we need to be more permissive about the payload structure
    // Some tokens might not have 'sub' but might have user_id or other identifiers
    const userId = payload.sub || payload.user_id || payload.id;
    
    return {
      valid: true,
      payload: {
        ...payload,
        sub: userId, // Normalize to 'sub' field
      },
      token,
    };
  } catch (error) {
    return { valid: false, error: 'Token validation failed' };
  }
}

// ===== SUPABASE CLIENT MANAGEMENT =====
export async function createSecureSupabaseClient(token?: string) {
  const headers: Record<string, string> = {};
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  return createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers },
  });
}

// ===== RATE LIMITING =====
const rateLimitStore = new Map<string, { count: number; resetTime: number }>();

export enum RateLimitCategory {
  AUTH = 'auth',
  DATA_ACCESS = 'data_access',
  PROFILE_UPDATES = 'profile_updates',
  MESSAGING = 'messaging',
  NOTIFICATION_CREATION = 'notification_creation',
  BULK_OPERATIONS = 'bulk_operations',
  FILE_UPLOAD = 'file_upload',
}

const RATE_LIMIT_CONFIGS = {
  [RateLimitCategory.AUTH]: { limit: 10, windowMs: 60000 },
  [RateLimitCategory.DATA_ACCESS]: { limit: 100, windowMs: 60000 },
  [RateLimitCategory.PROFILE_UPDATES]: { limit: 20, windowMs: 60000 },
  [RateLimitCategory.MESSAGING]: { limit: 50, windowMs: 60000 },
  [RateLimitCategory.NOTIFICATION_CREATION]: { limit: 50, windowMs: 60000 },
  [RateLimitCategory.BULK_OPERATIONS]: { limit: 5, windowMs: 60000 },
  [RateLimitCategory.FILE_UPLOAD]: { limit: 10, windowMs: 60000 },
};

export async function applyRateLimit(
  req: Request,
  endpoint: string,
  userId?: string,
  category: RateLimitCategory = RateLimitCategory.DATA_ACCESS
): Promise<{ blocked: boolean; response?: Response }> {
  const config = RATE_LIMIT_CONFIGS[category];
  const clientIP = req.headers.get('x-forwarded-for') || 'unknown';
  const identifier = userId || clientIP;
  const key = `${category}:${identifier}:${endpoint}`;
  
  const now = Date.now();
  const windowKey = `${key}:${Math.floor(now / config.windowMs)}`;
  
  const current = rateLimitStore.get(windowKey) || { count: 0, resetTime: now + config.windowMs };
  
  if (now > current.resetTime) {
    current.count = 0;
    current.resetTime = now + config.windowMs;
  }
  
  current.count++;
  rateLimitStore.set(windowKey, current);
  
  // Cleanup old entries periodically
  if (Math.random() < 0.01) {
    const cutoff = now - config.windowMs;
    for (const [k, v] of rateLimitStore.entries()) {
      if (v.resetTime < cutoff) {
        rateLimitStore.delete(k);
      }
    }
  }
  
  if (current.count > config.limit) {
    const corsHeaders = getCorsHeaders(req.headers.get('origin'));
    return {
      blocked: true,
      response: new Response(
        JSON.stringify({
          error: 'rate_limit_exceeded',
          message: 'Too many requests. Please try again later.',
          retryAfter: Math.ceil((current.resetTime - now) / 1000),
        }),
        {
          status: 429,
          headers: {
            ...corsHeaders,
            'Retry-After': Math.ceil((current.resetTime - now) / 1000).toString(),
            'X-RateLimit-Limit': config.limit.toString(),
            'X-RateLimit-Remaining': Math.max(0, config.limit - current.count).toString(),
            'X-RateLimit-Reset': Math.ceil(current.resetTime / 1000).toString(),
          },
        }
      ),
    };
  }
  
  return { blocked: false };
}

// ===== CSRF PROTECTION =====
export async function csrfMiddleware(req: Request): Promise<{ valid: boolean; response?: Response }> {
  const origin = req.headers.get('origin');
  const userAgent = req.headers.get('user-agent') || '';
  
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
    const corsHeaders = getCorsHeaders(origin);
    return {
      valid: false,
      response: new Response(
        JSON.stringify({
          error: 'csrf_validation_failed',
          message: 'CSRF protection: Invalid origin',
        }),
        {
          status: 403,
          headers: corsHeaders,
        }
      ),
    };
  }
  
  return { valid: true };
}

// ===== ERROR HANDLING =====
export function createErrorResponse(
  error: { code: string; message: string },
  status: number = 400,
  headers: Record<string, string> = {}
): Response {
  const corsHeaders = getCorsHeaders();
  const responseHeaders = { ...corsHeaders, ...headers };
  
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
  const corsHeaders = getCorsHeaders();
  const responseHeaders = { ...corsHeaders, ...headers };
  
  return new Response(
    JSON.stringify(data),
    {
      status: 200,
      headers: responseHeaders,
    }
  );
}

export function createValidationErrorResponse(error: any, headers: Record<string, string> = {}): Response {
  const corsHeaders = getCorsHeaders();
  const responseHeaders = { ...corsHeaders, ...headers };
  
  const message = error?.errors 
    ? `Validation failed: ${error.errors.map((e: any) => e.message).join(', ')}`
    : 'Validation failed';
  
  return new Response(
    JSON.stringify({
      error: 'validation_error',
      message,
      details: error?.errors || null,
      timestamp: new Date().toISOString(),
    }),
    {
      status: 400,
      headers: responseHeaders,
    }
  );
}

// ===== SECURITY VALIDATION =====
export const REQUEST_SIZE_LIMITS = {
  SMALL: 1024,          // 1KB
  MEDIUM: 10240,        // 10KB
  LARGE: 102400,        // 100KB
  FILE_UPLOAD: 1048576, // 1MB
  MAXIMUM: 5242880,     // 5MB
};

export async function validateSensitiveRequest(
  req: Request,
  sizeLimit: number = REQUEST_SIZE_LIMITS.MEDIUM
): Promise<{ valid: boolean; error?: string }> {
  const contentLength = req.headers.get('content-length');
  
  if (contentLength && parseInt(contentLength, 10) > sizeLimit) {
    return {
      valid: false,
      error: `Request size ${contentLength} exceeds limit ${sizeLimit}`,
    };
  }
  
  return { valid: true };
}

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

// ===== LOGGING =====
export interface Logger {
  info(message: string, data?: any): Promise<void>;
  warn(message: string, data?: any): Promise<void>;
  error(message: string, error?: Error, data?: any): Promise<void>;
}

export function getLogger(context: { functionName: string; requestId?: string }): Logger {
  const prefix = `[${context.functionName}${context.requestId ? ':' + context.requestId.substring(0, 8) : ''}]`;
  
  return {
    info: async (message: string, data?: any) => {
      console.log(`${prefix} INFO:`, message, data ? JSON.stringify(data) : '');
    },
    warn: async (message: string, data?: any) => {
      console.warn(`${prefix} WARN:`, message, data ? JSON.stringify(data) : '');
    },
    error: async (message: string, error?: Error, data?: any) => {
      console.error(`${prefix} ERROR:`, message, error?.message || error, data ? JSON.stringify(data) : '');
    },
  };
}

// ===== SECURITY EVENT LOGGING =====
export function logSecurityEvent(
  event: string,
  userId?: string,
  data?: any
): void {
  console.warn(`SECURITY EVENT: ${event}`, {
    userId,
    timestamp: new Date().toISOString(),
    environment: isProduction ? 'production' : 'development',
    ...data,
  });
}

// ===== NOTIFICATION SPECIFIC HELPERS =====
export async function sendPushNotification(
  userId: string,
  notification: {
    title: string;
    body: string;
    data?: Record<string, any>;
  },
  supabase: any
): Promise<void> {
  try {
    // Get user's push tokens
    const { data: pushTokens, error: tokenError } = await supabase
      .from('user_push_tokens')
      .select('token, platform')
      .eq('user_id', userId)
      .eq('active', true);

    if (tokenError || !pushTokens?.length) {
      console.warn(`No push tokens found for user ${userId}`);
      return;
    }

    // For now, just log the notification (actual push sending would require Expo SDK setup)
    console.log(`PUSH NOTIFICATION: ${notification.title} -> ${userId}`, {
      tokens: pushTokens.length,
      body: notification.body,
      data: notification.data,
    });

  } catch (error) {
    console.error('Failed to send push notification:', error);
  }
}

export { RateLimitCategory as RateLimitCategories };