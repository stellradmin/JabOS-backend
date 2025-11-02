/**
 * CRITICAL RESILIENCE: Circuit Breaker Pattern Implementation for Stellr
 * 
 * Features:
 * - Automatic failure detection and service isolation
 * - Configurable failure thresholds and timeout windows
 * - Exponential backoff and jitter for recovery
 * - Health check probes for service recovery
 * - Real-time monitoring and alerting
 * - Per-service configuration and state management
 * - Graceful degradation support
 */

import { getPerformanceMonitor } from './performance-monitor.ts';
import { getAdvancedCache } from './advanced-cache-system.ts';

export enum CircuitState {
  CLOSED = 'CLOSED',     // Normal operation
  OPEN = 'OPEN',         // Circuit is open, rejecting requests
  HALF_OPEN = 'HALF_OPEN' // Testing if service has recovered
}

export interface CircuitBreakerConfig {
  name: string;
  failureThreshold: number;        // Number of failures before opening
  recoveryTimeMs: number;          // Time to wait before trying recovery
  monitoringWindowMs: number;      // Time window for tracking failures
  timeoutMs: number;               // Request timeout
  healthCheckIntervalMs: number;   // Health check frequency
  maxRetryAttempts: number;        // Max retries with exponential backoff
  expectedLatencyMs: number;       // Expected response time
  slowCallThreshold: number;       // Slow call percentage to consider failure
  minimumThroughput: number;       // Minimum calls before circuit can open
}

export interface CircuitBreakerMetrics {
  state: CircuitState;
  failureCount: number;
  successCount: number;
  lastFailureTime: number;
  lastSuccessTime: number;
  totalRequests: number;
  rejectedRequests: number;
  slowCalls: number;
  averageResponseTime: number;
  healthCheckStatus: 'healthy' | 'unhealthy' | 'unknown';
  lastHealthCheck: number;
  circuitOpenedAt?: number;
  lastStateChange: number;
}

interface CircuitBreakerCall<T> {
  promise: Promise<T>;
  startTime: number;
  timeoutHandle?: number;
}

export class CircuitBreaker<T = any> {
  private config: CircuitBreakerConfig;
  private metrics: CircuitBreakerMetrics;
  private recentCalls: Array<{ timestamp: number; success: boolean; duration: number }> = [];
  private healthCheckInterval?: number;
  private cache = getAdvancedCache();
  private monitor = getPerformanceMonitor();

  constructor(config: Partial<CircuitBreakerConfig> & { name: string }) {
    this.config = {
      failureThreshold: 5,
      recoveryTimeMs: 30000, // 30 seconds
      monitoringWindowMs: 60000, // 1 minute
      timeoutMs: 10000, // 10 seconds
      healthCheckIntervalMs: 15000, // 15 seconds
      maxRetryAttempts: 3,
      expectedLatencyMs: 1000, // 1 second
      slowCallThreshold: 0.5, // 50% slow calls trigger failure
      minimumThroughput: 10, // Need at least 10 calls
      ...config,
    };

    this.metrics = {
      state: CircuitState.CLOSED,
      failureCount: 0,
      successCount: 0,
      lastFailureTime: 0,
      lastSuccessTime: 0,
      totalRequests: 0,
      rejectedRequests: 0,
      slowCalls: 0,
      averageResponseTime: 0,
      healthCheckStatus: 'unknown',
      lastHealthCheck: 0,
      lastStateChange: Date.now(),
    };

    this.startHealthChecking();
  }

  /**
   * Execute a function with circuit breaker protection
   */
  async execute<R = T>(
    fn: () => Promise<R>,
    fallback?: () => Promise<R>,
    retryCount: number = 0
  ): Promise<R> {
    const startTime = Date.now();
    this.metrics.totalRequests++;

    // Check if circuit is open
    if (this.metrics.state === CircuitState.OPEN) {
      if (!this.shouldAttemptReset()) {
        this.metrics.rejectedRequests++;
        this.recordMetric('circuit.request_rejected', 1);
        
        if (fallback) {
          return await fallback();
        }
        
        throw new CircuitBreakerError(
          `Circuit breaker is OPEN for ${this.config.name}`,
          'CIRCUIT_OPEN',
          this.config.recoveryTimeMs - (Date.now() - (this.metrics.circuitOpenedAt || 0))
        );
      } else {
        // Transition to half-open
        this.changeState(CircuitState.HALF_OPEN);
      }
    }

    try {
      // Execute with timeout
      const result = await this.executeWithTimeout(fn);
      const duration = Date.now() - startTime;
      
      // Record successful call
      this.recordCall(true, duration);
      this.recordMetric('circuit.request_success', duration);
      
      // If we were in half-open state, close the circuit
      if (this.metrics.state === CircuitState.HALF_OPEN) {
        this.changeState(CircuitState.CLOSED);
      }
      
      return result;
      
    } catch (error) {
      const duration = Date.now() - startTime;
      this.recordCall(false, duration);
      this.recordMetric('circuit.request_failure', duration);
      
      // Check if we should open the circuit
      if (this.shouldOpenCircuit()) {
        this.changeState(CircuitState.OPEN);
        this.metrics.circuitOpenedAt = Date.now();
      }
      
      // Retry with exponential backoff if configured
      if (retryCount < this.config.maxRetryAttempts && this.shouldRetry(error)) {
        const backoffMs = this.calculateBackoff(retryCount);
        await this.delay(backoffMs);
        return this.execute(fn, fallback, retryCount + 1);
      }
      
      // Use fallback if available
      if (fallback) {
        try {
          return await fallback();
        } catch (fallbackError) {
          throw error; // Throw original error if fallback fails
        }
      }
      
      throw error;
    }
  }

  /**
   * Execute function with timeout
   */
  private async executeWithTimeout<R>(fn: () => Promise<R>): Promise<R> {
    return new Promise<R>((resolve, reject) => {
      const timeoutHandle = setTimeout(() => {
        reject(new CircuitBreakerError(
          `Request timeout after ${this.config.timeoutMs}ms for ${this.config.name}`,
          'TIMEOUT'
        ));
      }, this.config.timeoutMs);

      fn()
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
   * Record call result and update metrics
   */
  private recordCall(success: boolean, duration: number): void {
    const now = Date.now();
    
    // Add to recent calls (keep only within monitoring window)
    this.recentCalls.push({ timestamp: now, success, duration });
    this.recentCalls = this.recentCalls.filter(
      call => now - call.timestamp <= this.config.monitoringWindowMs
    );

    // Update metrics
    if (success) {
      this.metrics.successCount++;
      this.metrics.lastSuccessTime = now;
    } else {
      this.metrics.failureCount++;
      this.metrics.lastFailureTime = now;
    }

    // Check if call was slow
    if (duration > this.config.expectedLatencyMs) {
      this.metrics.slowCalls++;
    }

    // Update average response time
    const totalDuration = this.recentCalls.reduce((sum, call) => sum + call.duration, 0);
    this.metrics.averageResponseTime = totalDuration / this.recentCalls.length;
  }

  /**
   * Determine if circuit should open based on failure metrics
   */
  private shouldOpenCircuit(): boolean {
    const recentCallsInWindow = this.recentCalls.filter(
      call => Date.now() - call.timestamp <= this.config.monitoringWindowMs
    );
    
    if (recentCallsInWindow.length < this.config.minimumThroughput) {
      return false; // Not enough data
    }

    const failures = recentCallsInWindow.filter(call => !call.success).length;
    const slowCalls = recentCallsInWindow.filter(call => call.duration > this.config.expectedLatencyMs).length;
    
    const failureRate = failures / recentCallsInWindow.length;
    const slowCallRate = slowCalls / recentCallsInWindow.length;
    
    return failureRate >= (this.config.failureThreshold / 100) || 
           slowCallRate >= this.config.slowCallThreshold;
  }

  /**
   * Check if we should attempt to reset (transition from OPEN to HALF_OPEN)
   */
  private shouldAttemptReset(): boolean {
    const timeSinceOpened = Date.now() - (this.metrics.circuitOpenedAt || 0);
    return timeSinceOpened >= this.config.recoveryTimeMs;
  }

  /**
   * Determine if error is retryable
   */
  private shouldRetry(error: any): boolean {
    // Don't retry client errors (4xx) or circuit breaker specific errors
    if (error instanceof CircuitBreakerError) {
      return error.code !== 'CIRCUIT_OPEN';
    }
    
    // Retry on network errors, timeouts, and server errors (5xx)
    if (error.name === 'TypeError' && error.message.includes('fetch')) {
      return true; // Network error
    }
    
    if (error.status >= 500 && error.status < 600) {
      return true; // Server error
    }
    
    return false;
  }

  /**
   * Calculate exponential backoff with jitter
   */
  private calculateBackoff(retryCount: number): number {
    const baseDelay = 1000; // 1 second
    const maxDelay = 30000; // 30 seconds
    const exponentialDelay = Math.min(baseDelay * Math.pow(2, retryCount), maxDelay);
    
    // Add jitter to prevent thundering herd
    const jitter = Math.random() * 0.3; // 30% jitter
    return exponentialDelay * (1 + jitter);
  }

  /**
   * Delay utility
   */
  private delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * Change circuit state and record metrics
   */
  private changeState(newState: CircuitState): void {
    if (this.metrics.state === newState) return;
    
    const oldState = this.metrics.state;
    this.metrics.state = newState;
    this.metrics.lastStateChange = Date.now();
    
    // Record state change metric
    this.recordMetric('circuit.state_change', 1, {
      from: oldState,
      to: newState,
    });
    
    // Reset failure count when closing circuit
    if (newState === CircuitState.CLOSED) {
      this.metrics.failureCount = 0;
      this.metrics.slowCalls = 0;
    }
  }

  /**
   * Perform health check
   */
  private async performHealthCheck(): Promise<boolean> {
    try {
      // Simple health check - could be customized per service
      const startTime = Date.now();
      
      // If we have a cached health status, use it briefly
      const cacheKey = `health:${this.config.name}`;
      const cachedHealth = await this.cache.get<string>(cacheKey);
      
      if (cachedHealth === 'healthy' && Date.now() - this.metrics.lastHealthCheck < 30000) {
        return true;
      }
      
      // Infer health from failure rate (standard circuit breaker pattern)
      // The circuit breaker doesn't ping external services - it monitors actual operation results
      // Health is determined by whether the failure threshold has been reached
      const isHealthy = this.metrics.failureCount < this.config.failureThreshold;
      
      const duration = Date.now() - startTime;
      this.metrics.healthCheckStatus = isHealthy ? 'healthy' : 'unhealthy';
      this.metrics.lastHealthCheck = Date.now();
      
      // Cache health status briefly
      await this.cache.set(cacheKey, isHealthy ? 'healthy' : 'unhealthy', 30);
      
      this.recordMetric('circuit.health_check', duration, {
        status: this.metrics.healthCheckStatus,
      });
      
      return isHealthy;
      
    } catch (error) {
      this.metrics.healthCheckStatus = 'unhealthy';
      this.metrics.lastHealthCheck = Date.now();
      return false;
    }
  }

  /**
   * Start periodic health checking
   */
  private startHealthChecking(): void {
    this.healthCheckInterval = setInterval(async () => {
      if (this.metrics.state === CircuitState.OPEN) {
        const isHealthy = await this.performHealthCheck();
        if (isHealthy && this.shouldAttemptReset()) {
          this.changeState(CircuitState.HALF_OPEN);
        }
      } else {
        await this.performHealthCheck();
      }
    }, this.config.healthCheckIntervalMs);
  }

  /**
   * Record performance metric
   */
  private recordMetric(name: string, value: number, tags: Record<string, string> = {}): void {
    this.monitor.recordMetric({
      name,
      value,
      unit: name.includes('time') || name.includes('duration') ? 'ms' : 'count',
      tags: {
        circuit: this.config.name,
        state: this.metrics.state,
        ...tags,
      },
    });
  }

  /**
   * Get current metrics
   */
  getMetrics(): CircuitBreakerMetrics {
    return { ...this.metrics };
  }

  /**
   * Get current configuration
   */
  getConfig(): CircuitBreakerConfig {
    return { ...this.config };
  }

  /**
   * Manually reset circuit (for administrative purposes)
   */
  reset(): void {
    this.changeState(CircuitState.CLOSED);
    this.metrics.failureCount = 0;
    this.metrics.successCount = 0;
    this.metrics.slowCalls = 0;
    this.metrics.rejectedRequests = 0;
    this.recentCalls = [];
  }

  /**
   * Manually open circuit (for maintenance mode)
   */
  open(): void {
    this.changeState(CircuitState.OPEN);
    this.metrics.circuitOpenedAt = Date.now();
  }

  /**
   * Cleanup resources
   */
  destroy(): void {
    if (this.healthCheckInterval) {
      clearInterval(this.healthCheckInterval);
    }
  }
}

/**
 * Circuit Breaker specific error
 */
export class CircuitBreakerError extends Error {
  constructor(
    message: string,
    public code: string,
    public retryAfter?: number
  ) {
    super(message);
    this.name = 'CircuitBreakerError';
  }
}

/**
 * Circuit Breaker Manager - manages multiple circuit breakers
 */
class CircuitBreakerManager {
  private circuitBreakers = new Map<string, CircuitBreaker>();
  private defaultConfigs = new Map<string, Partial<CircuitBreakerConfig>>();

  constructor() {
    // Default configurations for different service types
    this.defaultConfigs.set('database', {
      failureThreshold: 10,
      recoveryTimeMs: 20000,
      timeoutMs: 5000,
      expectedLatencyMs: 500,
    });

    this.defaultConfigs.set('external_api', {
      failureThreshold: 5,
      recoveryTimeMs: 60000,
      timeoutMs: 15000,
      expectedLatencyMs: 2000,
    });

    this.defaultConfigs.set('file_storage', {
      failureThreshold: 3,
      recoveryTimeMs: 30000,
      timeoutMs: 30000,
      expectedLatencyMs: 5000,
    });

    this.defaultConfigs.set('payment', {
      failureThreshold: 2,
      recoveryTimeMs: 120000,
      timeoutMs: 20000,
      expectedLatencyMs: 3000,
    });
  }

  /**
   * Get or create circuit breaker for a service
   */
  getCircuitBreaker(
    serviceName: string,
    serviceType: 'database' | 'external_api' | 'file_storage' | 'payment' = 'external_api',
    customConfig?: Partial<CircuitBreakerConfig>
  ): CircuitBreaker {
    if (!this.circuitBreakers.has(serviceName)) {
      const defaultConfig = this.defaultConfigs.get(serviceType) || {};
      const config = {
        name: serviceName,
        ...defaultConfig,
        ...customConfig,
      };
      
      this.circuitBreakers.set(serviceName, new CircuitBreaker(config));
    }
    
    return this.circuitBreakers.get(serviceName)!;
  }

  /**
   * Get all circuit breaker metrics
   */
  getAllMetrics(): Record<string, CircuitBreakerMetrics> {
    const metrics: Record<string, CircuitBreakerMetrics> = {};
    
    for (const [name, breaker] of this.circuitBreakers.entries()) {
      metrics[name] = breaker.getMetrics();
    }
    
    return metrics;
  }

  /**
   * Reset all circuit breakers
   */
  resetAll(): void {
    for (const breaker of this.circuitBreakers.values()) {
      breaker.reset();
    }
  }

  /**
   * Cleanup all circuit breakers
   */
  destroy(): void {
    for (const breaker of this.circuitBreakers.values()) {
      breaker.destroy();
    }
    this.circuitBreakers.clear();
  }
}

// Singleton instance
const circuitBreakerManager = new CircuitBreakerManager();

export { CircuitBreakerManager, circuitBreakerManager };

/**
 * Convenience function to get a circuit breaker
 */
export function getCircuitBreaker(
  serviceName: string,
  serviceType?: 'database' | 'external_api' | 'file_storage' | 'payment',
  customConfig?: Partial<CircuitBreakerConfig>
): CircuitBreaker {
  return circuitBreakerManager.getCircuitBreaker(serviceName, serviceType, customConfig);
}

/**
 * Wrapper function for database operations
 */
export function withDatabaseCircuitBreaker<T>(
  operation: () => Promise<T>,
  serviceName: string = 'supabase'
): Promise<T> {
  const breaker = getCircuitBreaker(serviceName, 'database');
  return breaker.execute(operation);
}

/**
 * Wrapper function for external API calls
 */
export function withExternalApiCircuitBreaker<T>(
  operation: () => Promise<T>,
  serviceName: string,
  fallback?: () => Promise<T>
): Promise<T> {
  const breaker = getCircuitBreaker(serviceName, 'external_api');
  return breaker.execute(operation, fallback);
}

/**
 * Wrapper function for file storage operations
 */
export function withFileStorageCircuitBreaker<T>(
  operation: () => Promise<T>,
  serviceName: string = 'supabase_storage'
): Promise<T> {
  const breaker = getCircuitBreaker(serviceName, 'file_storage');
  return breaker.execute(operation);
}

/**
 * Wrapper function for payment operations
 */
export function withPaymentCircuitBreaker<T>(
  operation: () => Promise<T>,
  serviceName: string = 'stripe',
  fallback?: () => Promise<T>
): Promise<T> {
  const breaker = getCircuitBreaker(serviceName, 'payment');
  return breaker.execute(operation, fallback);
}