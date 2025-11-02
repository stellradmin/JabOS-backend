/**
 * CRITICAL RESILIENCE: Enhanced Error Handling with Timeout Management and Retry Mechanisms
 * 
 * Features:
 * - Intelligent retry strategies with exponential backoff
 * - Timeout management with adaptive thresholds
 * - Dead letter queues for failed operations
 * - Error categorization and routing
 * - Graceful degradation patterns
 * - Real-time error monitoring and alerting
 * - Recovery orchestration
 */

import { getPerformanceMonitor } from './performance-monitor.ts';
import { getAdvancedCache } from './advanced-cache-system.ts';
import { CircuitBreaker, getCircuitBreaker } from './circuit-breaker.ts';

export enum ErrorCategory {
  TRANSIENT = 'transient',           // Temporary errors that should be retried
  PERMANENT = 'permanent',           // Errors that won't be resolved by retry
  RATE_LIMITED = 'rate_limited',     // Rate limiting errors
  TIMEOUT = 'timeout',               // Timeout errors
  AUTH = 'auth',                     // Authentication/authorization errors
  VALIDATION = 'validation',         // Input validation errors
  NETWORK = 'network',               // Network connectivity errors
  RESOURCE = 'resource',             // Resource exhaustion errors
  UNKNOWN = 'unknown'                // Uncategorized errors
}

export enum RetryStrategy {
  EXPONENTIAL_BACKOFF = 'exponential_backoff',
  LINEAR_BACKOFF = 'linear_backoff',
  FIXED_INTERVAL = 'fixed_interval',
  IMMEDIATE = 'immediate',
  NO_RETRY = 'no_retry'
}

export interface ErrorContext {
  operation: string;
  userId?: string;
  requestId?: string;
  endpoint?: string;
  timestamp: number;
  metadata?: Record<string, any>;
  stackTrace?: string;
  correlationId?: string;
}

export interface RetryConfig {
  maxAttempts: number;
  strategy: RetryStrategy;
  baseDelayMs: number;
  maxDelayMs: number;
  jitterFactor: number;
  backoffMultiplier: number;
  retryableErrors: ErrorCategory[];
  timeoutMs: number;
  circuitBreakerEnabled: boolean;
}

export interface TimeoutConfig {
  default: number;
  database: number;
  external_api: number;
  file_upload: number;
  payment: number;
  auth: number;
}

export interface ErrorRecoveryAction {
  type: 'retry' | 'fallback' | 'degrade' | 'circuit_break' | 'alert';
  config?: any;
  fallbackValue?: any;
  condition?: (error: EnhancedError) => boolean;
}

export class EnhancedError extends Error {
  public readonly category: ErrorCategory;
  public readonly isRetryable: boolean;
  public readonly context: ErrorContext;
  public readonly originalError?: Error;
  public readonly httpStatus: number;
  public readonly retryCount: number;
  public readonly recoveryActions: ErrorRecoveryAction[];

  constructor(
    message: string,
    category: ErrorCategory,
    context: ErrorContext,
    httpStatus: number = 500,
    originalError?: Error,
    retryCount: number = 0
  ) {
    super(message);
    this.name = 'EnhancedError';
    this.category = category;
    this.context = context;
    this.originalError = originalError;
    this.httpStatus = httpStatus;
    this.retryCount = retryCount;
    this.isRetryable = this.determineRetryability();
    this.recoveryActions = this.determineRecoveryActions();
  }

  private determineRetryability(): boolean {
    const retryableCategories = [
      ErrorCategory.TRANSIENT,
      ErrorCategory.TIMEOUT,
      ErrorCategory.NETWORK,
      ErrorCategory.RATE_LIMITED
    ];
    return retryableCategories.includes(this.category);
  }

  private determineRecoveryActions(): ErrorRecoveryAction[] {
    const actions: ErrorRecoveryAction[] = [];

    switch (this.category) {
      case ErrorCategory.TRANSIENT:
        actions.push({ type: 'retry' });
        break;
      
      case ErrorCategory.TIMEOUT:
        actions.push({ type: 'retry' });
        actions.push({ type: 'degrade' });
        break;
      
      case ErrorCategory.RATE_LIMITED:
        actions.push({ type: 'retry' });
        actions.push({ type: 'circuit_break' });
        break;
      
      case ErrorCategory.NETWORK:
        actions.push({ type: 'retry' });
        actions.push({ type: 'fallback' });
        break;
      
      case ErrorCategory.RESOURCE:
        actions.push({ type: 'circuit_break' });
        actions.push({ type: 'alert' });
        break;
      
      case ErrorCategory.AUTH:
        actions.push({ type: 'alert' });
        break;
      
      default:
        actions.push({ type: 'alert' });
    }

    return actions;
  }

  toJSON(): Record<string, any> {
    return {
      name: this.name,
      message: this.message,
      category: this.category,
      isRetryable: this.isRetryable,
      context: this.context,
      httpStatus: this.httpStatus,
      retryCount: this.retryCount,
      recoveryActions: this.recoveryActions,
      stack: this.stack,
    };
  }
}

/**
 * Enhanced error resilience manager
 */
export class ErrorResilienceManager {
  private monitor = getPerformanceMonitor();
  private cache = getAdvancedCache();
  
  private readonly DEFAULT_RETRY_CONFIG: RetryConfig = {
    maxAttempts: 3,
    strategy: RetryStrategy.EXPONENTIAL_BACKOFF,
    baseDelayMs: 1000,
    maxDelayMs: 30000,
    jitterFactor: 0.3,
    backoffMultiplier: 2,
    retryableErrors: [
      ErrorCategory.TRANSIENT,
      ErrorCategory.TIMEOUT,
      ErrorCategory.NETWORK,
      ErrorCategory.RATE_LIMITED
    ],
    timeoutMs: 10000,
    circuitBreakerEnabled: true,
  };

  private readonly DEFAULT_TIMEOUTS: TimeoutConfig = {
    default: 10000,      // 10 seconds
    database: 5000,      // 5 seconds
    external_api: 15000, // 15 seconds
    file_upload: 60000,  // 60 seconds
    payment: 30000,      // 30 seconds
    auth: 8000,          // 8 seconds
  };

  private deadLetterQueue: EnhancedError[] = [];
  private errorStats = new Map<string, { count: number; lastSeen: number }>();

  /**
   * Execute operation with comprehensive error handling
   */
  async executeWithResilience<T>(
    operation: () => Promise<T>,
    context: ErrorContext,
    config: Partial<RetryConfig> = {},
    timeoutMs?: number
  ): Promise<T> {
    const fullConfig = { ...this.DEFAULT_RETRY_CONFIG, ...config };
    const operationTimeout = timeoutMs || this.getTimeoutForOperation(context.operation);
    
    let lastError: EnhancedError | null = null;
    
    for (let attempt = 0; attempt < fullConfig.maxAttempts; attempt++) {
      try {
        // Execute with timeout
        const result = await this.executeWithTimeout(
          operation,
          operationTimeout,
          context
        );
        
        // Success - record metrics and return
        this.recordSuccessMetrics(context, attempt);
        return result;
        
      } catch (error) {
        const enhancedError = this.enhanceError(error, context, attempt);
        lastError = enhancedError;
        
        // Record error metrics
        this.recordErrorMetrics(enhancedError);
        
        // Check if we should retry
        if (!this.shouldRetry(enhancedError, attempt, fullConfig)) {
          break;
        }
        
        // Calculate and apply delay before retry
        const delay = this.calculateRetryDelay(attempt, fullConfig);
        await this.delay(delay);
        
        // Update context for next attempt
        context.metadata = {
          ...context.metadata,
          retryAttempt: attempt + 1,
        };
      }
    }
    
    // All retries failed - handle final error
    if (lastError) {
      await this.handleFinalError(lastError);
      throw lastError;
    }
    
    // This should never happen, but just in case
    throw new EnhancedError(
      'Operation failed with unknown error',
      ErrorCategory.UNKNOWN,
      context
    );
  }

  /**
   * Execute operation with timeout
   */
  private async executeWithTimeout<T>(
    operation: () => Promise<T>,
    timeoutMs: number,
    context: ErrorContext
  ): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timeoutHandle = setTimeout(() => {
        reject(new EnhancedError(
          `Operation timed out after ${timeoutMs}ms`,
          ErrorCategory.TIMEOUT,
          { ...context, metadata: { ...context.metadata, timeoutMs } }
        ));
      }, timeoutMs);

      operation()
        .then(result => {
          clearTimeout(timeoutHandle);
          resolve(result);
        })
        .catch(error => {
          clearTimeout(timeoutHandle);
          reject(error);
        });
    });
  }

  /**
   * Enhance error with additional context and categorization
   */
  private enhanceError(
    error: any,
    context: ErrorContext,
    retryCount: number
  ): EnhancedError {
    if (error instanceof EnhancedError) {
      return new EnhancedError(
        error.message,
        error.category,
        { ...context, ...error.context },
        error.httpStatus,
        error.originalError,
        retryCount
      );
    }

    const category = this.categorizeError(error);
    const httpStatus = this.getHttpStatus(error, category);
    
    return new EnhancedError(
      error.message || 'Unknown error occurred',
      category,
      context,
      httpStatus,
      error,
      retryCount
    );
  }

  /**
   * Categorize error for appropriate handling
   */
  private categorizeError(error: any): ErrorCategory {
    // Network errors
    if (error.name === 'TypeError' && error.message.includes('fetch')) {
      return ErrorCategory.NETWORK;
    }
    
    // Timeout errors
    if (error.message?.includes('timeout') || error.code === 'ETIMEDOUT') {
      return ErrorCategory.TIMEOUT;
    }
    
    // Rate limiting
    if (error.status === 429 || error.message?.includes('rate limit')) {
      return ErrorCategory.RATE_LIMITED;
    }
    
    // Authentication errors
    if (error.status === 401 || error.status === 403) {
      return ErrorCategory.AUTH;
    }
    
    // Validation errors
    if (error.status === 400 || error.name === 'ZodError') {
      return ErrorCategory.VALIDATION;
    }
    
    // Server errors (likely transient)
    if (error.status >= 500 && error.status < 600) {
      return ErrorCategory.TRANSIENT;
    }
    
    // Database connection errors
    if (error.code === 'PGRST301' || error.message?.includes('connection')) {
      return ErrorCategory.TRANSIENT;
    }
    
    // Resource exhaustion
    if (error.message?.includes('memory') || error.message?.includes('disk space')) {
      return ErrorCategory.RESOURCE;
    }
    
    // Default to permanent for client errors
    if (error.status >= 400 && error.status < 500) {
      return ErrorCategory.PERMANENT;
    }
    
    return ErrorCategory.UNKNOWN;
  }

  /**
   * Get appropriate HTTP status for error category
   */
  private getHttpStatus(error: any, category: ErrorCategory): number {
    if (error.status && typeof error.status === 'number') {
      return error.status;
    }
    
    switch (category) {
      case ErrorCategory.AUTH:
        return 401;
      case ErrorCategory.VALIDATION:
        return 400;
      case ErrorCategory.RATE_LIMITED:
        return 429;
      case ErrorCategory.TIMEOUT:
        return 408;
      case ErrorCategory.RESOURCE:
        return 507;
      default:
        return 500;
    }
  }

  /**
   * Determine if error should be retried
   */
  private shouldRetry(
    error: EnhancedError,
    attempt: number,
    config: RetryConfig
  ): boolean {
    // Check if we've exceeded max attempts
    if (attempt >= config.maxAttempts - 1) {
      return false;
    }
    
    // Check if error category is retryable
    if (!config.retryableErrors.includes(error.category)) {
      return false;
    }
    
    // Check circuit breaker state
    if (config.circuitBreakerEnabled) {
      const circuitBreaker = getCircuitBreaker(error.context.operation);
      const metrics = circuitBreaker.getMetrics();
      
      if (metrics.state === 'OPEN') {
        return false; // Circuit is open, don't retry
      }
    }
    
    return true;
  }

  /**
   * Calculate retry delay based on strategy
   */
  private calculateRetryDelay(attempt: number, config: RetryConfig): number {
    let delay: number;
    
    switch (config.strategy) {
      case RetryStrategy.EXPONENTIAL_BACKOFF:
        delay = Math.min(
          config.baseDelayMs * Math.pow(config.backoffMultiplier, attempt),
          config.maxDelayMs
        );
        break;
      
      case RetryStrategy.LINEAR_BACKOFF:
        delay = Math.min(
          config.baseDelayMs * (attempt + 1),
          config.maxDelayMs
        );
        break;
      
      case RetryStrategy.FIXED_INTERVAL:
        delay = config.baseDelayMs;
        break;
      
      case RetryStrategy.IMMEDIATE:
        delay = 0;
        break;
      
      default:
        delay = config.baseDelayMs;
    }
    
    // Add jitter to prevent thundering herd
    const jitter = delay * config.jitterFactor * Math.random();
    return Math.floor(delay + jitter);
  }

  /**
   * Get timeout for specific operation type
   */
  private getTimeoutForOperation(operation: string): number {
    if (operation.includes('database') || operation.includes('query')) {
      return this.DEFAULT_TIMEOUTS.database;
    }
    
    if (operation.includes('api') || operation.includes('external')) {
      return this.DEFAULT_TIMEOUTS.external_api;
    }
    
    if (operation.includes('upload') || operation.includes('file')) {
      return this.DEFAULT_TIMEOUTS.file_upload;
    }
    
    if (operation.includes('payment') || operation.includes('stripe')) {
      return this.DEFAULT_TIMEOUTS.payment;
    }
    
    if (operation.includes('auth') || operation.includes('login')) {
      return this.DEFAULT_TIMEOUTS.auth;
    }
    
    return this.DEFAULT_TIMEOUTS.default;
  }

  /**
   * Handle final error after all retries failed
   */
  private async handleFinalError(error: EnhancedError): Promise<void> {
    // Add to dead letter queue for later analysis
    this.deadLetterQueue.push(error);
    
    // Execute recovery actions
    for (const action of error.recoveryActions) {
      await this.executeRecoveryAction(action, error);
    }
    
    // Alert if necessary
    if (this.shouldAlert(error)) {
      await this.sendAlert(error);
    }
  }

  /**
   * Execute recovery action
   */
  private async executeRecoveryAction(
    action: ErrorRecoveryAction,
    error: EnhancedError
  ): Promise<void> {
    try {
      switch (action.type) {
        case 'circuit_break':
          const circuitBreaker = getCircuitBreaker(error.context.operation);
          circuitBreaker.open(); // Manually open circuit
          break;
        
        case 'degrade':
          // Implement graceful degradation logic
          await this.implementGracefulDegradation(error);
          break;
        
        case 'alert':
          await this.sendAlert(error);
          break;
        
        // Retry and fallback are handled elsewhere
      }
    } catch (actionError) {
      // Recovery action failed - log but don't throw
      this.monitor.recordMetric({
        name: 'error.recovery_action_failed',
        value: 1,
        unit: 'count',
        tags: {
          action: action.type,
          original_error: error.category,
        },
      });
    }
  }

  /**
   * Implement graceful degradation
   */
  private async implementGracefulDegradation(error: EnhancedError): Promise<void> {
    // Example: Use cached data instead of fresh data
    // Example: Return simplified response
    // Example: Disable non-essential features
    
    const degradationKey = `degradation_${error.context.operation}`;
    await this.cache.set(degradationKey, {
      degraded: true,
      reason: error.category,
      timestamp: Date.now(),
    }, 300); // 5 minutes
  }

  /**
   * Determine if alert should be sent
   */
  private shouldAlert(error: EnhancedError): boolean {
    const alertableCategories = [
      ErrorCategory.RESOURCE,
      ErrorCategory.UNKNOWN,
    ];
    
    if (alertableCategories.includes(error.category)) {
      return true;
    }
    
    // Alert on high error rates
    const errorKey = `${error.context.operation}_${error.category}`;
    const stats = this.errorStats.get(errorKey) || { count: 0, lastSeen: 0 };
    
    // Alert if more than 10 errors in 5 minutes
    const fiveMinutesAgo = Date.now() - (5 * 60 * 1000);
    if (stats.count > 10 && stats.lastSeen > fiveMinutesAgo) {
      return true;
    }
    
    return false;
  }

  /**
   * Send alert for critical errors
   */
  private async sendAlert(error: EnhancedError): Promise<void> {
    // In production, this would integrate with alerting system
    // For now, record as high-priority metric
    this.monitor.recordMetric({
      name: 'error.alert_triggered',
      value: 1,
      unit: 'count',
      tags: {
        category: error.category,
        operation: error.context.operation,
        status: error.httpStatus.toString(),
      },
      metadata: {
        message: error.message,
        context: error.context,
      },
    });
  }

  /**
   * Record success metrics
   */
  private recordSuccessMetrics(context: ErrorContext, attempts: number): void {
    this.monitor.recordMetric({
      name: 'operation.success',
      value: 1,
      unit: 'count',
      tags: {
        operation: context.operation,
        attempts: attempts.toString(),
      },
    });
    
    if (attempts > 0) {
      this.monitor.recordMetric({
        name: 'operation.retry_success',
        value: attempts,
        unit: 'count',
        tags: {
          operation: context.operation,
        },
      });
    }
  }

  /**
   * Record error metrics
   */
  private recordErrorMetrics(error: EnhancedError): void {
    const errorKey = `${error.context.operation}_${error.category}`;
    const stats = this.errorStats.get(errorKey) || { count: 0, lastSeen: 0 };
    
    stats.count++;
    stats.lastSeen = Date.now();
    this.errorStats.set(errorKey, stats);
    
    this.monitor.recordMetric({
      name: 'error.occurred',
      value: 1,
      unit: 'count',
      tags: {
        category: error.category,
        operation: error.context.operation,
        retryable: error.isRetryable.toString(),
        status: error.httpStatus.toString(),
      },
    });
  }

  /**
   * Delay utility
   */
  private delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * Get error statistics for monitoring
   */
  getErrorStats(): Record<string, any> {
    const stats: Record<string, any> = {};
    
    for (const [key, value] of this.errorStats.entries()) {
      stats[key] = value;
    }
    
    return {
      errorStats: stats,
      deadLetterQueueSize: this.deadLetterQueue.length,
      recentErrors: this.deadLetterQueue.slice(-10),
    };
  }

  /**
   * Clear dead letter queue (for maintenance)
   */
  clearDeadLetterQueue(): number {
    const count = this.deadLetterQueue.length;
    this.deadLetterQueue = [];
    return count;
  }
}

// Singleton instance
let resilienceManagerInstance: ErrorResilienceManager | null = null;

export function getErrorResilienceManager(): ErrorResilienceManager {
  if (!resilienceManagerInstance) {
    resilienceManagerInstance = new ErrorResilienceManager();
  }
  return resilienceManagerInstance;
}

/**
 * Convenience function for resilient execution
 */
export async function executeResilient<T>(
  operation: () => Promise<T>,
  context: Partial<ErrorContext>,
  config?: Partial<RetryConfig>
): Promise<T> {
  const manager = getErrorResilienceManager();
  
  const fullContext: ErrorContext = {
    operation: 'unknown_operation',
    timestamp: Date.now(),
    ...context,
  };
  
  return manager.executeWithResilience(operation, fullContext, config);
}

/**
 * Wrapper for database operations with resilience
 */
export async function executeDbResilient<T>(
  operation: () => Promise<T>,
  operationName: string,
  userId?: string
): Promise<T> {
  return executeResilient(
    operation,
    {
      operation: `database_${operationName}`,
      userId,
    },
    {
      maxAttempts: 3,
      timeoutMs: 5000,
      retryableErrors: [ErrorCategory.TRANSIENT, ErrorCategory.TIMEOUT, ErrorCategory.NETWORK],
    }
  );
}

/**
 * Wrapper for external API calls with resilience
 */
export async function executeApiResilient<T>(
  operation: () => Promise<T>,
  apiName: string,
  userId?: string
): Promise<T> {
  return executeResilient(
    operation,
    {
      operation: `api_${apiName}`,
      userId,
    },
    {
      maxAttempts: 3,
      timeoutMs: 15000,
      retryableErrors: [
        ErrorCategory.TRANSIENT,
        ErrorCategory.TIMEOUT,
        ErrorCategory.NETWORK,
        ErrorCategory.RATE_LIMITED
      ],
    }
  );
}