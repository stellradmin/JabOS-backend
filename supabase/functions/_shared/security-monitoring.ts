/**
 * PHASE 3 SECURITY: Comprehensive Security Monitoring & Intrusion Detection
 * 
 * Features:
 * - Real-time security event logging
 * - Intrusion detection patterns
 * - Automated threat response
 * - Security metrics and alerting
 * - Suspicious activity tracking
 */

import { getSupabaseAdmin } from './supabaseAdmin.ts';
import { getAdvancedCache } from './advanced-cache-system.ts';
import { getPerformanceMonitor } from './performance-monitor.ts';

/**
 * Security event types and severity levels
 */
export enum SecurityEventType {
  // Authentication events
  LOGIN_SUCCESS = 'login_success',
  LOGIN_FAILED = 'login_failed',
  ACCOUNT_LOCKED = 'account_locked',
  PASSWORD_RESET = 'password_reset',
  UNAUTHORIZED_ACCESS = 'unauthorized_access',
  
  // API Security events
  RATE_LIMIT_EXCEEDED = 'rate_limit_exceeded',
  INVALID_API_VERSION = 'invalid_api_version',
  MALFORMED_REQUEST = 'malformed_request',
  SQL_INJECTION_ATTEMPT = 'sql_injection_attempt',
  XSS_ATTEMPT = 'xss_attempt',
  
  // Data access events
  SENSITIVE_DATA_ACCESS = 'sensitive_data_access',
  DATA_EXPORT_ATTEMPT = 'data_export_attempt',
  UNAUTHORIZED_QUERY = 'unauthorized_query',
  PRIVILEGE_ESCALATION = 'privilege_escalation',
  
  // Infrastructure events
  SUSPICIOUS_IP = 'suspicious_ip',
  BOT_DETECTION = 'bot_detection',
  DDOS_ATTEMPT = 'ddos_attempt',
  SECURITY_SCAN = 'security_scan',
  
  // Application events
  FILE_UPLOAD_THREAT = 'file_upload_threat',
  CONTENT_INJECTION = 'content_injection',
  SUSPICIOUS_PATTERN = 'suspicious_pattern',
  ANOMALOUS_BEHAVIOR = 'anomalous_behavior'
}

export enum SecuritySeverity {
  LOW = 'low',
  MEDIUM = 'medium',
  HIGH = 'high',
  CRITICAL = 'critical'
}

/**
 * Security event interface
 */
export interface SecurityEvent {
  id?: string;
  type: SecurityEventType;
  severity: SecuritySeverity;
  timestamp: string;
  userId?: string;
  ip?: string;
  userAgent?: string;
  endpoint?: string;
  method?: string;
  requestId?: string;
  details: Record<string, any>;
  context?: Record<string, any>;
  threat_score?: number;
  blocked?: boolean;
  action_taken?: string;
}

/**
 * Intrusion detection patterns
 */
export interface ThreatPattern {
  name: string;
  pattern: RegExp;
  threat_score: number;
  severity: SecuritySeverity;
  description: string;
}

/**
 * Known threat patterns for detection
 */
export const THREAT_PATTERNS: ThreatPattern[] = [
  // SQL Injection patterns
  {
    name: 'sql_injection_union',
    pattern: /(\bunion\b.*\bselect\b)|(\bselect\b.*\bunion\b)/i,
    threat_score: 90,
    severity: SecuritySeverity.HIGH,
    description: 'SQL Union injection attempt'
  },
  {
    name: 'sql_injection_basic',
    pattern: /((\bor\b|\band\b)\s*['"]?\s*\d+\s*['"]?\s*=\s*['"]?\s*\d+)|(\bor\b\s+['"]1['"]=['"]1['"])/i,
    threat_score: 85,
    severity: SecuritySeverity.HIGH,
    description: 'Basic SQL injection attempt'
  },
  {
    name: 'sql_injection_comment',
    pattern: /(\b(select|insert|update|delete|drop|create|alter)\b.*--)|(-{2,}.*$)/i,
    threat_score: 80,
    severity: SecuritySeverity.MEDIUM,
    description: 'SQL comment injection attempt'
  },
  
  // XSS patterns
  {
    name: 'xss_script_tag',
    pattern: /<script[^>]*>.*?<\/script>/i,
    threat_score: 95,
    severity: SecuritySeverity.HIGH,
    description: 'Script tag XSS attempt'
  },
  {
    name: 'xss_javascript_protocol',
    pattern: /javascript:\s*[^;]/i,
    threat_score: 85,
    severity: SecuritySeverity.HIGH,
    description: 'JavaScript protocol XSS attempt'
  },
  {
    name: 'xss_event_handler',
    pattern: /\bon\w+\s*=\s*['"]/i,
    threat_score: 75,
    severity: SecuritySeverity.MEDIUM,
    description: 'Event handler XSS attempt'
  },
  
  // Command injection patterns
  {
    name: 'command_injection',
    pattern: /[;|&`$()]/,
    threat_score: 90,
    severity: SecuritySeverity.HIGH,
    description: 'Command injection attempt'
  },
  
  // Path traversal patterns
  {
    name: 'path_traversal',
    pattern: /(\.\.[\/\\]){2,}/,
    threat_score: 80,
    severity: SecuritySeverity.MEDIUM,
    description: 'Path traversal attempt'
  },
  
  // Suspicious patterns
  {
    name: 'suspicious_base64',
    pattern: /data:.*base64,.*[A-Za-z0-9+\/]{100,}/,
    threat_score: 60,
    severity: SecuritySeverity.LOW,
    description: 'Suspicious base64 data'
  }
];

/**
 * IP reputation and tracking
 */
const suspiciousIPs = new Map<string, { 
  score: number; 
  events: number; 
  lastSeen: number; 
  blocked: boolean;
  reasons: string[];
}>();

const userSessions = new Map<string, {
  events: SecurityEvent[];
  riskScore: number;
  lastActivity: number;
  anomalies: string[];
}>();

/**
 * Security monitoring class
 */
export class SecurityMonitor {
  private cache = getAdvancedCache();
  private performanceMonitor = getPerformanceMonitor();

  /**
   * Log a security event
   */
  async logSecurityEvent(event: Omit<SecurityEvent, 'id' | 'timestamp'>): Promise<void> {
    const securityEvent: SecurityEvent = {
      ...event,
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      threat_score: event.threat_score || this.calculateThreatScore(event),
    };

    try {
      // Store in database for persistent logging
      await this.persistSecurityEvent(securityEvent);
      
      // Cache for real-time analysis
      await this.cacheSecurityEvent(securityEvent);
      
      // Update user session tracking
      if (securityEvent.userId) {
        await this.updateUserSession(securityEvent);
      }
      
      // Update IP reputation
      if (securityEvent.ip) {
        await this.updateIPReputation(securityEvent);
      }
      
      // Trigger real-time analysis
      await this.analyzeEvent(securityEvent);
      
      // Record performance metrics
      this.performanceMonitor.recordMetric({
        name: 'security.event_logged',
        value: 1,
        unit: 'count',
        tags: {
          type: securityEvent.type,
          severity: securityEvent.severity,
        },
        metadata: {
          threat_score: securityEvent.threat_score || 0,
        }
      });

    } catch (error) {
      console.error('Failed to log security event:', error);
      // Fallback to local logging
      this.logToConsole(securityEvent);
    }
  }

  /**
   * Persist security event to database
   */
  private async persistSecurityEvent(event: SecurityEvent): Promise<void> {
    try {
      const { error } = await getSupabaseAdmin()
        .from('security_events')
        .insert({
          id: event.id,
          event_type: event.type,
          severity: event.severity,
          timestamp: event.timestamp,
          user_id: event.userId,
          ip_address: event.ip,
          user_agent: event.userAgent,
          endpoint: event.endpoint,
          method: event.method,
          request_id: event.requestId,
          details: event.details,
          context: event.context,
          threat_score: event.threat_score,
          blocked: event.blocked || false,
          action_taken: event.action_taken,
        });

      if (error) {
        throw error;
      }
    } catch (error) {
      console.error('Failed to persist security event:', error);
      throw error;
    }
  }

  /**
   * Cache security event for real-time analysis
   */
  private async cacheSecurityEvent(event: SecurityEvent): Promise<void> {
    const cacheKey = `security_event:${event.id}`;
    await this.cache.set(cacheKey, event, 3600); // Cache for 1 hour

    // Add to recent events list
    const recentKey = 'security_events:recent';
    const recent = await this.cache.get<SecurityEvent[]>(recentKey) || [];
    recent.unshift(event);
    
    // Keep only last 1000 events in memory
    if (recent.length > 1000) {
      recent.splice(1000);
    }
    
    await this.cache.set(recentKey, recent, 3600);
  }

  /**
   * Update user session tracking
   */
  private async updateUserSession(event: SecurityEvent): Promise<void> {
    if (!event.userId) return;

    const session = userSessions.get(event.userId) || {
      events: [],
      riskScore: 0,
      lastActivity: Date.now(),
      anomalies: []
    };

    session.events.push(event);
    session.lastActivity = Date.now();
    
    // Keep only last 100 events per user
    if (session.events.length > 100) {
      session.events.splice(0, session.events.length - 100);
    }

    // Calculate risk score
    session.riskScore = this.calculateUserRiskScore(session.events);
    
    // Detect anomalies
    const anomalies = this.detectUserAnomalies(session.events);
    session.anomalies = anomalies;

    userSessions.set(event.userId, session);

    // Alert on high risk
    if (session.riskScore > 80) {
      await this.triggerSecurityAlert({
        type: 'HIGH_RISK_USER',
        userId: event.userId,
        riskScore: session.riskScore,
        anomalies: anomalies,
        recentEvents: session.events.slice(-10)
      });
    }
  }

  /**
   * Update IP reputation scoring
   */
  private async updateIPReputation(event: SecurityEvent): Promise<void> {
    if (!event.ip) return;

    const reputation = suspiciousIPs.get(event.ip) || {
      score: 0,
      events: 0,
      lastSeen: Date.now(),
      blocked: false,
      reasons: []
    };

    reputation.events++;
    reputation.lastSeen = Date.now();

    // Increase score based on event severity
    const severityScores = {
      [SecuritySeverity.LOW]: 1,
      [SecuritySeverity.MEDIUM]: 5,
      [SecuritySeverity.HIGH]: 15,
      [SecuritySeverity.CRITICAL]: 30
    };

    reputation.score += severityScores[event.severity] || 1;
    
    // Add threat score bonus
    if (event.threat_score) {
      reputation.score += Math.floor(event.threat_score / 10);
    }

    // Track reasons for reputation score
    if (!reputation.reasons.includes(event.type)) {
      reputation.reasons.push(event.type);
    }

    // Auto-block high-risk IPs
    if (reputation.score > 100 && !reputation.blocked) {
      reputation.blocked = true;
      await this.blockIP(event.ip, reputation.score, reputation.reasons);
    }

    suspiciousIPs.set(event.ip, reputation);
  }

  /**
   * Calculate threat score for an event
   */
  private calculateThreatScore(event: SecurityEvent): number {
    let score = 0;

    // Base score by event type
    const eventTypeScores: Record<string, number> = {
      [SecurityEventType.LOGIN_FAILED]: 10,
      [SecurityEventType.RATE_LIMIT_EXCEEDED]: 20,
      [SecurityEventType.SQL_INJECTION_ATTEMPT]: 90,
      [SecurityEventType.XSS_ATTEMPT]: 85,
      [SecurityEventType.UNAUTHORIZED_ACCESS]: 70,
      [SecurityEventType.SUSPICIOUS_IP]: 50,
      [SecurityEventType.BOT_DETECTION]: 60,
      [SecurityEventType.DDOS_ATTEMPT]: 95,
    };

    score += eventTypeScores[event.type] || 5;

    // Severity multiplier
    const severityMultipliers = {
      [SecuritySeverity.LOW]: 1,
      [SecuritySeverity.MEDIUM]: 1.5,
      [SecuritySeverity.HIGH]: 2.5,
      [SecuritySeverity.CRITICAL]: 4
    };

    score *= severityMultipliers[event.severity] || 1;

    // Check for threat patterns in details
    const detailsString = JSON.stringify(event.details).toLowerCase();
    for (const pattern of THREAT_PATTERNS) {
      if (pattern.pattern.test(detailsString)) {
        score += pattern.threat_score;
      }
    }

    return Math.min(score, 100); // Cap at 100
  }

  /**
   * Calculate user risk score based on recent events
   */
  private calculateUserRiskScore(events: SecurityEvent[]): number {
    if (events.length === 0) return 0;

    const recentEvents = events.filter(e => 
      Date.now() - new Date(e.timestamp).getTime() < 3600000 // Last hour
    );

    if (recentEvents.length === 0) return 0;

    let totalScore = 0;
    for (const event of recentEvents) {
      totalScore += event.threat_score || 0;
    }

    // Average score with frequency bonus
    const avgScore = totalScore / recentEvents.length;
    const frequencyBonus = Math.min(recentEvents.length * 2, 20);
    
    return Math.min(avgScore + frequencyBonus, 100);
  }

  /**
   * Detect user behavior anomalies
   */
  private detectUserAnomalies(events: SecurityEvent[]): string[] {
    const anomalies: string[] = [];
    const recentEvents = events.slice(-50); // Last 50 events

    if (recentEvents.length < 10) return anomalies;

    // Detect unusual activity patterns
    const eventTypes = recentEvents.map(e => e.type);
    const uniqueTypes = new Set(eventTypes);

    // Too many different event types
    if (uniqueTypes.size > 10) {
      anomalies.push('unusual_activity_diversity');
    }

    // Rapid event frequency
    const timeSpan = new Date(recentEvents[0].timestamp).getTime() - 
                     new Date(recentEvents[recentEvents.length - 1].timestamp).getTime();
    if (timeSpan < 300000 && recentEvents.length > 20) { // 20 events in 5 minutes
      anomalies.push('rapid_event_frequency');
    }

    // Multiple IP addresses
    const ips = new Set(recentEvents.map(e => e.ip).filter(Boolean));
    if (ips.size > 5) {
      anomalies.push('multiple_ip_addresses');
    }

    // Multiple user agents
    const userAgents = new Set(recentEvents.map(e => e.userAgent).filter(Boolean));
    if (userAgents.size > 3) {
      anomalies.push('multiple_user_agents');
    }

    return anomalies;
  }

  /**
   * Analyze event for immediate threats
   */
  private async analyzeEvent(event: SecurityEvent): Promise<void> {
    // Check for immediate blocking conditions
    const shouldBlock = await this.shouldBlockEvent(event);
    
    if (shouldBlock) {
      await this.triggerImmediateResponse(event);
    }

    // Check for patterns that require alerting
    const alertConditions = await this.checkAlertConditions(event);
    
    for (const condition of alertConditions) {
      await this.triggerSecurityAlert(condition);
    }
  }

  /**
   * Determine if event should trigger immediate blocking
   */
  private async shouldBlockEvent(event: SecurityEvent): Promise<boolean> {
    // Critical events always block
    if (event.severity === SecuritySeverity.CRITICAL) {
      return true;
    }

    // High threat score events
    if ((event.threat_score || 0) > 85) {
      return true;
    }

    // Known attack patterns
    const criticalPatterns = [
      SecurityEventType.SQL_INJECTION_ATTEMPT,
      SecurityEventType.XSS_ATTEMPT,
      SecurityEventType.DDOS_ATTEMPT
    ];

    if (criticalPatterns.includes(event.type)) {
      return true;
    }

    return false;
  }

  /**
   * Check for conditions that require security alerts
   */
  private async checkAlertConditions(event: SecurityEvent): Promise<any[]> {
    const conditions = [];

    // Multiple failed login attempts
    if (event.type === SecurityEventType.LOGIN_FAILED && event.userId) {
      const recentFailures = await this.getRecentEventsByUser(
        event.userId, 
        SecurityEventType.LOGIN_FAILED, 
        300000 // 5 minutes
      );
      
      if (recentFailures.length >= 3) {
        conditions.push({
          type: 'MULTIPLE_LOGIN_FAILURES',
          userId: event.userId,
          count: recentFailures.length,
          timespan: '5 minutes'
        });
      }
    }

    // Suspicious IP activity
    if (event.ip) {
      const ipReputation = suspiciousIPs.get(event.ip);
      if (ipReputation && ipReputation.score > 50) {
        conditions.push({
          type: 'SUSPICIOUS_IP_ACTIVITY',
          ip: event.ip,
          score: ipReputation.score,
          reasons: ipReputation.reasons
        });
      }
    }

    return conditions;
  }

  /**
   * Trigger immediate security response
   */
  private async triggerImmediateResponse(event: SecurityEvent): Promise<void> {
    const response = {
      blocked: true,
      action_taken: 'auto_blocked',
      timestamp: new Date().toISOString(),
      reason: `Threat score: ${event.threat_score}, Severity: ${event.severity}`
    };

    // Update the event record
    event.blocked = true;
    event.action_taken = response.action_taken;

    // Block the IP if available
    if (event.ip) {
      await this.blockIP(event.ip, event.threat_score || 100, [event.type]);
    }

    // Log the response
    console.log('Security Response Triggered:', response);
  }

  /**
   * Block an IP address
   */
  private async blockIP(ip: string, score: number, reasons: string[]): Promise<void> {
    try {
      // Add to blocked IPs in database
      await getSupabaseAdmin()
        .from('blocked_ips')
        .upsert({
          ip_address: ip,
          blocked_at: new Date().toISOString(),
          threat_score: score,
          reasons: reasons,
          blocked_until: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString() // 24 hours
        });

      console.log(`IP ${ip} blocked with score ${score}`);
    } catch (error) {
      console.error('Failed to block IP:', error);
    }
  }

  /**
   * Trigger security alert
   */
  private async triggerSecurityAlert(alertData: any): Promise<void> {
    try {
      // Store alert in database
      await getSupabaseAdmin()
        .from('security_alerts')
        .insert({
          id: crypto.randomUUID(),
          alert_type: alertData.type,
          severity: this.determineAlertSeverity(alertData),
          data: alertData,
          created_at: new Date().toISOString(),
          resolved: false
        });

      // In production, this would also trigger:
      // - Email notifications
      // - Slack/Discord webhooks
      // - PagerDuty alerts
      // - SMS alerts for critical issues

      console.log('Security Alert Triggered:', alertData);
    } catch (error) {
      console.error('Failed to trigger security alert:', error);
    }
  }

  /**
   * Determine alert severity
   */
  private determineAlertSeverity(alertData: any): SecuritySeverity {
    if (alertData.type === 'HIGH_RISK_USER' && alertData.riskScore > 90) {
      return SecuritySeverity.CRITICAL;
    }
    
    if (alertData.type === 'SUSPICIOUS_IP_ACTIVITY' && alertData.score > 80) {
      return SecuritySeverity.HIGH;
    }

    return SecuritySeverity.MEDIUM;
  }

  /**
   * Get recent events by user
   */
  private async getRecentEventsByUser(
    userId: string, 
    eventType: SecurityEventType, 
    timeWindow: number
  ): Promise<SecurityEvent[]> {
    const session = userSessions.get(userId);
    if (!session) return [];

    const cutoff = Date.now() - timeWindow;
    return session.events.filter(e => 
      e.type === eventType && 
      new Date(e.timestamp).getTime() > cutoff
    );
  }

  /**
   * Console fallback logging
   */
  private logToConsole(event: SecurityEvent): void {
    console.log(`[SECURITY EVENT] ${event.severity.toUpperCase()}: ${event.type}`, {
      timestamp: event.timestamp,
      userId: event.userId,
      ip: event.ip,
      endpoint: event.endpoint,
      details: event.details
    });
  }

  /**
   * Get security metrics for dashboard
   */
  async getSecurityMetrics(): Promise<any> {
    try {
      const recentEvents = await this.cache.get<SecurityEvent[]>('security_events:recent') || [];
      const last24Hours = recentEvents.filter(e => 
        Date.now() - new Date(e.timestamp).getTime() < 86400000
      );

      const metrics = {
        totalEvents: last24Hours.length,
        eventsBySeverity: {
          critical: last24Hours.filter(e => e.severity === SecuritySeverity.CRITICAL).length,
          high: last24Hours.filter(e => e.severity === SecuritySeverity.HIGH).length,
          medium: last24Hours.filter(e => e.severity === SecuritySeverity.MEDIUM).length,
          low: last24Hours.filter(e => e.severity === SecuritySeverity.LOW).length,
        },
        eventsByType: {},
        blockedEvents: last24Hours.filter(e => e.blocked).length,
        suspiciousIPs: suspiciousIPs.size,
        activeUsers: userSessions.size,
        avgThreatScore: last24Hours.reduce((sum, e) => sum + (e.threat_score || 0), 0) / last24Hours.length || 0
      };

      // Group by event type
      for (const event of last24Hours) {
        metrics.eventsByType[event.type] = (metrics.eventsByType[event.type] || 0) + 1;
      }

      return metrics;
    } catch (error) {
      console.error('Failed to get security metrics:', error);
      return null;
    }
  }
}

// Global security monitor instance
export const securityMonitor = new SecurityMonitor();

/**
 * Convenience function for logging security events
 */
export async function logSecurityEvent(
  type: SecurityEventType,
  severity: SecuritySeverity,
  details: Record<string, any>,
  context?: {
    userId?: string;
    ip?: string;
    userAgent?: string;
    endpoint?: string;
    method?: string;
    requestId?: string;
  }
): Promise<void> {
  await securityMonitor.logSecurityEvent({
    type,
    severity,
    details,
    userId: context?.userId,
    ip: context?.ip,
    userAgent: context?.userAgent,
    endpoint: context?.endpoint,
    method: context?.method,
    requestId: context?.requestId,
  });
}

/**
 * Quick detection of threat patterns in text
 */
export function detectThreatPatterns(text: string): ThreatPattern[] {
  const detectedPatterns: ThreatPattern[] = [];
  
  for (const pattern of THREAT_PATTERNS) {
    if (pattern.pattern.test(text)) {
      detectedPatterns.push(pattern);
    }
  }
  
  return detectedPatterns;
}

/**
 * Check if IP is blocked
 */
export function isIPBlocked(ip: string): boolean {
  const reputation = suspiciousIPs.get(ip);
  return reputation?.blocked || false;
}

/**
 * Get IP reputation score
 */
export function getIPReputationScore(ip: string): number {
  const reputation = suspiciousIPs.get(ip);
  return reputation?.score || 0;
}

export { SecurityEventType, SecuritySeverity, SecurityEvent, ThreatPattern };