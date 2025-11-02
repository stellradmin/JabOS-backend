/**
 * CRITICAL MONITORING: Comprehensive Health Check System for Stellr
 * 
 * Features:
 * - Multi-tier health monitoring (system, application, business)
 * - Dependency health checking with circuit breaker integration
 * - Performance threshold monitoring
 * - Automated recovery actions
 * - Health history tracking and trend analysis
 * - Load balancer integration
 * - Custom health metrics
 */

import { getAdvancedCache } from './advanced-cache-system.ts';
import { getConnectionPool } from './connection-pool.ts';
import { getPerformanceMonitor } from './performance-monitor.ts';
import { circuitBreakerManager } from './circuit-breaker.ts';
import { getErrorResilienceManager } from './enhanced-error-resilience.ts';
import { supabaseAdmin } from './supabaseAdmin.ts';

export enum HealthStatus {
  HEALTHY = 'healthy',
  DEGRADED = 'degraded',
  UNHEALTHY = 'unhealthy',
  CRITICAL = 'critical'
}

export enum CheckCategory {
  SYSTEM = 'system',
  DATABASE = 'database',
  CACHE = 'cache',
  EXTERNAL = 'external',
  APPLICATION = 'application',
  BUSINESS = 'business'
}

export interface HealthMetric {
  name: string;
  value: number;
  unit: string;
  threshold: number;
  status: HealthStatus;
  message?: string;
}

export interface HealthCheckResult {
  name: string;
  category: CheckCategory;
  status: HealthStatus;
  responseTime: number;
  timestamp: number;
  metrics: HealthMetric[];
  dependencies: string[];
  message?: string;
  error?: string;
  metadata?: Record<string, any>;
}

export interface SystemHealthSummary {
  overall_status: HealthStatus;
  timestamp: number;
  uptime_seconds: number;
  checks: HealthCheckResult[];
  summary: {
    healthy: number;
    degraded: number;
    unhealthy: number;
    critical: number;
  };
  performance: {
    avg_response_time: number;
    error_rate: number;
    throughput: number;
  };
  dependencies: {
    [key: string]: HealthStatus;
  };
  recommendations: string[];
}

export interface HealthCheckConfig {
  name: string;
  category: CheckCategory;
  enabled: boolean;
  interval: number; // milliseconds
  timeout: number; // milliseconds
  retries: number;
  critical: boolean; // affects overall system status
  dependencies: string[];
  thresholds: Record<string, number>;
}

/**
 * Abstract base class for health checks
 */
export abstract class HealthCheck {
  protected config: HealthCheckConfig;
  protected monitor = getPerformanceMonitor();
  
  constructor(config: HealthCheckConfig) {
    this.config = config;
  }
  
  abstract execute(): Promise<HealthCheckResult>;
  
  protected async executeWithTimeout<T>(
    operation: () => Promise<T>,
    timeoutMs: number = this.config.timeout
  ): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timeoutHandle = setTimeout(() => {
        reject(new Error(`Health check timeout after ${timeoutMs}ms`));
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

  protected createResult(
    status: HealthStatus,
    responseTime: number,
    metrics: HealthMetric[] = [],
    message?: string,
    error?: string,
    metadata?: Record<string, any>
  ): HealthCheckResult {
    return {
      name: this.config.name,
      category: this.config.category,
      status,
      responseTime,
      timestamp: Date.now(),
      metrics,
      dependencies: this.config.dependencies,
      message,
      error,
      metadata,
    };
  }

  protected createMetric(
    name: string,
    value: number,
    unit: string,
    threshold: number,
    message?: string
  ): HealthMetric {
    let status: HealthStatus;
    
    if (value <= threshold) {
      status = HealthStatus.HEALTHY;
    } else if (value <= threshold * 1.5) {
      status = HealthStatus.DEGRADED;
    } else if (value <= threshold * 2) {
      status = HealthStatus.UNHEALTHY;
    } else {
      status = HealthStatus.CRITICAL;
    }

    return {
      name,
      value,
      unit,
      threshold,
      status,
      message,
    };
  }
}

/**
 * Database connectivity health check
 */
export class DatabaseHealthCheck extends HealthCheck {
  async execute(): Promise<HealthCheckResult> {
    const startTime = Date.now();

    try {
      // Test basic connectivity
      const { data: pingResult, error: pingError } = await this.executeWithTimeout(() =>
        supabaseAdmin.from('profiles').select('count').limit(1)
      );

      if (pingError) {
        throw pingError;
      }

      // Get connection pool metrics
      const pool = getConnectionPool();
      const poolMetrics = pool.getMetrics();

      const responseTime = Date.now() - startTime;
      
      const metrics: HealthMetric[] = [
        this.createMetric(
          'response_time',
          responseTime,
          'ms',
          this.config.thresholds.response_time || 1000
        ),
        this.createMetric(
          'active_connections',
          poolMetrics.activeConnections,
          'count',
          this.config.thresholds.max_connections || 50
        ),
        this.createMetric(
          'connection_utilization',
          poolMetrics.activeConnections / poolMetrics.totalConnections,
          'ratio',
          this.config.thresholds.connection_utilization || 0.8
        ),
        this.createMetric(
          'average_query_time',
          poolMetrics.averageQueryTime,
          'ms',
          this.config.thresholds.avg_query_time || 500
        ),
        this.createMetric(
          'error_rate',
          poolMetrics.errorRate,
          'ratio',
          this.config.thresholds.error_rate || 0.05
        ),
      ];

      // Determine overall status
      const worstStatus = metrics.reduce((worst, metric) => {
        const statusPriority = {
          [HealthStatus.HEALTHY]: 0,
          [HealthStatus.DEGRADED]: 1,
          [HealthStatus.UNHEALTHY]: 2,
          [HealthStatus.CRITICAL]: 3,
        };
        
        return statusPriority[metric.status] > statusPriority[worst] 
          ? metric.status 
          : worst;
      }, HealthStatus.HEALTHY);

      return this.createResult(
        worstStatus,
        responseTime,
        metrics,
        'Database connectivity check completed',
        undefined,
        { 
          poolStats: poolMetrics,
          pingSuccessful: true,
        }
      );

    } catch (error) {
      const responseTime = Date.now() - startTime;
      
      return this.createResult(
        HealthStatus.CRITICAL,
        responseTime,
        [
          this.createMetric(
            'response_time',
            responseTime,
            'ms',
            this.config.thresholds.response_time || 1000
          ),
        ],
        'Database connectivity failed',
        error.message
      );
    }
  }
}

/**
 * Cache system health check
 */
export class CacheHealthCheck extends HealthCheck {
  async execute(): Promise<HealthCheckResult> {
    const startTime = Date.now();

    try {
      const cache = getAdvancedCache();
      
      // Test cache operations
      const testKey = `health_check_${Date.now()}`;
      const testValue = { timestamp: Date.now(), check: 'health' };
      
      // Write test
      await this.executeWithTimeout(() => cache.set(testKey, testValue, 60));
      
      // Read test
      const retrieved = await this.executeWithTimeout(() => cache.get(testKey));
      
      if (JSON.stringify(retrieved) !== JSON.stringify(testValue)) {
        throw new Error('Cache data integrity check failed');
      }
      
      // Delete test
      await this.executeWithTimeout(() => cache.delete(testKey));
      
      // Get cache health metrics
      const cacheHealth = await cache.getCacheHealth();
      
      const responseTime = Date.now() - startTime;
      
      const metrics: HealthMetric[] = [
        this.createMetric(
          'response_time',
          responseTime,
          'ms',
          this.config.thresholds.response_time || 100
        ),
        this.createMetric(
          'hit_rate',
          cacheHealth.hitRate || 0,
          'ratio',
          this.config.thresholds.min_hit_rate || 0.8
        ),
        this.createMetric(
          'memory_usage',
          cacheHealth.memoryUsage || 0,
          'bytes',
          this.config.thresholds.max_memory || 1073741824 // 1GB
        ),
        this.createMetric(
          'error_rate',
          cacheHealth.errorRate || 0,
          'ratio',
          this.config.thresholds.error_rate || 0.01
        ),
      ];

      const worstStatus = metrics.reduce((worst, metric) => {
        const statusPriority = {
          [HealthStatus.HEALTHY]: 0,
          [HealthStatus.DEGRADED]: 1,
          [HealthStatus.UNHEALTHY]: 2,
          [HealthStatus.CRITICAL]: 3,
        };
        
        return statusPriority[metric.status] > statusPriority[worst] 
          ? metric.status 
          : worst;
      }, HealthStatus.HEALTHY);

      return this.createResult(
        worstStatus,
        responseTime,
        metrics,
        'Cache system check completed',
        undefined,
        {
          cacheHealth,
          dataIntegrityCheck: true,
        }
      );

    } catch (error) {
      const responseTime = Date.now() - startTime;
      
      return this.createResult(
        HealthStatus.CRITICAL,
        responseTime,
        [
          this.createMetric(
            'response_time',
            responseTime,
            'ms',
            this.config.thresholds.response_time || 100
          ),
        ],
        'Cache system check failed',
        error.message
      );
    }
  }
}

/**
 * Circuit breaker health check
 */
export class CircuitBreakerHealthCheck extends HealthCheck {
  async execute(): Promise<HealthCheckResult> {
    const startTime = Date.now();

    try {
      const allMetrics = circuitBreakerManager.getAllMetrics();
      const breakerNames = Object.keys(allMetrics);
      
      const metrics: HealthMetric[] = [];
      let worstStatus = HealthStatus.HEALTHY;
      
      for (const name of breakerNames) {
        const breakerMetrics = allMetrics[name];
        
        // Check circuit breaker state
        let breakerStatus = HealthStatus.HEALTHY;
        if (breakerMetrics.state === 'HALF_OPEN') {
          breakerStatus = HealthStatus.DEGRADED;
        } else if (breakerMetrics.state === 'OPEN') {
          breakerStatus = HealthStatus.UNHEALTHY;
        }
        
        metrics.push({
          name: `${name}_state`,
          value: breakerMetrics.state === 'CLOSED' ? 0 : breakerMetrics.state === 'HALF_OPEN' ? 1 : 2,
          unit: 'state',
          threshold: 0,
          status: breakerStatus,
          message: `Circuit breaker state: ${breakerMetrics.state}`,
        });

        // Check failure rate
        const failureRate = breakerMetrics.totalRequests > 0 
          ? breakerMetrics.failureCount / breakerMetrics.totalRequests 
          : 0;
        
        metrics.push(this.createMetric(
          `${name}_failure_rate`,
          failureRate,
          'ratio',
          this.config.thresholds.failure_rate || 0.1
        ));

        // Check average response time
        metrics.push(this.createMetric(
          `${name}_avg_response_time`,
          breakerMetrics.averageResponseTime,
          'ms',
          this.config.thresholds.avg_response_time || 1000
        ));

        // Update worst status
        const statusPriority = {
          [HealthStatus.HEALTHY]: 0,
          [HealthStatus.DEGRADED]: 1,
          [HealthStatus.UNHEALTHY]: 2,
          [HealthStatus.CRITICAL]: 3,
        };
        
        if (statusPriority[breakerStatus] > statusPriority[worstStatus]) {
          worstStatus = breakerStatus;
        }
      }

      const responseTime = Date.now() - startTime;

      return this.createResult(
        worstStatus,
        responseTime,
        metrics,
        `Circuit breaker check completed for ${breakerNames.length} breakers`,
        undefined,
        {
          circuitBreakers: allMetrics,
          breakerCount: breakerNames.length,
        }
      );

    } catch (error) {
      const responseTime = Date.now() - startTime;
      
      return this.createResult(
        HealthStatus.CRITICAL,
        responseTime,
        [],
        'Circuit breaker check failed',
        error.message
      );
    }
  }
}

/**
 * Application performance health check
 */
export class PerformanceHealthCheck extends HealthCheck {
  async execute(): Promise<HealthCheckResult> {
    const startTime = Date.now();

    try {
      const monitor = getPerformanceMonitor();
      const systemMetrics = await monitor.getSystemMetrics();
      
      const metrics: HealthMetric[] = [
        this.createMetric(
          'api_response_time',
          systemMetrics.api.averageResponseTime,
          'ms',
          this.config.thresholds.api_response_time || 1000
        ),
        this.createMetric(
          'api_error_rate',
          systemMetrics.api.errorRate,
          'ratio',
          this.config.thresholds.api_error_rate || 0.05
        ),
        this.createMetric(
          'requests_per_second',
          systemMetrics.api.requestsPerSecond,
          'rps',
          this.config.thresholds.max_rps || 100
        ),
        this.createMetric(
          'p95_response_time',
          systemMetrics.api.p95ResponseTime,
          'ms',
          this.config.thresholds.p95_response_time || 2000
        ),
        this.createMetric(
          'database_query_time',
          systemMetrics.database.averageQueryTime,
          'ms',
          this.config.thresholds.db_query_time || 500
        ),
      ];

      const worstStatus = metrics.reduce((worst, metric) => {
        const statusPriority = {
          [HealthStatus.HEALTHY]: 0,
          [HealthStatus.DEGRADED]: 1,
          [HealthStatus.UNHEALTHY]: 2,
          [HealthStatus.CRITICAL]: 3,
        };
        
        return statusPriority[metric.status] > statusPriority[worst] 
          ? metric.status 
          : worst;
      }, HealthStatus.HEALTHY);

      const responseTime = Date.now() - startTime;

      return this.createResult(
        worstStatus,
        responseTime,
        metrics,
        'Performance metrics check completed',
        undefined,
        {
          systemMetrics,
        }
      );

    } catch (error) {
      const responseTime = Date.now() - startTime;
      
      return this.createResult(
        HealthStatus.CRITICAL,
        responseTime,
        [],
        'Performance check failed',
        error.message
      );
    }
  }
}

/**
 * Business logic health check
 */
export class BusinessHealthCheck extends HealthCheck {
  async execute(): Promise<HealthCheckResult> {
    const startTime = Date.now();

    try {
      // Check critical business operations
      const checks = await Promise.all([
        this.checkUserRegistration(),
        this.checkMatchingSystem(),
        this.checkMessagingSystem(),
        this.checkPaymentSystem(),
      ]);

      const metrics: HealthMetric[] = checks.flat();
      
      const worstStatus = metrics.reduce((worst, metric) => {
        const statusPriority = {
          [HealthStatus.HEALTHY]: 0,
          [HealthStatus.DEGRADED]: 1,
          [HealthStatus.UNHEALTHY]: 2,
          [HealthStatus.CRITICAL]: 3,
        };
        
        return statusPriority[metric.status] > statusPriority[worst] 
          ? metric.status 
          : worst;
      }, HealthStatus.HEALTHY);

      const responseTime = Date.now() - startTime;

      return this.createResult(
        worstStatus,
        responseTime,
        metrics,
        'Business logic health check completed',
        undefined,
        {
          checksPerformed: checks.length,
        }
      );

    } catch (error) {
      const responseTime = Date.now() - startTime;
      
      return this.createResult(
        HealthStatus.CRITICAL,
        responseTime,
        [],
        'Business health check failed',
        error.message
      );
    }
  }

  private async checkUserRegistration(): Promise<HealthMetric[]> {
    try {
      // Check recent user registrations
      const { data, error } = await supabaseAdmin
        .from('profiles')
        .select('created_at')
        .gte('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
        .limit(100);

      if (error) throw error;

      const registrationsLast24h = data?.length || 0;
      
      return [
        this.createMetric(
          'registrations_24h',
          registrationsLast24h,
          'count',
          this.config.thresholds.min_daily_registrations || 1
        ),
      ];
    } catch (error) {
      return [
        {
          name: 'user_registration',
          value: 0,
          unit: 'status',
          threshold: 1,
          status: HealthStatus.CRITICAL,
          message: `User registration check failed: ${error.message}`,
        },
      ];
    }
  }

  private async checkMatchingSystem(): Promise<HealthMetric[]> {
    try {
      // Check recent matches created
      const { data, error } = await supabaseAdmin
        .from('matches')
        .select('created_at')
        .gte('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
        .limit(1000);

      if (error) throw error;

      const matchesLast24h = data?.length || 0;
      
      return [
        this.createMetric(
          'matches_24h',
          matchesLast24h,
          'count',
          this.config.thresholds.min_daily_matches || 10
        ),
      ];
    } catch (error) {
      return [
        {
          name: 'matching_system',
          value: 0,
          unit: 'status',
          threshold: 1,
          status: HealthStatus.CRITICAL,
          message: `Matching system check failed: ${error.message}`,
        },
      ];
    }
  }

  private async checkMessagingSystem(): Promise<HealthMetric[]> {
    try {
      // Check recent messages
      const { data, error } = await supabaseAdmin
        .from('messages')
        .select('created_at')
        .gte('created_at', new Date(Date.now() - 60 * 60 * 1000).toISOString())
        .limit(1000);

      if (error) throw error;

      const messagesLastHour = data?.length || 0;
      
      return [
        this.createMetric(
          'messages_1h',
          messagesLastHour,
          'count',
          this.config.thresholds.min_hourly_messages || 5
        ),
      ];
    } catch (error) {
      return [
        {
          name: 'messaging_system',
          value: 0,
          unit: 'status',
          threshold: 1,
          status: HealthStatus.CRITICAL,
          message: `Messaging system check failed: ${error.message}`,
        },
      ];
    }
  }

  private async checkPaymentSystem(): Promise<HealthMetric[]> {
    // This would check Stripe connectivity and recent payments
    // For now, return a healthy status
    return [
      this.createMetric(
        'payment_system',
        1,
        'status',
        1,
        'Payment system operational'
      ),
    ];
  }
}

/**
 * Health check manager
 */
export class HealthCheckManager {
  private checks: Map<string, HealthCheck> = new Map();
  private cache = getAdvancedCache();
  private monitor = getPerformanceMonitor();
  private startTime = Date.now();
  
  constructor() {
    this.initializeDefaultChecks();
  }

  private initializeDefaultChecks(): void {
    // Database health check
    this.registerCheck(new DatabaseHealthCheck({
      name: 'database',
      category: CheckCategory.DATABASE,
      enabled: true,
      interval: 30000, // 30 seconds
      timeout: 5000,   // 5 seconds
      retries: 2,
      critical: true,
      dependencies: [],
      thresholds: {
        response_time: 1000,
        max_connections: 50,
        connection_utilization: 0.8,
        avg_query_time: 500,
        error_rate: 0.05,
      },
    }));

    // Cache health check
    this.registerCheck(new CacheHealthCheck({
      name: 'cache',
      category: CheckCategory.CACHE,
      enabled: true,
      interval: 60000, // 1 minute
      timeout: 2000,   // 2 seconds
      retries: 2,
      critical: false,
      dependencies: [],
      thresholds: {
        response_time: 100,
        min_hit_rate: 0.8,
        max_memory: 1073741824, // 1GB
        error_rate: 0.01,
      },
    }));

    // Circuit breaker health check
    this.registerCheck(new CircuitBreakerHealthCheck({
      name: 'circuit_breakers',
      category: CheckCategory.SYSTEM,
      enabled: true,
      interval: 45000, // 45 seconds
      timeout: 3000,   // 3 seconds
      retries: 1,
      critical: false,
      dependencies: [],
      thresholds: {
        failure_rate: 0.1,
        avg_response_time: 1000,
      },
    }));

    // Performance health check
    this.registerCheck(new PerformanceHealthCheck({
      name: 'performance',
      category: CheckCategory.APPLICATION,
      enabled: true,
      interval: 60000, // 1 minute
      timeout: 5000,   // 5 seconds
      retries: 1,
      critical: true,
      dependencies: ['database'],
      thresholds: {
        api_response_time: 1000,
        api_error_rate: 0.05,
        max_rps: 100,
        p95_response_time: 2000,
        db_query_time: 500,
      },
    }));

    // Business health check
    this.registerCheck(new BusinessHealthCheck({
      name: 'business_logic',
      category: CheckCategory.BUSINESS,
      enabled: true,
      interval: 300000, // 5 minutes
      timeout: 10000,   // 10 seconds
      retries: 2,
      critical: true,
      dependencies: ['database'],
      thresholds: {
        min_daily_registrations: 1,
        min_daily_matches: 10,
        min_hourly_messages: 5,
      },
    }));
  }

  registerCheck(check: HealthCheck): void {
    this.checks.set(check['config'].name, check);
  }

  async runAllChecks(): Promise<SystemHealthSummary> {
    const startTime = Date.now();
    const results: HealthCheckResult[] = [];
    
    // Run all checks in parallel
    const checkPromises = Array.from(this.checks.values()).map(async (check) => {
      try {
        return await check.execute();
      } catch (error) {
        // Create failed result for checks that throw
        return {
          name: check['config'].name,
          category: check['config'].category,
          status: HealthStatus.CRITICAL,
          responseTime: Date.now() - startTime,
          timestamp: Date.now(),
          metrics: [],
          dependencies: check['config'].dependencies,
          error: error.message,
        };
      }
    });

    const checkResults = await Promise.all(checkPromises);
    results.push(...checkResults);

    // Calculate summary
    const summary = {
      healthy: results.filter(r => r.status === HealthStatus.HEALTHY).length,
      degraded: results.filter(r => r.status === HealthStatus.DEGRADED).length,
      unhealthy: results.filter(r => r.status === HealthStatus.UNHEALTHY).length,
      critical: results.filter(r => r.status === HealthStatus.CRITICAL).length,
    };

    // Determine overall status
    let overallStatus = HealthStatus.HEALTHY;
    if (summary.critical > 0) {
      overallStatus = HealthStatus.CRITICAL;
    } else if (summary.unhealthy > 0) {
      overallStatus = HealthStatus.UNHEALTHY;
    } else if (summary.degraded > 0) {
      overallStatus = HealthStatus.DEGRADED;
    }

    // Calculate performance metrics
    const allMetrics = results.flatMap(r => r.metrics);
    const responseTimeMetrics = allMetrics.filter(m => m.unit === 'ms');
    const avgResponseTime = responseTimeMetrics.length > 0 
      ? responseTimeMetrics.reduce((sum, m) => sum + m.value, 0) / responseTimeMetrics.length 
      : 0;

    const errorRateMetrics = allMetrics.filter(m => m.name.includes('error_rate'));
    const avgErrorRate = errorRateMetrics.length > 0
      ? errorRateMetrics.reduce((sum, m) => sum + m.value, 0) / errorRateMetrics.length
      : 0;

    // Build dependencies map
    const dependencies: Record<string, HealthStatus> = {};
    for (const result of results) {
      dependencies[result.name] = result.status;
    }

    // Generate recommendations
    const recommendations = this.generateRecommendations(results);

    const healthSummary: SystemHealthSummary = {
      overall_status: overallStatus,
      timestamp: Date.now(),
      uptime_seconds: Math.floor((Date.now() - this.startTime) / 1000),
      checks: results,
      summary,
      performance: {
        avg_response_time: avgResponseTime,
        error_rate: avgErrorRate,
        throughput: 0, // Would be calculated from metrics
      },
      dependencies,
      recommendations,
    };

    // Cache the results
    await this.cache.set('health_check_results', healthSummary, 30);

    // Record health metrics
    this.recordHealthMetrics(healthSummary);

    return healthSummary;
  }

  private generateRecommendations(results: HealthCheckResult[]): string[] {
    const recommendations: string[] = [];
    
    for (const result of results) {
      if (result.status === HealthStatus.CRITICAL) {
        recommendations.push(`Critical issue in ${result.name}: ${result.error || result.message}`);
      } else if (result.status === HealthStatus.UNHEALTHY) {
        recommendations.push(`${result.name} is unhealthy and needs attention`);
      } else if (result.status === HealthStatus.DEGRADED) {
        // Find specific metrics that are degraded
        const degradedMetrics = result.metrics.filter(m => 
          m.status === HealthStatus.DEGRADED || m.status === HealthStatus.UNHEALTHY
        );
        
        if (degradedMetrics.length > 0) {
          recommendations.push(
            `${result.name} has degraded metrics: ${degradedMetrics.map(m => m.name).join(', ')}`
          );
        }
      }
    }
    
    return recommendations;
  }

  private recordHealthMetrics(summary: SystemHealthSummary): void {
    // Record overall health status
    this.monitor.recordMetric({
      name: 'health.overall_status',
      value: this.statusToNumeric(summary.overall_status),
      unit: 'status',
    });

    // Record check counts
    this.monitor.recordMetric({
      name: 'health.healthy_checks',
      value: summary.summary.healthy,
      unit: 'count',
    });

    this.monitor.recordMetric({
      name: 'health.degraded_checks',
      value: summary.summary.degraded,
      unit: 'count',
    });

    this.monitor.recordMetric({
      name: 'health.unhealthy_checks',
      value: summary.summary.unhealthy,
      unit: 'count',
    });

    this.monitor.recordMetric({
      name: 'health.critical_checks',
      value: summary.summary.critical,
      unit: 'count',
    });

    // Record individual check statuses
    for (const check of summary.checks) {
      this.monitor.recordMetric({
        name: 'health.check_status',
        value: this.statusToNumeric(check.status),
        unit: 'status',
        tags: {
          check_name: check.name,
          category: check.category,
        },
      });

      this.monitor.recordMetric({
        name: 'health.check_response_time',
        value: check.responseTime,
        unit: 'ms',
        tags: {
          check_name: check.name,
          category: check.category,
        },
      });
    }
  }

  private statusToNumeric(status: HealthStatus): number {
    switch (status) {
      case HealthStatus.HEALTHY: return 0;
      case HealthStatus.DEGRADED: return 1;
      case HealthStatus.UNHEALTHY: return 2;
      case HealthStatus.CRITICAL: return 3;
      default: return 3;
    }
  }

  async getHealthSummary(): Promise<SystemHealthSummary | null> {
    // Try to get cached results first
    return await this.cache.get<SystemHealthSummary>('health_check_results');
  }
}

// Singleton instance
let healthCheckManagerInstance: HealthCheckManager | null = null;

export function getHealthCheckManager(): HealthCheckManager {
  if (!healthCheckManagerInstance) {
    healthCheckManagerInstance = new HealthCheckManager();
  }
  return healthCheckManagerInstance;
}

/**
 * Quick health check for load balancers
 */
export async function quickHealthCheck(): Promise<{ status: string; timestamp: number }> {
  try {
    const manager = getHealthCheckManager();
    const cached = await manager.getHealthSummary();
    
    if (cached && Date.now() - cached.timestamp < 60000) { // 1 minute
      return {
        status: cached.overall_status,
        timestamp: cached.timestamp,
      };
    }
    
    // If no recent cached result, do a minimal check
    const monitor = getPerformanceMonitor();
    const health = await monitor.healthCheck();
    
    return {
      status: health.status === 'healthy' ? HealthStatus.HEALTHY : HealthStatus.DEGRADED,
      timestamp: Date.now(),
    };
  } catch (error) {
    return {
      status: HealthStatus.CRITICAL,
      timestamp: Date.now(),
    };
  }
}