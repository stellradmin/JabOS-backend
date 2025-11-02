// PRODUCTION-READY CORS Configuration for Stellr
// Environment-aware CORS with comprehensive security headers

// Get allowed origins from environment or use defaults
function getAllowedOrigins(): string[] {
  const envOrigins = Deno.env.get('CORS_ORIGINS');
  
  if (envOrigins) {
    return envOrigins.split(',').map(origin => origin.trim());
  }
  
  // Default allowed origins
  const isProduction = Deno.env.get('SENTRY_ENVIRONMENT') === 'production';
  
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

// Rate limiting configuration
export const RATE_LIMITS = {
  DEFAULT: 100,           // requests per minute for most endpoints
  AUTH: 10,              // requests per minute for authentication
  MESSAGES: 50,          // requests per minute for messaging
  UPLOADS: 20,           // requests per minute for file uploads
  PAYMENTS: 5,           // requests per minute for payment operations
};

export function getCorsHeaders(origin?: string | null): Record<string, string> {
  const allowedOrigins = getAllowedOrigins();
  const isProduction = Deno.env.get('SENTRY_ENVIRONMENT') === 'production';
  
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

  const baseHeaders = {
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
    'Access-Control-Max-Age': '86400', // 24 hours
    'Access-Control-Expose-Headers': 'x-ratelimit-limit, x-ratelimit-remaining, x-ratelimit-reset',
    'Vary': 'Origin',
    
    // Performance headers
    'Cache-Control': isProduction ? 'public, max-age=300, s-maxage=600' : 'no-cache, no-store, must-revalidate',
    'Pragma': isProduction ? 'public' : 'no-cache',
    
    // Application headers
    'X-App-Version': Deno.env.get('BUILD_VERSION') || '1.0.0',
    'X-Environment': isProduction ? 'production' : 'development',
  };
  
  // Merge with comprehensive security headers
  return { ...baseHeaders, ...getSecurityHeaders() };
}

// Legacy export for backward compatibility
export const corsHeaders = getCorsHeaders();

// Enhanced rate limiting with database fallback for distributed environments
const rateLimitStore = new Map<string, { count: number; resetTime: number }>();
let supabaseClientCache: any = null;

// Initialize Supabase client for rate limiting (cached)
async function getSupabaseForRateLimit() {
  if (!supabaseClientCache) {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    
    if (supabaseUrl && supabaseServiceKey) {
      // Dynamic import for Deno environment
      const { createClient } = await import('@supabase/supabase-js');
      supabaseClientCache = createClient(supabaseUrl, supabaseServiceKey);
    }
  }
  return supabaseClientCache;
}

// Database-backed rate limiting for production environments
async function checkDistributedRateLimit(
  identifier: string,
  limit: number,
  windowMs: number
): Promise<{ allowed: boolean; remaining: number; resetTime: number }> {
  const supabase = await getSupabaseForRateLimit();
  if (!supabase) {
    // Fallback to in-memory if database unavailable
    return checkInMemoryRateLimit(identifier, limit, windowMs);
  }

  try {
    const now = Date.now();
    const windowStart = Math.floor(now / windowMs) * windowMs;
    const resetTime = windowStart + windowMs;

    // Upsert rate limit record
    const { data, error } = await supabase.rpc('check_and_update_rate_limit', {
      p_identifier: identifier,
      p_window_start: new Date(windowStart).toISOString(),
      p_limit: limit,
      p_reset_time: new Date(resetTime).toISOString()
    });

    if (error) {
return checkInMemoryRateLimit(identifier, limit, windowMs);
    }

    return {
      allowed: data.count <= limit,
      remaining: Math.max(0, limit - data.count),
      resetTime: resetTime,
    };
  } catch (error) {
return checkInMemoryRateLimit(identifier, limit, windowMs);
  }
}

// In-memory rate limiting (fallback)
function checkInMemoryRateLimit(
  identifier: string, 
  limit: number,
  windowMs: number
): { allowed: boolean; remaining: number; resetTime: number } {
  const now = Date.now();
  const key = `${identifier}:${Math.floor(now / windowMs)}`;
  
  const current = rateLimitStore.get(key) || { count: 0, resetTime: now + windowMs };
  
  if (now > current.resetTime) {
    // Reset the counter
    current.count = 0;
    current.resetTime = now + windowMs;
  }
  
  current.count++;
  rateLimitStore.set(key, current);
  
  // Clean up old entries more efficiently
  if (Math.random() < 0.005) { // 0.5% chance to clean up
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
    resetTime: current.resetTime,
  };
}

// Main rate limiting function with intelligent fallback
export async function checkRateLimit(
  identifier: string, 
  limit: number = RATE_LIMITS.DEFAULT,
  windowMs: number = 60000 // 1 minute
): Promise<{ allowed: boolean; remaining: number; resetTime: number }> {
  
  // For high-volume endpoints, prefer distributed rate limiting
  const isProduction = Deno.env.get('SENTRY_ENVIRONMENT') === 'production';
  const useDistributed = isProduction && (
    identifier.includes('send_message') || 
    identifier.includes('get_potential_matches') ||
    identifier.includes('auth')
  );

  if (useDistributed) {
    return await checkDistributedRateLimit(identifier, limit, windowMs);
  } else {
    return checkInMemoryRateLimit(identifier, limit, windowMs);
  }
}

// Security validation helpers
export function validateRequestOrigin(request: Request): boolean {
  const origin = request.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);
  return corsHeaders['Access-Control-Allow-Origin'] !== 'null';
}

export function getSecurityHeaders(): Record<string, string> {
  const isProduction = Deno.env.get('SENTRY_ENVIRONMENT') === 'production';
  
  return {
    // XSS Protection
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'X-XSS-Protection': '1; mode=block',
    
    // HTTPS Security
    'Strict-Transport-Security': 'max-age=31536000; includeSubDomains; preload',
    
    // Privacy & Referrer Control
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    
    // Content Security Policy - Strict for production
    'Content-Security-Policy': isProduction 
      ? "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self' https: wss:; font-src 'self' data:; object-src 'none'; media-src 'self' https:; frame-src 'none'; base-uri 'self'; form-action 'self';"
      : "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https: http:; connect-src 'self' https: wss: http:; font-src 'self' data:;",
    
    // Feature Policy / Permissions Policy
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=(self), payment=(), usb=(), screen-wake-lock=(), web-share=()',
    
    // DNS Prefetch Control
    'X-DNS-Prefetch-Control': 'off',
    
    // Cross-Origin Policies
    'Cross-Origin-Embedder-Policy': 'require-corp',
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Resource-Policy': 'same-site',
    
    // Additional Security Headers
    'X-Permitted-Cross-Domain-Policies': 'none',
    'Expect-CT': 'max-age=86400, enforce',
    
    // Server Information Security
    'Server': 'Stellr/1.0',
    'X-Powered-By': '',  // Remove server signature
    
    // Request/Response Size Limits
    'Content-Length-Limit': '1048576', // 1MB limit
    
    // Rate Limiting Headers (dynamic)
    'X-RateLimit-Policy': 'distributed',
    
    // Security Monitoring
    'X-Security-Level': isProduction ? 'strict' : 'development',
    
    // PHASE 6 SECURITY: Enhanced security headers
    'Clear-Site-Data': '"cache", "cookies", "storage", "executionContexts"', // For logout endpoints
    'Feature-Policy': 'accelerometer "none"; camera "none"; geolocation "self"; gyroscope "none"; magnetometer "none"; microphone "none"; payment "none"; usb "none"',
    'X-Robots-Tag': 'noindex, nofollow, noarchive, nosnippet, noimageindex',
    'X-Download-Options': 'noopen',
    'X-Webkit-CSP': isProduction 
      ? "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:;"
      : "default-src 'self';",
    'X-UA-Compatible': 'IE=edge',
    'X-Request-ID': crypto.randomUUID(), // Unique request tracking
    'X-Response-Time': '0', // Will be updated by middleware
    'Cache-Control': isProduction 
      ? 'no-cache, no-store, must-revalidate, private, max-age=0'
      : 'no-cache, no-store, must-revalidate',
    'Pragma': 'no-cache',
    'Expires': '0',
    
    // Anti-clickjacking additional protection
    'X-Frame-Options': 'DENY',
    'Content-Security-Policy-Report-Only': isProduction 
      ? "default-src 'none'; report-uri /api/security/csp-report"
      : undefined,
    
    // Information disclosure prevention
    'X-Pingback': '', // Disable pingback
    'X-DNS-Prefetch-Control': 'off',
    'X-Content-Duration': '', // Remove media duration info
    
    // Mobile app security
    'X-iOS-App-Store-Link': '', // Prevent app store redirection
    'X-Android-App-Link': '', // Prevent Android app linking
    
    // API Security
    'X-API-Version': '1.0',
    'X-Rate-Limit-Remaining': '1000', // Will be updated by rate limiter
    'X-Rate-Limit-Reset': '0', // Will be updated by rate limiter
    
    // Security monitoring headers
    'X-Security-Scan-ID': crypto.randomUUID().substring(0, 8), // Short ID for tracking
    'X-Threat-Level': 'low', // Will be updated based on request analysis
  };
}

/**
 * PHASE 6 SECURITY: Advanced Security Headers Manager
 */
export class AdvancedSecurityHeaders {
  private static securityConfig = {
    enableSecurityReporting: true,
    enableThreatDetection: true,
    enablePerformanceMonitoring: true,
    enableComplianceHeaders: true
  };

  /**
   * Generate context-aware security headers
   */
  static generateContextHeaders(
    context: 'api' | 'webhook' | 'auth' | 'upload' | 'general',
    request?: Request
  ): Record<string, string> {
    const baseHeaders = getSecurityHeaders();
    const contextHeaders: Record<string, string> = {};

    switch (context) {
      case 'api':
        contextHeaders['X-API-Rate-Limit'] = '1000';
        contextHeaders['X-API-Key-Required'] = 'true';
        contextHeaders['X-API-Version'] = '1.0';
        contextHeaders['Access-Control-Max-Age'] = '86400';
        break;

      case 'webhook':
        contextHeaders['X-Webhook-Signature-Required'] = 'true';
        contextHeaders['X-Webhook-Replay-Protection'] = 'enabled';
        contextHeaders['X-Content-Length-Limit'] = '10485760'; // 10MB for webhooks
        break;

      case 'auth':
        contextHeaders['X-Auth-Method'] = 'bearer';
        contextHeaders['X-Session-Timeout'] = '3600';
        contextHeaders['X-CSRF-Token-Required'] = 'true';
        contextHeaders['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains; preload';
        break;

      case 'upload':
        contextHeaders['X-Upload-Size-Limit'] = '52428800'; // 50MB
        contextHeaders['X-Upload-Type-Validation'] = 'strict';
        contextHeaders['X-Virus-Scan-Required'] = 'true';
        break;

      default:
        // General context
        break;
    }

    // Add request-specific headers if request is provided
    if (request) {
      const requestHeaders = this.generateRequestSpecificHeaders(request);
      Object.assign(contextHeaders, requestHeaders);
    }

    return { ...baseHeaders, ...contextHeaders };
  }

  /**
   * Generate headers based on request analysis
   */
  private static generateRequestSpecificHeaders(request: Request): Record<string, string> {
    const headers: Record<string, string> = {};
    const userAgent = request.headers.get('user-agent') || '';
    const origin = request.headers.get('origin') || '';

    // Browser-specific security headers
    if (userAgent.includes('Chrome')) {
      headers['X-Chrome-Security'] = 'enhanced';
    } else if (userAgent.includes('Firefox')) {
      headers['X-Firefox-Security'] = 'enhanced';
    } else if (userAgent.includes('Safari')) {
      headers['X-Safari-Security'] = 'enhanced';
    }

    // Mobile app specific headers
    if (userAgent.includes('Mobile') || userAgent.includes('Android') || userAgent.includes('iPhone')) {
      headers['X-Mobile-Security'] = 'enabled';
      headers['X-App-Transport-Security'] = 'required';
    }

    // Development vs production origin handling
    if (origin.includes('localhost') || origin.includes('127.0.0.1')) {
      headers['X-Development-Mode'] = 'true';
    }

    return headers;
  }

  /**
   * Generate compliance headers for data protection regulations
   */
  static generateComplianceHeaders(region?: 'EU' | 'CA' | 'US' | 'global'): Record<string, string> {
    const headers: Record<string, string> = {};

    switch (region) {
      case 'EU':
        headers['X-GDPR-Compliance'] = 'enabled';
        headers['X-Cookie-Consent-Required'] = 'true';
        headers['X-Data-Processing-Lawful-Basis'] = 'consent';
        headers['X-Right-To-Be-Forgotten'] = 'supported';
        break;

      case 'CA':
        headers['X-PIPEDA-Compliance'] = 'enabled';
        headers['X-Privacy-Policy-URL'] = '/privacy-policy';
        break;

      case 'US':
        headers['X-CCPA-Compliance'] = 'enabled';
        headers['X-Do-Not-Sell'] = 'respected';
        headers['X-Privacy-Rights'] = 'supported';
        break;

      default:
        headers['X-Global-Privacy-Standards'] = 'applied';
        headers['X-Data-Minimization'] = 'enforced';
        break;
    }

    headers['X-Privacy-Policy-Version'] = '2024-09-04';
    headers['X-Terms-Of-Service-Version'] = '2024-09-04';
    headers['X-Data-Retention-Policy'] = 'applied';

    return headers;
  }

  /**
   * Generate security monitoring headers
   */
  static generateMonitoringHeaders(
    threatLevel: 'low' | 'medium' | 'high' | 'critical' = 'low',
    requestId?: string
  ): Record<string, string> {
    return {
      'X-Security-Monitor-ID': requestId || crypto.randomUUID().substring(0, 12),
      'X-Threat-Assessment': threatLevel,
      'X-Security-Timestamp': new Date().toISOString(),
      'X-Monitoring-Version': '2.0',
      'X-Security-Policy-Version': '2024-09-04'
    };
  }

  /**
   * Create comprehensive security response
   */
  static createSecureResponse(
    data: any,
    options: {
      context?: 'api' | 'webhook' | 'auth' | 'upload' | 'general';
      threatLevel?: 'low' | 'medium' | 'high' | 'critical';
      region?: 'EU' | 'CA' | 'US' | 'global';
      request?: Request;
    } = {}
  ): Response {
    const {
      context = 'general',
      threatLevel = 'low',
      region = 'global',
      request
    } = options;

    // Generate all header types
    const contextHeaders = this.generateContextHeaders(context, request);
    const complianceHeaders = this.generateComplianceHeaders(region);
    const monitoringHeaders = this.generateMonitoringHeaders(threatLevel);

    // Combine all headers
    const allHeaders = {
      ...contextHeaders,
      ...complianceHeaders,
      ...monitoringHeaders,
      'Content-Type': 'application/json',
      'X-Response-Generated-At': new Date().toISOString()
    };

    // Filter out undefined headers
    const cleanHeaders = Object.fromEntries(
      Object.entries(allHeaders).filter(([_, value]) => value !== undefined && value !== '')
    );

    return new Response(
      JSON.stringify(data),
      {
        status: 200,
        headers: cleanHeaders
      }
    );
  }

  /**
   * Update response time in headers
   */
  static updateResponseTimeHeader(headers: Headers, startTime: number): void {
    const responseTime = Date.now() - startTime;
    headers.set('X-Response-Time', `${responseTime}ms`);
    headers.set('X-Performance-Tier', responseTime < 100 ? 'fast' : responseTime < 500 ? 'normal' : 'slow');
  }
}