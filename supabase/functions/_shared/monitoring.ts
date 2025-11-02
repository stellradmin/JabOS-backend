/**
 * Production-Ready Monitoring and Logging System for Stellr
 * Provides comprehensive performance metrics, security monitoring, and error tracking
 */

// Monitoring event types
type EventType = 
  | 'api_request' 
  | 'database_query' 
  | 'authentication' 
  | 'rate_limit' 
  | 'security_incident'
  | 'performance_metric'
  | 'error'
  | 'business_metric';

// Performance metrics interface
interface PerformanceMetric {
  name: string;
  value: number;
  unit: 'ms' | 'count' | 'bytes' | 'percentage';
  tags?: Record<string, string>;
}

// Security event interface
interface SecurityEvent {
  type: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
  userId?: string;
  details: Record<string, any>;
  mitigationTaken?: string;
}

// API request metrics
interface APIRequestMetric {
  endpoint: string;
  method: string;
  statusCode: number;
  responseTime: number;
  userId?: string;
  userAgent?: string;
  origin?: string;
  size?: {
    request: number;
    response: number;
  };
}

// Environment detection
function getEnvironment(): string {
  return Deno.env.get('SENTRY_ENVIRONMENT') || 
         Deno.env.get('NODE_ENV') || 
         'production';
}

function isProduction(): boolean {
  return getEnvironment() === 'production';
}

// Enhanced logger with structured logging
export class StructuredLogger {
  private serviceName: string;
  private environment: string;

  constructor(serviceName: string = 'stellr-api') {
    this.serviceName = serviceName;
    this.environment = getEnvironment();
  }

  private createBaseLog(level: string, message: string, data?: any) {
    return {
      timestamp: new Date().toISOString(),
      level: level.toLowerCase(),
      service: this.serviceName,
      environment: this.environment,
      message,
      requestId: this.generateRequestId(),
      ...data
    };
  }

  private generateRequestId(): string {
    return `req_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
  }

  info(message: string, data?: any) {
    const logEntry = this.createBaseLog('INFO', message, data);
    console.log(JSON.stringify(logEntry));
  }

  warn(message: string, data?: any) {
    const logEntry = this.createBaseLog('WARN', message, data);
    console.warn(JSON.stringify(logEntry));
  }

  error(message: string, error?: any, data?: any) {
    const logEntry = this.createBaseLog('ERROR', message, {
      error: {
        message: error?.message || 'Unknown error',
        stack: error?.stack,
        code: error?.code,
        name: error?.name
      },
      ...data
    });
    console.error(JSON.stringify(logEntry));
  }

  security(event: SecurityEvent) {
    const logEntry = this.createBaseLog('SECURITY', `Security event: ${event.type}`, {
      security: {
        type: event.type,
        severity: event.severity,
        userId: event.userId ? `user_${String(event.userId).substring(0, 8)}...` : undefined,
        details: event.details,
        mitigationTaken: event.mitigationTaken
      }
    });
    
    // Use appropriate log level based on severity
    switch (event.severity) {
      case 'critical':
      case 'high':
        console.error('🚨 SECURITY ALERT:', JSON.stringify(logEntry));
        break;
      case 'medium':
        console.warn('⚠️ SECURITY WARNING:', JSON.stringify(logEntry));
        break;
      case 'low':
        console.info('🔒 SECURITY INFO:', JSON.stringify(logEntry));
        break;
    }
  }

  performance(metric: PerformanceMetric) {
    const logEntry = this.createBaseLog('PERFORMANCE', `Performance metric: ${metric.name}`, {
      metric: {
        name: metric.name,
        value: metric.value,
        unit: metric.unit,
        tags: metric.tags
      }
    });
    console.log(JSON.stringify(logEntry));
  }

  apiRequest(metric: APIRequestMetric) {
    const logEntry = this.createBaseLog('API_REQUEST', `${metric.method} ${metric.endpoint}`, {
      api: {
        endpoint: metric.endpoint,
        method: metric.method,
        statusCode: metric.statusCode,
        responseTime: metric.responseTime,
        userId: metric.userId ? `user_${String(metric.userId).substring(0, 8)}...` : undefined,
        userAgent: metric.userAgent ? 'present' : undefined,
        origin: metric.origin,
        size: metric.size
      }
    });
    
    // Log at appropriate level based on status code
    if (metric.statusCode >= 500) {
      console.error(JSON.stringify(logEntry));
    } else if (metric.statusCode >= 400) {
      console.warn(JSON.stringify(logEntry));
    } else {
      console.log(JSON.stringify(logEntry));
    }
  }
}

// Global logger instance
export const logger = new StructuredLogger();

// Performance monitoring utilities
export class PerformanceMonitor {
  private static timers = new Map<string, number>();

  static startTimer(name: string): string {
    const timerId = `${name}_${Date.now()}_${Math.random().toString(36).substr(2, 6)}`;
    this.timers.set(timerId, performance.now());
    return timerId;
  }

  static endTimer(timerId: string, tags?: Record<string, string>): number {
    const startTime = this.timers.get(timerId);
    if (!startTime) {
      logger.warn('Timer not found', { timerId });
      return 0;
    }

    const duration = performance.now() - startTime;
    this.timers.delete(timerId);

    // Log performance metric
    logger.performance({
      name: timerId.split('_')[0],
      value: duration,
      unit: 'ms',
      tags
    });

    return duration;
  }

  static async measureAsync<T>(
    name: string, 
    operation: () => Promise<T>,
    tags?: Record<string, string>
  ): Promise<T> {
    const timerId = this.startTimer(name);
    try {
      const result = await operation();
      this.endTimer(timerId, { ...tags, status: 'success' });
      return result;
    } catch (error) {
      this.endTimer(timerId, { ...tags, status: 'error' });
      throw error;
    }
  }

  static measure<T>(
    name: string, 
    operation: () => T,
    tags?: Record<string, string>
  ): T {
    const timerId = this.startTimer(name);
    try {
      const result = operation();
      this.endTimer(timerId, { ...tags, status: 'success' });
      return result;
    } catch (error) {
      this.endTimer(timerId, { ...tags, status: 'error' });
      throw error;
    }
  }
}

// Database query monitoring
export async function monitorDatabaseQuery<T>(
  queryName: string,
  query: () => Promise<T>,
  context?: Record<string, any>
): Promise<T> {
  return await PerformanceMonitor.measureAsync(
    `db_query_${queryName}`,
    async () => {
      try {
        const result = await query();
        
        // Log successful query
        logger.info(`Database query completed: ${queryName}`, {
          query: {
            name: queryName,
            success: true,
            context
          }
        });
        
        return result;
      } catch (error) {
        // Log failed query
        logger.error(`Database query failed: ${queryName}`, error, {
          query: {
            name: queryName,
            success: false,
            context
          }
        });
        throw error;
      }
    },
    { query: queryName, ...context }
  );
}

// Security monitoring helpers
export function trackSecurityEvent(
  type: string,
  severity: SecurityEvent['severity'],
  userId?: string,
  details?: Record<string, any>,
  mitigationTaken?: string
) {
  logger.security({
    type,
    severity,
    userId,
    details: details || {},
    mitigationTaken
  });
}

// Business metrics tracking
export function trackBusinessMetric(
  name: string,
  value: number,
  tags?: Record<string, string>
) {
  logger.performance({
    name: `business_${name}`,
    value,
    unit: 'count',
    tags: { ...tags, type: 'business' }
  });
}

// API request monitoring middleware
export function createAPIMonitoringMiddleware(endpoint: string) {
  return {
    startRequest: (req: Request) => {
      const startTime = performance.now();
      const requestSize = req.headers.get('content-length') 
        ? parseInt(req.headers.get('content-length') || '0') 
        : 0;

      return {
        startTime,
        requestSize,
        method: req.method,
        userAgent: req.headers.get('user-agent'),
        origin: req.headers.get('origin')
      };
    },

    endRequest: (
      requestData: any, 
      response: Response, 
      userId?: string,
      responseSize?: number
    ) => {
      const responseTime = performance.now() - requestData.startTime;
      
      logger.apiRequest({
        endpoint,
        method: requestData.method,
        statusCode: response.status,
        responseTime,
        userId,
        userAgent: requestData.userAgent,
        origin: requestData.origin,
        size: {
          request: requestData.requestSize,
          response: responseSize || 0
        }
      });

      // Track response time performance
      logger.performance({
        name: 'api_response_time',
        value: responseTime,
        unit: 'ms',
        tags: {
          endpoint,
          method: requestData.method,
          status: response.status.toString()
        }
      });
    }
  };
}

// Health check utilities
export interface HealthCheckResult {
  service: string;
  status: 'healthy' | 'degraded' | 'unhealthy';
  responseTime: number;
  details?: Record<string, any>;
}

export async function checkDatabaseHealth(supabaseClient: any): Promise<HealthCheckResult> {
  const startTime = performance.now();
  
  try {
    // Simple health check query
    const { data, error } = await supabaseClient
      .from('profiles')
      .select('id')
      .limit(1);
    
    const responseTime = performance.now() - startTime;
    
    if (error) {
      return {
        service: 'database',
        status: 'unhealthy',
        responseTime,
        details: { error: error.message }
      };
    }
    
    const status = responseTime > 1000 ? 'degraded' : 'healthy';
    
    return {
      service: 'database',
      status,
      responseTime,
      details: { recordsAvailable: !!data }
    };
  } catch (error) {
    return {
      service: 'database',
      status: 'unhealthy',
      responseTime: performance.now() - startTime,
      details: { error: error instanceof Error ? error.message : 'Unknown error' }
    };
  }
}

// Memory usage monitoring (for Edge Functions)
export function getMemoryUsage(): PerformanceMetric {
  // Deno doesn't expose detailed memory info, but we can track basic metrics
  const memoryUsage = (Deno as any).memoryUsage?.() || { 
    rss: 0, 
    heapUsed: 0, 
    heapTotal: 0 
  };
  
  return {
    name: 'memory_usage',
    value: memoryUsage.heapUsed || 0,
    unit: 'bytes',
    tags: {
      type: 'heap_used',
      total: memoryUsage.heapTotal?.toString() || '0'
    }
  };
}

// Rate limit monitoring
export function trackRateLimitEvent(
  identifier: string,
  allowed: boolean,
  remaining: number,
  endpoint: string
) {
  logger.info('Rate limit check', {
    rateLimit: {
      identifier: identifier.split(':')[0], // Don't log full identifier for privacy
      allowed,
      remaining,
      endpoint
    }
  });

  if (!allowed) {
    trackSecurityEvent(
      'rate_limit_exceeded',
      'medium',
      identifier.includes('user_') ? identifier : undefined,
      { endpoint, remaining }
    );
  }
}

// Export convenience functions for common monitoring patterns
export const monitor = {
  timer: PerformanceMonitor,
  db: monitorDatabaseQuery,
  security: trackSecurityEvent,
  business: trackBusinessMetric,
  api: createAPIMonitoringMiddleware,
  health: checkDatabaseHealth,
  memory: getMemoryUsage,
  rateLimit: trackRateLimitEvent
};