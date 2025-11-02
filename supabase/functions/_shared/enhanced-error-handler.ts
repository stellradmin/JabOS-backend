/**
 * Enhanced Centralized Error Handler for Stellr Edge Functions
 * Builds on existing error-handler.ts with comprehensive improvements
 * Provides advanced error handling, recovery, and user experience optimization
 */

import { createErrorResponse, createValidationErrorResponse, createRateLimitErrorResponse, createSuccessResponse, logSecurityEvent, CircuitBreaker, retryWithBackoff, trackErrorMetrics } from './error-handler.ts';

// PHASE 2 SECURITY: Import secure error sanitization
import { sanitizeErrorForUser, sanitizeErrorForDevelopment, SanitizedErrorResponse } from './secure-error-sanitizer.ts';

// Enhanced error types with context and recovery information
export interface EnhancedErrorContext {
  requestId: string;
  userId?: string;
  endpoint: string;
  operation?: string;
  startTime: number;
  retryCount: number;
  circuitBreakerState?: any;
  userAgent?: string;
  ip?: string;
  sessionId?: string;
  correlationId?: string;
}

// Error recovery strategies
export type ErrorRecoveryStrategy = 
  | 'immediate-retry'
  | 'exponential-backoff'
  | 'circuit-breaker'
  | 'fallback-data'
  | 'graceful-degradation'
  | 'manual-intervention'
  | 'redirect-flow';

// Enhanced error classification
export interface ErrorClassification {
  severity: 'low' | 'medium' | 'high' | 'critical';
  category: 'network' | 'database' | 'authentication' | 'validation' | 'business-logic' | 'external-service' | 'rate-limit' | 'performance';
  recoverable: boolean;
  userImpact: 'none' | 'minor' | 'major' | 'blocking';
  recoveryStrategy: ErrorRecoveryStrategy;
  retryable: boolean;
  maxRetries: number;
  fallbackAvailable: boolean;
}

// Enhanced error mappings with recovery strategies
const ENHANCED_ERROR_MAPPINGS: Record<string, ErrorClassification & { publicMessage: string; logLevel: 'error' | 'warn' | 'info' }> = {
  // Authentication errors with enhanced recovery
  'PGRST301': { 
    publicMessage: 'Access denied - please verify your permissions', 
    logLevel: 'warn', 
    severity: 'high',
    category: 'authentication',
    recoverable: true,
    userImpact: 'blocking',
    recoveryStrategy: 'manual-intervention',
    retryable: false,
    maxRetries: 0,
    fallbackAvailable: false
  },
  'invalid_grant': { 
    publicMessage: 'Authentication failed - please log in again', 
    logLevel: 'warn',
    severity: 'high',
    category: 'authentication',
    recoverable: true,
    userImpact: 'blocking',
    recoveryStrategy: 'redirect-flow',
    retryable: true,
    maxRetries: 1,
    fallbackAvailable: false
  },
  'jwt_expired': {
    publicMessage: 'Session expired - refreshing authentication',
    logLevel: 'info',
    severity: 'medium',
    category: 'authentication',
    recoverable: true,
    userImpact: 'minor',
    recoveryStrategy: 'immediate-retry',
    retryable: true,
    maxRetries: 2,
    fallbackAvailable: false
  },

  // Database errors with fallback strategies
  'PGRST106': { 
    publicMessage: 'Resource not found', 
    logLevel: 'warn',
    severity: 'medium',
    category: 'database',
    recoverable: true,
    userImpact: 'major',
    recoveryStrategy: 'fallback-data',
    retryable: false,
    maxRetries: 0,
    fallbackAvailable: true
  },
  'connection_timeout': { 
    publicMessage: 'Connection timeout - retrying request', 
    logLevel: 'warn',
    severity: 'high',
    category: 'database',
    recoverable: true,
    userImpact: 'major',
    recoveryStrategy: 'exponential-backoff',
    retryable: true,
    maxRetries: 3,
    fallbackAvailable: true
  },
  'query_timeout': { 
    publicMessage: 'Operation taking longer than expected - please wait', 
    logLevel: 'error',
    severity: 'high',
    category: 'performance',
    recoverable: true,
    userImpact: 'major',
    recoveryStrategy: 'circuit-breaker',
    retryable: true,
    maxRetries: 2,
    fallbackAvailable: true
  },

  // Network and external service errors
  'network_error': { 
    publicMessage: 'Network connectivity issue - please check your connection', 
    logLevel: 'warn',
    severity: 'medium',
    category: 'network',
    recoverable: true,
    userImpact: 'major',
    recoveryStrategy: 'exponential-backoff',
    retryable: true,
    maxRetries: 3,
    fallbackAvailable: true
  },
  'external_service_error': { 
    publicMessage: 'External service temporarily unavailable', 
    logLevel: 'error',
    severity: 'high',
    category: 'external-service',
    recoverable: true,
    userImpact: 'major',
    recoveryStrategy: 'circuit-breaker',
    retryable: true,
    maxRetries: 2,
    fallbackAvailable: true
  },

  // Business logic errors
  'compatibility_calculation_failed': {
    publicMessage: 'Unable to calculate compatibility - using simplified algorithm',
    logLevel: 'warn',
    severity: 'medium',
    category: 'business-logic',
    recoverable: true,
    userImpact: 'minor',
    recoveryStrategy: 'fallback-data',
    retryable: true,
    maxRetries: 2,
    fallbackAvailable: true
  },
  'matching_service_unavailable': {
    publicMessage: 'Matching service temporarily unavailable - showing cached results',
    logLevel: 'error',
    severity: 'high',
    category: 'business-logic',
    recoverable: true,
    userImpact: 'major',
    recoveryStrategy: 'graceful-degradation',
    retryable: true,
    maxRetries: 2,
    fallbackAvailable: true
  },

  // Rate limiting with intelligent backoff
  'rate_limit_exceeded': { 
    publicMessage: 'Request rate exceeded - please wait before trying again', 
    logLevel: 'info',
    severity: 'low',
    category: 'rate-limit',
    recoverable: true,
    userImpact: 'minor',
    recoveryStrategy: 'exponential-backoff',
    retryable: true,
    maxRetries: 5,
    fallbackAvailable: false
  },

  // Validation errors with detailed feedback
  'validation_error': { 
    publicMessage: 'Invalid input provided - please check your data', 
    logLevel: 'info',
    severity: 'low',
    category: 'validation',
    recoverable: true,
    userImpact: 'minor',
    recoveryStrategy: 'manual-intervention',
    retryable: false,
    maxRetries: 0,
    fallbackAvailable: false
  }
};

// Enhanced circuit breaker with metrics and auto-recovery
export class EnhancedCircuitBreaker extends CircuitBreaker {
  private metrics = {
    successCount: 0,
    failureCount: 0,
    timeoutCount: 0,
    lastSuccessTime: 0,
    averageResponseTime: 0,
    responseTimeHistory: [] as number[]
  };

  private autoRecoveryEnabled = true;
  private healthCheckInterval?: NodeJS.Timeout;

  constructor(
    failureThreshold = 5,
    timeout = 60000,
    private serviceName = 'unknown',
    private healthCheckUrl?: string
  ) {
    super(failureThreshold, timeout);
    this.startHealthCheck();
  }

  async execute<T>(operation: () => Promise<T>, fallback?: () => T | Promise<T>): Promise<T> {
    const startTime = Date.now();
    
    try {
      const result = await super.execute(operation, fallback);
      this.recordSuccess(Date.now() - startTime);
      return result;
    } catch (error) {
      this.recordFailure(error);
      throw error;
    }
  }

  private recordSuccess(responseTime: number): void {
    this.metrics.successCount++;
    this.metrics.lastSuccessTime = Date.now();
    this.metrics.responseTimeHistory.push(responseTime);
    
    // Keep only last 100 response times
    if (this.metrics.responseTimeHistory.length > 100) {
      this.metrics.responseTimeHistory = this.metrics.responseTimeHistory.slice(-100);
    }
    
    this.metrics.averageResponseTime = 
      this.metrics.responseTimeHistory.reduce((a, b) => a + b, 0) / 
      this.metrics.responseTimeHistory.length;
  }

  private recordFailure(error: any): void {
    this.metrics.failureCount++;
    
    if (error?.message?.includes('timeout')) {
      this.metrics.timeoutCount++;
    }
  }

  private startHealthCheck(): void {
    if (!this.autoRecoveryEnabled || !this.healthCheckUrl) return;

    this.healthCheckInterval = setInterval(async () => {
      if (this.getState().state === 'open') {
        try {
          // Simple health check
          const response = await fetch(this.healthCheckUrl!, { 
            method: 'HEAD',
            timeout: 5000 
          });
          
          if (response.ok) {
            // Debug logging removed for security
// Reset circuit breaker state for recovery attempt
            this.reset();
          }
        } catch (error) {
          // Debug logging removed for security
}
      }
    }, 30000); // Check every 30 seconds
  }

  private reset(): void {
    // Reset internal state (implement based on parent class)
    this.onSuccess();
  }

  getMetrics() {
    return {
      ...this.metrics,
      ...this.getState(),
      serviceName: this.serviceName
    };
  }

  destroy(): void {
    if (this.healthCheckInterval) {
      clearInterval(this.healthCheckInterval);
    }
  }
}

// Enhanced retry mechanism with intelligent backoff
export async function enhancedRetryWithBackoff<T>(
  operation: () => Promise<T>,
  context: EnhancedErrorContext,
  maxRetries = 3,
  baseDelay = 1000
): Promise<T> {
  let lastError: any;
  
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const result = await operation();
      
      // Log successful retry
      if (attempt > 0) {
        // Debug logging removed for security
}
      
      return result;
    } catch (error) {
      lastError = error;
      
      if (attempt === maxRetries) {
        break;
      }
      
      // Get error classification
      const errorCode = extractErrorCode(error);
      const classification = ENHANCED_ERROR_MAPPINGS[errorCode] || getDefaultClassification();
      
      // Don't retry non-retryable errors
      if (!classification.retryable) {
        // Debug logging removed for security
break;
      }
      
      // Calculate intelligent delay based on error type and attempt
      const delay = calculateRetryDelay(classification, attempt, baseDelay);

      // Debug logging removed for security

      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }
  
  // Track failed operation
  trackErrorMetrics(lastError, context.endpoint, Date.now() - context.startTime, context.userId);
  
  throw lastError;
}

// Intelligent retry delay calculation
function calculateRetryDelay(
  classification: ErrorClassification, 
  attempt: number, 
  baseDelay: number
): number {
  switch (classification.recoveryStrategy) {
    case 'immediate-retry':
      return Math.min(baseDelay, 500); // Quick retry for auth issues
    
    case 'exponential-backoff':
      // Exponential backoff with jitter
      const exponentialDelay = baseDelay * Math.pow(2, attempt);
      const jitter = Math.random() * 1000;
      return Math.min(exponentialDelay + jitter, 30000); // Max 30 seconds
    
    case 'circuit-breaker':
      return baseDelay * (attempt + 1); // Linear increase for circuit breaker
    
    default:
      return baseDelay * Math.pow(1.5, attempt); // Moderate exponential backoff
  }
}

// PHASE 2 SECURITY: Secure error response with sanitization
export function createSecureErrorResponse(
  error: any,
  context: EnhancedErrorContext,
  corsHeaders: Record<string, string> = {},
  isProduction: boolean = true
): Response {
  const errorCode = extractErrorCode(error);
  const classification = ENHANCED_ERROR_MAPPINGS[errorCode] || getDefaultClassification();
  
  // Sanitize error based on environment
  const sanitizedError = isProduction 
    ? sanitizeErrorForUser(error, context.requestId, { 
        userId: context.userId, 
        endpoint: context.endpoint 
      })
    : sanitizeErrorForDevelopment(error, context.requestId, {
        userId: context.userId,
        endpoint: context.endpoint
      });

  // Create enhanced response with security sanitization
  const secureResponse = {
    success: false,
    error: sanitizedError.userMessage, // User-friendly message
    code: sanitizedError.code,
    timestamp: sanitizedError.timestamp,
    recovery: {
      strategy: classification.recoveryStrategy,
      retryable: classification.retryable,
      maxRetries: classification.maxRetries,
      fallbackAvailable: classification.fallbackAvailable,
      userImpact: classification.userImpact,
      estimatedRecoveryTime: getEstimatedRecoveryTime(classification)
    },
    context: {
      requestId: context.requestId,
      correlationId: context.correlationId || context.requestId,
      retryCount: context.retryCount
    },
    // Only include technical details in development
    ...(isProduction ? {} : {
      technicalError: sanitizedError.technicalMessage,
      systemInfoRemoved: sanitizedError.systemInfoRemoved
    })
  };

  // Determine HTTP status code
  let statusCode = 500;
  if (classification.category === 'authentication') statusCode = 401;
  else if (classification.category === 'validation') statusCode = 400;
  else if (classification.category === 'rate-limit') statusCode = 429;
  else if (classification.severity === 'low') statusCode = 400;

  return new Response(JSON.stringify(secureResponse), {
    status: statusCode,
    headers: {
      'Content-Type': 'application/json',
      'X-Recovery-Strategy': classification.recoveryStrategy,
      'X-Retryable': classification.retryable.toString(),
      'X-Error-Code': sanitizedError.code || 'UNKNOWN',
      'X-Request-ID': context.requestId,
      ...corsHeaders
    }
  });
}

// Enhanced error response with recovery information (legacy - now uses secure version)
export function createEnhancedErrorResponse(
  error: any,
  context: EnhancedErrorContext,
  corsHeaders: Record<string, string> = {}
): Response {
  const errorCode = extractErrorCode(error);
  const classification = ENHANCED_ERROR_MAPPINGS[errorCode] || getDefaultClassification();
  
  // Create base error response
  const baseResponse = createErrorResponse(error, context, corsHeaders);
  
  // Parse the existing response to enhance it
  return baseResponse.text().then(responseText => {
    const responseData = JSON.parse(responseText);
    
    // Enhance with recovery information
    const enhancedResponse = {
      ...responseData,
      recovery: {
        strategy: classification.recoveryStrategy,
        retryable: classification.retryable,
        maxRetries: classification.maxRetries,
        fallbackAvailable: classification.fallbackAvailable,
        userImpact: classification.userImpact,
        estimatedRecoveryTime: getEstimatedRecoveryTime(classification)
      },
      context: {
        requestId: context.requestId,
        correlationId: context.correlationId || context.requestId,
        retryCount: context.retryCount,
        circuitBreakerState: context.circuitBreakerState
      }
    };
    
    return new Response(JSON.stringify(enhancedResponse), {
      status: baseResponse.status,
      headers: {
        ...Object.fromEntries(baseResponse.headers.entries()),
        'X-Recovery-Strategy': classification.recoveryStrategy,
        'X-Retryable': classification.retryable.toString(),
        'X-Fallback-Available': classification.fallbackAvailable.toString(),
        'X-User-Impact': classification.userImpact
      }
    });
  }).catch(() => {
    // If parsing fails, return the original response
    return baseResponse;
  });
}

// Fallback data strategies
export interface FallbackDataStrategy {
  type: 'cached' | 'simplified' | 'empty' | 'mock';
  maxAge?: number; // for cached data
  simplificationLevel?: 'minimal' | 'basic' | 'full'; // for simplified data
}

export async function getFallbackData<T>(
  operation: string,
  strategy: FallbackDataStrategy,
  context: EnhancedErrorContext
): Promise<T | null> {
  try {
    switch (strategy.type) {
      case 'cached':
        return await getCachedData<T>(operation, strategy.maxAge || 300000); // 5 min default
      
      case 'simplified':
        return await getSimplifiedData<T>(operation, strategy.simplificationLevel || 'basic');
      
      case 'empty':
        return getEmptyData<T>(operation);
      
      case 'mock':
        return await getMockData<T>(operation);
      
      default:
        return null;
    }
  } catch (error) {
return null;
  }
}

// Graceful degradation manager
export class GracefulDegradationManager {
  private static degradationStates = new Map<string, {
    level: 'none' | 'partial' | 'minimal' | 'emergency';
    startTime: number;
    affectedFeatures: string[];
  }>();

  static setDegradationLevel(
    service: string, 
    level: 'none' | 'partial' | 'minimal' | 'emergency',
    affectedFeatures: string[] = []
  ): void {
    if (level === 'none') {
      this.degradationStates.delete(service);
    } else {
      this.degradationStates.set(service, {
        level,
        startTime: Date.now(),
        affectedFeatures
      });
    }

    // Debug logging removed for security
  }

  static getDegradationLevel(service: string): 'none' | 'partial' | 'minimal' | 'emergency' {
    return this.degradationStates.get(service)?.level || 'none';
  }

  static getAffectedFeatures(service: string): string[] {
    return this.degradationStates.get(service)?.affectedFeatures || [];
  }

  static shouldDegrade(service: string, feature: string): boolean {
    const state = this.degradationStates.get(service);
    if (!state) return false;
    
    return state.affectedFeatures.includes(feature) || 
           state.level === 'emergency'; // Emergency mode affects all features
  }

  static getAllDegradationStates(): Record<string, any> {
    const states: Record<string, any> = {};
    this.degradationStates.forEach((value, key) => {
      states[key] = {
        ...value,
        duration: Date.now() - value.startTime
      };
    });
    return states;
  }
}

// Utility functions
function extractErrorCode(error: any): string {
  if (error?.code) return error.code;
  if (error?.message?.includes('timeout')) return 'connection_timeout';
  if (error?.message?.includes('network')) return 'network_error';
  if (error?.message?.includes('auth')) return 'invalid_grant';
  if (error?.message?.includes('rate')) return 'rate_limit_exceeded';
  return 'server_error';
}

function getDefaultClassification(): ErrorClassification {
  return {
    severity: 'medium',
    category: 'network',
    recoverable: true,
    userImpact: 'major',
    recoveryStrategy: 'exponential-backoff',
    retryable: true,
    maxRetries: 3,
    fallbackAvailable: false
  };
}

function getEstimatedRecoveryTime(classification: ErrorClassification): number {
  switch (classification.recoveryStrategy) {
    case 'immediate-retry': return 1000; // 1 second
    case 'exponential-backoff': return 5000; // 5 seconds
    case 'circuit-breaker': return 30000; // 30 seconds
    case 'fallback-data': return 0; // Immediate
    case 'graceful-degradation': return 0; // Immediate
    case 'manual-intervention': return -1; // Unknown
    default: return 10000; // 10 seconds
  }
}

// Cached data implementation
async function getCachedData<T>(operation: string, maxAge: number): Promise<T | null> {
  // Implementation would use Redis or in-memory cache
  // For now, return null (no cache available)
  return null;
}

// Simplified data implementation
async function getSimplifiedData<T>(operation: string, level: string): Promise<T | null> {
  // Implementation would return simplified versions of data
  // For example, basic profile data instead of full compatibility data
  return null;
}

// Empty data implementation
function getEmptyData<T>(operation: string): T | null {
  switch (operation) {
    case 'get-potential-matches-optimized':
      return [] as any;
    case 'get-compatibility-details':
      return { overallScore: 50, astrological_score: 50, personality_score: 50 } as any;
    default:
      return null;
  }
}

// Mock data implementation
async function getMockData<T>(operation: string): Promise<T | null> {
  // Implementation would return realistic mock data for testing/fallback
  return null;
}

// Export enhanced error handling functions
export {
  createErrorResponse,
  createValidationErrorResponse,
  createRateLimitErrorResponse,
  createSuccessResponse,
  logSecurityEvent,
  retryWithBackoff,
  trackErrorMetrics
};