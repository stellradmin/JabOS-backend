/**
 * CRITICAL SECURITY: SQL Injection Protection for Stellr Edge Functions
 * 
 * Comprehensive protection against SQL injection attacks including:
 * - Second-order SQL injection in stored content
 * - JSONB injection in profile data
 * - Dynamic query injection prevention
 * - SQL pattern detection and blocking
 * 
 * SECURITY FEATURES:
 * - Multi-layer SQL injection detection
 * - Content sanitization for database storage
 * - JSONB structure validation and cleaning
 * - SQL keyword filtering
 * - Parameterized query enforcement
 */

import { logSecurityEvent } from './error-handler.ts';

// SQL injection patterns - comprehensive detection
const SQL_INJECTION_PATTERNS = [
  // Basic SQL injection patterns
  /(\b(SELECT|INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|EXEC|EXECUTE|UNION|MERGE|TRUNCATE)\b)/gi,
  
  // SQL comments and terminations
  /(--|#|\/\*|\*\/)/g,
  /;[\s]*$/g, // Query termination
  
  // SQL operators and functions
  /(\b(AND|OR|NOT|LIKE|IN|EXISTS|BETWEEN|IS\s+NULL|IS\s+NOT\s+NULL)\b)/gi,
  /(=|<>|!=|<=|>=|<|>)/g,
  
  // SQL string manipulation
  /(\b(CONCAT|SUBSTRING|CHAR|ASCII|HEX|UNHEX|LOAD_FILE|INTO\s+OUTFILE)\b)/gi,
  
  // Database system functions
  /(\b(USER|VERSION|DATABASE|SCHEMA|TABLE_NAME|COLUMN_NAME)\b)/gi,
  /(\b(INFORMATION_SCHEMA|SYS|MYSQL|POSTGRESQL|SQLITE)\b)/gi,
  
  // Time-based blind injection
  /(\b(SLEEP|WAITFOR|DELAY|BENCHMARK)\b)/gi,
  
  // Union and subquery patterns
  /(\bUNION\s+(ALL\s+)?SELECT\b)/gi,
  /(\bSELECT\s+[\w\*\,\s]+\s+FROM\b)/gi,
  
  // PostgreSQL specific
  /(\b(PG_SLEEP|PG_USER|PG_DATABASE|CURRENT_USER|SESSION_USER)\b)/gi,
  /(\b(CAST|EXTRACT|TO_CHAR|TO_NUMBER)\b)/gi,
  
  // Boolean-based blind injection
  /(\b(TRUE|FALSE)\b.*(\bAND\b|\bOR\b).*(\b(TRUE|FALSE)\b))/gi,
  
  // Error-based injection
  /(\b(CONVERT|EXTRACTVALUE|UPDATEXML|EXP|POW)\b)/gi,
  
  // Stored procedures
  /(\b(CALL|EXEC|EXECUTE|SP_|XP_)\b)/gi,
  
  // Hex encoding attempts
  /(0x[0-9a-fA-F]+)/g,
  
  // JSONB injection specific patterns
  /(\$\$|\$[0-9]+\$)/g, // PostgreSQL dollar quoting
  /(\b(JSONB_SET|JSONB_INSERT|JSON_EXTRACT)\b)/gi,
  
  // Advanced evasion techniques
  /(%27|%22|%2D%2D|%23)/gi, // URL encoded SQL characters
  /(char\(|chr\(|ascii\()/gi, // Character function evasion
  
  // PHASE 2 SECURITY: Enhanced evasion detection
  /(\bunion\s+all\s+select\b)/gi, // Union all select
  /(\bselect\s+.*\s+from\s+.*\s+where\b)/gi, // Select from where patterns
  /(\border\s+by\s+\d+)/gi, // Order by column number
  /(\bgroup\s+by\s+\d+)/gi, // Group by column number
  /(\bhaving\s+count\s*\(\s*\*\s*\)\s*>\s*\d+)/gi, // Having count patterns
  /(\bcase\s+when\b.*\bthen\b.*\belse\b.*\bend\b)/gi, // Case when patterns
  /(\bif\s*\(\s*.*\s*,\s*.*\s*,\s*.*\s*\))/gi, // If function patterns
  /(\bisnull\s*\(\s*.*\s*,\s*.*\s*\))/gi, // IsNull function patterns
  /(\bcoalesce\s*\(\s*.*\s*,\s*.*\s*\))/gi, // Coalesce function patterns
  
  // NoSQL injection patterns (for MongoDB-style attacks)
  /(\$where|\$regex|\$ne|\$gt|\$lt|\$gte|\$lte|\$in|\$nin)/gi,
  /(\$or|\$and|\$not|\$nor|\$exists|\$size|\$all|\$elemMatch)/gi,
  
  // Time-based detection enhancements
  /(\bpg_sleep\s*\(\s*\d+\s*\))/gi,
  /(\bwaitfor\s+delay\s+'\d+:\d+:\d+')/gi,
  /(\bbenchmark\s*\(\s*\d+\s*,\s*.*\))/gi,
  
  // Blind SQL injection patterns
  /(\b\d+\s*=\s*\d+\b)/g, // Numeric comparisons
  /(\b'[^']*'\s*=\s*'[^']*'\b)/g, // String comparisons
  /(\blength\s*\(\s*.*\s*\)\s*[><=]\s*\d+)/gi, // Length comparisons
  /(\bsubstring\s*\(\s*.*\s*,\s*\d+\s*,\s*\d+\s*\))/gi, // Substring extractions
];

// Dangerous keywords that should never appear in user content
const DANGEROUS_SQL_KEYWORDS = [
  'DROP', 'DELETE', 'TRUNCATE', 'ALTER', 'CREATE', 'EXEC', 'EXECUTE',
  'SHUTDOWN', 'KILL', 'GRANT', 'REVOKE', 'BACKUP', 'RESTORE',
  'LOAD_FILE', 'INTO OUTFILE', 'DUMPFILE', 'BULK INSERT',
  'SP_', 'XP_', 'OPENROWSET', 'OPENDATASOURCE'
];

// JSONB injection specific patterns
const JSONB_INJECTION_PATTERNS = [
  // PostgreSQL JSONB operators that could be dangerous
  /(@>|<@|\?\?|\?&|\?|#>|#>>|#-)/g,
  
  // JSON path injection
  /(\$\.[a-zA-Z_][a-zA-Z0-9_]*\[)/g,
  
  // Function calls in JSON
  /("function"|"eval"|"constructor"|"__proto__"|"prototype")/gi,
  
  // JavaScript-like injection in JSON values
  /(".*\$\{.*\}.*")/g,
  
  // SQL in JSON string values
  /(".*('|";|"--|"#).*")/g,
];

export interface SQLSanitizationResult {
  sanitized: string | object;
  originalLength: number;
  sanitizedLength: number;
  removedPatterns: string[];
  securityRisk: 'none' | 'low' | 'medium' | 'high' | 'critical';
  isClean: boolean;
}

export interface JSONBSanitizationResult {
  sanitized: object;
  originalSize: number;
  sanitizedSize: number;
  removedKeys: string[];
  securityRisk: 'none' | 'low' | 'medium' | 'high' | 'critical';
  isClean: boolean;
}

/**
 * CRITICAL SECURITY: Detect SQL injection patterns in text content
 * 
 * @param content - Text content to analyze for SQL injection
 * @returns Detection result with security risk assessment
 */
export function detectSQLInjection(content: string): {
  detected: boolean;
  patterns: string[];
  risk: 'none' | 'low' | 'medium' | 'high' | 'critical';
  details: string[];
} {
  if (!content || typeof content !== 'string') {
    return { detected: false, patterns: [], risk: 'none', details: [] };
  }

  const detectedPatterns: string[] = [];
  const details: string[] = [];
  let maxRisk: 'none' | 'low' | 'medium' | 'high' | 'critical' = 'none';

  // Check for dangerous keywords first (highest risk)
  for (const keyword of DANGEROUS_SQL_KEYWORDS) {
    const regex = new RegExp(`\\b${keyword}\\b`, 'gi');
    if (regex.test(content)) {
      detectedPatterns.push(`DANGEROUS_KEYWORD: ${keyword}`);
      details.push(`Found dangerous SQL keyword: ${keyword}`);
      maxRisk = 'critical';
    }
  }

  // Check all SQL injection patterns
  for (let i = 0; i < SQL_INJECTION_PATTERNS.length; i++) {
    const pattern = SQL_INJECTION_PATTERNS[i];
    const matches = content.match(pattern);
    if (matches) {
      detectedPatterns.push(`PATTERN_${i}: ${matches[0]}`);
      details.push(`SQL injection pattern detected: ${matches[0]}`);
      
      // Assess risk level based on pattern type
      if (i < 3) { // Basic SQL keywords
        maxRisk = maxRisk === 'critical' ? 'critical' : 'high';
      } else if (i < 8) { // SQL operators and functions
        maxRisk = maxRisk === 'critical' || maxRisk === 'high' ? maxRisk : 'medium';
      } else {
        maxRisk = maxRisk === 'none' ? 'low' : maxRisk;
      }
    }
  }

  // Log security event if injection detected
  if (detectedPatterns.length > 0) {
    logSecurityEvent('sql_injection_detected', undefined, {
      patterns: detectedPatterns.slice(0, 5), // Log first 5 patterns
      contentLength: content.length,
      riskLevel: maxRisk,
      contentSample: content.substring(0, 100) // First 100 chars for analysis
    });
  }

  return {
    detected: detectedPatterns.length > 0,
    patterns: detectedPatterns,
    risk: maxRisk,
    details
  };
}

/**
 * CRITICAL SECURITY: Sanitize text content to prevent SQL injection
 * 
 * @param content - Text content to sanitize
 * @param options - Sanitization options
 * @returns Sanitization result with security details
 */
export function sanitizeForSQL(
  content: string,
  options: {
    maxLength?: number;
    allowSpecialChars?: boolean;
    preserveSpaces?: boolean;
  } = {}
): SQLSanitizationResult {
  if (!content || typeof content !== 'string') {
    return {
      sanitized: '',
      originalLength: 0,
      sanitizedLength: 0,
      removedPatterns: [],
      securityRisk: 'none',
      isClean: true
    };
  }

  const originalLength = content.length;
  let sanitized = content;
  const removedPatterns: string[] = [];

  // Step 1: Remove dangerous SQL keywords (replace with safe alternatives)
  for (const keyword of DANGEROUS_SQL_KEYWORDS) {
    const regex = new RegExp(`\\b${keyword}\\b`, 'gi');
    if (regex.test(sanitized)) {
      sanitized = sanitized.replace(regex, '[REMOVED]');
      removedPatterns.push(`KEYWORD: ${keyword}`);
    }
  }

  // Step 2: Remove SQL injection patterns
  for (let i = 0; i < SQL_INJECTION_PATTERNS.length; i++) {
    const pattern = SQL_INJECTION_PATTERNS[i];
    const originalSanitized = sanitized;
    sanitized = sanitized.replace(pattern, (match) => {
      removedPatterns.push(`PATTERN_${i}: ${match}`);
      return '[FILTERED]';
    });
  }

  // Step 3: Character-level sanitization
  if (!options.allowSpecialChars) {
    // Remove potentially dangerous characters
    const dangerousChars = /['"`;\\|&$(){}[\]<>]/g;
    sanitized = sanitized.replace(dangerousChars, (match) => {
      removedPatterns.push(`CHAR: ${match}`);
      return '';
    });
  }

  // Step 4: Length limitation
  if (options.maxLength && sanitized.length > options.maxLength) {
    sanitized = sanitized.substring(0, options.maxLength);
    removedPatterns.push(`LENGTH_TRUNCATED: ${sanitized.length} -> ${options.maxLength}`);
  }

  // Step 5: Whitespace normalization
  if (options.preserveSpaces) {
    sanitized = sanitized.replace(/\s+/g, ' ').trim();
  }

  // Assess security risk
  let securityRisk: 'none' | 'low' | 'medium' | 'high' | 'critical' = 'none';
  if (removedPatterns.some(p => p.includes('KEYWORD'))) {
    securityRisk = 'critical';
  } else if (removedPatterns.length > 5) {
    securityRisk = 'high';
  } else if (removedPatterns.length > 0) {
    securityRisk = 'medium';
  }

  // Log security event if significant sanitization occurred
  if (securityRisk === 'critical' || securityRisk === 'high') {
    logSecurityEvent('sql_injection_sanitized', undefined, {
      originalLength,
      sanitizedLength: sanitized.length,
      removedPatterns: removedPatterns.slice(0, 10),
      securityRisk,
      contentSample: content.substring(0, 50)
    });
  }

  return {
    sanitized,
    originalLength,
    sanitizedLength: sanitized.length,
    removedPatterns,
    securityRisk,
    isClean: removedPatterns.length === 0
  };
}

/**
 * CRITICAL SECURITY: Sanitize JSONB data to prevent injection attacks
 * 
 * @param data - Object to sanitize for JSONB storage
 * @param options - Sanitization options
 * @returns Sanitized object with security details
 */
export function sanitizeJSONB(
  data: any,
  options: {
    maxDepth?: number;
    maxKeys?: number;
    maxStringLength?: number;
    allowedTypes?: string[];
  } = {}
): JSONBSanitizationResult {
  const defaults = {
    maxDepth: 5,
    maxKeys: 50,
    maxStringLength: 1000,
    allowedTypes: ['string', 'number', 'boolean', 'object', 'array']
  };
  
  const opts = { ...defaults, ...options };
  const removedKeys: string[] = [];
  let securityRisk: 'none' | 'low' | 'medium' | 'high' | 'critical' = 'none';

  function sanitizeValue(value: any, depth: number = 0, path: string = ''): any {
    // Depth protection
    if (depth > opts.maxDepth) {
      removedKeys.push(`${path}: DEPTH_LIMIT`);
      securityRisk = securityRisk === 'critical' ? 'critical' : 'high';
      return null;
    }

    // Type validation
    const valueType = Array.isArray(value) ? 'array' : typeof value;
    if (!opts.allowedTypes!.includes(valueType)) {
      removedKeys.push(`${path}: INVALID_TYPE_${valueType}`);
      securityRisk = securityRisk === 'critical' ? 'critical' : 'medium';
      return null;
    }

    switch (valueType) {
      case 'string':
        // SQL injection detection in string values
        const sqlDetection = detectSQLInjection(value);
        if (sqlDetection.detected) {
          if (sqlDetection.risk === 'critical' || sqlDetection.risk === 'high') {
            removedKeys.push(`${path}: SQL_INJECTION_${sqlDetection.risk.toUpperCase()}`);
            securityRisk = 'critical';
            return '[SQL_INJECTION_BLOCKED]';
          }
        }

        // JSONB-specific injection patterns
        for (const pattern of JSONB_INJECTION_PATTERNS) {
          if (pattern.test(value)) {
            removedKeys.push(`${path}: JSONB_INJECTION`);
            securityRisk = securityRisk === 'critical' ? 'critical' : 'high';
            value = value.replace(pattern, '[FILTERED]');
          }
        }

        // Length limitation
        if (value.length > opts.maxStringLength!) {
          removedKeys.push(`${path}: LENGTH_TRUNCATED`);
          value = value.substring(0, opts.maxStringLength!);
        }

        return value;

      case 'number':
        // Validate number safety
        if (!Number.isFinite(value) || Math.abs(value) > Number.MAX_SAFE_INTEGER) {
          removedKeys.push(`${path}: UNSAFE_NUMBER`);
          securityRisk = securityRisk === 'critical' ? 'critical' : 'medium';
          return 0;
        }
        return value;

      case 'boolean':
        return value;

      case 'array':
        return value.map((item: any, index: number) => 
          sanitizeValue(item, depth + 1, `${path}[${index}]`)
        ).filter((item: any) => item !== null);

      case 'object':
        if (value === null) return null;

        const sanitizedObj: any = {};
        const keys = Object.keys(value);

        // Key count protection
        if (keys.length > opts.maxKeys!) {
          removedKeys.push(`${path}: TOO_MANY_KEYS_${keys.length}`);
          securityRisk = securityRisk === 'critical' ? 'critical' : 'high';
          keys.splice(opts.maxKeys!);
        }

        for (const key of keys) {
          // Validate key name
          const cleanKey = String(key).replace(/[^a-zA-Z0-9_]/g, '');
          if (cleanKey !== key || cleanKey.length === 0) {
            removedKeys.push(`${path}.${key}: INVALID_KEY`);
            securityRisk = securityRisk === 'critical' ? 'critical' : 'medium';
            continue;
          }

          // Dangerous key names
          if (['__proto__', 'constructor', 'prototype', 'toString', 'valueOf'].includes(cleanKey)) {
            removedKeys.push(`${path}.${key}: DANGEROUS_KEY`);
            securityRisk = 'critical';
            continue;
          }

          const sanitizedValue = sanitizeValue(value[key], depth + 1, `${path}.${cleanKey}`);
          if (sanitizedValue !== null) {
            sanitizedObj[cleanKey] = sanitizedValue;
          }
        }

        return sanitizedObj;

      default:
        removedKeys.push(`${path}: UNKNOWN_TYPE`);
        return null;
    }
  }

  const originalSize = JSON.stringify(data).length;
  const sanitized = sanitizeValue(data);
  const sanitizedSize = JSON.stringify(sanitized).length;

  // Log critical security events
  if (securityRisk === 'critical' || securityRisk === 'high') {
    logSecurityEvent('jsonb_injection_sanitized', undefined, {
      originalSize,
      sanitizedSize,
      removedKeys: removedKeys.slice(0, 10),
      securityRisk,
      dataSample: JSON.stringify(data).substring(0, 100)
    });
  }

  return {
    sanitized: sanitized || {},
    originalSize,
    sanitizedSize,
    removedKeys,
    securityRisk,
    isClean: removedKeys.length === 0
  };
}

/**
 * SECURITY UTILITY: Validate that queries use parameterized approach
 * 
 * @param queryText - SQL query text to validate
 * @returns Validation result with security recommendations
 */
export function validateParameterizedQuery(queryText: string): {
  isParameterized: boolean;
  recommendations: string[];
  riskLevel: 'low' | 'medium' | 'high';
} {
  const recommendations: string[] = [];
  let riskLevel: 'low' | 'medium' | 'high' = 'low';

  // Check for string concatenation patterns
  if (queryText.includes('${') || queryText.includes('"+') || queryText.includes("'+")) {
    recommendations.push('Avoid string concatenation in SQL queries');
    riskLevel = 'high';
  }

  // Check for Supabase client usage (recommended)
  const hasSupabaseClient = queryText.includes('.from(') || queryText.includes('.select(') || queryText.includes('.insert(');
  if (!hasSupabaseClient) {
    recommendations.push('Use Supabase client methods instead of raw SQL');
    riskLevel = riskLevel === 'high' ? 'high' : 'medium';
  }

  return {
    isParameterized: recommendations.length === 0,
    recommendations,
    riskLevel
  };
}

/**
 * PHASE 2 SECURITY: Real-time SQL injection monitoring with automatic blocking
 */
export class SQLInjectionMonitor {
  private static suspiciousIPStore = new Map<string, { count: number; lastSeen: number }>();
  private static blockedIPStore = new Set<string>();
  
  // Configuration
  private static readonly MAX_VIOLATIONS_PER_HOUR = 5;
  private static readonly BLOCK_DURATION_MS = 60 * 60 * 1000; // 1 hour
  private static readonly CLEANUP_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes

  /**
   * Monitor and potentially block IP addresses showing SQL injection patterns
   */
  static async monitorAndBlock(
    content: string,
    request: Request,
    context: string = 'unknown'
  ): Promise<{ allowed: boolean; reason?: string }> {
    const clientIP = this.extractClientIP(request);
    const userAgent = request.headers.get('user-agent') || 'unknown';
    
    // Check if IP is already blocked
    if (this.blockedIPStore.has(clientIP)) {
      await logSecurityEvent('sql_injection_blocked_ip_attempt', undefined, {
        clientIP,
        userAgent,
        context,
        reason: 'IP_PREVIOUSLY_BLOCKED'
      });
      
      return {
        allowed: false,
        reason: 'IP address blocked due to repeated SQL injection attempts'
      };
    }

    // Detect SQL injection
    const detection = detectSQLInjection(content);
    
    if (detection.detected) {
      // Log the attempt
      await logSecurityEvent('sql_injection_attempt', undefined, {
        clientIP,
        userAgent,
        context,
        patterns: detection.patterns.slice(0, 3),
        riskLevel: detection.risk,
        contentSample: content.substring(0, 50)
      });

      // Track suspicious activity
      const now = Date.now();
      const record = this.suspiciousIPStore.get(clientIP) || { count: 0, lastSeen: 0 };
      
      // Reset count if more than an hour has passed
      if (now - record.lastSeen > this.BLOCK_DURATION_MS) {
        record.count = 0;
      }
      
      record.count++;
      record.lastSeen = now;
      this.suspiciousIPStore.set(clientIP, record);

      // Block IP if too many violations
      if (record.count >= this.MAX_VIOLATIONS_PER_HOUR) {
        this.blockedIPStore.add(clientIP);
        
        await logSecurityEvent('sql_injection_ip_blocked', undefined, {
          clientIP,
          userAgent,
          context,
          violationCount: record.count,
          reason: 'EXCEEDED_VIOLATION_THRESHOLD'
        });

        // Schedule IP unblock
        setTimeout(() => {
          this.blockedIPStore.delete(clientIP);
          this.suspiciousIPStore.delete(clientIP);
        }, this.BLOCK_DURATION_MS);

        return {
          allowed: false,
          reason: 'IP address blocked due to repeated SQL injection attempts'
        };
      }

      // For high/critical risk, block immediately
      if (detection.risk === 'critical' || detection.risk === 'high') {
        return {
          allowed: false,
          reason: 'SQL injection attempt detected'
        };
      }
    }

    return { allowed: true };
  }

  /**
   * Extract client IP from request headers
   */
  private static extractClientIP(request: Request): string {
    const forwardedFor = request.headers.get('x-forwarded-for');
    const realIP = request.headers.get('x-real-ip');
    const cfConnectingIP = request.headers.get('cf-connecting-ip');
    
    return cfConnectingIP || realIP || forwardedFor?.split(',')[0]?.trim() || 'unknown';
  }

  /**
   * Get current monitoring statistics
   */
  static getMonitoringStats(): {
    suspiciousIPs: number;
    blockedIPs: number;
    totalViolations: number;
  } {
    const totalViolations = Array.from(this.suspiciousIPStore.values())
      .reduce((sum, record) => sum + record.count, 0);

    return {
      suspiciousIPs: this.suspiciousIPStore.size,
      blockedIPs: this.blockedIPStore.size,
      totalViolations
    };
  }

  /**
   * Manual cleanup of old entries
   */
  static cleanup(): void {
    const now = Date.now();
    const cutoff = now - this.BLOCK_DURATION_MS;

    for (const [ip, record] of this.suspiciousIPStore.entries()) {
      if (record.lastSeen < cutoff) {
        this.suspiciousIPStore.delete(ip);
      }
    }
  }
}

/**
 * PHASE 2 SECURITY: Enhanced parameterized query validation
 */
export function validateQuerySecurity(
  queryText: string,
  parameters: any[] = []
): {
  isSecure: boolean;
  vulnerabilities: string[];
  recommendations: string[];
  riskScore: number; // 0-100
} {
  const vulnerabilities: string[] = [];
  const recommendations: string[] = [];
  let riskScore = 0;

  // Check for SQL injection patterns
  const injectionResult = detectSQLInjection(queryText);
  if (injectionResult.detected) {
    vulnerabilities.push(`SQL injection patterns detected: ${injectionResult.patterns.join(', ')}`);
    riskScore += injectionResult.risk === 'critical' ? 50 : 
                 injectionResult.risk === 'high' ? 35 :
                 injectionResult.risk === 'medium' ? 20 : 10;
  }

  // Check parameter usage
  const parameterPlaceholders = (queryText.match(/\$\d+|\?/g) || []).length;
  if (parameters.length !== parameterPlaceholders) {
    vulnerabilities.push(`Parameter count mismatch: ${parameters.length} provided, ${parameterPlaceholders} expected`);
    riskScore += 25;
  }

  // Check for dynamic SQL construction
  if (queryText.includes('${') || queryText.includes('"+') || queryText.includes("'+")) {
    vulnerabilities.push('Dynamic SQL construction detected');
    recommendations.push('Use parameterized queries instead of string concatenation');
    riskScore += 30;
  }

  // Check for unescaped user input
  if (queryText.includes("'") && !queryText.match(/\$\d+/)) {
    vulnerabilities.push('Potential unescaped string literals');
    recommendations.push('Use parameter placeholders for all user input');
    riskScore += 20;
  }

  // Security score assessment
  if (riskScore === 0) {
    recommendations.push('Query appears secure');
  } else if (riskScore < 30) {
    recommendations.push('Minor security improvements recommended');
  } else if (riskScore < 60) {
    recommendations.push('Moderate security vulnerabilities detected');
  } else {
    recommendations.push('Critical security vulnerabilities detected - immediate action required');
  }

  return {
    isSecure: riskScore < 30,
    vulnerabilities,
    recommendations,
    riskScore: Math.min(100, riskScore)
  };
}

/**
 * PHASE 2 SECURITY: Advanced JSONB sanitization with schema validation
 */
export function sanitizeJSONBWithSchema(
  data: any,
  schema: {
    allowedKeys?: string[];
    requiredKeys?: string[];
    keyPatterns?: RegExp[];
    valueValidators?: Record<string, (value: any) => boolean>;
  } = {}
): JSONBSanitizationResult & {
  schemaViolations: string[];
} {
  const baseResult = sanitizeJSONB(data);
  const schemaViolations: string[] = [];

  if (schema.allowedKeys) {
    const dataKeys = Object.keys(baseResult.sanitized);
    const unauthorizedKeys = dataKeys.filter(key => !schema.allowedKeys!.includes(key));
    if (unauthorizedKeys.length > 0) {
      schemaViolations.push(`Unauthorized keys: ${unauthorizedKeys.join(', ')}`);
      // Remove unauthorized keys
      for (const key of unauthorizedKeys) {
        delete (baseResult.sanitized as any)[key];
      }
    }
  }

  if (schema.requiredKeys) {
    const dataKeys = Object.keys(baseResult.sanitized);
    const missingKeys = schema.requiredKeys.filter(key => !dataKeys.includes(key));
    if (missingKeys.length > 0) {
      schemaViolations.push(`Missing required keys: ${missingKeys.join(', ')}`);
    }
  }

  return {
    ...baseResult,
    schemaViolations
  };
}

// Export constants for testing
export const SQL_SECURITY_CONSTANTS = {
  SQL_INJECTION_PATTERNS,
  DANGEROUS_SQL_KEYWORDS,
  JSONB_INJECTION_PATTERNS
};