/**
 * COMPATIBILITY PERFORMANCE MONITORING SYSTEM
 * 
 * Real-time monitoring for compatibility calculation performance
 * Tracks response times, cache hit rates, error rates, and optimization opportunities
 * 
 * Performance Targets:
 * - Single compatibility: <100ms
 * - Batch compatibility: <500ms  
 * - Potential matches: <200ms
 * - Cache hit rate: >60%
 * - Error rate: <1%
 */

import { supabaseAdmin } from './supabaseAdmin.ts';

export interface PerformanceMetric {
  operation_type: 'single_compatibility' | 'batch_compatibility' | 'potential_matches';
  user_id: string;
  response_time_ms: number;
  batch_size: number;
  cache_hit_rate: number;
  error_count: number;
  success: boolean;
  timestamp: Date;
  metadata?: {
    candidate_count?: number;
    cache_hits?: number;
    cache_misses?: number;
    database_query_time_ms?: number;
    calculation_time_ms?: number;
    memory_usage_mb?: number;
  };
}

export interface PerformanceStats {
  avg_response_time_ms: number;
  p95_response_time_ms: number;
  p99_response_time_ms: number;
  cache_hit_rate: number;
  success_rate: number;
  total_operations: number;
  operations_per_minute: number;
  slow_operations_count: number;
  error_rate: number;
  performance_grade: 'A' | 'B' | 'C' | 'D' | 'F';
  recommendations: string[];
}

export interface PerformanceAlert {
  severity: 'LOW' | 'MEDIUM' | 'HIGH' | 'CRITICAL';
  message: string;
  metric_value: number;
  threshold_value: number;
  timestamp: Date;
  user_id?: string;
  operation_type?: string;
}

/**
 * High-Performance Compatibility Monitor
 */
export class CompatibilityPerformanceMonitor {
  private metrics: PerformanceMetric[] = [];
  private alerts: PerformanceAlert[] = [];
  
  // Performance thresholds
  private readonly THRESHOLDS = {
    SINGLE_COMPATIBILITY_MS: 100,
    BATCH_COMPATIBILITY_MS: 500,
    POTENTIAL_MATCHES_MS: 200,
    MIN_CACHE_HIT_RATE: 0.6,
    MAX_ERROR_RATE: 0.01,
    CRITICAL_RESPONSE_TIME_MS: 1000,
    HIGH_RESPONSE_TIME_MS: 750
  };

  /**
   * Record performance metric
   */
  recordMetric(metric: PerformanceMetric): void {
    // Add timestamp if not provided
    if (!metric.timestamp) {
      metric.timestamp = new Date();
    }

    // Store metric in memory (with size limit)
    this.metrics.push(metric);
    if (this.metrics.length > 1000) {
      this.metrics = this.metrics.slice(-500); // Keep most recent 500
    }

    // Check for performance alerts
    this.checkPerformanceAlerts(metric);

    // Log to database for persistent tracking (async, don't block)
    this.logToDatabase(metric).catch(error => {
      console.error('Failed to log performance metric to database:', error);
    });
  }

  /**
   * Start tracking an operation
   */
  startTracking(
    operation_type: PerformanceMetric['operation_type'],
    user_id: string,
    metadata?: PerformanceMetric['metadata']
  ): PerformanceTracker {
    return new PerformanceTracker(this, operation_type, user_id, metadata);
  }

  /**
   * Get current performance statistics
   */
  getPerformanceStats(timeWindowMinutes = 60): PerformanceStats {
    const cutoffTime = new Date(Date.now() - timeWindowMinutes * 60 * 1000);
    const recentMetrics = this.metrics.filter(m => m.timestamp >= cutoffTime);

    if (recentMetrics.length === 0) {
      return this.getEmptyStats();
    }

    // Calculate response time statistics
    const responseTimes = recentMetrics.map(m => m.response_time_ms);
    responseTimes.sort((a, b) => a - b);

    const avgResponseTime = responseTimes.reduce((a, b) => a + b, 0) / responseTimes.length;
    const p95Index = Math.floor(responseTimes.length * 0.95);
    const p99Index = Math.floor(responseTimes.length * 0.99);
    const p95ResponseTime = responseTimes[p95Index] || 0;
    const p99ResponseTime = responseTimes[p99Index] || 0;

    // Calculate success and cache statistics
    const successfulOps = recentMetrics.filter(m => m.success).length;
    const successRate = successfulOps / recentMetrics.length;
    const avgCacheHitRate = recentMetrics.reduce((sum, m) => sum + m.cache_hit_rate, 0) / recentMetrics.length;
    const errorRate = recentMetrics.filter(m => !m.success).length / recentMetrics.length;

    // Count slow operations
    const slowOpsCount = recentMetrics.filter(m => m.response_time_ms > this.getThresholdForOperation(m.operation_type)).length;

    // Calculate operations per minute
    const operationsPerMinute = recentMetrics.length / timeWindowMinutes;

    // Calculate performance grade
    const grade = this.calculatePerformanceGrade(avgResponseTime, successRate, avgCacheHitRate, errorRate);

    // Generate recommendations
    const recommendations = this.generateRecommendations(recentMetrics, avgResponseTime, successRate, avgCacheHitRate);

    return {
      avg_response_time_ms: Math.round(avgResponseTime),
      p95_response_time_ms: Math.round(p95ResponseTime),
      p99_response_time_ms: Math.round(p99ResponseTime),
      cache_hit_rate: Math.round(avgCacheHitRate * 100) / 100,
      success_rate: Math.round(successRate * 100) / 100,
      total_operations: recentMetrics.length,
      operations_per_minute: Math.round(operationsPerMinute * 10) / 10,
      slow_operations_count: slowOpsCount,
      error_rate: Math.round(errorRate * 1000) / 1000,
      performance_grade: grade,
      recommendations
    };
  }

  /**
   * Get recent performance alerts
   */
  getRecentAlerts(severityFilter?: PerformanceAlert['severity']): PerformanceAlert[] {
    let alerts = this.alerts.filter(alert => 
      alert.timestamp >= new Date(Date.now() - 24 * 60 * 60 * 1000) // Last 24 hours
    );

    if (severityFilter) {
      alerts = alerts.filter(alert => alert.severity === severityFilter);
    }

    return alerts.sort((a, b) => b.timestamp.getTime() - a.timestamp.getTime());
  }

  /**
   * Check for performance issues and create alerts
   */
  private checkPerformanceAlerts(metric: PerformanceMetric): void {
    const alerts: PerformanceAlert[] = [];

    // Critical response time alert
    if (metric.response_time_ms > this.THRESHOLDS.CRITICAL_RESPONSE_TIME_MS) {
      alerts.push({
        severity: 'CRITICAL',
        message: `Critical response time: ${metric.response_time_ms}ms for ${metric.operation_type}`,
        metric_value: metric.response_time_ms,
        threshold_value: this.THRESHOLDS.CRITICAL_RESPONSE_TIME_MS,
        timestamp: new Date(),
        user_id: metric.user_id,
        operation_type: metric.operation_type
      });
    }

    // High response time alert
    if (metric.response_time_ms > this.THRESHOLDS.HIGH_RESPONSE_TIME_MS && metric.response_time_ms <= this.THRESHOLDS.CRITICAL_RESPONSE_TIME_MS) {
      alerts.push({
        severity: 'HIGH',
        message: `High response time: ${metric.response_time_ms}ms for ${metric.operation_type}`,
        metric_value: metric.response_time_ms,
        threshold_value: this.THRESHOLDS.HIGH_RESPONSE_TIME_MS,
        timestamp: new Date(),
        user_id: metric.user_id,
        operation_type: metric.operation_type
      });
    }

    // Operation-specific threshold alerts
    const threshold = this.getThresholdForOperation(metric.operation_type);
    if (metric.response_time_ms > threshold) {
      alerts.push({
        severity: 'MEDIUM',
        message: `${metric.operation_type} exceeded target: ${metric.response_time_ms}ms (target: ${threshold}ms)`,
        metric_value: metric.response_time_ms,
        threshold_value: threshold,
        timestamp: new Date(),
        user_id: metric.user_id,
        operation_type: metric.operation_type
      });
    }

    // Low cache hit rate alert
    if (metric.cache_hit_rate < this.THRESHOLDS.MIN_CACHE_HIT_RATE) {
      alerts.push({
        severity: 'MEDIUM',
        message: `Low cache hit rate: ${Math.round(metric.cache_hit_rate * 100)}% (target: ${Math.round(this.THRESHOLDS.MIN_CACHE_HIT_RATE * 100)}%)`,
        metric_value: metric.cache_hit_rate,
        threshold_value: this.THRESHOLDS.MIN_CACHE_HIT_RATE,
        timestamp: new Date(),
        user_id: metric.user_id,
        operation_type: metric.operation_type
      });
    }

    // Error alert
    if (!metric.success) {
      alerts.push({
        severity: 'HIGH',
        message: `Operation failed: ${metric.operation_type} for user ${metric.user_id}`,
        metric_value: 1,
        threshold_value: 0,
        timestamp: new Date(),
        user_id: metric.user_id,
        operation_type: metric.operation_type
      });
    }

    // Add alerts to collection
    this.alerts.push(...alerts);

    // Keep only recent alerts (last 24 hours)
    const cutoffTime = new Date(Date.now() - 24 * 60 * 60 * 1000);
    this.alerts = this.alerts.filter(alert => alert.timestamp >= cutoffTime);

    // Log critical alerts immediately
    alerts.filter(alert => alert.severity === 'CRITICAL').forEach(alert => {
      console.error('CRITICAL PERFORMANCE ALERT:', alert.message);
    });
  }

  /**
   * Log metric to database
   */
  private async logToDatabase(metric: PerformanceMetric): Promise<void> {
    try {
      await supabaseAdmin.rpc('log_compatibility_performance', {
        p_user_id: metric.user_id,
        p_batch_size: metric.batch_size,
        p_calculation_time_ms: metric.response_time_ms,
        p_cache_hit_rate: metric.cache_hit_rate,
        p_error_count: metric.error_count
      });
    } catch (error) {
      // Don't throw - just log the error to avoid disrupting main flow
      console.error('Database logging failed:', error);
    }
  }

  /**
   * Get threshold for specific operation type
   */
  private getThresholdForOperation(operationType: PerformanceMetric['operation_type']): number {
    switch (operationType) {
      case 'single_compatibility':
        return this.THRESHOLDS.SINGLE_COMPATIBILITY_MS;
      case 'batch_compatibility':
        return this.THRESHOLDS.BATCH_COMPATIBILITY_MS;
      case 'potential_matches':
        return this.THRESHOLDS.POTENTIAL_MATCHES_MS;
      default:
        return 500; // Default threshold
    }
  }

  /**
   * Calculate overall performance grade
   */
  private calculatePerformanceGrade(
    avgResponseTime: number,
    successRate: number,
    cacheHitRate: number,
    errorRate: number
  ): 'A' | 'B' | 'C' | 'D' | 'F' {
    let score = 0;

    // Response time scoring (40% weight)
    if (avgResponseTime <= 200) score += 40;
    else if (avgResponseTime <= 400) score += 30;
    else if (avgResponseTime <= 600) score += 20;
    else if (avgResponseTime <= 800) score += 10;

    // Success rate scoring (30% weight)
    if (successRate >= 0.99) score += 30;
    else if (successRate >= 0.95) score += 25;
    else if (successRate >= 0.90) score += 20;
    else if (successRate >= 0.80) score += 10;

    // Cache hit rate scoring (20% weight)
    if (cacheHitRate >= 0.8) score += 20;
    else if (cacheHitRate >= 0.6) score += 15;
    else if (cacheHitRate >= 0.4) score += 10;
    else if (cacheHitRate >= 0.2) score += 5;

    // Error rate scoring (10% weight)
    if (errorRate <= 0.001) score += 10;
    else if (errorRate <= 0.01) score += 8;
    else if (errorRate <= 0.05) score += 5;
    else if (errorRate <= 0.1) score += 2;

    // Convert to letter grade
    if (score >= 90) return 'A';
    if (score >= 80) return 'B';
    if (score >= 70) return 'C';
    if (score >= 60) return 'D';
    return 'F';
  }

  /**
   * Generate performance recommendations
   */
  private generateRecommendations(
    metrics: PerformanceMetric[],
    avgResponseTime: number,
    successRate: number,
    cacheHitRate: number
  ): string[] {
    const recommendations: string[] = [];

    // Response time recommendations
    if (avgResponseTime > 400) {
      recommendations.push('Consider optimizing database queries or adding more aggressive caching');
    }
    if (avgResponseTime > 600) {
      recommendations.push('Critical: Response times exceed acceptable limits - immediate optimization needed');
    }

    // Cache recommendations
    if (cacheHitRate < 0.4) {
      recommendations.push('Cache hit rate is low - review caching strategy and TTL settings');
    }
    if (cacheHitRate < 0.6) {
      recommendations.push('Consider pre-warming cache for frequently requested compatibility calculations');
    }

    // Error rate recommendations
    if (successRate < 0.95) {
      recommendations.push('High error rate detected - review error logs and add more robust error handling');
    }

    // Batch size recommendations
    const batchMetrics = metrics.filter(m => m.operation_type === 'batch_compatibility');
    if (batchMetrics.length > 0) {
      const avgBatchSize = batchMetrics.reduce((sum, m) => sum + m.batch_size, 0) / batchMetrics.length;
      if (avgBatchSize > 50) {
        recommendations.push('Consider reducing batch size for better performance and error isolation');
      }
    }

    // Memory recommendations
    const memoryMetrics = metrics.filter(m => m.metadata?.memory_usage_mb).map(m => m.metadata!.memory_usage_mb!);
    if (memoryMetrics.length > 0) {
      const avgMemory = memoryMetrics.reduce((a, b) => a + b, 0) / memoryMetrics.length;
      if (avgMemory > 512) {
        recommendations.push('High memory usage detected - consider memory optimization strategies');
      }
    }

    // General recommendations
    if (recommendations.length === 0) {
      if (avgResponseTime < 200 && cacheHitRate > 0.8 && successRate > 0.99) {
        recommendations.push('Excellent performance! Consider this as a baseline for monitoring');
      } else {
        recommendations.push('Performance is acceptable but can be optimized further');
      }
    }

    return recommendations;
  }

  /**
   * Get empty stats object
   */
  private getEmptyStats(): PerformanceStats {
    return {
      avg_response_time_ms: 0,
      p95_response_time_ms: 0,
      p99_response_time_ms: 0,
      cache_hit_rate: 0,
      success_rate: 0,
      total_operations: 0,
      operations_per_minute: 0,
      slow_operations_count: 0,
      error_rate: 0,
      performance_grade: 'F',
      recommendations: ['No data available for analysis']
    };
  }
}

/**
 * Performance Tracker for individual operations
 */
export class PerformanceTracker {
  private startTime: number;
  private monitor: CompatibilityPerformanceMonitor;
  private operationType: PerformanceMetric['operation_type'];
  private userId: string;
  private metadata: PerformanceMetric['metadata'];
  private batchSize = 1;
  private cacheHits = 0;
  private cacheMisses = 0;
  private errorCount = 0;

  constructor(
    monitor: CompatibilityPerformanceMonitor,
    operationType: PerformanceMetric['operation_type'],
    userId: string,
    metadata?: PerformanceMetric['metadata']
  ) {
    this.monitor = monitor;
    this.operationType = operationType;
    this.userId = userId;
    this.metadata = metadata || {};
    this.startTime = performance.now();
  }

  /**
   * Set batch size for the operation
   */
  setBatchSize(size: number): void {
    this.batchSize = size;
  }

  /**
   * Record a cache hit
   */
  recordCacheHit(): void {
    this.cacheHits++;
  }

  /**
   * Record a cache miss
   */
  recordCacheMiss(): void {
    this.cacheMisses++;
  }

  /**
   * Record an error
   */
  recordError(): void {
    this.errorCount++;
  }

  /**
   * End tracking and record the metric
   */
  end(success = true): number {
    const responseTime = Math.round(performance.now() - this.startTime);
    const totalCacheRequests = this.cacheHits + this.cacheMisses;
    const cacheHitRate = totalCacheRequests > 0 ? this.cacheHits / totalCacheRequests : 0;

    const metric: PerformanceMetric = {
      operation_type: this.operationType,
      user_id: this.userId,
      response_time_ms: responseTime,
      batch_size: this.batchSize,
      cache_hit_rate: cacheHitRate,
      error_count: this.errorCount,
      success: success && this.errorCount === 0,
      timestamp: new Date(),
      metadata: {
        ...this.metadata,
        cache_hits: this.cacheHits,
        cache_misses: this.cacheMisses,
        calculation_time_ms: responseTime
      }
    };

    this.monitor.recordMetric(metric);
    return responseTime;
  }
}

// Singleton monitor instance
let monitorInstance: CompatibilityPerformanceMonitor | null = null;

/**
 * Get singleton performance monitor instance
 */
export function getCompatibilityPerformanceMonitor(): CompatibilityPerformanceMonitor {
  if (!monitorInstance) {
    monitorInstance = new CompatibilityPerformanceMonitor();
  }
  return monitorInstance;
}

/**
 * Quick performance tracking helper
 */
export function trackPerformance(
  operationType: PerformanceMetric['operation_type'],
  userId: string,
  metadata?: PerformanceMetric['metadata']
): PerformanceTracker {
  const monitor = getPerformanceMonitor();
  return monitor.startTracking(operationType, userId, metadata);
}