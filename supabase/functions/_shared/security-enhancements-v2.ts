/**
 * CRITICAL SECURITY ENHANCEMENTS V2 for Stellr Matching System
 * 
 * Additional security layers for production-ready deployment
 * Implements advanced threat detection and prevention mechanisms
 * 
 * SECURITY FEATURES:
 * - Request fingerprinting for anomaly detection
 * - Advanced input validation patterns
 * - Content Security Policy enforcement
 * - Timing attack prevention
 * - Advanced XSS protection
 * - Data exfiltration prevention
 */

import { logSecurityEvent, SecurityEventType, SecuritySeverity } from './security-monitoring.ts';
import { sanitizeForSQL, detectSQLInjection } from './sql-injection-protection.ts';
import { validateUUID } from './security-validation.ts';

// Request fingerprinting for advanced threat detection
export interface RequestFingerprint {
  id: string;
  ip: string;
  userAgent: string;
  acceptLanguage: string;
  acceptEncoding: string;
  timestamp: number;
  pathPattern: string;
  payloadSize: number;
  headerCount: number;
  suspiciousIndicators: string[];
  riskScore: number;
}

// Advanced threat detection patterns
const ADVANCED_THREAT_PATTERNS = {
  // SQL injection variants not covered in basic protection
  ADVANCED_SQL_PATTERNS: [
    // Time-based blind injection variants
    /waitfor\s+delay\s+/gi,
    /pg_sleep\s*\(/gi,
    /sleep\s*\(\s*\d+\s*\)/gi,
    
    // Error-based injection variants
    /extractvalue\s*\(/gi,
    /updatexml\s*\(/gi,
    /exp\s*\(\s*~\s*\(/gi,
    
    // Boolean-based blind variants
    /(\d+)\s*=\s*\1/g,
    /(\w+)\s*(and|or)\s*\1/gi,
    
    // Advanced union variants
    /union\s+(all\s+)?select\s+null/gi,
    /union\s+(all\s+)?select\s+\d+/gi,
    
    // PostgreSQL specific advanced patterns
    /\bpg_read_file\b/gi,
    /\bpg_ls_dir\b/gi,
    /\bcurrent_setting\b/gi,
    /\bversion\s*\(\s*\)/gi,
  ],
  
  // XSS variants for JSON payloads
  JSON_XSS_PATTERNS: [
    /javascript\s*:/gi,
    /data\s*:/gi,
    /vbscript\s*:/gi,
    /on\w+\s*=/gi,
    /<script[^>]*>.*?<\/script>/gi,
    /<iframe[^>]*>.*?<\/iframe>/gi,
    /eval\s*\(/gi,
    /Function\s*\(/gi,
    /setTimeout\s*\(/gi,
    /setInterval\s*\(/gi,
  ],
  
  // NoSQL injection patterns (future-proofing)
  NOSQL_PATTERNS: [
    /\$where\s*:/gi,
    /\$regex\s*:/gi,
    /\$ne\s*:/gi,
    /\$gt\s*:/gi,
    /\$lt\s*:/gi,
    /\$in\s*:/gi,
    /\$nin\s*:/gi,
  ],
  
  // Path traversal variants
  PATH_TRAVERSAL_PATTERNS: [
    /\.\.[\/\\]/g,
    /%2e%2e[\/\\]/gi,
    /\.\.\%2f/gi,
    /\.\.\%5c/gi,
    /file\s*:/gi,
  ],
  
  // Command injection patterns
  COMMAND_INJECTION_PATTERNS: [
    /[;&|`$\(\)\[\]\{\}]/g,
    /\bcat\b|\bls\b|\bpwd\b|\bwhoami\b/gi,
    /\bcurl\b|\bwget\b|\bnc\b|\bnetcat\b/gi,
    /\bbash\b|\bsh\b|\bcmd\b|\bpowershell\b/gi,
  ]
};

// Advanced validation schemas for edge cases
export const ADVANCED_VALIDATION_PATTERNS = {
  // UUID variants that bypass basic checks
  UUID_VARIANTS: [
    /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
    /^[0-9a-fA-F]{32}$/, // UUID without hyphens
    /^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$/ // UUID with braces
  ],
  
  // Email patterns that bypass basic regex
  SUSPICIOUS_EMAIL_PATTERNS: [
    /\+.*\+/g, // Multiple plus signs
    /\.{2,}/g, // Multiple consecutive dots
    /@.*@/g, // Multiple @ symbols
    /[<>]/g, // Angle brackets
    /#/g, // Hash symbol in email
  ],
  
  // Phone number injection attempts
  PHONE_INJECTION_PATTERNS: [
    /\+{2,}/g, // Multiple plus signs
    /[a-zA-Z]/g, // Letters in phone numbers
    /[^0-9+\-\s\(\)]/g, // Invalid phone characters
  ]
};

/**
 * SECURITY: Generate request fingerprint for threat analysis
 */
export function generateRequestFingerprint(
  req: Request,
  payload?: any
): RequestFingerprint {
  const userAgent = req.headers.get('User-Agent') || '';
  const acceptLanguage = req.headers.get('Accept-Language') || '';
  const acceptEncoding = req.headers.get('Accept-Encoding') || '';
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 
             req.headers.get('x-real-ip') || 'unknown';
  
  const url = new URL(req.url);
  const pathPattern = url.pathname.replace(/\/[0-9a-f-]{36}/g, '/:id'); // Normalize UUIDs
  
  const suspiciousIndicators: string[] = [];
  let riskScore = 0;
  
  // Analyze User-Agent for suspicious patterns
  if (!userAgent || userAgent.length < 10) {
    suspiciousIndicators.push('missing_or_short_user_agent');
    riskScore += 2;
  }
  
  if (/bot|crawler|spider|scraper/i.test(userAgent)) {
    suspiciousIndicators.push('automated_user_agent');
    riskScore += 1;
  }
  
  // Analyze request headers
  const headerCount = Array.from(req.headers.entries()).length;
  if (headerCount < 5) {
    suspiciousIndicators.push('minimal_headers');
    riskScore += 1;
  }
  
  // Analyze payload if present
  let payloadSize = 0;
  if (payload) {
    const payloadString = JSON.stringify(payload);
    payloadSize = payloadString.length;
    
    // Check for suspicious payload patterns
    for (const [category, patterns] of Object.entries(ADVANCED_THREAT_PATTERNS)) {
      for (const pattern of patterns) {
        if (pattern.test(payloadString)) {
          suspiciousIndicators.push(`${category.toLowerCase()}_pattern`);
          riskScore += category.includes('SQL') ? 5 : 3;
        }
      }
    }
  }
  
  return {
    id: `fp_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
    ip,
    userAgent,
    acceptLanguage,
    acceptEncoding,
    timestamp: Date.now(),
    pathPattern,
    payloadSize,
    headerCount,
    suspiciousIndicators,
    riskScore
  };
}

/**
 * SECURITY: Advanced input validation with edge case detection
 */
export function validateAdvancedInput(
  value: any,
  fieldName: string,
  type: 'uuid' | 'email' | 'phone' | 'text' | 'json'
): { valid: boolean; sanitized?: any; threats: string[]; riskLevel: number } {
  const threats: string[] = [];
  let riskLevel = 0;
  let sanitized = value;
  
  if (!value || (typeof value === 'string' && !value.trim())) {
    return { valid: true, sanitized: '', threats: [], riskLevel: 0 };
  }
  
  const valueString = typeof value === 'string' ? value : JSON.stringify(value);
  
  switch (type) {
    case 'uuid':
      // Enhanced UUID validation
      if (typeof value !== 'string') {
        threats.push('uuid_wrong_type');
        riskLevel += 2;
        return { valid: false, threats, riskLevel };
      }
      
      // Check for UUID variants
      const isValidUUID = ADVANCED_VALIDATION_PATTERNS.UUID_VARIANTS.some(pattern => 
        pattern.test(value)
      );
      
      if (!isValidUUID) {
        threats.push('invalid_uuid_format');
        riskLevel += 1;
      }
      
      // Additional UUID security checks
      if (value.includes('..') || value.includes('/')) {
        threats.push('uuid_path_traversal_attempt');
        riskLevel += 3;
      }
      
      break;
      
    case 'email':
      // Enhanced email validation
      if (typeof value !== 'string') {
        threats.push('email_wrong_type');
        riskLevel += 2;
        return { valid: false, threats, riskLevel };
      }
      
      for (const [patternName, pattern] of Object.entries(ADVANCED_VALIDATION_PATTERNS.SUSPICIOUS_EMAIL_PATTERNS)) {
        if (pattern.test(value)) {
          threats.push(`email_${patternName.toLowerCase()}`);
          riskLevel += 2;
        }
      }
      
      break;
      
    case 'phone':
      // Enhanced phone validation
      if (typeof value !== 'string') {
        threats.push('phone_wrong_type');
        riskLevel += 2;
        return { valid: false, threats, riskLevel };
      }
      
      for (const [patternName, pattern] of Object.entries(ADVANCED_VALIDATION_PATTERNS.PHONE_INJECTION_PATTERNS)) {
        if (pattern.test(value)) {
          threats.push(`phone_${patternName.toLowerCase()}`);
          riskLevel += 2;
          sanitized = value.replace(pattern, '');
        }
      }
      
      break;
      
    case 'text':
    case 'json':
      // Advanced text/JSON validation
      for (const [category, patterns] of Object.entries(ADVANCED_THREAT_PATTERNS)) {
        for (const pattern of patterns) {
          if (pattern.test(valueString)) {
            threats.push(`${category.toLowerCase()}_detected`);
            riskLevel += category.includes('SQL') ? 5 : 3;
            
            // Sanitize by removing the dangerous pattern
            if (typeof sanitized === 'string') {
              sanitized = sanitized.replace(pattern, '[FILTERED]');
            }
          }
        }
      }
      
      break;
  }
  
  // SQL injection detection as final check
  const sqlDetection = detectSQLInjection(valueString);
  if (sqlDetection.detected) {
    threats.push(...sqlDetection.patterns);
    riskLevel += sqlDetection.risk === 'critical' ? 10 : 5;
  }
  
  return {
    valid: riskLevel < 5, // Threshold for valid input
    sanitized,
    threats,
    riskLevel
  };
}

/**
 * SECURITY: Content Security Policy headers for API responses
 */
export function getAdvancedSecurityHeaders(
  contentType: 'json' | 'html' | 'image' | 'text' = 'json',
  hasUserData: boolean = false
): Record<string, string> {
  const baseHeaders: Record<string, string> = {
    // Prevent MIME sniffing
    'X-Content-Type-Options': 'nosniff',
    
    // Prevent clickjacking
    'X-Frame-Options': 'DENY',
    
    // Control referrer information
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    
    // Prevent XSS attacks
    'X-XSS-Protection': '1; mode=block',
    
    // Enforce HTTPS
    'Strict-Transport-Security': 'max-age=31536000; includeSubDomains; preload',
    
    // Permissions policy (restrict dangerous features)
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=()',
  };
  
  // Content-specific CSP
  switch (contentType) {
    case 'json':
      baseHeaders['Content-Security-Policy'] = [
        "default-src 'none'",
        "frame-ancestors 'none'",
        "base-uri 'none'"
      ].join('; ');
      break;
      
    case 'html':
      baseHeaders['Content-Security-Policy'] = [
        "default-src 'self'",
        "script-src 'self' 'unsafe-inline'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: https:",
        "font-src 'self'",
        "connect-src 'self'",
        "frame-ancestors 'none'",
        "base-uri 'self'"
      ].join('; ');
      break;
      
    case 'image':
      baseHeaders['Content-Security-Policy'] = [
        "default-src 'none'",
        "img-src 'self'",
        "frame-ancestors 'none'"
      ].join('; ');
      break;
  }
  
  // Additional headers for user data
  if (hasUserData) {
    baseHeaders['Cache-Control'] = 'no-store, no-cache, must-revalidate, private, max-age=0';
    baseHeaders['Pragma'] = 'no-cache';
    baseHeaders['Expires'] = '0';
    baseHeaders['X-Robots-Tag'] = 'noindex, nofollow, nosnippet, noarchive';
  }
  
  return baseHeaders;
}

/**
 * SECURITY: Timing attack prevention for sensitive operations
 */
export async function safeTimeComparison<T>(
  sensitiveOperation: () => Promise<T>,
  minExecutionTime: number = 100
): Promise<T> {
  const startTime = Date.now();
  
  try {
    const result = await sensitiveOperation();
    
    // Ensure minimum execution time to prevent timing attacks
    const executionTime = Date.now() - startTime;
    if (executionTime < minExecutionTime) {
      await new Promise(resolve => 
        setTimeout(resolve, minExecutionTime - executionTime)
      );
    }
    
    return result;
  } catch (error) {
    // Still wait minimum time even on error
    const executionTime = Date.now() - startTime;
    if (executionTime < minExecutionTime) {
      await new Promise(resolve => 
        setTimeout(resolve, minExecutionTime - executionTime)
      );
    }
    
    throw error;
  }
}

/**
 * SECURITY: Advanced rate limiting with behavioral analysis
 */
export interface BehaviorAnalysis {
  isHuman: boolean;
  confidence: number;
  indicators: {
    regularTiming: boolean;
    naturalPauses: boolean;
    variableRequestSizes: boolean;
    consistentHeaders: boolean;
  };
  riskScore: number;
}

export function analyzeBehavior(
  fingerprints: RequestFingerprint[]
): BehaviorAnalysis {
  if (fingerprints.length < 2) {
    return {
      isHuman: true,
      confidence: 0.5,
      indicators: {
        regularTiming: false,
        naturalPauses: false,
        variableRequestSizes: false,
        consistentHeaders: false
      },
      riskScore: 0
    };
  }
  
  const timingIntervals = [];
  const payloadSizes = [];
  let riskScore = 0;
  
  // Calculate timing intervals
  for (let i = 1; i < fingerprints.length; i++) {
    const interval = fingerprints[i].timestamp - fingerprints[i-1].timestamp;
    timingIntervals.push(interval);
    payloadSizes.push(fingerprints[i].payloadSize);
  }
  
  // Check for regular timing (bot behavior)
  const avgInterval = timingIntervals.reduce((a, b) => a + b, 0) / timingIntervals.length;
  const variance = timingIntervals.reduce((acc, interval) => 
    acc + Math.pow(interval - avgInterval, 2), 0) / timingIntervals.length;
  const stdDev = Math.sqrt(variance);
  
  const regularTiming = stdDev < (avgInterval * 0.1); // Less than 10% variation
  if (regularTiming && avgInterval < 5000) { // Very regular and fast
    riskScore += 3;
  }
  
  // Check for natural pauses (human behavior)
  const hasLongPauses = timingIntervals.some(interval => interval > 10000); // 10+ seconds
  const naturalPauses = hasLongPauses && !regularTiming;
  
  // Check payload size variation
  const uniquePayloadSizes = new Set(payloadSizes).size;
  const variableRequestSizes = uniquePayloadSizes > payloadSizes.length * 0.3;
  
  // Check header consistency
  const userAgents = fingerprints.map(fp => fp.userAgent);
  const uniqueUserAgents = new Set(userAgents).size;
  const consistentHeaders = uniqueUserAgents === 1 && userAgents[0].length > 20;
  
  // Calculate confidence
  let confidence = 0.5;
  if (naturalPauses) confidence += 0.2;
  if (variableRequestSizes) confidence += 0.2;
  if (consistentHeaders && !regularTiming) confidence += 0.1;
  if (regularTiming) confidence -= 0.3;
  
  confidence = Math.max(0, Math.min(1, confidence));
  
  return {
    isHuman: confidence > 0.6 && riskScore < 3,
    confidence,
    indicators: {
      regularTiming,
      naturalPauses,
      variableRequestSizes,
      consistentHeaders
    },
    riskScore
  };
}

/**
 * SECURITY: Data exfiltration prevention
 */
export function detectDataExfiltration(
  requestData: any,
  responseSize: number,
  userRole: 'user' | 'admin' = 'user'
): { threat: boolean; indicators: string[]; allowResponse: boolean } {
  const indicators: string[] = [];
  let threat = false;
  
  // Check for excessive data requests
  const maxResponseSize = userRole === 'admin' ? 1024 * 1024 : 256 * 1024; // 1MB for admin, 256KB for user
  
  if (responseSize > maxResponseSize) {
    indicators.push('excessive_response_size');
    threat = true;
  }
  
  // Check for bulk data queries in request
  if (requestData && typeof requestData === 'object') {
    const requestString = JSON.stringify(requestData).toLowerCase();
    
    // Patterns that indicate bulk data access
    const bulkPatterns = [
      /limit\s*:\s*(\d{3,})/g, // Large limit values
      /pagesize\s*:\s*(\d{3,})/g, // Large page sizes
      /\*/, // Wildcard selections (in JSON strings)
    ];
    
    for (const pattern of bulkPatterns) {
      if (pattern.test(requestString)) {
        indicators.push('bulk_data_request');
        threat = true;
      }
    }
  }
  
  return {
    threat,
    indicators,
    allowResponse: !threat || userRole === 'admin'
  };
}

/**
 * SECURITY: Enhanced middleware for comprehensive protection
 */
export async function applyAdvancedSecurityMiddleware(
  req: Request,
  payload?: any,
  options: {
    requireFingerprinting?: boolean;
    enableBehaviorAnalysis?: boolean;
    enforceCSP?: boolean;
    preventTimingAttacks?: boolean;
  } = {}
): Promise<{
  allowed: boolean;
  response?: Response;
  fingerprint?: RequestFingerprint;
  securityWarnings?: string[];
}> {
  const securityWarnings: string[] = [];
  
  // Generate request fingerprint
  const fingerprint = generateRequestFingerprint(req, payload);
  
  // Check risk score threshold
  if (fingerprint.riskScore > 10) {
    await logSecurityEvent(
      SecurityEventType.SUSPICIOUS_PATTERN,
      SecuritySeverity.HIGH,
      {
        fingerprint: fingerprint,
        indicators: fingerprint.suspiciousIndicators,
        riskScore: fingerprint.riskScore
      },
      {
        ip: fingerprint.ip,
        userAgent: fingerprint.userAgent,
        endpoint: fingerprint.pathPattern
      }
    );
    
    const securityHeaders = getAdvancedSecurityHeaders('json', false);
    
    return {
      allowed: false,
      response: new Response(
        JSON.stringify({
          error: 'Security validation failed',
          message: 'Request blocked due to security policy',
          requestId: fingerprint.id,
          timestamp: new Date().toISOString()
        }),
        {
          status: 403,
          headers: {
            'Content-Type': 'application/json',
            ...securityHeaders
          }
        }
      ),
      fingerprint,
      securityWarnings: fingerprint.suspiciousIndicators
    };
  }
  
  // Warnings for moderate risk
  if (fingerprint.riskScore > 5) {
    securityWarnings.push(...fingerprint.suspiciousIndicators);
  }
  
  return {
    allowed: true,
    fingerprint,
    securityWarnings: securityWarnings.length > 0 ? securityWarnings : undefined
  };
}

// Export threat patterns for testing
export const SECURITY_TEST_PATTERNS = ADVANCED_THREAT_PATTERNS;