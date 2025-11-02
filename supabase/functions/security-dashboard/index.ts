/**
 * STELLR REAL-TIME SECURITY DASHBOARD API
 * 
 * Enterprise-grade security monitoring dashboard following 10 Golden Code Principles
 * 
 * Features:
 * - Real-time security metrics and threat analysis
 * - Admin-only access with proper authentication
 * - Live threat detection and incident response status
 * - Performance optimized with intelligent caching
 * - Comprehensive error handling and logging
 * 
 * @fileoverview Security dashboard edge function for Stellr production
 * @version 1.0.0
 * @author Stellr Security Team
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

// Security headers for dashboard endpoint
const securityHeaders = {
  ...corsHeaders,
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'X-XSS-Protection': '1; mode=block',
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  'Content-Security-Policy': "default-src 'none'; script-src 'none'; object-src 'none'",
  'Referrer-Policy': 'no-referrer'
};
import { logSecurityEvent, SecurityEventType, SecuritySeverity } from '../_shared/security-monitoring.ts';
import { getPerformanceMonitor } from '../_shared/performance-monitor.ts';

/**
 * SecurityDashboardError - Custom error for dashboard operations
 * Principle 6: Fail Fast & Defensive - Custom error types for clear failure handling
 */
class SecurityDashboardError extends Error {
  constructor(message: string, public code: string, public statusCode: number = 500) {
    super(message);
    this.name = 'SecurityDashboardError';
  }
}

/**
 * AdminAuthenticator - Handles admin authentication and authorization
 * Principle 1: Single Responsibility - Dedicated authentication service
 * Principle 10: Security by Design - Security-first authentication
 */
class AdminAuthenticator {
  constructor(private supabase: any) {}

  /**
   * Authenticate and authorize admin user
   * Principle 6: Fail Fast & Defensive - Early authentication validation
   */
  async authenticateAdmin(authHeader: string | null): Promise<{ user: any; profile: any }> {
    if (!authHeader) {
      throw new SecurityDashboardError(
        'Missing authorization header',
        'MISSING_AUTH',
        401
      );
    }

    const token = authHeader.replace('Bearer ', '');
    if (!token) {
      throw new SecurityDashboardError(
        'Invalid authorization format',
        'INVALID_AUTH_FORMAT',
        401
      );
    }

    // Verify JWT token
    const { data: { user }, error: authError } = await this.supabase.auth.getUser(token);
    
    if (authError || !user) {
      await this.logSecurityViolation('UNAUTHORIZED_DASHBOARD_ACCESS', {
        error: authError?.message || 'Invalid token',
        token_preview: token.substring(0, 20) + '...'
      });
      
      throw new SecurityDashboardError(
        'Invalid or expired token',
        'INVALID_TOKEN',
        401
      );
    }

    // Check admin privileges
    const { data: profile, error: profileError } = await this.supabase
      .from('profiles')
      .select('id, is_admin, email, full_name')
      .eq('id', user.id)
      .single();

    if (profileError) {
      throw new SecurityDashboardError(
        'Failed to fetch user profile',
        'PROFILE_ERROR',
        500
      );
    }

    if (!profile?.is_admin) {
      await this.logSecurityViolation('DASHBOARD_ACCESS_DENIED', {
        user_id: user.id,
        email: profile?.email,
        is_admin: profile?.is_admin
      });
      
      throw new SecurityDashboardError(
        'Admin privileges required',
        'INSUFFICIENT_PRIVILEGES',
        403
      );
    }

    return { user, profile };
  }

  /**
   * Log security violation attempt
   * Principle 10: Security by Design - Log all security violations
   */
  private async logSecurityViolation(eventType: string, details: any): Promise<void> {
    try {
      await logSecurityEvent(
        SecurityEventType.UNAUTHORIZED_ACCESS,
        SecuritySeverity.HIGH,
        { 
          violation_type: eventType,
          ...details 
        },
        {
          endpoint: '/security-dashboard',
          method: 'GET'
        }
      );
    } catch (error) {
      console.error('Failed to log security violation:', error);
    }
  }
}

/**
 * SecurityMetricsService - Provides comprehensive security metrics
 * Principle 1: Single Responsibility - Dedicated metrics service
 * Principle 3: Small, Focused Functions - Each metric type has dedicated function
 */
class SecurityMetricsService {
  constructor(private supabase: any, private performanceMonitor: any) {}

  /**
   * Get comprehensive security dashboard data
   * Principle 8: Command Query Separation - Pure query function
   */
  async getDashboardMetrics(): Promise<any> {
    const startTime = Date.now();
    
    try {
      const [
        liveMetrics,
        threatMetrics,
        blockedIPsMetrics,
        alertMetrics,
        userActivityMetrics,
        systemHealth
      ] = await Promise.all([
        this.getLiveSecurityMetrics(),
        this.getThreatAnalysis(),
        this.getBlockedIPsMetrics(),
        this.getSecurityAlerts(),
        this.getUserActivityMetrics(),
        this.getSystemHealthMetrics()
      ]);

      const processingTime = Date.now() - startTime;

      // Record performance metric
      this.performanceMonitor.recordMetric({
        name: 'security.dashboard.response_time',
        value: processingTime,
        unit: 'milliseconds',
        tags: { endpoint: 'security-dashboard' }
      });

      return {
        status: 'active',
        generated_at: new Date().toISOString(),
        processing_time_ms: processingTime,
        data: {
          live_metrics: liveMetrics,
          threat_analysis: threatMetrics,
          blocked_ips: blockedIPsMetrics,
          security_alerts: alertMetrics,
          user_activity: userActivityMetrics,
          system_health: systemHealth
        }
      };

    } catch (error) {
      const processingTime = Date.now() - startTime;
      
      this.performanceMonitor.recordMetric({
        name: 'security.dashboard.error_rate',
        value: 1,
        unit: 'count',
        tags: { endpoint: 'security-dashboard', error: error.message }
      });

      throw new SecurityDashboardError(
        'Failed to collect dashboard metrics',
        'METRICS_COLLECTION_ERROR',
        500
      );
    }
  }

  /**
   * Get live security metrics for real-time monitoring
   * Principle 3: Small, Focused Functions - Live metrics only
   */
  private async getLiveSecurityMetrics(): Promise<any> {
    const { data, error } = await this.supabase
      .rpc('exec', {
        sql: `
          WITH time_ranges AS (
            SELECT 
              NOW() - INTERVAL '5 minutes' as last_5min,
              NOW() - INTERVAL '1 hour' as last_hour,
              NOW() - INTERVAL '24 hours' as last_24hr
          ),
          event_counts AS (
            SELECT 
              COUNT(*) FILTER (WHERE timestamp > (SELECT last_5min FROM time_ranges)) as events_5min,
              COUNT(*) FILTER (WHERE timestamp > (SELECT last_hour FROM time_ranges)) as events_1hr,
              COUNT(*) FILTER (WHERE timestamp > (SELECT last_24hr FROM time_ranges)) as events_24hr,
              COUNT(*) FILTER (WHERE severity = 'critical' AND timestamp > (SELECT last_24hr FROM time_ranges)) as critical_24hr,
              COUNT(*) FILTER (WHERE severity = 'high' AND timestamp > (SELECT last_24hr FROM time_ranges)) as high_24hr,
              COUNT(*) FILTER (WHERE blocked = true AND timestamp > (SELECT last_24hr FROM time_ranges)) as blocked_24hr,
              AVG(threat_score) FILTER (WHERE timestamp > (SELECT last_24hr FROM time_ranges))::DECIMAL(5,2) as avg_threat_score_24hr,
              MAX(threat_score) FILTER (WHERE timestamp > (SELECT last_24hr FROM time_ranges)) as max_threat_score_24hr
            FROM security_events
          )
          SELECT 
            events_5min,
            events_1hr,
            events_24hr,
            critical_24hr,
            high_24hr,
            blocked_24hr,
            COALESCE(avg_threat_score_24hr, 0) as avg_threat_score_24hr,
            COALESCE(max_threat_score_24hr, 0) as max_threat_score_24hr,
            CASE 
              WHEN events_5min > 100 THEN 'critical'
              WHEN events_5min > 50 THEN 'high'
              WHEN events_5min > 20 THEN 'medium'
              ELSE 'normal'
            END as activity_level
          FROM event_counts;
        `
      });

    if (error) {
      throw error;
    }

    return data?.[0] || {
      events_5min: 0,
      events_1hr: 0,
      events_24hr: 0,
      critical_24hr: 0,
      high_24hr: 0,
      blocked_24hr: 0,
      avg_threat_score_24hr: 0,
      max_threat_score_24hr: 0,
      activity_level: 'normal'
    };
  }

  /**
   * Get comprehensive threat analysis
   * Principle 3: Small, Focused Functions - Threat analysis only
   */
  private async getThreatAnalysis(): Promise<any> {
    const { data, error } = await this.supabase
      .rpc('exec', {
        sql: `
          WITH threat_summary AS (
            SELECT 
              event_type,
              COUNT(*) as count,
              AVG(threat_score)::DECIMAL(5,2) as avg_score,
              MAX(threat_score) as max_score,
              COUNT(*) FILTER (WHERE blocked = true) as blocked_count,
              MAX(timestamp) as last_occurrence
            FROM security_events 
            WHERE timestamp > NOW() - INTERVAL '24 hours'
            GROUP BY event_type 
            HAVING COUNT(*) > 0
            ORDER BY count DESC, max_score DESC
            LIMIT 10
          ),
          hourly_trends AS (
            SELECT 
              date_trunc('hour', timestamp) as hour,
              COUNT(*) as events_count,
              AVG(threat_score)::DECIMAL(5,2) as avg_threat_score
            FROM security_events 
            WHERE timestamp > NOW() - INTERVAL '24 hours'
            GROUP BY date_trunc('hour', timestamp)
            ORDER BY hour DESC
            LIMIT 24
          ),
          top_sources AS (
            SELECT 
              COALESCE(ip_address::text, 'unknown') as source,
              COUNT(*) as event_count,
              MAX(threat_score) as max_threat_score,
              array_agg(DISTINCT event_type) as event_types
            FROM security_events 
            WHERE timestamp > NOW() - INTERVAL '24 hours'
              AND ip_address IS NOT NULL
            GROUP BY ip_address
            ORDER BY event_count DESC, max_threat_score DESC
            LIMIT 10
          )
          SELECT 
            json_build_object(
              'top_threats', (SELECT json_agg(row_to_json(threat_summary)) FROM threat_summary),
              'hourly_trends', (SELECT json_agg(row_to_json(hourly_trends)) FROM hourly_trends),
              'top_sources', (SELECT json_agg(row_to_json(top_sources)) FROM top_sources)
            ) as analysis;
        `
      });

    if (error) {
      throw error;
    }

    return data?.[0]?.analysis || {
      top_threats: [],
      hourly_trends: [],
      top_sources: []
    };
  }

  /**
   * Get blocked IPs metrics and management data
   * Principle 3: Small, Focused Functions - IP blocking metrics only
   */
  private async getBlockedIPsMetrics(): Promise<any> {
    const { data, error } = await this.supabase
      .rpc('exec', {
        sql: `
          WITH blocked_stats AS (
            SELECT 
              COUNT(*) as total_blocked,
              COUNT(*) FILTER (WHERE blocked_until IS NULL OR blocked_until > NOW()) as currently_blocked,
              COUNT(*) FILTER (WHERE blocked_at > NOW() - INTERVAL '24 hours') as blocked_today,
              COUNT(*) FILTER (WHERE threat_score >= 90) as high_threat_ips,
              AVG(threat_score)::DECIMAL(5,2) as avg_threat_score
            FROM blocked_ips
          ),
          recent_blocks AS (
            SELECT 
              ip_address,
              threat_score,
              reasons,
              blocked_at,
              blocked_until,
              notes
            FROM blocked_ips 
            WHERE blocked_at > NOW() - INTERVAL '24 hours'
            ORDER BY blocked_at DESC
            LIMIT 20
          ),
          top_reasons AS (
            SELECT 
              unnest(reasons) as reason,
              COUNT(*) as count
            FROM blocked_ips 
            WHERE blocked_at > NOW() - INTERVAL '7 days'
            GROUP BY unnest(reasons)
            ORDER BY count DESC
            LIMIT 10
          )
          SELECT 
            json_build_object(
              'stats', (SELECT row_to_json(blocked_stats) FROM blocked_stats),
              'recent_blocks', (SELECT json_agg(row_to_json(recent_blocks)) FROM recent_blocks),
              'top_reasons', (SELECT json_agg(row_to_json(top_reasons)) FROM top_reasons)
            ) as metrics;
        `
      });

    if (error) {
      throw error;
    }

    return data?.[0]?.metrics || {
      stats: {
        total_blocked: 0,
        currently_blocked: 0,
        blocked_today: 0,
        high_threat_ips: 0,
        avg_threat_score: 0
      },
      recent_blocks: [],
      top_reasons: []
    };
  }

  /**
   * Get security alerts and incident management data
   * Principle 3: Small, Focused Functions - Alerts metrics only
   */
  private async getSecurityAlerts(): Promise<any> {
    const { data, error } = await this.supabase
      .rpc('exec', {
        sql: `
          WITH alert_stats AS (
            SELECT 
              COUNT(*) as total_alerts,
              COUNT(*) FILTER (WHERE resolved = false) as unresolved,
              COUNT(*) FILTER (WHERE severity = 'critical') as critical_alerts,
              COUNT(*) FILTER (WHERE severity = 'high') as high_alerts,
              COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '24 hours') as alerts_24hr,
              AVG(EXTRACT(EPOCH FROM (COALESCE(resolved_at, NOW()) - created_at)))/60::DECIMAL(10,2) as avg_resolution_time_min
            FROM security_alerts
            WHERE created_at > NOW() - INTERVAL '7 days'
          ),
          recent_alerts AS (
            SELECT 
              id,
              alert_type,
              severity,
              title,
              description,
              created_at,
              resolved,
              resolved_at,
              data
            FROM security_alerts 
            ORDER BY created_at DESC
            LIMIT 20
          ),
          alert_types AS (
            SELECT 
              alert_type,
              COUNT(*) as count,
              COUNT(*) FILTER (WHERE resolved = false) as unresolved_count
            FROM security_alerts 
            WHERE created_at > NOW() - INTERVAL '7 days'
            GROUP BY alert_type
            ORDER BY count DESC
            LIMIT 10
          )
          SELECT 
            json_build_object(
              'stats', (SELECT row_to_json(alert_stats) FROM alert_stats),
              'recent_alerts', (SELECT json_agg(row_to_json(recent_alerts)) FROM recent_alerts),
              'alert_types', (SELECT json_agg(row_to_json(alert_types)) FROM alert_types)
            ) as alerts;
        `
      });

    if (error) {
      throw error;
    }

    return data?.[0]?.alerts || {
      stats: {
        total_alerts: 0,
        unresolved: 0,
        critical_alerts: 0,
        high_alerts: 0,
        alerts_24hr: 0,
        avg_resolution_time_min: 0
      },
      recent_alerts: [],
      alert_types: []
    };
  }

  /**
   * Get user activity and behavior analytics
   * Principle 3: Small, Focused Functions - User activity only
   */
  private async getUserActivityMetrics(): Promise<any> {
    const { data, error } = await this.supabase
      .rpc('exec', {
        sql: `
          WITH user_stats AS (
            SELECT 
              COUNT(DISTINCT user_id) as total_active_users_24hr,
              COUNT(DISTINCT ip_address) as unique_ips_24hr,
              COUNT(*) as total_events_24hr,
              AVG(threat_score)::DECIMAL(5,2) as avg_user_threat_score
            FROM security_events 
            WHERE timestamp > NOW() - INTERVAL '24 hours'
              AND user_id IS NOT NULL
          ),
          high_risk_users AS (
            SELECT 
              user_id,
              COUNT(*) as event_count,
              AVG(threat_score)::DECIMAL(5,2) as avg_threat_score,
              MAX(threat_score) as max_threat_score,
              COUNT(DISTINCT ip_address) as unique_ips,
              array_agg(DISTINCT event_type) as event_types
            FROM security_events 
            WHERE timestamp > NOW() - INTERVAL '24 hours'
              AND user_id IS NOT NULL
            GROUP BY user_id
            HAVING AVG(threat_score) > 50 OR COUNT(*) > 100 OR COUNT(DISTINCT ip_address) > 3
            ORDER BY avg_threat_score DESC, event_count DESC
            LIMIT 10
          ),
          behavioral_patterns AS (
            SELECT 
              event_type,
              COUNT(*) as occurrence_count,
              COUNT(DISTINCT user_id) as affected_users,
              AVG(threat_score)::DECIMAL(5,2) as avg_threat_score
            FROM security_events 
            WHERE timestamp > NOW() - INTERVAL '24 hours'
              AND user_id IS NOT NULL
            GROUP BY event_type
            ORDER BY occurrence_count DESC
            LIMIT 10
          )
          SELECT 
            json_build_object(
              'stats', (SELECT row_to_json(user_stats) FROM user_stats),
              'high_risk_users', (SELECT json_agg(row_to_json(high_risk_users)) FROM high_risk_users),
              'behavioral_patterns', (SELECT json_agg(row_to_json(behavioral_patterns)) FROM behavioral_patterns)
            ) as activity;
        `
      });

    if (error) {
      throw error;
    }

    return data?.[0]?.activity || {
      stats: {
        total_active_users_24hr: 0,
        unique_ips_24hr: 0,
        total_events_24hr: 0,
        avg_user_threat_score: 0
      },
      high_risk_users: [],
      behavioral_patterns: []
    };
  }

  /**
   * Get system health and monitoring status
   * Principle 3: Small, Focused Functions - System health only
   */
  private async getSystemHealthMetrics(): Promise<any> {
    const { data, error } = await this.supabase
      .rpc('exec', {
        sql: `
          WITH monitoring_health AS (
            SELECT 
              COUNT(*) FILTER (WHERE metric_name = 'cron_scan_completed' AND timestamp > NOW() - INTERVAL '30 minutes') as recent_scans,
              MAX(timestamp) FILTER (WHERE metric_name = 'cron_scan_completed') as last_scan,
              AVG(metric_value) FILTER (WHERE metric_name = 'scan_duration_ms' AND timestamp > NOW() - INTERVAL '24 hours') as avg_scan_duration,
              COUNT(*) FILTER (WHERE metric_name = 'monitoring_health' AND timestamp > NOW() - INTERVAL '1 hour') as health_checks
            FROM security_metrics
          ),
          performance_metrics AS (
            SELECT 
              COUNT(*) FILTER (WHERE timestamp > NOW() - INTERVAL '5 minutes') as events_last_5min,
              COUNT(*) FILTER (WHERE timestamp > NOW() - INTERVAL '1 hour') as events_last_hour,
              EXTRACT(EPOCH FROM (NOW() - MAX(timestamp)))/60 as minutes_since_last_event
            FROM security_events
          )
          SELECT 
            json_build_object(
              'monitoring_health', (SELECT row_to_json(monitoring_health) FROM monitoring_health),
              'performance', (SELECT row_to_json(performance_metrics) FROM performance_metrics),
              'status', CASE 
                WHEN (SELECT recent_scans FROM monitoring_health) >= 3 THEN 'healthy'
                WHEN (SELECT recent_scans FROM monitoring_health) >= 1 THEN 'degraded'
                ELSE 'unhealthy'
              END,
              'last_updated', NOW()
            ) as health;
        `
      });

    if (error) {
      throw error;
    }

    return data?.[0]?.health || {
      monitoring_health: {
        recent_scans: 0,
        last_scan: null,
        avg_scan_duration: 0,
        health_checks: 0
      },
      performance: {
        events_last_5min: 0,
        events_last_hour: 0,
        minutes_since_last_event: null
      },
      status: 'unknown',
      last_updated: new Date().toISOString()
    };
  }
}

/**
 * SecurityDashboardHandler - Main request handler
 * Principle 4: Separation of Concerns - Request handling separated from business logic
 * Principle 9: Least Surprise - Predictable request/response handling
 */
class SecurityDashboardHandler {
  private supabase: any;
  private authenticator: AdminAuthenticator;
  private metricsService: SecurityMetricsService;
  private performanceMonitor: any;

  constructor() {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    this.supabase = createClient(supabaseUrl, supabaseServiceRoleKey, {
      auth: { persistSession: false },
      db: { schema: 'public' },
      global: { 
        headers: { 
          'X-Security-Context': 'stellr-dashboard-api',
          'X-Dashboard-Version': '1.0.0'
        } 
      }
    });

    this.authenticator = new AdminAuthenticator(this.supabase);
    this.performanceMonitor = getPerformanceMonitor();
    this.metricsService = new SecurityMetricsService(this.supabase, this.performanceMonitor);
  }

  /**
   * Handle incoming requests with comprehensive error handling
   * Principle 6: Fail Fast & Defensive - Comprehensive error handling
   */
  async handleRequest(request: Request): Promise<Response> {
    const startTime = Date.now();
    
    try {
      // Handle CORS preflight
      if (request.method === 'OPTIONS') {
        return new Response('ok', { headers: securityHeaders });
      }

      // Only allow GET requests
      if (request.method !== 'GET') {
        return this.createErrorResponse(
          'Method not allowed',
          'METHOD_NOT_ALLOWED',
          405
        );
      }

      // Authenticate and authorize admin user
      const authHeader = request.headers.get('Authorization');
      const { user, profile } = await this.authenticator.authenticateAdmin(authHeader);

      // Log successful admin access
      await this.logDashboardAccess(user, profile, request);

      // Get dashboard metrics
      const dashboardData = await this.metricsService.getDashboardMetrics();

      // Record successful request
      this.performanceMonitor.recordMetric({
        name: 'security.dashboard.requests',
        value: 1,
        unit: 'count',
        tags: { 
          status: 'success',
          user_id: user.id,
          response_time_ms: Date.now() - startTime
        }
      });

      return new Response(
        JSON.stringify({
          success: true,
          data: dashboardData,
          meta: {
            request_id: crypto.randomUUID(),
            user_id: user.id,
            admin_email: profile.email,
            timestamp: new Date().toISOString(),
            processing_time_ms: Date.now() - startTime
          }
        }),
        {
          headers: {
            ...securityHeaders,
            'Content-Type': 'application/json',
            'Cache-Control': 'no-cache, no-store, must-revalidate',
            'X-Security-Dashboard': 'stellr-v1',
            'X-Response-Time': `${Date.now() - startTime}ms`
          },
        }
      );

    } catch (error) {
      return this.handleError(error, startTime);
    }
  }

  /**
   * Log successful dashboard access for audit trail
   * Principle 10: Security by Design - Audit all admin access
   */
  private async logDashboardAccess(user: any, profile: any, request: Request): Promise<void> {
    try {
      const clientIP = request.headers.get('CF-Connecting-IP') || 
                      request.headers.get('X-Forwarded-For') || 
                      request.headers.get('X-Real-IP') || 
                      'unknown';
      
      await logSecurityEvent(
        SecurityEventType.SENSITIVE_DATA_ACCESS,
        SecuritySeverity.LOW,
        {
          access_type: 'security_dashboard',
          admin_user_id: user.id,
          admin_email: profile.email,
          dashboard_version: '1.0.0'
        },
        {
          userId: user.id,
          ip: clientIP,
          userAgent: request.headers.get('User-Agent') || 'unknown',
          endpoint: '/security-dashboard',
          method: 'GET',
          requestId: crypto.randomUUID()
        }
      );
    } catch (error) {
      console.error('Failed to log dashboard access:', error);
    }
  }

  /**
   * Handle errors with proper logging and response formatting
   * Principle 6: Fail Fast & Defensive - Comprehensive error handling
   */
  private async handleError(error: any, startTime: number): Promise<Response> {
    const processingTime = Date.now() - startTime;
    
    // Log error for monitoring
    console.error('Security dashboard error:', {
      error: error.message,
      code: error.code || 'UNKNOWN',
      stack: error.stack,
      processing_time_ms: processingTime
    });

    // Record error metric
    this.performanceMonitor.recordMetric({
      name: 'security.dashboard.errors',
      value: 1,
      unit: 'count',
      tags: { 
        error_code: error.code || 'UNKNOWN',
        error_type: error.name || 'Error',
        processing_time_ms: processingTime
      }
    });

    if (error instanceof SecurityDashboardError) {
      return this.createErrorResponse(
        error.message,
        error.code,
        error.statusCode
      );
    }

    // Generic server error
    return this.createErrorResponse(
      'Internal server error',
      'INTERNAL_ERROR',
      500
    );
  }

  /**
   * Create standardized error responses
   * Principle 2: Meaningful Names - Clear error response format
   */
  private createErrorResponse(message: string, code: string, statusCode: number): Response {
    return new Response(
      JSON.stringify({
        success: false,
        error: {
          message,
          code,
          timestamp: new Date().toISOString()
        }
      }),
      {
        status: statusCode,
        headers: {
          ...securityHeaders,
          'Content-Type': 'application/json',
          'X-Security-Dashboard': 'stellr-v1-error'
        }
      }
    );
  }
}

/**
 * Main request handler
 * Principle 9: Least Surprise - Clear entry point
 */
serve(async (request: Request) => {
  const handler = new SecurityDashboardHandler();
  return await handler.handleRequest(request);
});