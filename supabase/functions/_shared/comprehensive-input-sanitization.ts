/**
 * COMPREHENSIVE INPUT SANITIZATION MIDDLEWARE PIPELINE
 * 
 * Advanced sanitization system that prevents XSS, SQL injection, and other 
 * input-based attacks while maintaining data integrity and user experience.
 * 
 * Features:
 * - Multi-layer sanitization pipeline
 * - XSS prevention with whitelist approach
 * - SQL injection detection and blocking
 * - Content Security Policy violation detection
 * - Performance-optimized with caching
 * - Detailed logging for security monitoring
 */

import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { getEnhancedCache, StellarCacheKeys } from './redis-enhanced.ts';
import { getPerformanceMonitor } from './performance-monitor.ts';

// ============================================================================
// SANITIZATION CONFIGURATION
// ============================================================================

interface SanitizationConfig {
  // XSS Prevention
  allowedHTMLTags: string[];
  allowedAttributes: string[];
  maxStringLength: number;
  
  // Content filtering
  profanityFilter: boolean;
  urlValidation: boolean;
  
  // Performance
  cacheResults: boolean;
  cacheTTL: number;
  
  // Logging
  logSuspiciousPatterns: boolean;
  logAllSanitization: boolean;
}

const DEFAULT_CONFIG: SanitizationConfig = {
  allowedHTMLTags: [], // No HTML allowed by default
  allowedAttributes: [],
  maxStringLength: 10000,
  profanityFilter: true,
  urlValidation: true,
  cacheResults: true,
  cacheTTL: 3600, // 1 hour
  logSuspiciousPatterns: true,
  logAllSanitization: false,
};

// Load configuration from environment
const SANITIZATION_CONFIG: SanitizationConfig = {
  ...DEFAULT_CONFIG,
  allowedHTMLTags: (Deno.env.get('SANITIZATION_ALLOWED_TAGS') || '').split(',').filter(t => t.length > 0),
  maxStringLength: parseInt(Deno.env.get('SANITIZATION_MAX_LENGTH') || '10000', 10),
  profanityFilter: Deno.env.get('SANITIZATION_PROFANITY_FILTER') !== 'false',
  urlValidation: Deno.env.get('SANITIZATION_URL_VALIDATION') !== 'false',
  cacheResults: Deno.env.get('SANITIZATION_CACHE_RESULTS') !== 'false',
  logSuspiciousPatterns: Deno.env.get('SANITIZATION_LOG_SUSPICIOUS') !== 'false',
};

// ============================================================================
// THREAT DETECTION PATTERNS
// ============================================================================

/**
 * Comprehensive threat detection patterns
 */
const THREAT_PATTERNS = {
  // XSS patterns (more comprehensive than basic HTML removal)
  xss: [
    /<script[\s\S]*?>[\s\S]*?<\/script>/gi,
    /<iframe[\s\S]*?>[\s\S]*?<\/iframe>/gi,
    /<object[\s\S]*?>[\s\S]*?<\/object>/gi,
    /<embed[\s\S]*?>/gi,
    /<link[\s\S]*?>/gi,
    /<meta[\s\S]*?>/gi,
    /javascript:/gi,
    /vbscript:/gi,
    /data:text\/html/gi,
    /onload\s*=/gi,
    /onerror\s*=/gi,
    /onclick\s*=/gi,
    /onmouseover\s*=/gi,
    /onfocus\s*=/gi,
    /onblur\s*=/gi,
    /onchange\s*=/gi,
    /onsubmit\s*=/gi,
    /<img[^>]*src\s*=\s*[\"']?javascript:/gi,
    /<img[^>]*src\s*=\s*[\"']?data:/gi,
    /expression\s*\(/gi,
    /@import/gi,
    /url\s*\(/gi,
    /\*\/.*?\/\*/gs,
  ],

  // SQL injection patterns (enhanced)
  sqlInjection: [
    /(\bunion\s+(all\s+)?select\b)/gi,
    /(\bdrop\s+(table|database|schema|index|view|trigger|function)\b)/gi,
    /(\bdelete\s+from\b)/gi,
    /(\binsert\s+into\b)/gi,
    /(\bupdate\s+.*\s+set\b)/gi,
    /(\bselect\s+.*\s+from\b)/gi,
    /(\balter\s+(table|database|schema)\b)/gi,
    /(\bcreate\s+(table|database|schema|index|view|trigger|function)\b)/gi,
    /(\btruncate\s+table\b)/gi,
    /(;|\-\-|\#|\/\*|\*\/)/g,
    /(\bor\s+1\s*[=<>!]+\s*1\b)/gi,
    /(\band\s+1\s*[=<>!]+\s*1\b)/gi,
    /(\bor\s+true\b|\band\s+false\b)/gi,
    /(\bor\s+'[^']*'\s*=\s*'[^']*')/gi,
    /(\b(exec|execute|sp_|xp_)\b)/gi,
    /(\binformation_schema\b)/gi,
    /(\bload_file\s*\(.*\))/gi,
    /(\binto\s+(outfile|dumpfile)\b)/gi,
    /(\bwaitfor\s+delay\b)/gi,
    /(\bbenchmark\s*\(.*\))/gi,
    /(\bsleep\s*\(.*\))/gi,
  ],

  // Command injection patterns
  commandInjection: [
    /(\b(cat|ls|ps|id|pwd|whoami|uname|which|find|grep)\s)/gi,
    /(\$\{.*\})/g,
    /(\$\(.*\))/g,
    /([\|;&`])/g,
    /(&&|\|\|)/g,
    /(\.\.(\/|\\\))/g,
    /(\/etc\/passwd)/gi,
    /(\/proc\/)/gi,
    /(cmd\.exe|powershell\.exe|sh|bash)/gi,
  ],

  // Path traversal patterns
  pathTraversal: [
    /\.\.(\/|\\)/g,
    /(\/|\\)\.\.(\/|\\)/g,
    /%2e%2e/gi,
    /%252e%252e/gi,
    /\.\.%2f/gi,
    /\.\.%5c/gi,
    /%c0%ae%c0%ae/gi,
    /%c1%9c/gi,
  ],

  // Code injection patterns
  codeInjection: [
    /(eval\s*\()/gi,
    /(function\s*\()/gi,
    /(new\s+Function)/gi,
    /(setTimeout\s*\()/gi,
    /(setInterval\s*\()/gi,
    /(document\.write)/gi,
    /(innerHTML\s*=)/gi,
    /(outerHTML\s*=)/gi,
  ],

  // Header injection patterns
  headerInjection: [
    /(\r\n|\n|\r)/g,
    /%0d%0a/gi,
    /%0a/gi,
    /%0d/gi,
    /\x00/g,
    /Content-Type:/gi,
    /Location:/gi,
    /Set-Cookie:/gi,
  ],
};

// ============================================================================
// SANITIZATION FUNCTIONS
// ============================================================================

/**
 * Comprehensive threat assessment result
 */
interface ThreatAssessment {
  isSafe: boolean;
  threatsFound: string[];
  riskLevel: 'low' | 'medium' | 'high' | 'critical';
  sanitizedValue: string;
  originalLength: number;
  sanitizedLength: number;
  processingTime: number;
}

/**
 * Assess threats in input string
 */
function assessThreats(input: string): ThreatAssessment {
  const startTime = performance.now();
  let sanitized = input;
  const threats: string[] = [];
  let riskLevel: 'low' | 'medium' | 'high' | 'critical' = 'low';

  // Check each threat category
  for (const [category, patterns] of Object.entries(THREAT_PATTERNS)) {
    for (const pattern of patterns) {
      if (pattern.test(input)) {
        threats.push(category);
        
        // Update risk level based on threat type
        switch (category) {
          case 'sqlInjection':
          case 'commandInjection':
            riskLevel = 'critical';
            break;
          case 'xss':
          case 'codeInjection':
            if (riskLevel !== 'critical') riskLevel = 'high';
            break;
          case 'pathTraversal':
          case 'headerInjection':
            if (riskLevel === 'low') riskLevel = 'medium';
            break;
        }
        
        // Remove or replace malicious content
        sanitized = sanitized.replace(pattern, '');
      }
    }
  }

  const processingTime = performance.now() - startTime;

  return {
    isSafe: threats.length === 0,
    threatsFound: [...new Set(threats)], // Remove duplicates
    riskLevel,
    sanitizedValue: sanitized,
    originalLength: input.length,
    sanitizedLength: sanitized.length,
    processingTime,
  };
}

/**
 * Advanced HTML sanitization with whitelist approach
 */
function sanitizeHTML(input: string, allowedTags: string[] = []): string {
  let sanitized = input;

  // If no tags are allowed, remove all HTML
  if (allowedTags.length === 0) {
    sanitized = sanitized.replace(/<[^>]*>/g, '');
  } else {
    // Remove all tags except allowed ones
    const tagRegex = /<\/?([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>/g;
    sanitized = sanitized.replace(tagRegex, (match, tagName) => {
      return allowedTags.includes(tagName.toLowerCase()) ? match : '';
    });
  }

  // Remove HTML entities that could be used for XSS
  const dangerousEntities = [
    /&javascript:/gi,
    /&vbscript:/gi,
    /&#x6A;&#x61;&#x76;&#x61;&#x73;&#x63;&#x72;&#x69;&#x70;&#x74;/gi,
    /&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;/gi,
  ];

  for (const entity of dangerousEntities) {
    sanitized = sanitized.replace(entity, '');
  }

  return sanitized.trim();
}

/**
 * URL validation and sanitization
 */
function sanitizeURL(url: string): { isValid: boolean; sanitized: string; threats: string[] } {
  const threats: string[] = [];
  let sanitized = url.trim();

  try {
    const urlObj = new URL(sanitized);
    
    // Check for suspicious protocols
    const dangerousProtocols = ['javascript:', 'vbscript:', 'data:', 'file:', 'ftp:'];
    if (dangerousProtocols.some(proto => urlObj.protocol.includes(proto))) {
      threats.push('dangerous_protocol');
      return { isValid: false, sanitized: '', threats };
    }

    // Check for suspicious domains
    const suspiciousDomains = [
      'localhost', '127.0.0.1', '0.0.0.0', '::1',
      '10.', '172.16.', '192.168.', // Private IP ranges
    ];
    
    if (suspiciousDomains.some(domain => urlObj.hostname.includes(domain))) {
      threats.push('suspicious_domain');
    }

    // Check for path traversal in URL
    if (THREAT_PATTERNS.pathTraversal.some(pattern => pattern.test(urlObj.pathname))) {
      threats.push('path_traversal');
      return { isValid: false, sanitized: '', threats };
    }

    // Reconstruct clean URL
    sanitized = `${urlObj.protocol}//${urlObj.hostname}${urlObj.port ? ':' + urlObj.port : ''}${urlObj.pathname}${urlObj.search}`;
    
    return { 
      isValid: threats.length === 0, 
      sanitized: sanitized.substring(0, 2083), // Max URL length
      threats 
    };

  } catch (error) {
    threats.push('invalid_format');
    return { isValid: false, sanitized: '', threats };
  }
}

/**
 * Content-based profanity filtering (basic implementation)
 */
function filterProfanity(input: string): { filtered: string; detectedWords: string[] } {
  // Basic profanity word list (in production, use a comprehensive library)
  const profanityWords = [
    // This would be loaded from a comprehensive database in production
    'spam', 'scam', 'fake', 'bot', // Common dating app issues
  ];

  let filtered = input;
  const detected: string[] = [];

  for (const word of profanityWords) {
    const regex = new RegExp(`\\b${word}\\b`, 'gi');
    if (regex.test(filtered)) {
      detected.push(word);
      filtered = filtered.replace(regex, '*'.repeat(word.length));
    }
  }

  return { filtered, detectedWords: detected };
}

// ============================================================================
// MAIN SANITIZATION PIPELINE
// ============================================================================

/**
 * Comprehensive input sanitization result
 */
export interface SanitizationResult {
  success: boolean;
  originalValue: string;
  sanitizedValue: string;
  threats: {
    found: string[];
    riskLevel: 'low' | 'medium' | 'high' | 'critical';
    details: Record<string, unknown>;
  };
  modifications: {
    lengthChanged: boolean;
    contentChanged: boolean;
    urlsValidated: number;
    profanityFiltered: string[];
  };
  performance: {
    processingTime: number;
    fromCache: boolean;
  };
  metadata: {
    timestamp: string;
    config: Partial<SanitizationConfig>;
  };
}

/**
 * Main sanitization pipeline function
 */
export async function sanitizeInput(
  input: unknown,
  options: Partial<SanitizationConfig> = {}
): Promise<SanitizationResult> {
  const startTime = performance.now();
  const config = { ...SANITIZATION_CONFIG, ...options };
  const cache = getEnhancedCache();
  const monitor = getPerformanceMonitor();

  // Convert input to string safely
  let stringInput: string;
  if (typeof input === 'string') {
    stringInput = input;
  } else if (input === null || input === undefined) {
    stringInput = '';
  } else {
    stringInput = String(input);
  }

  // Check cache first
  let fromCache = false;
  if (config.cacheResults && stringInput.length < 1000) { // Cache smaller inputs
    const cacheKey = StellarCacheKeys.rateLimit(`sanitization:${btoa(stringInput).substring(0, 50)}`, 'cache');
    const cached = await cache.get<SanitizationResult>(cacheKey);
    
    if (cached) {
      fromCache = true;
      cached.performance.fromCache = true;
      return cached;
    }
  }

  // Initialize result
  const result: SanitizationResult = {
    success: true,
    originalValue: stringInput,
    sanitizedValue: stringInput,
    threats: {
      found: [],
      riskLevel: 'low',
      details: {},
    },
    modifications: {
      lengthChanged: false,
      contentChanged: false,
      urlsValidated: 0,
      profanityFiltered: [],
    },
    performance: {
      processingTime: 0,
      fromCache,
    },
    metadata: {
      timestamp: new Date().toISOString(),
      config: {
        maxStringLength: config.maxStringLength,
        profanityFilter: config.profanityFilter,
        urlValidation: config.urlValidation,
      },
    },
  };

  try {
    let sanitized = stringInput;
    const originalLength = sanitized.length;

    // Step 1: Length validation
    if (sanitized.length > config.maxStringLength) {
      sanitized = sanitized.substring(0, config.maxStringLength);
      result.modifications.lengthChanged = true;
      result.modifications.contentChanged = true;
    }

    // Step 2: Threat assessment
    const threatAssessment = assessThreats(sanitized);
    result.threats.found = threatAssessment.threatsFound;
    result.threats.riskLevel = threatAssessment.riskLevel;
    result.threats.details = {
      originalLength: threatAssessment.originalLength,
      sanitizedLength: threatAssessment.sanitizedLength,
      processingTime: threatAssessment.processingTime,
    };

    if (!threatAssessment.isSafe) {
      sanitized = threatAssessment.sanitizedValue;
      result.modifications.contentChanged = true;
      result.success = false; // Mark as unsuccessful if threats were found
    }

    // Step 3: HTML sanitization
    const htmlSanitized = sanitizeHTML(sanitized, config.allowedHTMLTags);
    if (htmlSanitized !== sanitized) {
      sanitized = htmlSanitized;
      result.modifications.contentChanged = true;
    }

    // Step 4: URL validation (if applicable)
    const urlRegex = /https?:\/\/[^\s]+/g;
    const urls = sanitized.match(urlRegex) || [];
    
    for (const url of urls) {
      const urlValidation = sanitizeURL(url);
      result.modifications.urlsValidated++;
      
      if (!urlValidation.isValid) {
        sanitized = sanitized.replace(url, urlValidation.sanitized);
        result.modifications.contentChanged = true;
        result.threats.found.push(...urlValidation.threats);
      }
    }

    // Step 5: Profanity filtering
    if (config.profanityFilter) {
      const profanityResult = filterProfanity(sanitized);
      if (profanityResult.detectedWords.length > 0) {
        sanitized = profanityResult.filtered;
        result.modifications.profanityFiltered = profanityResult.detectedWords;
        result.modifications.contentChanged = true;
      }
    }

    // Step 6: Final validation
    result.sanitizedValue = sanitized;
    result.modifications.lengthChanged = result.modifications.lengthChanged || (sanitized.length !== originalLength);
    
    // Update processing time
    result.performance.processingTime = performance.now() - startTime;

    // Cache result for future use
    if (config.cacheResults && stringInput.length < 1000) {
      const cacheKey = StellarCacheKeys.rateLimit(`sanitization:${btoa(stringInput).substring(0, 50)}`, 'cache');
      await cache.set(cacheKey, result, { ttl: config.cacheTTL });
    }

    // Log suspicious patterns if configured
    if (config.logSuspiciousPatterns && (result.threats.found.length > 0 || result.threats.riskLevel !== 'low')) {
      monitor.recordMetric({
        name: 'input_sanitization.threat_detected',
        value: result.threats.found.length,
        unit: 'count',
        tags: {
          risk_level: result.threats.riskLevel,
          threats: result.threats.found.join(','),
          content_changed: result.modifications.contentChanged.toString(),
        },
        metadata: {
          original_length: originalLength,
          sanitized_length: sanitized.length,
          processing_time: result.performance.processingTime,
        },
      });
    }

    return result;

  } catch (error) {
    // Handle sanitization errors gracefully
    result.success = false;
    result.threats.riskLevel = 'critical';
    result.threats.found.push('sanitization_error');
    result.threats.details = { error: error.message };
    result.performance.processingTime = performance.now() - startTime;

    monitor.recordMetric({
      name: 'input_sanitization.error',
      value: 1,
      unit: 'count',
      tags: {
        error: error.message.substring(0, 50),
      },
    });

    return result;
  }
}

// ============================================================================
// ZOD INTEGRATION
// ============================================================================

/**
 * Create a Zod transform that applies sanitization
 */
export function createSanitizedString(options: Partial<SanitizationConfig> = {}) {
  return z.string().transform(async (val, ctx) => {
    const result = await sanitizeInput(val, options);
    
    // Add issues for high-risk threats
    if (result.threats.riskLevel === 'critical' || result.threats.riskLevel === 'high') {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `Input contains security threats: ${result.threats.found.join(', ')}`,
        path: [],
      });
    }
    
    return result.sanitizedValue;
  });
}

/**
 * Middleware for Edge Functions that applies sanitization to request bodies
 */
export function createSanitizationMiddleware(options: Partial<SanitizationConfig> = {}) {
  return async (request: Request): Promise<{
    success: boolean;
    sanitizedData?: unknown;
    response?: Response;
    threats?: string[];
  }> => {
    try {
      const contentType = request.headers.get('content-type') || '';
      
      if (!contentType.includes('application/json')) {
        return { success: true, sanitizedData: null };
      }

      const rawData = await request.json();
      const sanitizedData = await deepSanitizeObject(rawData, options);

      return {
        success: true,
        sanitizedData,
      };

    } catch (error) {
      const errorResponse = new Response(
        JSON.stringify({
          success: false,
          error: {
            code: 'SANITIZATION_ERROR',
            message: 'Failed to sanitize request data',
            details: { error: error.message },
          },
          metadata: {
            timestamp: new Date().toISOString(),
            requestId: `sanitize_err_${Date.now()}`,
          },
        }),
        {
          status: 400,
          headers: {
            'Content-Type': 'application/json',
            'Cache-Control': 'no-store',
          },
        }
      );

      return {
        success: false,
        response: errorResponse,
      };
    }
  };
}

/**
 * Recursively sanitize all string values in an object
 */
async function deepSanitizeObject(
  obj: unknown,
  options: Partial<SanitizationConfig> = {},
  depth: number = 0
): Promise<unknown> {
  // Prevent infinite recursion
  if (depth > 10) {
    return obj;
  }

  if (typeof obj === 'string') {
    const result = await sanitizeInput(obj, options);
    return result.sanitizedValue;
  }

  if (Array.isArray(obj)) {
    return Promise.all(obj.map(item => deepSanitizeObject(item, options, depth + 1)));
  }

  if (obj && typeof obj === 'object') {
    const sanitized: Record<string, unknown> = {};
    
    for (const [key, value] of Object.entries(obj)) {
      // Sanitize the key as well
      const sanitizedKey = (await sanitizeInput(key, options)).sanitizedValue;
      sanitized[sanitizedKey] = await deepSanitizeObject(value, options, depth + 1);
    }
    
    return sanitized;
  }

  return obj;
}

// ============================================================================
// MONITORING AND HEALTH
// ============================================================================

/**
 * Get sanitization system health and metrics
 */
export async function getSanitizationSystemHealth(): Promise<{
  status: 'healthy' | 'degraded';
  metrics: {
    threatsDetected: number;
    processingTime: number;
    cacheHitRate: number;
  };
  configuration: SanitizationConfig;
}> {
  const cache = getEnhancedCache();
  const monitor = getPerformanceMonitor();

  // Test sanitization performance
  const testInput = 'This is a <script>alert("test")</script> test input';
  const startTime = performance.now();
  const result = await sanitizeInput(testInput);
  const processingTime = performance.now() - startTime;

  return {
    status: processingTime < 50 ? 'healthy' : 'degraded', // Should process in <50ms
    metrics: {
      threatsDetected: result.threats.found.length,
      processingTime,
      cacheHitRate: result.performance.fromCache ? 1 : 0,
    },
    configuration: SANITIZATION_CONFIG,
  };
}

// ============================================================================
// PHASE 5 SECURITY: ADVANCED INPUT SANITIZATION ENHANCEMENTS
// ============================================================================

// Enhanced threat detection patterns for advanced attacks
const ADVANCED_THREAT_PATTERNS = {
  // Zero-day exploit patterns
  zeroDay: [
    /eval\s*\(\s*[^)]*\)/gi,
    /setTimeout\s*\(\s*[^)]*\)/gi,
    /setInterval\s*\(\s*[^)]*\)/gi,
    /new\s+Function\s*\(/gi,
    /\\x[0-9a-fA-F]{2}/g, // Hex-encoded characters
    /\\u[0-9a-fA-F]{4}/g, // Unicode escape sequences
  ],

  // Advanced XSS vectors
  advancedXSS: [
    /data:text\/html/gi,
    /data:application\/javascript/gi,
    /vbscript:/gi,
    /mhtml:/gi,
    /javascript&colon;/gi,
    /&#[0-9]+;/g, // HTML entities
    /&amp;#[0-9]+;/g, // Double-encoded entities
    /<svg[^>]*onload/gi,
    /<math[^>]*href/gi,
  ],

  // Protocol smuggling
  protocolSmuggling: [
    /jar:http/gi,
    /jar:https/gi,
    /view-source:/gi,
    /chrome-extension:/gi,
    /moz-extension:/gi,
    /ms-appx:/gi,
  ],

  // Template injection
  templateInjection: [
    /\{\{.*\}\}/g, // Handlebars/Angular
    /\{%.*%\}/g, // Jinja2/Django
    /<%.*%>/g, // JSP/ASP
    /\$\{.*\}/g, // Expression Language
  ],

  // Command injection
  commandInjection: [
    /;\s*cat\s+/gi,
    /;\s*ls\s+/gi,
    /;\s*ps\s+/gi,
    /;\s*id\s*$/gi,
    /\|\s*cat\s+/gi,
    /&&\s*cat\s+/gi,
    /`[^`]*`/g, // Backtick command substitution
    /\$\([^)]*\)/g, // Command substitution
  ],
};

/**
 * Advanced Content Analysis Engine for sophisticated threat detection
 */
export class AdvancedContentAnalyzer {
  private static suspiciousPhrases = [
    // Social engineering
    'click here to verify', 'verify your account', 'suspended account', 
    'urgent action required', 'limited time offer', 'act now',
    
    // Phishing indicators
    'update payment information', 'confirm your identity', 'security alert',
    'unusual activity detected', 'account will be closed',
    
    // Malware indicators
    'download now', 'install this', 'run this file', 'double click to open',
    
    // Cryptocurrency scams
    'bitcoin giveaway', 'crypto investment', 'guaranteed returns',
    'double your bitcoin', 'send bitcoin to'
  ];

  /**
   * Analyze content for advanced security threats
   */
  static analyzeAdvancedThreats(content: string): {
    threats: string[];
    riskScore: number;
    categories: string[];
    recommendations: string[];
  } {
    const threats: string[] = [];
    const categories = new Set<string>();
    let riskScore = 0;

    // Check each threat category
    for (const [category, patterns] of Object.entries(ADVANCED_THREAT_PATTERNS)) {
      for (const pattern of patterns) {
        const matches = content.match(pattern);
        if (matches) {
          threats.push(`${category}: ${matches[0]}`);
          categories.add(category);
          riskScore += this.getCategoryRiskScore(category);
        }
      }
    }

    // Check suspicious phrases
    const lowerContent = content.toLowerCase();
    for (const phrase of this.suspiciousPhrases) {
      if (lowerContent.includes(phrase.toLowerCase())) {
        threats.push(`suspicious_phrase: ${phrase}`);
        categories.add('social_engineering');
        riskScore += 10;
      }
    }

    // Generate recommendations
    const recommendations = this.generateSecurityRecommendations(categories);

    return {
      threats,
      riskScore: Math.min(100, riskScore),
      categories: Array.from(categories),
      recommendations
    };
  }

  private static getCategoryRiskScore(category: string): number {
    const riskScores: Record<string, number> = {
      zeroDay: 50,
      advancedXSS: 40,
      protocolSmuggling: 30,
      templateInjection: 35,
      commandInjection: 50
    };
    return riskScores[category] || 20;
  }

  private static generateSecurityRecommendations(categories: Set<string>): string[] {
    const recommendations: string[] = [];

    if (categories.has('zeroDay')) {
      recommendations.push('Block content immediately - potential zero-day exploit');
    }
    if (categories.has('advancedXSS')) {
      recommendations.push('Strip all HTML and JavaScript content');
    }
    if (categories.has('commandInjection')) {
      recommendations.push('Validate against OS command patterns');
    }
    if (categories.has('social_engineering')) {
      recommendations.push('Flag for manual review - potential social engineering');
    }

    if (recommendations.length === 0) {
      recommendations.push('Continue with standard sanitization');
    }

    return recommendations;
  }
}

/**
 * Enhanced Multi-Layer Sanitization Pipeline
 */
export class EnhancedSanitizationPipeline {
  /**
   * Process content through advanced multi-layer sanitization
   */
  static async sanitizeWithAdvancedPipeline(
    content: string,
    context: 'message' | 'profile' | 'search' | 'filename' | 'general' = 'general'
  ): Promise<{
    sanitized: string;
    originalLength: number;
    sanitizedLength: number;
    advancedThreats: string[];
    pipelineSteps: string[];
    riskAssessment: {
      score: number;
      level: 'low' | 'medium' | 'high' | 'critical';
      categories: string[];
    };
    isClean: boolean;
    processingTime: number;
  }> {
    const startTime = performance.now();
    const pipelineSteps: string[] = [];
    let workingContent = content;
    const advancedThreats: string[] = [];

    try {
      // Layer 1: Advanced threat detection
      pipelineSteps.push('threat_detection');
      const threatAnalysis = AdvancedContentAnalyzer.analyzeAdvancedThreats(workingContent);
      advancedThreats.push(...threatAnalysis.threats);

      // Block critical threats immediately
      if (threatAnalysis.riskScore > 80) {
        return {
          sanitized: '[BLOCKED - HIGH RISK CONTENT]',
          originalLength: content.length,
          sanitizedLength: 29,
          advancedThreats,
          pipelineSteps,
          riskAssessment: {
            score: threatAnalysis.riskScore,
            level: 'critical',
            categories: threatAnalysis.categories
          },
          isClean: false,
          processingTime: performance.now() - startTime
        };
      }

      // Layer 2: Encoding normalization
      pipelineSteps.push('encoding_normalization');
      workingContent = this.normalizeEncoding(workingContent);

      // Layer 3: Content filtering
      pipelineSteps.push('content_filtering');
      workingContent = this.filterDangerousContent(workingContent, threatAnalysis.categories);

      // Layer 4: Structural validation
      pipelineSteps.push('structural_validation');
      workingContent = this.validateStructure(workingContent, context);

      // Layer 5: Semantic analysis
      pipelineSteps.push('semantic_analysis');
      const semanticResult = this.performSemanticAnalysis(workingContent, context);
      workingContent = semanticResult.content;

      // Layer 6: Final cleanup
      pipelineSteps.push('final_cleanup');
      workingContent = this.finalCleanup(workingContent);

      // Determine risk level
      const riskLevel = this.assessRiskLevel(threatAnalysis.riskScore);

      return {
        sanitized: workingContent,
        originalLength: content.length,
        sanitizedLength: workingContent.length,
        advancedThreats,
        pipelineSteps,
        riskAssessment: {
          score: threatAnalysis.riskScore,
          level: riskLevel,
          categories: threatAnalysis.categories
        },
        isClean: advancedThreats.length === 0,
        processingTime: performance.now() - startTime
      };

    } catch (error) {
      // Emergency fallback
      return {
        sanitized: this.emergencyFallback(content),
        originalLength: content.length,
        sanitizedLength: 0,
        advancedThreats: [`processing_error: ${error.message}`],
        pipelineSteps: [...pipelineSteps, 'emergency_fallback'],
        riskAssessment: {
          score: 100,
          level: 'critical',
          categories: ['processing_error']
        },
        isClean: false,
        processingTime: performance.now() - startTime
      };
    }
  }

  private static normalizeEncoding(content: string): string {
    // Decode HTML entities
    content = content
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&#x27;/g, "'")
      .replace(/&#x2F;/g, '/');

    // Normalize Unicode
    content = content.normalize('NFC');

    // Remove null bytes and control characters
    content = content.replace(/[\0-\x1F\x7F-\x9F]/g, '');

    return content;
  }

  private static filterDangerousContent(content: string, threatCategories: string[]): string {
    let filtered = content;

    // Apply category-specific filtering
    if (threatCategories.includes('advancedXSS')) {
      filtered = filtered.replace(/<[^>]*>/g, ''); // Strip all HTML tags
    }

    if (threatCategories.includes('commandInjection')) {
      filtered = filtered.replace(/[|&;$`\\]/g, ''); // Remove command chars
    }

    return filtered;
  }

  private static validateStructure(content: string, context: string): string {
    const maxLengths: Record<string, number> = {
      message: 5000,
      profile: 2000,
      search: 100,
      filename: 255,
      general: 1000
    };

    const maxLength = maxLengths[context] || maxLengths.general;
    
    if (content.length > maxLength) {
      content = content.substring(0, maxLength);
    }

    return content;
  }

  private static performSemanticAnalysis(content: string, context: string): {
    content: string;
    semanticFlags: string[];
  } {
    const semanticFlags: string[] = [];
    let analyzedContent = content;

    // Check for context-inappropriate content
    if (context === 'profile' || context === 'message') {
      // Remove potential contact information
      const phoneRegex = /\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/g;
      const emailRegex = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/g;
      
      if (phoneRegex.test(analyzedContent)) {
        semanticFlags.push('phone_number_detected');
        analyzedContent = analyzedContent.replace(phoneRegex, '[PHONE]');
      }
      
      if (emailRegex.test(analyzedContent)) {
        semanticFlags.push('email_detected');
        analyzedContent = analyzedContent.replace(emailRegex, '[EMAIL]');
      }
    }

    return {
      content: analyzedContent,
      semanticFlags
    };
  }

  private static finalCleanup(content: string): string {
    // Trim whitespace
    content = content.trim();

    // Normalize repeated characters
    content = content.replace(/(.)\1{10,}/g, '$1$1$1'); // Max 3 repeated chars

    // Remove excessive punctuation
    content = content.replace(/[!?]{4,}/g, '!!!');
    content = content.replace(/\.{4,}/g, '...');

    return content;
  }

  private static assessRiskLevel(score: number): 'low' | 'medium' | 'high' | 'critical' {
    if (score >= 80) return 'critical';
    if (score >= 60) return 'high';
    if (score >= 30) return 'medium';
    return 'low';
  }

  private static emergencyFallback(content: string): string {
    // Ultra-conservative fallback: only allow alphanumeric and basic punctuation
    return content.replace(/[^a-zA-Z0-9\s.,!?-]/g, '').substring(0, 100);
  }
}

/**
 * Enhanced sanitization function using the advanced pipeline
 */
export async function sanitizeWithAdvancedProtection(
  content: string,
  context: 'message' | 'profile' | 'search' | 'filename' | 'general' = 'general'
) {
  return await EnhancedSanitizationPipeline.sanitizeWithAdvancedPipeline(content, context);
}

export {
  SANITIZATION_CONFIG,
  THREAT_PATTERNS,
  ADVANCED_THREAT_PATTERNS,
  assessThreats,
  sanitizeHTML,
  sanitizeURL,
  filterProfanity,
  AdvancedContentAnalyzer,
  EnhancedSanitizationPipeline,
  sanitizeWithAdvancedProtection,
};