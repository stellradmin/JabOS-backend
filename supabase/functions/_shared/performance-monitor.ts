/**
 * Performance Monitoring and Metrics Collection System for Stellr
 * 
 * Features:
 * - Real-time performance tracking
 * - Database query monitoring
 * - Cache performance metrics
 * - API response time tracking
 * - Error rate monitoring
 * - Resource utilization tracking
 * - Custom metrics and alerts
 * - Performance anomaly detection
 * 
 * Integrations:
 * - Supabase Analytics
 * - Redis metrics
 * - Custom alerting system
 * - Performance dashboards
 */

import { getAdvancedCache } from './advanced-cache-system.ts';
import { getConnectionPool } from './connection-pool.ts';

export interface PerformanceMetric {
  name: string;
  value: number;
  unit: string;
  timestamp: number;
  tags?: Record<string, string>;
  metadata?: Record<string, any>;
}

export interface RequestMetrics {
  requestId: string;
  endpoint: string;
  method: string;
  userId?: string;
  startTime: number;
  endTime?: number;
  duration?: number;
  status?: number;
  responseSize?: number;
  fromCache?: boolean;
  dbQueries?: number;
  dbQueryTime?: number;
  error?: string;
  userAgent?: string;
  ip?: string;
}

export interface SystemMetrics {
  timestamp: number;
  memory: {
    used: number;
    available: number;
    percentage: number;
  };
  cpu: {
    usage: number;
    cores: number;
  };
  database: {
    activeConnections: number;
    totalConnections: number;
    averageQueryTime: number;
    errorRate: number;
  };
  cache: {
    hitRate: number;
    memory: number;
    operations: number;
    errors: number;
  };
  api: {
    requestsPerSecond: number;
    averageResponseTime: number;
    errorRate: number;
    p95ResponseTime: number;
    p99ResponseTime: number;
  };
}

export interface Alert {
  id: string;
  name: string;
  level: 'info' | 'warning' | 'error' | 'critical';
  message: string;
  metric: string;
  threshold: number;
  currentValue: number;
  timestamp: number;
  resolved?: boolean;
  resolvedAt?: number;
}

export interface MonitorConfig {
  enableRealTimeTracking: boolean;
  enableDatabaseMonitoring: boolean;
  enableCacheMonitoring: boolean;
  enableApiMonitoring: boolean;
  enableResourceMonitoring: boolean;
  enableAnomalyDetection: boolean;
  metricsRetentionDays: number;
  alertThresholds: Record<string, number>;
  samplingRate: number; // 0-1, percentage of requests to track
}

class PerformanceMonitor {
  private config: MonitorConfig;
  private metrics: Map<string, PerformanceMetric[]> = new Map();
  private requestMetrics: Map<string, RequestMetrics> = new Map();
  private systemMetrics: SystemMetrics[] = [];
  private activeAlerts: Map<string, Alert> = new Map();

  // DENO FIX: Lazy initialization to prevent cascading constructor calls during bundling
  private _cache: any = null;
  private get cache() {
    if (!this._cache) {
      this._cache = getAdvancedCache();
    }
    return this._cache;
  }

  private _db: any = null;
  private get db() {
    if (!this._db) {
      this._db = getConnectionPool();
    }
    return this._db;
  }
  
  // Performance tracking
  private responseTimeBuckets: number[] = [];
  private errorRateWindow: boolean[] = [];
  private requestsPerSecond: number = 0;
  private lastRequestCountReset: number = Date.now();
  private requestCount: number = 0;

  // Intervals
  private metricsCollectionInterval: number | null = null;
  private alertCheckInterval: number | null = null;
  private cleanupInterval: number | null = null;

  constructor(config: Partial<MonitorConfig> = {}) {
    this.config = {
      enableRealTimeTracking: true,
      enableDatabaseMonitoring: true,
      enableCacheMonitoring: true,
      enableApiMonitoring: true,
      enableResourceMonitoring: true,
      enableAnomalyDetection: true,
      metricsRetentionDays: 7,
      samplingRate: 1.0, // Track all requests initially
      alertThresholds: {
        'api.response_time.p95': 1000, // 1 second
        'api.error_rate': 0.05, // 5%
        'database.query_time.avg': 500, // 500ms
        'cache.hit_rate': 0.8, // 80%
        'memory.usage': 0.9, // 90%
        'database.error_rate': 0.02, // 2%
      },
      ...config
    };

    // Defer initialization to prevent BOOT_ERROR in Edge Functions
    // this.initialize();
  }

  private async initialize(): Promise<void> {
    // DENO FIX: Comment out timer-based initialization to prevent bundling crash
    // setInterval is forbidden during module initialization in Deno Edge Functions
    // if (this.config.enableRealTimeTracking) {
    //   this.startMetricsCollection();
    //   this.startAlertMonitoring();
    //   this.startCleanup();
    // }

    // Debug logging removed for security
}

  /**
   * Start tracking a request
   */
  startRequest(requestInfo: {
    requestId: string;
    endpoint: string;
    method: string;
    userId?: string;
    userAgent?: string;
    ip?: string;
  }): void {
    if (Math.random() > this.config.samplingRate) {
      return; // Skip tracking based on sampling rate
    }

    const metrics: RequestMetrics = {
      ...requestInfo,
      startTime: Date.now()
    };

    this.requestMetrics.set(requestInfo.requestId, metrics);
    this.requestCount++;
  }

  /**
   * End tracking a request
   */
  endRequest(requestId: string, outcome: {
    status: number;
    responseSize?: number;
    fromCache?: boolean;
    dbQueries?: number;
    dbQueryTime?: number;
    error?: string;
  }): void {
    const metrics = this.requestMetrics.get(requestId);
    
    if (!metrics) {
      return; // Not tracking this request
    }

    metrics.endTime = Date.now();
    metrics.duration = metrics.endTime - metrics.startTime;
    metrics.status = outcome.status;
    metrics.responseSize = outcome.responseSize;
    metrics.fromCache = outcome.fromCache;
    metrics.dbQueries = outcome.dbQueries;
    metrics.dbQueryTime = outcome.dbQueryTime;
    metrics.error = outcome.error;

    // Store completed metrics
    this.storeRequestMetrics(metrics);
    
    // Update real-time tracking
    this.updateRealTimeMetrics(metrics);
    
    // Clean up active tracking
    this.requestMetrics.delete(requestId);
  }

  /**
   * Record a custom metric
   */
  recordMetric(metric: Omit<PerformanceMetric, 'timestamp'>): void {
    const fullMetric: PerformanceMetric = {
      ...metric,
      timestamp: Date.now()
    };

    const existing = this.metrics.get(metric.name) || [];
    existing.push(fullMetric);
    
    // Keep only recent metrics
    const cutoff = Date.now() - (this.config.metricsRetentionDays * 24 * 60 * 60 * 1000);
    const filtered = existing.filter(m => m.timestamp > cutoff);
    
    this.metrics.set(metric.name, filtered);

    // Check for alerts
    this.checkMetricAlert(fullMetric);
  }

  /**
   * Track database query performance
   */
  trackDatabaseQuery(queryInfo: {
    queryId: string;
    operation: string;
    table?: string;
    duration: number;
    success: boolean;
    error?: string;
  }): void {
    if (!this.config.enableDatabaseMonitoring) return;

    this.recordMetric({
      name: 'database.query_time',
      value: queryInfo.duration,
      unit: 'ms',
      tags: {
        operation: queryInfo.operation,
        table: queryInfo.table || 'unknown',
        success: queryInfo.success.toString()
      },
      metadata: {
        queryId: queryInfo.queryId,
        error: queryInfo.error
      }
    });

    if (!queryInfo.success) {
      this.recordMetric({
        name: 'database.error',
        value: 1,
        unit: 'count',
        tags: {
          operation: queryInfo.operation,
          table: queryInfo.table || 'unknown'
        },
        metadata: {
          error: queryInfo.error
        }
      });
    }
  }

  /**
   * Track cache performance
   */
  trackCacheOperation(operation: {
    type: 'hit' | 'miss' | 'set' | 'error';
    key: string;
    duration: number;
    size?: number;
  }): void {
    if (!this.config.enableCacheMonitoring) return;

    this.recordMetric({
      name: `cache.${operation.type}`,
      value: operation.duration,
      unit: 'ms',
      tags: {
        operation: operation.type
      },
      metadata: {
        key: operation.key,
        size: operation.size
      }
    });
  }

  /**
   * Get current system metrics
   */
  async getSystemMetrics(): Promise<SystemMetrics> {
    const now = Date.now();
    
    // Get database metrics
    const dbMetrics = this.db.getMetrics();
    
    // Get cache metrics
    const cacheHealth = await this.cache.getCacheHealth();
    
    // Calculate API metrics
    const apiMetrics = this.calculateApiMetrics();
    
    const systemMetrics: SystemMetrics = {
      timestamp: now,
      memory: {
        used: 0, // Would be populated with actual memory usage
        available: 0,
        percentage: 0
      },
      cpu: {
        usage: 0,
        cores: 1
      },
      database: {
        activeConnections: dbMetrics.activeConnections,
        totalConnections: dbMetrics.totalConnections,
        averageQueryTime: dbMetrics.averageQueryTime,
        errorRate: dbMetrics.errorRate
      },
      cache: {
        hitRate: 0, // Would be calculated from cache metrics
        memory: 0,
        operations: 0,
        errors: 0
      },
      api: apiMetrics
    };

    this.systemMetrics.push(systemMetrics);
    
    // Keep only recent metrics
    this.systemMetrics = this.systemMetrics.slice(-1000);
    
    return systemMetrics;
  }

  /**
   * Get performance metrics for a specific metric name
   */
  getMetrics(metricName: string, timeRange?: { start: number; end: number }): PerformanceMetric[] {
    const metrics = this.metrics.get(metricName) || [];
    
    if (!timeRange) {
      return metrics;
    }
    
    return metrics.filter(m => 
      m.timestamp >= timeRange.start && m.timestamp <= timeRange.end
    );
  }

  /**
   * Get aggregated metrics for dashboards
   */
  getAggregatedMetrics(timeRange: { start: number; end: number }): Record<string, any> {
    const aggregated: Record<string, any> = {};
    
    for (const [metricName, metrics] of this.metrics.entries()) {
      const filteredMetrics = metrics.filter(m => 
        m.timestamp >= timeRange.start && m.timestamp <= timeRange.end
      );
      
      if (filteredMetrics.length === 0) continue;
      
      const values = filteredMetrics.map(m => m.value);
      
      aggregated[metricName] = {
        count: values.length,
        avg: values.reduce((sum, v) => sum + v, 0) / values.length,
        min: Math.min(...values),
        max: Math.max(...values),
        p50: this.percentile(values, 0.5),
        p95: this.percentile(values, 0.95),
        p99: this.percentile(values, 0.99)
      };
    }
    
    return aggregated;
  }

  /**
   * Get current alerts
   */
  getActiveAlerts(): Alert[] {
    return Array.from(this.activeAlerts.values())
      .filter(alert => !alert.resolved);
  }

  /**
   * Resolve an alert
   */
  resolveAlert(alertId: string): boolean {
    const alert = this.activeAlerts.get(alertId);
    
    if (alert && !alert.resolved) {
      alert.resolved = true;
      alert.resolvedAt = Date.now();
      return true;
    }
    
    return false;
  }

  /**
   * Health check for monitoring system
   */
  async healthCheck(): Promise<{ status: string; details: any }> {
    try {
      const metrics = await this.getSystemMetrics();
      const activeAlerts = this.getActiveAlerts();
      const criticalAlerts = activeAlerts.filter(a => a.level === 'critical');
      
      const status = criticalAlerts.length > 0 ? 'degraded' : 'healthy';
      
      return {
        status,
        details: {
          metricsCollected: this.metrics.size,
          activeRequests: this.requestMetrics.size,
          activeAlerts: activeAlerts.length,
          criticalAlerts: criticalAlerts.length,
          systemMetrics: {
            apiResponseTime: metrics.api.averageResponseTime,
            dbQueryTime: metrics.database.averageQueryTime,
            errorRate: metrics.api.errorRate
          }
        }
      };
    } catch (error) {
      return {
        status: 'unhealthy',
        details: { error: error.message }
      };
    }
  }

  // Private methods
  private storeRequestMetrics(metrics: RequestMetrics): void {
    // In production, would store to database or external service
    // For now, just track in memory for real-time metrics
  }

  private updateRealTimeMetrics(metrics: RequestMetrics): void {
    // Update response time buckets
    if (metrics.duration) {
      this.responseTimeBuckets.push(metrics.duration);
      if (this.responseTimeBuckets.length > 1000) {
        this.responseTimeBuckets = this.responseTimeBuckets.slice(-500);
      }
    }

    // Update error rate window
    this.errorRateWindow.push(metrics.status !== undefined && metrics.status >= 400);
    if (this.errorRateWindow.length > 100) {
      this.errorRateWindow = this.errorRateWindow.slice(-50);
    }
  }

  private calculateApiMetrics(): SystemMetrics['api'] {
    // Calculate requests per second
    const now = Date.now();
    const timeSinceReset = now - this.lastRequestCountReset;
    
    if (timeSinceReset >= 1000) { // Reset every second
      this.requestsPerSecond = this.requestCount / (timeSinceReset / 1000);
      this.requestCount = 0;
      this.lastRequestCountReset = now;
    }

    // Calculate response time percentiles
    const responseTimes = this.responseTimeBuckets.slice().sort((a, b) => a - b);
    const avgResponseTime = responseTimes.length > 0 ? 
      responseTimes.reduce((sum, time) => sum + time, 0) / responseTimes.length : 0;
    
    const p95ResponseTime = responseTimes.length > 0 ? 
      this.percentile(responseTimes, 0.95) : 0;
    
    const p99ResponseTime = responseTimes.length > 0 ? 
      this.percentile(responseTimes, 0.99) : 0;

    // Calculate error rate
    const errorRate = this.errorRateWindow.length > 0 ? 
      this.errorRateWindow.filter(isError => isError).length / this.errorRateWindow.length : 0;

    return {
      requestsPerSecond: this.requestsPerSecond,
      averageResponseTime: avgResponseTime,
      errorRate,
      p95ResponseTime,
      p99ResponseTime
    };
  }

  private percentile(values: number[], p: number): number {
    if (values.length === 0) return 0;
    
    const sorted = values.slice().sort((a, b) => a - b);
    const index = Math.ceil(sorted.length * p) - 1;
    return sorted[Math.max(0, index)];
  }

  private checkMetricAlert(metric: PerformanceMetric): void {
    const threshold = this.config.alertThresholds[metric.name];
    
    if (threshold === undefined) return;
    
    const shouldAlert = metric.value > threshold;
    const alertId = `${metric.name}_threshold`;
    const existingAlert = this.activeAlerts.get(alertId);

    if (shouldAlert && !existingAlert) {
      // Create new alert
      const alert: Alert = {
        id: alertId,
        name: `${metric.name} threshold exceeded`,
        level: this.getAlertLevel(metric.name, metric.value, threshold),
        message: `${metric.name} is ${metric.value}${metric.unit}, exceeding threshold of ${threshold}${metric.unit}`,
        metric: metric.name,
        threshold,
        currentValue: metric.value,
        timestamp: Date.now()
      };

      this.activeAlerts.set(alertId, alert);
} else if (!shouldAlert && existingAlert && !existingAlert.resolved) {
      // Resolve alert
      this.resolveAlert(alertId);
      // Debug logging removed for security
}
  }

  private getAlertLevel(metricName: string, value: number, threshold: number): Alert['level'] {
    const ratio = value / threshold;
    
    if (ratio > 2) return 'critical';
    if (ratio > 1.5) return 'error';
    if (ratio > 1.2) return 'warning';
    return 'info';
  }

  private startMetricsCollection(): void {
    this.metricsCollectionInterval = setInterval(async () => {
      await this.getSystemMetrics();
    }, 60000); // Collect every minute
  }

  private startAlertMonitoring(): void {
    this.alertCheckInterval = setInterval(() => {
      // Check for system-level alerts
      this.checkSystemAlerts();
    }, 30000); // Check every 30 seconds
  }

  private startCleanup(): void {
    this.cleanupInterval = setInterval(() => {
      this.cleanupOldMetrics();
    }, 3600000); // Cleanup every hour
  }

  private checkSystemAlerts(): void {
    // Check database connection health
    const dbMetrics = this.db.getMetrics();
    
    if (dbMetrics.errorRate > this.config.alertThresholds['database.error_rate']) {
      this.recordMetric({
        name: 'database.error_rate',
        value: dbMetrics.errorRate,
        unit: 'percentage'
      });
    }

    // Check average query time
    if (dbMetrics.averageQueryTime > this.config.alertThresholds['database.query_time.avg']) {
      this.recordMetric({
        name: 'database.query_time.avg',
        value: dbMetrics.averageQueryTime,
        unit: 'ms'
      });
    }
  }

  private cleanupOldMetrics(): void {
    const cutoff = Date.now() - (this.config.metricsRetentionDays * 24 * 60 * 60 * 1000);
    
    for (const [metricName, metrics] of this.metrics.entries()) {
      const filtered = metrics.filter(m => m.timestamp > cutoff);
      
      if (filtered.length === 0) {
        this.metrics.delete(metricName);
      } else {
        this.metrics.set(metricName, filtered);
      }
    }

    // Clean up old system metrics
    this.systemMetrics = this.systemMetrics.filter(m => m.timestamp > cutoff);
    
    // Clean up resolved alerts older than 24 hours
    const alertCutoff = Date.now() - (24 * 60 * 60 * 1000);
    for (const [alertId, alert] of this.activeAlerts.entries()) {
      if (alert.resolved && alert.resolvedAt && alert.resolvedAt < alertCutoff) {
        this.activeAlerts.delete(alertId);
      }
    }
  }

  /**
   * Shutdown monitoring system
   */
  shutdown(): void {
    if (this.metricsCollectionInterval) {
      clearInterval(this.metricsCollectionInterval);
    }
    
    if (this.alertCheckInterval) {
      clearInterval(this.alertCheckInterval);
    }
    
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
    }
    
    // Debug logging removed for security
}
}

// Singleton instance
let monitorInstance: PerformanceMonitor | null = null;

export function getPerformanceMonitor(): PerformanceMonitor {
  if (!monitorInstance) {
    monitorInstance = new PerformanceMonitor();
  }
  return monitorInstance;
}

// Convenience functions for common monitoring patterns
export const MonitoringHelpers = {
  // Track API endpoint performance
  trackEndpoint: (requestId: string, endpoint: string, method: string, userId?: string) => {
    const monitor = getPerformanceMonitor();
    monitor.startRequest({ requestId, endpoint, method, userId });
    
    return {
      end: (status: number, options: { responseSize?: number; fromCache?: boolean } = {}) => {
        monitor.endRequest(requestId, { status, ...options });
      }
    };
  },

  // Track database operation
  trackDatabase: (operation: string, table: string) => {
    const startTime = Date.now();
    
    return {
      end: (success: boolean, error?: string) => {
        const monitor = getPerformanceMonitor();
        monitor.trackDatabaseQuery({
          queryId: `${operation}_${Date.now()}`,
          operation,
          table,
          duration: Date.now() - startTime,
          success,
          error
        });
      }
    };
  },

  // Track cache operation
  trackCache: (operation: 'hit' | 'miss' | 'set' | 'error', key: string) => {
    const startTime = Date.now();
    
    return {
      end: (size?: number) => {
        const monitor = getPerformanceMonitor();
        monitor.trackCacheOperation({
          type: operation,
          key,
          duration: Date.now() - startTime,
          size
        });
      }
    };
  }
};

export { PerformanceMonitor };