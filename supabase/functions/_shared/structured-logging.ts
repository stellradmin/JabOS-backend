/**
 * Structured Logging Utility for Stellr Backend
 * Provides production-ready logging with security event tracking
 */

export enum LogLevel {
  DEBUG = 'debug',
  INFO = 'info',
  WARN = 'warn',
  ERROR = 'error',
  CRITICAL = 'critical',
  SECURITY = 'security'
}

export enum LogCategory {
  AUTH = 'authentication',
  PAYMENTS = 'payments',
  MESSAGING = 'messaging',
  MATCHING = 'matching',
  PHOTOS = 'photos',
  WEBHOOK = 'webhook',
  SECURITY = 'security',
  PERFORMANCE = 'performance',
  USER_ACTIVITY = 'user_activity'
}

interface LogContext {
  userId?: string;
  sessionId?: string;
  clientIP?: string;
  userAgent?: string;
  requestId?: string;
  function?: string;
  duration?: number;
  [key: string]: any;
}

interface LogEntry {
  timestamp: string;
  level: LogLevel;
  category: LogCategory;
  message: string;
  context?: LogContext;
  stack?: string;
  securityEvent?: boolean;
  businessImpact?: 'low' | 'medium' | 'high' | 'critical';
}

class StructuredLogger {
  private static instance: StructuredLogger;
  private environment: string;
  private serviceName: string;

  private constructor() {
    this.environment = Deno.env.get('ENVIRONMENT') || 'development';
    this.serviceName = 'stellr-backend';
  }

  public static getInstance(): StructuredLogger {
    if (!StructuredLogger.instance) {
      StructuredLogger.instance = new StructuredLogger();
    }
    return StructuredLogger.instance;
  }

  private formatLogEntry(
    level: LogLevel,
    category: LogCategory,
    message: string,
    context?: LogContext,
    error?: Error
  ): LogEntry {
    const entry: LogEntry = {
      timestamp: new Date().toISOString(),
      level,
      category,
      message,
      context: {
        ...context,
        environment: this.environment,
        service: this.serviceName,
      }
    };

    if (error) {
      entry.stack = error.stack;
    }

    // Mark security-related events
    if (category === LogCategory.SECURITY || level === LogLevel.SECURITY) {
      entry.securityEvent = true;
    }

    // Determine business impact
    if (level === LogLevel.CRITICAL) {
      entry.businessImpact = 'critical';
    } else if (level === LogLevel.ERROR) {
      entry.businessImpact = 'high';
    } else if (level === LogLevel.WARN) {
      entry.businessImpact = 'medium';
    } else {
      entry.businessImpact = 'low';
    }

    return entry;
  }

  private shouldLog(level: LogLevel): boolean {
    // In production, log INFO and above
    if (this.environment === 'production') {
      return ![LogLevel.DEBUG].includes(level);
    }
    // In development, log everything
    return true;
  }

  private outputLog(entry: LogEntry): void {
    if (!this.shouldLog(entry.level)) {
      return;
    }

    // In production, output as JSON for log aggregation
    if (this.environment === 'production') {
      console.log(JSON.stringify(entry));
    } else {
      // In development, output human-readable format
      const timestamp = entry.timestamp;
      const level = entry.level.toUpperCase().padEnd(8);
      const category = entry.category.toUpperCase().padEnd(12);
      console.log(`[${timestamp}] ${level} ${category} ${entry.message}`);
      
      if (entry.context && Object.keys(entry.context).length > 0) {
        console.log('  Context:', JSON.stringify(entry.context, null, 2));
      }
      
      if (entry.stack) {
        console.log('  Stack:', entry.stack);
      }
    }
  }

  public debug(category: LogCategory, message: string, context?: LogContext): void {
    const entry = this.formatLogEntry(LogLevel.DEBUG, category, message, context);
    this.outputLog(entry);
  }

  public info(category: LogCategory, message: string, context?: LogContext): void {
    const entry = this.formatLogEntry(LogLevel.INFO, category, message, context);
    this.outputLog(entry);
  }

  public warn(category: LogCategory, message: string, context?: LogContext): void {
    const entry = this.formatLogEntry(LogLevel.WARN, category, message, context);
    this.outputLog(entry);
  }

  public error(category: LogCategory, message: string, context?: LogContext, error?: Error): void {
    const entry = this.formatLogEntry(LogLevel.ERROR, category, message, context, error);
    this.outputLog(entry);
  }

  public critical(category: LogCategory, message: string, context?: LogContext, error?: Error): void {
    const entry = this.formatLogEntry(LogLevel.CRITICAL, category, message, context, error);
    this.outputLog(entry);
  }

  public security(message: string, context?: LogContext, error?: Error): void {
    const entry = this.formatLogEntry(LogLevel.SECURITY, LogCategory.SECURITY, message, context, error);
    this.outputLog(entry);
  }

  // Convenience methods for common scenarios
  public authFailure(message: string, context?: LogContext): void {
    this.security(`Authentication failure: ${message}`, context);
  }

  public rateLimitExceeded(endpoint: string, clientIP: string, context?: LogContext): void {
    this.warn(LogCategory.SECURITY, `Rate limit exceeded for endpoint ${endpoint}`, {
      ...context,
      clientIP,
      securityEvent: true
    });
  }

  public paymentEvent(message: string, context?: LogContext): void {
    this.info(LogCategory.PAYMENTS, message, context);
  }

  public performanceWarning(message: string, duration: number, context?: LogContext): void {
    this.warn(LogCategory.PERFORMANCE, message, {
      ...context,
      duration,
      performanceIssue: true
    });
  }

  public userActivity(action: string, userId: string, context?: LogContext): void {
    this.info(LogCategory.USER_ACTIVITY, `User action: ${action}`, {
      ...context,
      userId
    });
  }
}

// Export singleton instance
export const logger = StructuredLogger.getInstance();

// Export helper function for creating request context
export function createRequestContext(req: Request): LogContext {
  return {
    clientIP: req.headers.get('CF-Connecting-IP') || 
              req.headers.get('X-Forwarded-For')?.split(',')[0] || 
              req.headers.get('X-Real-IP') || 
              'unknown',
    userAgent: req.headers.get('User-Agent') || 'unknown',
    requestId: crypto.randomUUID(),
  };
}

// Export helper function for measuring request duration
export function createTimerContext(): { getElapsed: () => number } {
  const startTime = Date.now();
  return {
    getElapsed: () => Date.now() - startTime
  };
}