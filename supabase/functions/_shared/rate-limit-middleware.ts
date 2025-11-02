/**
 * CRITICAL SECURITY: Comprehensive Rate Limiting Middleware for Stellr Edge Functions
 * 
 * Features:
 * - Tiered rate limits based on operation cost
 * - Distributed rate limiting with database fallback
 * - Request context analysis for intelligent limiting
 * - Circuit breaker integration
 * - Real-time monitoring and alerting
 * - Whitelist/blacklist support
 * - Exponential backoff for repeated violations
 */

import { checkRateLimit, RATE_LIMITS } from './cors.ts';
// Removed unused import: supabaseAdmin
import { getAdvancedCache } from './advanced-cache-system.ts';
import { getEnhancedCache, StellarCacheKeys } from './redis-enhanced.ts';
import { getPerformanceMonitor } from './performance-monitor.ts';
import { 
  handleError, 
  createErrorContext, 
  EdgeFunctionError, 
  ErrorCode 
} from './error-handler.ts';

// Enhanced configurable rate limit configurations with environment support
interface RateLimitConfig {
  limit: number;
  windowMs: number;
  description: string;
  blockDurationMs: number;
  burstLimit?: number; // Allow burst traffic up to this limit
  exponentialBackoff?: boolean; // Apply exponential backoff on violations
  skipWhitelist?: boolean; // Skip whitelist checks for this category
}

// Get environment-based configuration with fallbacks
const getEnvRateLimit = (category: string, defaultConfig: RateLimitConfig): RateLimitConfig => {
  const envPrefix = `RATE_LIMIT_${category.toUpperCase()}`;
  
  return {
    limit: parseInt(Deno.env.get(`${envPrefix}_LIMIT`) || defaultConfig.limit.toString(), 10),
    windowMs: parseInt(Deno.env.get(`${envPrefix}_WINDOW_MS`) || defaultConfig.windowMs.toString(), 10),
    description: defaultConfig.description,
    blockDurationMs: parseInt(Deno.env.get(`${envPrefix}_BLOCK_MS`) || defaultConfig.blockDurationMs.toString(), 10),
    burstLimit: defaultConfig.burstLimit ? parseInt(Deno.env.get(`${envPrefix}_BURST`) || defaultConfig.burstLimit.toString(), 10) : undefined,
    exponentialBackoff: defaultConfig.exponentialBackoff,
    skipWhitelist: defaultConfig.skipWhitelist,
  };
};

// Tiered rate limit configurations as specified (now configurable via environment)
export const TIERED_RATE_LIMITS = {
  // Authentication operations - strictest limits
  AUTHENTICATION: getEnvRateLimit('AUTHENTICATION', {
    limit: 5,
    windowMs: 60000, // 1 minute
    description: 'Auth operations (login, register, password reset)',
    blockDurationMs: 300000, // 5 minutes block on violation
    burstLimit: 8, // Allow short bursts for legitimate use
    exponentialBackoff: true,
  }),
  
  // Matching operations - as per requirements: 10 requests/minute
  MATCHING: getEnvRateLimit('MATCHING', {
    limit: 10,
    windowMs: 60000, // 1 minute
    description: 'Matching operations (get matches, swipe, compatibility)',
    blockDurationMs: 120000, // 2 minutes block on violation
    burstLimit: 15, // Allow some burst for quick swipes
    exponentialBackoff: true,
  }),
  
  // Compatibility calculations - as per requirements: 5 requests/minute
  COMPATIBILITY: getEnvRateLimit('COMPATIBILITY', {
    limit: 5,
    windowMs: 60000, // 1 minute
    description: 'Compatibility calculations and detailed analysis',
    blockDurationMs: 180000, // 3 minutes block on violation
    burstLimit: 7,
    exponentialBackoff: true,
  }),
  
  // Profile operations - as per requirements: 3 requests/minute for updates
  PROFILE_UPDATES: getEnvRateLimit('PROFILE_UPDATES', {
    limit: 3,
    windowMs: 60000, // 1 minute
    description: 'Profile updates and modifications',
    blockDurationMs: 60000, // 1 minute block on violation
    burstLimit: 5, // Allow quick successive updates
    exponentialBackoff: true,
  }),
  
  // Messaging operations - high throughput
  MESSAGING: getEnvRateLimit('MESSAGING', {
    limit: 60,
    windowMs: 60000, // 1 minute
    description: 'Messaging and conversation operations',
    blockDurationMs: 30000, // 30 seconds block on violation
    burstLimit: 80,
    exponentialBackoff: false, // Less strict for messaging
  }),
  
  // File upload operations - strict limits due to resource cost
  FILE_UPLOADS: getEnvRateLimit('FILE_UPLOADS', {
    limit: 10,
    windowMs: 60000, // 1 minute
    description: 'File upload operations (photos, media)',
    blockDurationMs: 180000, // 3 minutes block on violation
    burstLimit: 12,
    exponentialBackoff: true,
  }),
  
  // Payment operations - very strict
  PAYMENTS: getEnvRateLimit('PAYMENTS', {
    limit: 3,
    windowMs: 60000, // 1 minute
    description: 'Payment and subscription operations',
    blockDurationMs: 600000, // 10 minutes block on violation
    exponentialBackoff: true,
    skipWhitelist: true, // Always apply strict limits for payments
  }),
  
  // General API calls - as per requirements: 100 requests/minute
  DEFAULT: getEnvRateLimit('DEFAULT', {
    limit: 100,
    windowMs: 60000, // 1 minute
    description: 'General API operations',
    blockDurationMs: 60000, // 1 minute block on violation
    burstLimit: 120,
    exponentialBackoff: false,
  }),
} as const;

// Rate limit categories for different endpoint types
export const ENDPOINT_CATEGORIES = {
  // Authentication endpoints
  '/auth': 'AUTHENTICATION',
  '/login': 'AUTHENTICATION',
  '/register': 'AUTHENTICATION',
  '/complete-onboarding-profile': 'AUTHENTICATION',
  '/delete-user-account': 'AUTHENTICATION',
  
  // Matching endpoints
  
  '/get-potential-matches-optimized': 'MATCHING',
  '/create-match-request': 'MATCHING',
  '/confirm-system-match': 'MATCHING',
  '/check-match-eligibility': 'MATCHING',
  '/record-swipe': 'MATCHING',
  
  // Compatibility calculation endpoints (separate from matching)
  '/get-compatibility-details': 'COMPATIBILITY',
  '/calculate-compatibility-encrypted': 'COMPATIBILITY',
  '/calculate-natal-chart': 'COMPATIBILITY',
  
  // Profile operations
  '/update-my-profile': 'PROFILE_UPDATES',
  '/update-user-settings': 'PROFILE_UPDATES',
  '/update-gender-preference': 'PROFILE_UPDATES',
  '/get-gender-preference': 'PROFILE_UPDATES',
  
  // Messaging operations
  '/send-message': 'MESSAGING',
  '/get-my-conversations': 'MESSAGING',
  '/manage-date-proposal': 'MESSAGING',
  '/get-date-proposals': 'MESSAGING',
  
  // File operations (if any endpoint handles file uploads)
  '/upload': 'FILE_UPLOADS',
  
  // Payment operations
  '/create-checkout-session': 'PAYMENTS',
  '/stripe-webhook': 'PAYMENTS',
  
  // Notification operations
  '/send-push-notification': 'MESSAGING',
  
  // Reporting operations
  '/report-issue': 'DEFAULT',
  
  // Health check (exempt from rate limiting)
  '/health-check': 'EXEMPT',
} as const;

// Redis-backed rate limiting and blocking system
const redisCache = getEnhancedCache();

// Whitelist management (configurable via environment)
const WHITELISTED_IPS = new Set((Deno.env.get('RATE_LIMIT_WHITELIST_IPS') || '').split(',').filter(ip => ip.length > 0));
const WHITELISTED_USERS = new Set((Deno.env.get('RATE_LIMIT_WHITELIST_USERS') || '').split(',').filter(id => id.length > 0));

// Rate limiting performance tracking
interface RateLimitMetrics {
  requestsBlocked: number;
  requestsAllowed: number;
  averageResponseTime: number;
  cacheHitRate: number;
  lastReset: string;
}

let rateLimitMetrics: RateLimitMetrics = {
  requestsBlocked: 0,
  requestsAllowed: 0,
  averageResponseTime: 0,
  cacheHitRate: 0,
  lastReset: new Date().toISOString(),
};

interface RateLimitContext {
  endpoint: string;
  userId?: string;
  ip?: string;
  userAgent?: string;
  requestSize: number;
  hasFiles: boolean;
  isAuthenticated: boolean;
  subscriptionTier?: 'free' | 'premium' | 'admin';
}

interface RateLimitResult {
  allowed: boolean;
  remaining: number;
  resetTime: number;
  category: string;
  blocked?: boolean;
  blockUntil?: number;
  reason?: string;
  retryAfter?: number;
}

/**
 * Determine rate limit category for an endpoint
 */
function determineRateLimitCategory(endpoint: string): keyof typeof TIERED_RATE_LIMITS {
  // Check exact matches first
  for (const [pattern, category] of Object.entries(ENDPOINT_CATEGORIES)) {
    if (endpoint === pattern || endpoint.includes(pattern)) {
      return category as keyof typeof TIERED_RATE_LIMITS;
    }
  }
  
  // Fallback to pattern matching
  if (endpoint.includes('auth') || endpoint.includes('login') || endpoint.includes('register')) {
    return 'AUTHENTICATION';
  }
  
  if (endpoint.includes('match') || endpoint.includes('compatibility') || endpoint.includes('swipe')) {
    return 'MATCHING';
  }
  
  if (endpoint.includes('profile') || endpoint.includes('settings') || endpoint.includes('preference')) {
    return 'PROFILE_UPDATES';
  }
  
  if (endpoint.includes('message') || endpoint.includes('conversation') || endpoint.includes('proposal')) {
    return 'MESSAGING';
  }
  
  if (endpoint.includes('upload') || endpoint.includes('file') || endpoint.includes('photo')) {
    return 'FILE_UPLOADS';
  }
  
  if (endpoint.includes('payment') || endpoint.includes('stripe') || endpoint.includes('checkout')) {
    return 'PAYMENTS';
  }
  
  return 'DEFAULT';
}

/**
 * Get rate limit configuration with subscription tier adjustments
 */
function getRateLimitConfig(
  category: keyof typeof TIERED_RATE_LIMITS,
  subscriptionTier: 'free' | 'premium' | 'admin' = 'free'
): typeof TIERED_RATE_LIMITS[keyof typeof TIERED_RATE_LIMITS] {
  const baseConfig = TIERED_RATE_LIMITS[category];
  
  // Premium users get higher limits (except for auth and payments)
  if (subscriptionTier === 'premium' && category !== 'AUTHENTICATION' && category !== 'PAYMENTS') {
    return {
      ...baseConfig,
      limit: Math.floor(baseConfig.limit * 1.5), // 50% increase
      blockDurationMs: Math.floor(baseConfig.blockDurationMs * 0.75), // 25% shorter blocks
    };
  }
  
  // Admin users get very high limits (except payments)
  if (subscriptionTier === 'admin' && category !== 'PAYMENTS') {
    return {
      ...baseConfig,
      limit: baseConfig.limit * 10, // 10x increase
      blockDurationMs: Math.floor(baseConfig.blockDurationMs * 0.1), // 90% shorter blocks
    };
  }
  
  return baseConfig;
}

/**
 * Check if user/IP is currently blocked using Redis
 */
async function checkBlocked(userId?: string, ip?: string): Promise<{ blocked: boolean; reason?: string; until?: number }> {
  const now = Date.now();
  
  // Check user block
  if (userId) {
    const userBlockKey = StellarCacheKeys.rateLimit(`blocked_user:${userId}`, 'permanent');
    const userBlock = await redisCache.get<{ until: number; reason: string; violations: number }>(userBlockKey);
    
    if (userBlock && userBlock.until > now) {
      return { blocked: true, reason: userBlock.reason, until: userBlock.until };
    } else if (userBlock && userBlock.until <= now) {
      // Expired block, remove it
      await redisCache.delete(userBlockKey);
    }
  }
  
  // Check IP block
  if (ip) {
    const ipBlockKey = StellarCacheKeys.rateLimit(`blocked_ip:${ip}`, 'permanent');
    const ipBlock = await redisCache.get<{ until: number; reason: string; violations: number }>(ipBlockKey);
    
    if (ipBlock && ipBlock.until > now) {
      return { blocked: true, reason: ipBlock.reason, until: ipBlock.until };
    } else if (ipBlock && ipBlock.until <= now) {
      // Expired block, remove it
      await redisCache.delete(ipBlockKey);
    }
  }
  
  return { blocked: false };
}

/**
 * Block user/IP with escalating penalties using Redis
 */
async function blockIdentifier(
  identifier: string,
  type: 'user' | 'ip',
  duration: number,
  reason: string
): Promise<void> {
  const now = Date.now();
  
  // Get violation history from Redis
  const violationKey = StellarCacheKeys.rateLimit(`violations:${identifier}`, 'history');
  const violations = await redisCache.get<{ count: number; lastViolation: number; level: number }>(violationKey) || 
    { count: 0, lastViolation: 0, level: 0 };
  
  // Escalate penalties for repeated violations
  violations.count++;
  violations.lastViolation = now;
  
  // Calculate escalation level (resets after 24 hours of good behavior)
  const dayAgo = 24 * 60 * 60 * 1000;
  if (now - violations.lastViolation > dayAgo) {
    violations.level = 0; // Reset escalation
  } else {
    violations.level = Math.min(violations.level + 1, 5); // Max level 5
  }
  
  // Apply escalation multiplier with exponential backoff
  const escalationMultiplier = Math.pow(2, violations.level); // 2^level
  const finalDuration = duration * escalationMultiplier;
  
  const blockInfo = {
    until: now + finalDuration,
    reason: `${reason} (Level ${violations.level} violation)`,
    violations: violations.count,
  };
  
  // Store block information in Redis
  const blockKey = StellarCacheKeys.rateLimit(`blocked_${type}:${identifier}`, 'permanent');
  await redisCache.set(blockKey, blockInfo, { ttl: Math.ceil(finalDuration / 1000) });
  
  // Update violation history
  await redisCache.set(violationKey, violations, { ttl: dayAgo / 1000 }); // Keep for 24 hours
  
  // Update metrics
  rateLimitMetrics.requestsBlocked++;
  
  // Log the block for monitoring
  const monitor = getPerformanceMonitor();
  monitor.recordMetric({
    name: 'rate_limit.block_applied',
    value: finalDuration,
    unit: 'ms',
    tags: {
      type,
      reason: reason.substring(0, 50), // Truncate for logging
      level: violations.level.toString(),
    },
    metadata: {
      identifier: identifier.substring(0, 20), // Truncate for security
      violations: violations.count,
    },
  });
}

/**
 * Get user's subscription tier (with caching)
 */
async function getUserSubscriptionTier(userId: string): Promise<'free' | 'premium' | 'admin'> {
  try {
    const cache = getAdvancedCache();
    const cacheKey = `subscription_tier:${userId}`;
    
    // Try cache first
    const cached = await cache.get<string>(cacheKey);
    if (cached) {
      return cached as 'free' | 'premium' | 'admin';
    }
    
    // Query database
    const { data, error } = await supabaseAdmin
      .from('profiles')
      .select('subscription_status, is_admin')
      .eq('id', userId)
      .single();
    
    if (error || !data) {
      return 'free'; // Default to free on error
    }
    
    let tier: 'free' | 'premium' | 'admin' = 'free';
    
    if (data.is_admin) {
      tier = 'admin';
    } else if (data.subscription_status === 'active') {
      tier = 'premium';
    }
    
    // Cache for 5 minutes
    await cache.set(cacheKey, tier, 300);
    
    return tier;
  } catch (error) {
    // Fail safely to free tier
    return 'free';
  }
}

/**
 * Enhanced rate limiting check function with whitelist support and Redis storage
 */
export async function checkRateLimitWithContext(
  context: RateLimitContext
): Promise<RateLimitResult> {
  const startTime = performance.now();
  const category = determineRateLimitCategory(context.endpoint);
  const rateLimitConfig = getRateLimitConfig(category, context.subscriptionTier || 'free');
  
  // Health check endpoints are exempt
  if (category === 'EXEMPT') {
    rateLimitMetrics.requestsAllowed++;
    return {
      allowed: true,
      remaining: 999,
      resetTime: Date.now() + 60000,
      category: 'EXEMPT',
    };
  }
  
  // Check whitelist (unless explicitly disabled for this category)
  if (!rateLimitConfig.skipWhitelist) {
    const isWhitelisted = (context.ip && WHITELISTED_IPS.has(context.ip)) ||
                         (context.userId && WHITELISTED_USERS.has(context.userId));
    
    if (isWhitelisted) {
      rateLimitMetrics.requestsAllowed++;
      return {
        allowed: true,
        remaining: 999,
        resetTime: Date.now() + 60000,
        category,
      };
    }
  }
  
  // Check if blocked first
  const blockCheck = await checkBlocked(context.userId, context.ip);
  if (blockCheck.blocked) {
    rateLimitMetrics.requestsBlocked++;
    return {
      allowed: false,
      remaining: 0,
      resetTime: blockCheck.until || Date.now() + 60000,
      category,
      blocked: true,
      blockUntil: blockCheck.until,
      reason: blockCheck.reason,
      retryAfter: blockCheck.until ? Math.ceil((blockCheck.until - Date.now()) / 1000) : 60,
    };
  }
  
  // Create identifier for rate limiting
  const identifier = context.userId || context.ip || 'anonymous';
  const rateLimitKey = StellarCacheKeys.rateLimit(`${category}:${identifier}`, 'window');
  
  // Check current count in window using Redis
  const windowStart = Date.now() - rateLimitConfig.windowMs;
  const currentCount = await redisCache.get<number>(rateLimitKey) || 0;
  const resetTime = Date.now() + rateLimitConfig.windowMs;
  
  // Check burst limit first (if configured)
  const effectiveLimit = (rateLimitConfig.burstLimit && currentCount < rateLimitConfig.burstLimit) 
    ? rateLimitConfig.burstLimit 
    : rateLimitConfig.limit;
  
  let rateLimitResult = {
    allowed: currentCount < effectiveLimit,
    remaining: Math.max(0, effectiveLimit - currentCount - 1),
    resetTime,
  };
  
  // If using burst limit, fall back to regular limit if burst exceeded
  if (!rateLimitResult.allowed && rateLimitConfig.burstLimit && currentCount >= rateLimitConfig.burstLimit) {
    rateLimitResult = {
      allowed: currentCount < rateLimitConfig.limit,
      remaining: Math.max(0, rateLimitConfig.limit - currentCount - 1),
      resetTime,
    };
  }
  
  // Update request count if allowed
  if (rateLimitResult.allowed) {
    const newCount = await redisCache.increment(rateLimitKey, 1, { ttl: Math.ceil(rateLimitConfig.windowMs / 1000) });
    if (newCount !== null) {
      rateLimitResult.remaining = Math.max(0, effectiveLimit - newCount);
      rateLimitMetrics.cacheHitRate = (rateLimitMetrics.cacheHitRate + 1) / 2; // Simple moving average
    }
    
    rateLimitMetrics.requestsAllowed++;
  } else {
    // Rate limit exceeded, apply blocking if configured
    const blockReason = `Rate limit exceeded for ${category} (${effectiveLimit} requests per minute)`;
    
    if (rateLimitConfig.exponentialBackoff) {
      // Block user/IP with escalating penalties
      if (context.userId) {
        await blockIdentifier(context.userId, 'user', rateLimitConfig.blockDurationMs, blockReason);
      } else if (context.ip) {
        await blockIdentifier(context.ip, 'ip', rateLimitConfig.blockDurationMs, blockReason);
      }
    }
    
    rateLimitMetrics.requestsBlocked++;
    
    // Track the request for monitoring
    const monitor = getPerformanceMonitor();
    monitor.recordMetric({
      name: 'rate_limit.request_blocked',
      value: currentCount,
      unit: 'count',
      tags: {
        category,
        tier: context.subscriptionTier || 'free',
        endpoint: context.endpoint.substring(0, 30), // Truncate for logging
        reason: 'exceeded_limit',
      },
    });
    
    return {
      allowed: false,
      remaining: 0,
      resetTime: rateLimitResult.resetTime,
      category,
      blocked: rateLimitConfig.exponentialBackoff,
      blockUntil: rateLimitConfig.exponentialBackoff ? Date.now() + rateLimitConfig.blockDurationMs : undefined,
      reason: blockReason,
      retryAfter: rateLimitConfig.exponentialBackoff ? Math.ceil(rateLimitConfig.blockDurationMs / 1000) : 60,
    };
  }
  
  // Update performance metrics
  const duration = performance.now() - startTime;
  rateLimitMetrics.averageResponseTime = (rateLimitMetrics.averageResponseTime + duration) / 2;
  
  // Track the request for monitoring
  const monitor = getPerformanceMonitor();
  monitor.recordMetric({
    name: 'rate_limit.request_allowed',
    value: rateLimitResult.remaining,
    unit: 'remaining',
    tags: {
      category,
      tier: context.subscriptionTier || 'free',
      endpoint: context.endpoint.substring(0, 30), // Truncate for logging
    },
  });
  
  return {
    allowed: true,
    remaining: rateLimitResult.remaining,
    resetTime: rateLimitResult.resetTime,
    category,
  };
}

/**
 * Rate limiting middleware for Edge Functions
 */
export async function applyRateLimit(
  request: Request,
  endpoint: string,
  userId?: string
): Promise<{ allowed: boolean; response?: Response; rateLimitInfo?: RateLimitResult }> {
  try {
    // Extract request context
    const ip = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 
               request.headers.get('x-real-ip') || 
               'unknown';
    const userAgent = request.headers.get('user-agent') || 'unknown';
    const contentLength = parseInt(request.headers.get('content-length') || '0', 10);
    const contentType = request.headers.get('content-type') || '';
    
    // Get subscription tier for more accurate rate limiting
    const subscriptionTier = userId ? await getUserSubscriptionTier(userId) : 'free';
    
    const context: RateLimitContext = {
      endpoint,
      userId,
      ip,
      userAgent,
      requestSize: contentLength,
      hasFiles: contentType.includes('multipart/form-data') || contentType.includes('image/'),
      isAuthenticated: !!userId,
      subscriptionTier,
    };
    
    // Check rate limit
    const rateLimitResult = await checkRateLimitWithContext(context);
    
    if (!rateLimitResult.allowed) {
      // Create comprehensive rate limit exceeded response with enhanced headers
      const config = getRateLimitConfig(determineRateLimitCategory(endpoint), context.subscriptionTier);
      const headers = new Headers({
        'Content-Type': 'application/json',
        
        // Standard rate limit headers
        'X-RateLimit-Limit': config.limit.toString(),
        'X-RateLimit-Remaining': '0',
        'X-RateLimit-Reset': Math.ceil(rateLimitResult.resetTime / 1000).toString(),
        'X-RateLimit-Category': rateLimitResult.category,
        'X-RateLimit-Window': Math.ceil(config.windowMs / 1000).toString(),
        
        // Burst limit info (if applicable)
        ...(config.burstLimit && { 'X-RateLimit-Burst-Limit': config.burstLimit.toString() }),
        
        // Retry information
        'Retry-After': (rateLimitResult.retryAfter || 60).toString(),
        
        // Enhanced headers for better client handling
        'X-RateLimit-Policy': `${config.limit};w=${Math.ceil(config.windowMs / 1000)}${config.burstLimit ? `;burst=${config.burstLimit}` : ''}`,
        'X-RateLimit-Scope': context.userId ? 'user' : 'ip',
        
        // Performance and caching headers
        'Cache-Control': 'no-store, no-cache, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
      });
      
      // Add blocking information if applicable
      if (rateLimitResult.blocked && rateLimitResult.blockUntil) {
        headers.set('X-RateLimit-Blocked-Until', Math.ceil(rateLimitResult.blockUntil / 1000).toString());
        headers.set('X-RateLimit-Block-Duration', Math.ceil(config.blockDurationMs / 1000).toString());
      }
      
      // Add tier information for transparency
      if (context.subscriptionTier && context.subscriptionTier !== 'free') {
        headers.set('X-RateLimit-Tier', context.subscriptionTier);
      }
      
      const errorResponse = new Response(
        JSON.stringify({
          error: 'Rate limit exceeded',
          message: rateLimitResult.reason || `Too many requests for ${rateLimitResult.category}. Limit: ${config.limit} requests per minute.`,
          details: {
            category: rateLimitResult.category,
            limit: config.limit,
            windowSeconds: Math.ceil(config.windowMs / 1000),
            retryAfter: rateLimitResult.retryAfter || 60,
            blocked: rateLimitResult.blocked || false,
            subscriptionTier: context.subscriptionTier || 'free',
            ...(config.burstLimit && { burstLimit: config.burstLimit }),
          },
          timestamp: new Date().toISOString(),
          requestId: `rl_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
        }),
        {
          status: 429,
          headers,
        }
      );
      
      return {
        allowed: false,
        response: errorResponse,
        rateLimitInfo: rateLimitResult,
      };
    }
    
    return {
      allowed: true,
      rateLimitInfo: rateLimitResult,
    };
  } catch (error) {
    // If rate limiting fails, allow the request but log the error
    const monitor = getPerformanceMonitor();
    monitor.recordMetric({
      name: 'rate_limit.error',
      value: 1,
      unit: 'count',
      tags: {
        endpoint,
        error: error.message,
      },
    });
    
    return { allowed: true };
  }
}

/**
 * Get rate limit headers for successful responses
 */
export function getRateLimitHeaders(rateLimitInfo: RateLimitResult, endpoint: string = '', subscriptionTier: 'free' | 'premium' | 'admin' = 'free'): Record<string, string> {
  const category = determineRateLimitCategory(endpoint);
  const config = getRateLimitConfig(category, subscriptionTier);
  
  const headers: Record<string, string> = {
    'X-RateLimit-Limit': config.limit.toString(),
    'X-RateLimit-Remaining': rateLimitInfo.remaining.toString(),
    'X-RateLimit-Reset': Math.ceil(rateLimitInfo.resetTime / 1000).toString(),
    'X-RateLimit-Category': rateLimitInfo.category,
    'X-RateLimit-Window': Math.ceil(config.windowMs / 1000).toString(),
    'X-RateLimit-Policy': `${config.limit};w=${Math.ceil(config.windowMs / 1000)}${config.burstLimit ? `;burst=${config.burstLimit}` : ''}`,
  };

  // Add burst limit if applicable
  if (config.burstLimit) {
    headers['X-RateLimit-Burst-Limit'] = config.burstLimit.toString();
  }

  // Add tier information for transparency
  if (subscriptionTier !== 'free') {
    headers['X-RateLimit-Tier'] = subscriptionTier;
  }

  return headers;
}

/**
 * Get rate limiting metrics for monitoring
 */
export function getRateLimitMetrics(): RateLimitMetrics & {
  configuredLimits: typeof TIERED_RATE_LIMITS;
  whitelistSizes: { ips: number; users: number };
} {
  return {
    ...rateLimitMetrics,
    configuredLimits: TIERED_RATE_LIMITS,
    whitelistSizes: {
      ips: WHITELISTED_IPS.size,
      users: WHITELISTED_USERS.size,
    },
  };
}

/**
 * Reset rate limiting metrics
 */
export function resetRateLimitMetrics(): void {
  rateLimitMetrics = {
    requestsBlocked: 0,
    requestsAllowed: 0,
    averageResponseTime: 0,
    cacheHitRate: 0,
    lastReset: new Date().toISOString(),
  };
}

/**
 * Add user or IP to whitelist (runtime addition)
 */
export function addToWhitelist(identifier: string, type: 'ip' | 'user'): boolean {
  try {
    if (type === 'ip') {
      WHITELISTED_IPS.add(identifier);
    } else {
      WHITELISTED_USERS.add(identifier);
    }
    return true;
  } catch (error) {
    return false;
  }
}

/**
 * Remove user or IP from whitelist
 */
export function removeFromWhitelist(identifier: string, type: 'ip' | 'user'): boolean {
  try {
    if (type === 'ip') {
      return WHITELISTED_IPS.delete(identifier);
    } else {
      return WHITELISTED_USERS.delete(identifier);
    }
  } catch (error) {
    return false;
  }
}

/**
 * Cleanup expired blocks and violations - Redis handles TTL automatically
 * This function is now primarily for metrics cleanup and cache optimization
 */
export async function cleanupRateLimitData(): Promise<void> {
  try {
    // Reset metrics if they're getting stale (older than 1 hour)
    const lastReset = new Date(rateLimitMetrics.lastReset);
    const hourAgo = new Date(Date.now() - 60 * 60 * 1000);
    
    if (lastReset < hourAgo) {
      // Archive current metrics before reset (for monitoring)
      const monitor = getPerformanceMonitor();
      monitor.recordMetric({
        name: 'rate_limit.metrics_archived',
        value: rateLimitMetrics.requestsBlocked + rateLimitMetrics.requestsAllowed,
        unit: 'count',
        tags: {
          requests_blocked: rateLimitMetrics.requestsBlocked.toString(),
          requests_allowed: rateLimitMetrics.requestsAllowed.toString(),
          avg_response_time: rateLimitMetrics.averageResponseTime.toFixed(2),
          cache_hit_rate: rateLimitMetrics.cacheHitRate.toFixed(2),
        },
      });
      
      // Reset metrics for next hour
      resetRateLimitMetrics();
    }
    
    // Perform Redis cache maintenance
    const cacheHealth = redisCache.getHealthStatus();
    if (!cacheHealth.connected) {
      // Try to reconnect if disconnected
      await redisCache.get('health_check'); // This will trigger reconnection
    }
    
  } catch (error) {
    // Fail silently but log for monitoring
    const monitor = getPerformanceMonitor();
    monitor.recordMetric({
      name: 'rate_limit.cleanup_error',
      value: 1,
      unit: 'count',
      tags: {
        error: (error as Error).message.substring(0, 50),
      },
    });
  }
}

/**
 * Health check for rate limiting system
 */
export async function getRateLimitSystemHealth(): Promise<{
  status: 'healthy' | 'degraded' | 'unhealthy';
  redis: { connected: boolean; latency?: number };
  metrics: RateLimitMetrics;
  configuration: {
    categories: number;
    whitelistSizes: { ips: number; users: number };
    environmentOverrides: boolean;
  };
}> {
  const startTime = performance.now();
  
  // Test Redis connectivity and latency
  let redisLatency: number | undefined;
  let redisConnected = false;
  
  try {
    const testKey = `health_check_${Date.now()}`;
    await redisCache.set(testKey, 'test', { ttl: 10 });
    const retrieved = await redisCache.get(testKey);
    redisConnected = retrieved === 'test';
    redisLatency = performance.now() - startTime;
    await redisCache.delete(testKey); // Cleanup
  } catch (error) {
    redisConnected = false;
  }
  
  // Determine overall health status
  let status: 'healthy' | 'degraded' | 'unhealthy';
  if (!redisConnected) {
    status = 'unhealthy'; // Redis is critical for distributed rate limiting
  } else if ((redisLatency || 0) > 100) {
    status = 'degraded'; // High latency might impact performance
  } else {
    status = 'healthy';
  }
  
  return {
    status,
    redis: {
      connected: redisConnected,
      latency: redisLatency,
    },
    metrics: rateLimitMetrics,
    configuration: {
      categories: Object.keys(TIERED_RATE_LIMITS).length,
      whitelistSizes: {
        ips: WHITELISTED_IPS.size,
        users: WHITELISTED_USERS.size,
      },
      environmentOverrides: !!(Deno.env.get('RATE_LIMIT_DEFAULT_LIMIT') || 
                              Deno.env.get('RATE_LIMIT_MATCHING_LIMIT') ||
                              Deno.env.get('RATE_LIMIT_AUTHENTICATION_LIMIT')),
    },
  };
}

// Cleanup interval (run every 5 minutes)
// DISABLED: setInterval at module level causes BOOT_ERROR in Edge Functions
// setInterval(cleanupRateLimitData, 5 * 60 * 1000);

export { RateLimitContext, RateLimitResult, ENDPOINT_CATEGORIES };