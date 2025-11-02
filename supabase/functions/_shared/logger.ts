// Production-Ready Structured Logging for Stellr Edge Functions
// Comprehensive logging with proper formatting, levels, and aggregation

interface LogContext {
  userId?: string;
  functionName?: string;
  requestId?: string;
  sessionId?: string;
  correlationId?: string;
  userAgent?: string;
  clientIP?: string;
  [key: string]: any;
}

interface LogEntry {
  timestamp: string;
  level: LogLevel;
  message: string;
  context: LogContext;
  environment: string;
  service: string;
  version: string;
  trace?: {
    traceId?: string;
    spanId?: string;
  };
  error?: {
    name: string;
    message: string;
    stack?: string;
  };
  performance?: {
    duration?: number;
    memoryUsage?: number;
    cpuUsage?: number;
  };
  metadata?: Record<string, any>;
}

type LogLevel = 'debug' | 'info' | 'warn' | 'error' | 'fatal';

class StructuredLogger {
  private context: LogContext;
  private service: string;
  private version: string;
  private environment: string;

  constructor(context: LogContext = {}) {
    this.context = context;
    this.service = 'stellr-edge-functions';
    this.version = Deno.env.get('BUILD_VERSION') || '1.0.0';
    this.environment = Deno.env.get('SENTRY_ENVIRONMENT') || 'development';
  }

  private createLogEntry(
    level: LogLevel,
    message: string,
    additionalContext: LogContext = {},
    error?: Error,
    metadata?: Record<string, any>
  ): LogEntry {
    const entry: LogEntry = {
      timestamp: new Date().toISOString(),
      level,
      message,
      context: { ...this.context, ...additionalContext },
      environment: this.environment,
      service: this.service,
      version: this.version,
    };

    // Add trace information if available
    const traceId = this.context.requestId || crypto.randomUUID();
    entry.trace = {
      traceId,
      spanId: crypto.randomUUID().substring(0, 16),
    };

    // Add error information
    if (error) {
      entry.error = {
        name: error.name,
        message: error.message,
        stack: error.stack,
      };
    }

    // Add performance metrics if available
    if (globalThis.performance) {
      entry.performance = {
        memoryUsage: this.getMemoryUsage(),
      };
    }

    // Add metadata
    if (metadata) {
      entry.metadata = metadata;
    }

    return entry;
  }

  private getMemoryUsage(): number {
    try {
      // Deno memory usage (if available)
      if (typeof Deno !== 'undefined' && Deno.memoryUsage) {
        return Deno.memoryUsage().rss;
      }
      return 0;
    } catch {
      return 0;
    }
  }

  private shouldLog(level: LogLevel): boolean {
    const configuredLevel = Deno.env.get('LOG_LEVEL') || 'info';
    const levels = ['debug', 'info', 'warn', 'error', 'fatal'];
    const configuredLevelIndex = levels.indexOf(configuredLevel);
    const messageLevelIndex = levels.indexOf(level);
    
    return messageLevelIndex >= configuredLevelIndex;
  }

  private formatLog(entry: LogEntry): string {
    const isProduction = this.environment === 'production';
    
    if (isProduction) {
      // JSON format for production log aggregation
      return JSON.stringify(entry);
    } else {
      // Human-readable format for development
      const timestamp = entry.timestamp.substring(11, 23); // Time only
      const level = entry.level.toUpperCase().padEnd(5);
      const context = entry.context.functionName 
        ? `[${entry.context.functionName}]` 
        : '[unknown]';
      
      let logLine = `${timestamp} ${level} ${context} ${entry.message}`;
      
      if (entry.error) {
        logLine += `\n  Error: ${entry.error.name}: ${entry.error.message}`;
        if (entry.error.stack) {
          logLine += `\n  Stack: ${entry.error.stack}`;
        }
      }
      
      if (entry.metadata && Object.keys(entry.metadata).length > 0) {
        logLine += `\n  Metadata: ${JSON.stringify(entry.metadata, null, 2)}`;
      }
      
      return logLine;
    }
  }

  private async sendToExternalService(entry: LogEntry): Promise<void> {
    // Send to external log aggregation service (e.g., Datadog, LogDNA, etc.)
    const logEndpoint = Deno.env.get('LOG_AGGREGATION_ENDPOINT');
    const logApiKey = Deno.env.get('LOG_AGGREGATION_API_KEY');
    
    if (!logEndpoint || !logApiKey) {
      return; // External logging not configured
    }

    try {
      await fetch(logEndpoint, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${logApiKey}`,
          'X-Source': 'stellr-edge-functions',
        },
        body: JSON.stringify(entry),
      });
    } catch (error) {
      // Don't log errors about logging to avoid infinite loops
}
  }

  private async log(
    level: LogLevel,
    message: string,
    context: LogContext = {},
    error?: Error,
    metadata?: Record<string, any>
  ): Promise<void> {
    if (!this.shouldLog(level)) {
      return;
    }

    const entry = this.createLogEntry(level, message, context, error, metadata);
    const formatted = this.formatLog(entry);
    
    // Output to console
    switch (level) {
      case 'debug':
        // Debug statement removed
break;
      case 'info':
        // Debug statement removed
break;
      case 'warn':
        console.warn(formatted);
        break;
      case 'error':
      case 'fatal':
        console.error(formatted);
        break;
    }

    // Send to external log aggregation service
    if (this.environment === 'production') {
      await this.sendToExternalService(entry);
    }

    // Record in database for critical errors
    if (level === 'error' || level === 'fatal') {
      await this.recordErrorInDatabase(entry);
    }
  }

  private async recordErrorInDatabase(entry: LogEntry): Promise<void> {
    try {
      const { createClient } = await import('@supabase/supabase-js');
      const supabaseUrl = Deno.env.get('SUPABASE_URL');
      const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
      
      if (!supabaseUrl || !supabaseServiceKey) {
        return;
      }

      const supabase = createClient(supabaseUrl, supabaseServiceKey);
      
      await supabase.from('error_logs').insert({
        error_level: entry.level,
        error_message: entry.message,
        error_code: entry.error?.name,
        function_name: entry.context.functionName,
        user_id: entry.context.userId,
        request_data: entry.metadata,
        stack_trace: entry.error?.stack,
      });
    } catch (error) {
      // Don't throw errors from logging
}
  }

  // Public logging methods
  async debug(message: string, context?: LogContext, metadata?: Record<string, any>): Promise<void> {
    await this.log('debug', message, context, undefined, metadata);
  }

  async info(message: string, context?: LogContext, metadata?: Record<string, any>): Promise<void> {
    await this.log('info', message, context, undefined, metadata);
  }

  async warn(message: string, context?: LogContext, metadata?: Record<string, any>): Promise<void> {
    await this.log('warn', message, context, undefined, metadata);
  }

  async error(message: string, error?: Error, context?: LogContext, metadata?: Record<string, any>): Promise<void> {
    await this.log('error', message, context, error, metadata);
  }

  async fatal(message: string, error?: Error, context?: LogContext, metadata?: Record<string, any>): Promise<void> {
    await this.log('fatal', message, context, error, metadata);
  }

  // Performance logging
  async logPerformance(
    operation: string,
    duration: number,
    context?: LogContext,
    metadata?: Record<string, any>
  ): Promise<void> {
    const perfContext = {
      ...context,
      operation,
      duration_ms: duration,
    };

    const perfMetadata = {
      ...metadata,
      performance: {
        duration,
        slow: duration > 1000, // Mark as slow if > 1 second
      },
    };

    if (duration > 5000) {
      await this.warn(`Slow operation detected: ${operation}`, perfContext, perfMetadata);
    } else {
      await this.info(`Operation completed: ${operation}`, perfContext, perfMetadata);
    }
  }

  // Request logging
  async logRequest(
    request: Request,
    response: { status: number; size?: number },
    duration: number,
    context?: LogContext
  ): Promise<void> {
    const url = new URL(request.url);
    const requestContext = {
      ...context,
      method: request.method,
      path: url.pathname,
      query: url.search,
      status: response.status,
      duration_ms: duration,
    };

    const metadata = {
      request: {
        method: request.method,
        url: request.url,
        headers: Object.fromEntries(request.headers.entries()),
        userAgent: request.headers.get('user-agent'),
        referrer: request.headers.get('referer'),
      },
      response: {
        status: response.status,
        size: response.size,
      },
      performance: {
        duration,
      },
    };

    const level = response.status >= 500 ? 'error' : 
                 response.status >= 400 ? 'warn' : 
                 duration > 5000 ? 'warn' : 'info';

    await this.log(level, `${request.method} ${url.pathname} ${response.status}`, requestContext, undefined, metadata);
  }

  // Create child logger with additional context
  child(additionalContext: LogContext): StructuredLogger {
    return new StructuredLogger({ ...this.context, ...additionalContext });
  }

  // Add context to existing logger
  addContext(additionalContext: LogContext): void {
    this.context = { ...this.context, ...additionalContext };
  }
}

// Global logger instance
let globalLogger: StructuredLogger | null = null;

export function getLogger(context?: LogContext): StructuredLogger {
  if (!globalLogger) {
    globalLogger = new StructuredLogger(context);
  } else if (context) {
    globalLogger.addContext(context);
  }
  return globalLogger;
}

export function createLogger(context: LogContext): StructuredLogger {
  return new StructuredLogger(context);
}

// Performance measurement utility
export class PerformanceTimer {
  private startTime: number;
  private operation: string;
  private logger: StructuredLogger;
  private context: LogContext;

  constructor(operation: string, logger?: StructuredLogger, context?: LogContext) {
    this.operation = operation;
    this.logger = logger || getLogger();
    this.context = context || {};
    this.startTime = performance.now();
  }

  async finish(metadata?: Record<string, any>): Promise<number> {
    const duration = performance.now() - this.startTime;
    await this.logger.logPerformance(this.operation, duration, this.context, metadata);
    return duration;
  }
}

// Request logging middleware
export function createRequestLogger(functionName: string) {
  return async (req: Request, handler: (req: Request) => Promise<Response>): Promise<Response> => {
    const startTime = performance.now();
    const requestId = crypto.randomUUID();
    
    const logger = createLogger({
      functionName,
      requestId,
      method: req.method,
      url: req.url,
    });

    try {
      await logger.info(`Request started: ${req.method} ${new URL(req.url).pathname}`);
      
      const response = await handler(req);
      const duration = performance.now() - startTime;
      
      await logger.logRequest(req, { 
        status: response.status,
        size: response.headers.get('content-length') ? 
              parseInt(response.headers.get('content-length')!) : undefined 
      }, duration);
      
      return response;
    } catch (error) {
      const duration = performance.now() - startTime;
      
      await logger.error(
        `Request failed: ${req.method} ${new URL(req.url).pathname}`,
        error as Error,
        { duration_ms: duration }
      );
      
      throw error;
    }
  };
}

// Simple wrapper functions for backwards compatibility
const defaultLogger = new StructuredLogger();

export function logError(message: string, error?: Error, context?: LogContext): Promise<void> {
  return defaultLogger.error(message, error, context);
}

export function logWarn(message: string, context?: LogContext): Promise<void> {
  return defaultLogger.warn(message, context);
}

export function logInfo(message: string, context?: LogContext): Promise<void> {
  return defaultLogger.info(message, context);
}

export function logDebug(message: string, context?: LogContext): Promise<void> {
  return defaultLogger.debug(message, context);
}

export function logUserAction(action: string, userId: string, context?: LogContext): Promise<void> {
  return defaultLogger.logUserAction(action, userId, context);
}

// Export types and utilities
export type { LogContext, LogLevel, LogEntry };
export { StructuredLogger };