/**
 * Centralized Error Handler for Stellr Edge Functions
 * Provides secure error handling, response formatting, and logging
 */

import { logger } from './logger.ts';
import { getCorsHeaders } from './cors.ts';

// Error types for better classification
export interface ErrorContext {
  endpoint: string;
  userId?: string;
  phase?: string;
  [key: string]: any;
}

export interface SecurityEvent {
  type: string;
  userId?: string;
  metadata?: Record<string, any>;
}

// Circuit breaker for handling service failures
export class CircuitBreaker {
  private failureCount = 0;
  private lastFailureTime = 0;
  private state: 'closed' | 'open' | 'half-open' = 'closed';

  constructor(
    private failureThreshold: number = 5,
    private timeout: number = 60000
  ) {}

  async execute<T>(
    operation: () => Promise<T>, 
    fallback?: () => T | Promise<T>
  ): Promise<T> {
    if (this.state === 'open') {
      if (Date.now() - this.lastFailureTime > this.timeout) {
        this.state = 'half-open';
      } else {
        if (fallback) {
          return await fallback();
        }
        throw new Error('Circuit breaker is open');
      }
    }

    try {
      const result = await operation();
      this.onSuccess();
      return result;
    } catch (error) {
      this.onFailure();
      if (fallback && this.state === 'open') {
        return await fallback();
      }
      throw error;
    }
  }

  private onSuccess(): void {
    this.failureCount = 0;
    this.state = 'closed';
  }

  private onFailure(): void {
    this.failureCount++;
    this.lastFailureTime = Date.now();
    
    if (this.failureCount >= this.failureThreshold) {
      this.state = 'open';
    }
  }

  getState(): { state: string; failureCount: number; lastFailureTime: number } {
    return {
      state: this.state,
      failureCount: this.failureCount,
      lastFailureTime: this.lastFailureTime
    };
  }
}

// Retry mechanism with exponential backoff
export async function retryWithBackoff<T>(
  operation: () => Promise<T>,
  maxRetries: number = 3,
  baseDelay: number = 1000
): Promise<T> {
  let lastError: any;
  
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      
      if (attempt === maxRetries) {
        break;
      }
      
      const delay = baseDelay * Math.pow(2, attempt);
      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }
  
  throw lastError;
}

// Security event logging
export function logSecurityEvent(
  eventType: string, 
  userId?: string, 
  metadata?: Record<string, any>
): void {
  const securityEvent = {
    type: eventType,
    userId,
    timestamp: new Date().toISOString(),
    metadata: {
      ...metadata,
      // Remove sensitive data
      userAgent: metadata?.userAgent ? 'redacted' : undefined,
      ip: metadata?.ip ? 'redacted' : undefined
    }
  };

  logger.warn('Security event detected', securityEvent);
}

// Error metrics tracking
export function trackErrorMetrics(
  error: any, 
  endpoint: string, 
  duration: number, 
  userId?: string
): void {
  const errorCode = error?.code || 'unknown';
  const errorType = error?.constructor?.name || 'Error';
  
  logger.info('Error metrics', {
    endpoint,
    errorCode,
    errorType,
    duration,
    userId: userId ? 'present' : 'none', // Don't log actual user ID
    timestamp: new Date().toISOString()
  });
}

// Create standardized error response
export function createErrorResponse(
  error: any,
  context: ErrorContext = { endpoint: 'unknown' },
  corsHeaders: Record<string, string> = {}
): Response {
  const errorCode = error?.code || 'server_error';
  const errorMessage = sanitizeErrorMessage(error?.message || 'An error occurred');
  
  // Log error with context
  logger.error('API Error', {
    code: errorCode,
    message: errorMessage,
    endpoint: context.endpoint,
    userId: context.userId ? 'present' : 'none',
    phase: context.phase
  });

  const responseBody = {
    success: false,
    error: {
      code: errorCode,
      message: getPublicErrorMessage(errorCode, errorMessage),
      timestamp: new Date().toISOString()
    }
  };

  const status = getHttpStatusFromError(errorCode);
  
  return new Response(JSON.stringify(responseBody), {
    status,
    headers: {
      'Content-Type': 'application/json',
      ...corsHeaders
    }
  });
}

// Create validation error response
export function createValidationErrorResponse(
  validationError: any,
  corsHeaders: Record<string, string> = {}
): Response {
  const errors = validationError?.issues?.map((issue: any) => ({
    field: issue.path?.join('.') || 'unknown',
    message: issue.message || 'Invalid value',
    code: issue.code || 'invalid_input'
  })) || [{ field: 'input', message: 'Invalid input provided', code: 'validation_error' }];

  logger.warn('Validation Error', { errors });

  const responseBody = {
    success: false,
    error: {
      code: 'validation_error',
      message: 'Input validation failed',
      details: errors,
      timestamp: new Date().toISOString()
    }
  };

  return new Response(JSON.stringify(responseBody), {
    status: 400,
    headers: {
      'Content-Type': 'application/json',
      ...corsHeaders
    }
  });
}

// Create rate limit error response
export function createRateLimitErrorResponse(
  remaining: number,
  resetTime: number,
  corsHeaders: Record<string, string> = {}
): Response {
  const responseBody = {
    success: false,
    error: {
      code: 'rate_limit_exceeded',
      message: 'Rate limit exceeded. Please try again later.',
      details: {
        remaining,
        resetTime: new Date(resetTime).toISOString()
      },
      timestamp: new Date().toISOString()
    }
  };

  return new Response(JSON.stringify(responseBody), {
    status: 429,
    headers: {
      'Content-Type': 'application/json',
      'X-RateLimit-Remaining': remaining.toString(),
      'X-RateLimit-Reset': resetTime.toString(),
      ...corsHeaders
    }
  });
}

// Create success response
export function createSuccessResponse(
  data: any,
  corsHeaders: Record<string, string> = {},
  status: number = 200
): Response {
  const responseBody = {
    success: true,
    data,
    timestamp: new Date().toISOString()
  };

  return new Response(JSON.stringify(responseBody), {
    status,
    headers: {
      'Content-Type': 'application/json',
      ...corsHeaders
    }
  });
}

// Helper functions
function sanitizeErrorMessage(message: string): string {
  // Remove sensitive information from error messages
  return message
    .replace(/password/gi, '[REDACTED]')
    .replace(/token/gi, '[REDACTED]')
    .replace(/key/gi, '[REDACTED]')
    .replace(/secret/gi, '[REDACTED]')
    .replace(/\b\d{4}-\d{4}-\d{4}-\d{4}\b/g, '[CARD-REDACTED]')
    .replace(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/g, '[EMAIL-REDACTED]');
}

function getPublicErrorMessage(errorCode: string, originalMessage: string): string {
  // Map internal error codes to user-friendly messages
  const publicMessages: Record<string, string> = {
    'PGRST301': 'Access denied',
    'invalid_grant': 'Authentication failed',
    'validation_error': 'Invalid input provided',
    'rate_limit_exceeded': 'Too many requests',
    'server_error': 'Server error occurred'
  };

  return publicMessages[errorCode] || 'An error occurred';
}

function getHttpStatusFromError(errorCode: string): number {
  const statusMap: Record<string, number> = {
    'PGRST301': 403,
    'invalid_grant': 401,
    'validation_error': 400,
    'rate_limit_exceeded': 429,
    'not_found': 404,
    'server_error': 500
  };

  return statusMap[errorCode] || 500;
}