/**
 * PHASE 4 SECURITY: Comprehensive CSRF/XSRF Protection for Stellr
 * 
 * This module provides robust protection against Cross-Site Request Forgery attacks
 * with multiple validation layers, token management, and origin verification.
 * 
 * Features:
 * - Double Submit Cookie pattern
 * - Synchronizer Token pattern
 * - Origin and Referer validation
 * - SameSite cookie enforcement
 * - Custom header verification
 * - Rate limiting for token requests
 */

import { logSecurityEvent } from './error-handler.ts';
import { checkRateLimit } from './cors.ts';

// CSRF Protection Configuration
export interface CSRFConfig {
  tokenLength: number;
  tokenTTL: number; // Time to live in milliseconds
  cookieName: string;
  headerName: string;
  enforceOriginCheck: boolean;
  enforceSameSite: boolean;
  requireCustomHeader: boolean;
  allowedOrigins: string[];
  tokenRotationInterval: number;
}

// Default CSRF configuration
const DEFAULT_CSRF_CONFIG: CSRFConfig = {
  tokenLength: 32,
  tokenTTL: 30 * 60 * 1000, // 30 minutes
  cookieName: 'stellr-csrf-token',
  headerName: 'X-CSRF-Token',
  enforceOriginCheck: true,
  enforceSameSite: true,
  requireCustomHeader: true,
  allowedOrigins: [], // Will be populated from CORS configuration
  tokenRotationInterval: 15 * 60 * 1000, // 15 minutes
};

// CSRF Token Store (in-memory for Edge Functions, consider Redis for production)
interface CSRFTokenData {
  token: string;
  userId?: string;
  sessionId?: string;
  createdAt: number;
  lastUsed: number;
  usageCount: number;
  clientIP: string;
  userAgent: string;
}

class CSRFTokenStore {
  private static store = new Map<string, CSRFTokenData>();
  private static readonly MAX_TOKENS_PER_IP = 10;
  private static readonly MAX_TOKEN_USAGE = 50; // Max times a token can be used

  static generateToken(): string {
    const array = new Uint8Array(DEFAULT_CSRF_CONFIG.tokenLength);
    crypto.getRandomValues(array);
    return Array.from(array, byte => byte.toString(16).padStart(2, '0')).join('');
  }

  static storeToken(
    token: string,
    clientIP: string,
    userAgent: string,
    userId?: string,
    sessionId?: string
  ): void {
    // Clean up old tokens first
    this.cleanup();

    // Enforce per-IP token limit
    const ipTokens = Array.from(this.store.values()).filter(data => data.clientIP === clientIP);
    if (ipTokens.length >= this.MAX_TOKENS_PER_IP) {
      // Remove oldest token for this IP
      const oldestToken = ipTokens.sort((a, b) => a.createdAt - b.createdAt)[0];
      for (const [key, value] of this.store.entries()) {
        if (value === oldestToken) {
          this.store.delete(key);
          break;
        }
      }
    }

    const now = Date.now();
    this.store.set(token, {
      token,
      userId,
      sessionId,
      createdAt: now,
      lastUsed: now,
      usageCount: 0,
      clientIP,
      userAgent,
    });
  }

  static validateAndUseToken(
    token: string,
    clientIP: string,
    userAgent: string
  ): {
    valid: boolean;
    reason?: string;
    tokenData?: CSRFTokenData;
  } {
    const tokenData = this.store.get(token);
    
    if (!tokenData) {
      return { valid: false, reason: 'Token not found' };
    }

    const now = Date.now();

    // Check if token has expired
    if (now - tokenData.createdAt > DEFAULT_CSRF_CONFIG.tokenTTL) {
      this.store.delete(token);
      return { valid: false, reason: 'Token expired' };
    }

    // Check if token has been overused
    if (tokenData.usageCount >= this.MAX_TOKEN_USAGE) {
      this.store.delete(token);
      return { valid: false, reason: 'Token usage limit exceeded' };
    }

    // Validate client IP (optional - can be disabled for mobile apps)
    if (tokenData.clientIP !== clientIP) {
      // Allow IP changes but log suspicious activity
      logSecurityEvent('csrf_token_ip_mismatch', undefined, {
        originalIP: tokenData.clientIP,
        currentIP: clientIP,
        token: token.substring(0, 8) + '...',
        userAgent: userAgent.substring(0, 50)
      });
    }

    // Update usage statistics
    tokenData.lastUsed = now;
    tokenData.usageCount++;

    return { valid: true, tokenData };
  }

  static cleanup(): void {
    const now = Date.now();
    const expiredTokens: string[] = [];

    for (const [token, data] of this.store.entries()) {
      if (now - data.createdAt > DEFAULT_CSRF_CONFIG.tokenTTL) {
        expiredTokens.push(token);
      }
    }

    for (const token of expiredTokens) {
      this.store.delete(token);
    }
  }

  static getStats(): {
    totalTokens: number;
    activeTokens: number;
    expiredTokens: number;
  } {
    const now = Date.now();
    let activeTokens = 0;
    let expiredTokens = 0;

    for (const data of this.store.values()) {
      if (now - data.createdAt > DEFAULT_CSRF_CONFIG.tokenTTL) {
        expiredTokens++;
      } else {
        activeTokens++;
      }
    }

    return {
      totalTokens: this.store.size,
      activeTokens,
      expiredTokens
    };
  }
}

/**
 * PHASE 4 SECURITY: Main CSRF Protection Class
 */
export class CSRFProtection {
  private config: CSRFConfig;

  constructor(config: Partial<CSRFConfig> = {}) {
    this.config = { ...DEFAULT_CSRF_CONFIG, ...config };
  }

  /**
   * Generate a new CSRF token
   */
  async generateToken(request: Request): Promise<{
    token: string;
    cookie: string;
    expires: Date;
  }> {
    const clientIP = this.extractClientIP(request);
    const userAgent = request.headers.get('user-agent') || 'unknown';

    // Rate limit token generation
    const rateLimitResult = await checkRateLimit(
      `csrf_token_${clientIP}`,
      10, // Max 10 tokens per minute
      60000 // 1 minute window
    );

    if (!rateLimitResult.allowed) {
      throw new Error('CSRF token generation rate limit exceeded');
    }

    const token = CSRFTokenStore.generateToken();
    const expires = new Date(Date.now() + this.config.tokenTTL);

    // Store token with metadata
    CSRFTokenStore.storeToken(token, clientIP, userAgent);

    // Create secure cookie
    const cookieOptions = [
      `${this.config.cookieName}=${token}`,
      `Expires=${expires.toUTCString()}`,
      'Path=/',
      'HttpOnly',
      'Secure',
      'SameSite=Strict'
    ];

    const cookie = cookieOptions.join('; ');

    // Log token generation for monitoring
    logSecurityEvent('csrf_token_generated', undefined, {
      clientIP,
      userAgent: userAgent.substring(0, 100),
      tokenPrefix: token.substring(0, 8),
      expires: expires.toISOString()
    });

    return { token, cookie, expires };
  }

  /**
   * Validate CSRF protection for incoming requests
   */
  async validateRequest(request: Request): Promise<{
    valid: boolean;
    reason?: string;
    shouldBlock: boolean;
  }> {
    const method = request.method.toUpperCase();
    
    // Skip CSRF validation for safe methods
    if (['GET', 'HEAD', 'OPTIONS', 'TRACE'].includes(method)) {
      return { valid: true, shouldBlock: false };
    }

    const clientIP = this.extractClientIP(request);
    const userAgent = request.headers.get('user-agent') || 'unknown';

    try {
      // 1. Origin/Referer validation
      if (this.config.enforceOriginCheck) {
        const originCheck = this.validateOrigin(request);
        if (!originCheck.valid) {
          await this.logSecurityViolation('csrf_origin_validation_failed', request, originCheck.reason);
          return { valid: false, reason: originCheck.reason, shouldBlock: true };
        }
      }

      // 2. Custom header validation (helps prevent simple form submissions)
      if (this.config.requireCustomHeader) {
        const hasCustomHeader = request.headers.has('X-Requested-With') ||
                               request.headers.has('X-CSRF-Token') ||
                               request.headers.has('X-API-Key');
        
        if (!hasCustomHeader) {
          await this.logSecurityViolation('csrf_custom_header_missing', request, 'Missing custom header');
          return { valid: false, reason: 'Missing custom header', shouldBlock: true };
        }
      }

      // 3. Double Submit Cookie validation
      const tokenValidation = this.validateDoubleSubmitCookie(request);
      if (!tokenValidation.valid) {
        await this.logSecurityViolation('csrf_token_validation_failed', request, tokenValidation.reason);
        return { valid: false, reason: tokenValidation.reason, shouldBlock: true };
      }

      // 4. Token usage validation
      const token = this.extractToken(request);
      if (token) {
        const tokenUsage = CSRFTokenStore.validateAndUseToken(token, clientIP, userAgent);
        if (!tokenUsage.valid) {
          await this.logSecurityViolation('csrf_token_usage_invalid', request, tokenUsage.reason);
          return { valid: false, reason: tokenUsage.reason, shouldBlock: true };
        }
      }

      return { valid: true, shouldBlock: false };

    } catch (error) {
      await this.logSecurityViolation('csrf_validation_error', request, `Validation error: ${error.message}`);
      return { valid: false, reason: 'Validation error', shouldBlock: true };
    }
  }

  /**
   * Validate origin header against allowed origins
   */
  private validateOrigin(request: Request): { valid: boolean; reason?: string } {
    const origin = request.headers.get('origin');
    const referer = request.headers.get('referer');

    // If no origin header, check referer as fallback
    const sourceOrigin = origin || (referer ? new URL(referer).origin : null);

    if (!sourceOrigin) {
      return { valid: false, reason: 'Missing origin and referer headers' };
    }

    // Get allowed origins from environment or configuration
    const allowedOrigins = this.getAllowedOrigins();
    
    if (!allowedOrigins.includes(sourceOrigin) && !allowedOrigins.includes('*')) {
      return { valid: false, reason: `Origin ${sourceOrigin} not allowed` };
    }

    return { valid: true };
  }

  /**
   * Validate double submit cookie pattern
   */
  private validateDoubleSubmitCookie(request: Request): { valid: boolean; reason?: string } {
    // Extract token from cookie
    const cookieHeader = request.headers.get('cookie') || '';
    const cookieMatch = cookieHeader.match(new RegExp(`${this.config.cookieName}=([^;]+)`));
    const cookieToken = cookieMatch ? cookieMatch[1] : null;

    // Extract token from header or body
    const headerToken = request.headers.get(this.config.headerName);
    
    if (!cookieToken) {
      return { valid: false, reason: 'CSRF cookie not found' };
    }

    if (!headerToken) {
      return { valid: false, reason: 'CSRF header not found' };
    }

    // Compare tokens (timing-safe comparison)
    if (!this.secureCompare(cookieToken, headerToken)) {
      return { valid: false, reason: 'CSRF token mismatch' };
    }

    return { valid: true };
  }

  /**
   * Extract CSRF token from request
   */
  private extractToken(request: Request): string | null {
    // Try header first
    const headerToken = request.headers.get(this.config.headerName);
    if (headerToken) return headerToken;

    // Try cookie as fallback
    const cookieHeader = request.headers.get('cookie') || '';
    const cookieMatch = cookieHeader.match(new RegExp(`${this.config.cookieName}=([^;]+)`));
    return cookieMatch ? cookieMatch[1] : null;
  }

  /**
   * Timing-safe string comparison
   */
  private secureCompare(a: string, b: string): boolean {
    if (a.length !== b.length) return false;

    let result = 0;
    for (let i = 0; i < a.length; i++) {
      result |= a.charCodeAt(i) ^ b.charCodeAt(i);
    }
    return result === 0;
  }

  /**
   * Extract client IP from request headers
   */
  private extractClientIP(request: Request): string {
    const forwardedFor = request.headers.get('x-forwarded-for');
    const realIP = request.headers.get('x-real-ip');
    const cfConnectingIP = request.headers.get('cf-connecting-ip');
    
    return cfConnectingIP || realIP || forwardedFor?.split(',')[0]?.trim() || 'unknown';
  }

  /**
   * Get allowed origins from configuration
   */
  private getAllowedOrigins(): string[] {
    if (this.config.allowedOrigins.length > 0) {
      return this.config.allowedOrigins;
    }

    // Fallback to environment configuration
    const envOrigins = Deno.env.get('CORS_ORIGINS');
    if (envOrigins) {
      return envOrigins.split(',').map(origin => origin.trim());
    }

    // Default origins based on environment
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
        'http://127.0.0.1:3000',
        'exp://localhost:8081'
      ];
    }
  }

  /**
   * Log security violations
   */
  private async logSecurityViolation(
    eventType: string,
    request: Request,
    reason: string
  ): Promise<void> {
    const clientIP = this.extractClientIP(request);
    const userAgent = request.headers.get('user-agent') || 'unknown';
    const origin = request.headers.get('origin') || 'unknown';
    const referer = request.headers.get('referer') || 'unknown';

    await logSecurityEvent(eventType, undefined, {
      reason,
      clientIP,
      userAgent: userAgent.substring(0, 100),
      origin,
      referer,
      method: request.method,
      url: request.url,
      timestamp: new Date().toISOString()
    });
  }
}

/**
 * PHASE 4 SECURITY: Middleware factory for CSRF protection
 */
export function createCSRFMiddleware(config?: Partial<CSRFConfig>) {
  const csrfProtection = new CSRFProtection(config);

  return {
    /**
     * Generate CSRF token endpoint
     */
    generateToken: async (request: Request): Promise<Response> => {
      try {
        const { token, cookie, expires } = await csrfProtection.generateToken(request);
        
        return new Response(
          JSON.stringify({
            token,
            expires: expires.toISOString(),
            message: 'CSRF token generated successfully'
          }),
          {
            status: 200,
            headers: {
              'Content-Type': 'application/json',
              'Set-Cookie': cookie,
              'Cache-Control': 'no-cache, no-store, must-revalidate',
              'Pragma': 'no-cache'
            }
          }
        );
      } catch (error) {
        return new Response(
          JSON.stringify({ error: 'Failed to generate CSRF token' }),
          { 
            status: 429,
            headers: { 'Content-Type': 'application/json' }
          }
        );
      }
    },

    /**
     * Validate CSRF token middleware
     */
    validateCSRF: async (request: Request): Promise<{ valid: true } | { valid: false; response: Response }> => {
      const validation = await csrfProtection.validateRequest(request);
      
      if (!validation.valid) {
        const status = validation.shouldBlock ? 403 : 400;
        
        return {
          valid: false,
          response: new Response(
            JSON.stringify({
              error: 'CSRF validation failed',
              reason: validation.reason,
              code: 'CSRF_VALIDATION_ERROR'
            }),
            {
              status,
              headers: {
                'Content-Type': 'application/json',
                'X-Content-Type-Options': 'nosniff',
                'X-Frame-Options': 'DENY'
              }
            }
          )
        };
      }

      return { valid: true };
    },

    /**
     * Get CSRF protection statistics
     */
    getStats: (): Response => {
      const stats = CSRFTokenStore.getStats();
      
      return new Response(
        JSON.stringify({
          ...stats,
          config: {
            tokenTTL: config?.tokenTTL || DEFAULT_CSRF_CONFIG.tokenTTL,
            enforceOriginCheck: config?.enforceOriginCheck ?? DEFAULT_CSRF_CONFIG.enforceOriginCheck,
            requireCustomHeader: config?.requireCustomHeader ?? DEFAULT_CSRF_CONFIG.requireCustomHeader
          }
        }),
        {
          status: 200,
          headers: { 'Content-Type': 'application/json' }
        }
      );
    }
  };
}

// Convenience exports
export const defaultCSRFProtection = new CSRFProtection();
export const csrfMiddleware = createCSRFMiddleware();

// Export for testing
export { CSRFTokenStore };