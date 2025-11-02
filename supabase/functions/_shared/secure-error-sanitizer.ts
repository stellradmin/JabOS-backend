/**
 * PHASE 2 SECURITY: Secure Error Message Sanitization for Stellr
 * 
 * Comprehensive error sanitization to prevent system information disclosure
 * while maintaining user-friendly error messages for production deployment.
 */

// PHASE 2 SECURITY: Error Sanitization Configuration
export interface ErrorSanitizationConfig {
  productionMode: boolean;
  hideSystemDetails: boolean;
  hideStackTraces: boolean;
  hideFileNames: boolean;
  hideIPAddresses: boolean;
  hideDatabaseDetails: boolean;
  maxErrorMessageLength: number;
  enableErrorMapping: boolean;
}

// PHASE 2 SECURITY: Sanitized Error Response
export interface SanitizedErrorResponse {
  error: string;
  code?: string;
  details?: string;
  timestamp: string;
  requestId?: string;
  userMessage: string;
  technicalMessage?: string; // Only in development
  systemInfoRemoved: string[]; // What was removed for security
}

// PHASE 2 SECURITY: Error Classification for User-Friendly Messages
export interface ErrorMapping {
  pattern: RegExp;
  userMessage: string;
  code: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
  logLevel: 'info' | 'warn' | 'error';
  hideFromUser: boolean;
}

// PHASE 2 SECURITY: Comprehensive Error Mappings
const SECURE_ERROR_MAPPINGS: ErrorMapping[] = [
  // Authentication Errors
  {
    pattern: /jwt.*expired|token.*expired|session.*expired/i,
    userMessage: 'Your session has expired. Please log in again.',
    code: 'SESSION_EXPIRED',
    severity: 'low',
    logLevel: 'info',
    hideFromUser: false
  },
  {
    pattern: /invalid.*token|unauthorized|access.*denied|PGRST301/i,
    userMessage: 'Access denied. Please check your permissions and try again.',
    code: 'ACCESS_DENIED',
    severity: 'medium',
    logLevel: 'warn',
    hideFromUser: false
  },
  {
    pattern: /authentication.*failed|login.*failed|invalid.*credentials/i,
    userMessage: 'Authentication failed. Please check your credentials.',
    code: 'AUTH_FAILED',
    severity: 'medium',
    logLevel: 'warn',
    hideFromUser: false
  },

  // Database Errors
  {
    pattern: /connection.*timeout|query.*timeout|statement.*timeout/i,
    userMessage: 'The request is taking longer than expected. Please try again.',
    code: 'TIMEOUT_ERROR',
    severity: 'medium',
    logLevel: 'warn',
    hideFromUser: false
  },
  {
    pattern: /duplicate.*key|unique.*constraint|already.*exists/i,
    userMessage: 'This information already exists. Please use different values.',
    code: 'DUPLICATE_DATA',
    severity: 'low',
    logLevel: 'info',
    hideFromUser: false
  },
  {
    pattern: /foreign.*key.*constraint|reference.*constraint/i,
    userMessage: 'Cannot complete this action due to data dependencies.',
    code: 'DATA_DEPENDENCY',
    severity: 'medium',
    logLevel: 'warn',
    hideFromUser: false
  },
  {
    pattern: /relation.*does.*not.*exist|table.*does.*not.*exist|column.*does.*not.*exist/i,
    userMessage: 'A system error occurred. Our team has been notified.',
    code: 'SYSTEM_ERROR',
    severity: 'high',
    logLevel: 'error',
    hideFromUser: true
  },

  // Network Errors
  {
    pattern: /network.*error|connection.*refused|host.*unreachable/i,
    userMessage: 'Connection issue detected. Please check your internet connection.',
    code: 'NETWORK_ERROR',
    severity: 'medium',
    logLevel: 'warn',
    hideFromUser: false
  },
  {
    pattern: /rate.*limit|too.*many.*requests|quota.*exceeded/i,
    userMessage: 'You are making requests too quickly. Please wait a moment and try again.',
    code: 'RATE_LIMITED',
    severity: 'low',
    logLevel: 'info',
    hideFromUser: false
  },

  // Validation Errors
  {
    pattern: /validation.*failed|invalid.*input|bad.*request/i,
    userMessage: 'Please check your input and try again.',
    code: 'VALIDATION_ERROR',
    severity: 'low',
    logLevel: 'info',
    hideFromUser: false
  },
  {
    pattern: /file.*too.*large|size.*exceeded|too.*big/i,
    userMessage: 'The file you uploaded is too large. Please choose a smaller file.',
    code: 'FILE_TOO_LARGE',
    severity: 'low',
    logLevel: 'info',
    hideFromUser: false
  },
  {
    pattern: /unsupported.*format|invalid.*format|format.*not.*allowed/i,
    userMessage: 'This file format is not supported. Please use a supported format.',
    code: 'UNSUPPORTED_FORMAT',
    severity: 'low',
    logLevel: 'info',
    hideFromUser: false
  },

  // System Errors (Hide from users)
  {
    pattern: /internal.*server.*error|500|system.*error|unexpected.*error/i,
    userMessage: 'Something went wrong on our end. Please try again later.',
    code: 'INTERNAL_ERROR',
    severity: 'high',
    logLevel: 'error',
    hideFromUser: true
  },
  {
    pattern: /out.*of.*memory|memory.*allocation|heap.*size/i,
    userMessage: 'Service temporarily unavailable. Please try again in a moment.',
    code: 'RESOURCE_ERROR',
    severity: 'critical',
    logLevel: 'error',
    hideFromUser: true
  },

  // Security-related Errors (Hide details)
  {
    pattern: /sql.*injection|xss|cross.*site|malicious|threat.*detected/i,
    userMessage: 'Security validation failed. Please contact support if this continues.',
    code: 'SECURITY_VIOLATION',
    severity: 'critical',
    logLevel: 'error',
    hideFromUser: true
  }
];

// PHASE 2 SECURITY: Secure Error Sanitization Service
export class SecureErrorSanitizer {
  private config: ErrorSanitizationConfig;

  constructor(config: Partial<ErrorSanitizationConfig> = {}) {
    this.config = {
      productionMode: true, // Default to production mode for security
      hideSystemDetails: true,
      hideStackTraces: true,
      hideFileNames: true,
      hideIPAddresses: true,
      hideDatabaseDetails: true,
      maxErrorMessageLength: 200,
      enableErrorMapping: true,
      ...config
    };
  }

  /**
   * PHASE 2 SECURITY: Sanitize error for safe public exposure
   */
  sanitizeError(
    error: any, 
    requestId?: string, 
    context?: { userId?: string; endpoint?: string }
  ): SanitizedErrorResponse {
    const systemInfoRemoved: string[] = [];
    let originalMessage = this.extractErrorMessage(error);
    let sanitizedMessage = originalMessage;
    let userMessage = 'An error occurred. Please try again.';
    let errorCode = 'UNKNOWN_ERROR';
    
    try {
      // Step 1: Apply error mapping for user-friendly messages
      if (this.config.enableErrorMapping) {
        const mapping = this.findErrorMapping(originalMessage);
        if (mapping) {
          userMessage = mapping.userMessage;
          errorCode = mapping.code;
          
          // Hide technical details if specified
          if (mapping.hideFromUser && this.config.productionMode) {
            sanitizedMessage = mapping.userMessage;
          }
        }
      }

      // Step 2: Remove system information
      const systemSanitized = this.removeSystemInformation(sanitizedMessage);
      sanitizedMessage = systemSanitized.cleaned;
      systemInfoRemoved.push(...systemSanitized.removed);

      // Step 3: Remove database details
      if (this.config.hideDatabaseDetails) {
        const dbSanitized = this.removeDatabaseDetails(sanitizedMessage);
        sanitizedMessage = dbSanitized.cleaned;
        systemInfoRemoved.push(...dbSanitized.removed);
      }

      // Step 4: Remove file paths and stack traces
      if (this.config.hideFileNames || this.config.hideStackTraces) {
        const pathSanitized = this.removeFilePathsAndStackTraces(sanitizedMessage);
        sanitizedMessage = pathSanitized.cleaned;
        systemInfoRemoved.push(...pathSanitized.removed);
      }

      // Step 5: Remove IP addresses
      if (this.config.hideIPAddresses) {
        const ipSanitized = this.removeIPAddresses(sanitizedMessage);
        sanitizedMessage = ipSanitized.cleaned;
        systemInfoRemoved.push(...ipSanitized.removed);
      }

      // Step 6: Remove other sensitive information
      const sensitiveSanitized = this.removeSensitiveInformation(sanitizedMessage);
      sanitizedMessage = sensitiveSanitized.cleaned;
      systemInfoRemoved.push(...sensitiveSanitized.removed);

      // Step 7: Truncate if too long
      if (sanitizedMessage.length > this.config.maxErrorMessageLength) {
        sanitizedMessage = sanitizedMessage.substring(0, this.config.maxErrorMessageLength) + '...';
        systemInfoRemoved.push('Message truncated for security');
      }

      // Step 8: Final cleanup
      sanitizedMessage = this.finalCleanup(sanitizedMessage);

    } catch (sanitizationError) {
      // If sanitization fails, use safe fallback
      sanitizedMessage = 'An error occurred during processing.';
      userMessage = 'Something went wrong. Please try again later.';
      errorCode = 'SANITIZATION_ERROR';
      systemInfoRemoved.push('Sanitization process failed - using safe fallback');
    }

    return {
      error: sanitizedMessage,
      code: errorCode,
      timestamp: new Date().toISOString(),
      requestId,
      userMessage,
      technicalMessage: this.config.productionMode ? undefined : originalMessage,
      systemInfoRemoved
    };
  }

  private extractErrorMessage(error: any): string {
    if (typeof error === 'string') return error;
    if (error?.message) return error.message;
    if (error?.error) return error.error;
    if (error?.details) return error.details;
    if (error?.code) return `Error code: ${error.code}`;
    return 'Unknown error occurred';
  }

  private findErrorMapping(message: string): ErrorMapping | null {
    for (const mapping of SECURE_ERROR_MAPPINGS) {
      if (mapping.pattern.test(message)) {
        return mapping;
      }
    }
    return null;
  }

  private removeSystemInformation(message: string): { cleaned: string; removed: string[] } {
    const removed: string[] = [];
    let cleaned = message;

    // Remove server names and hostnames
    const serverPatterns = [
      /server\s+[\w\-\.]+\.\w+/gi,
      /host\s+[\w\-\.]+\.\w+/gi,
      /hostname\s*[:=]\s*[\w\-\.]+/gi,
    ];

    for (const pattern of serverPatterns) {
      const matches = cleaned.match(pattern) || [];
      if (matches.length > 0) {
        removed.push(...matches);
        cleaned = cleaned.replace(pattern, '[SERVER]');
      }
    }

    // Remove port numbers
    const portPattern = /:\d{2,5}/g;
    const portMatches = cleaned.match(portPattern) || [];
    if (portMatches.length > 0) {
      removed.push(...portMatches);
      cleaned = cleaned.replace(portPattern, ':[PORT]');
    }

    // Remove version information
    const versionPatterns = [
      /version\s+\d+\.\d+[\.\d]*/gi,
      /v\d+\.\d+[\.\d]*/gi,
    ];

    for (const pattern of versionPatterns) {
      const matches = cleaned.match(pattern) || [];
      if (matches.length > 0) {
        removed.push(...matches);
        cleaned = cleaned.replace(pattern, '[VERSION]');
      }
    }

    return { cleaned, removed };
  }

  private removeDatabaseDetails(message: string): { cleaned: string; removed: string[] } {
    const removed: string[] = [];
    let cleaned = message;

    // Remove database connection strings
    const connectionPatterns = [
      /postgresql:\/\/[^\s]+/gi,
      /postgres:\/\/[^\s]+/gi,
      /mongodb:\/\/[^\s]+/gi,
      /mysql:\/\/[^\s]+/gi,
      /host=[^\s]+/gi,
      /user=[^\s]+/gi,
      /password=[^\s]+/gi,
      /database=[^\s]+/gi,
    ];

    for (const pattern of connectionPatterns) {
      const matches = cleaned.match(pattern) || [];
      if (matches.length > 0) {
        removed.push(...matches);
        cleaned = cleaned.replace(pattern, '[DB_CONNECTION]');
      }
    }

    // Remove table and column names (be careful not to remove user data)
    const dbElementPatterns = [
      /table\s+"[^"]+"/gi,
      /column\s+"[^"]+"/gi,
      /relation\s+"[^"]+"/gi,
      /constraint\s+"[^"]+"/gi,
    ];

    for (const pattern of dbElementPatterns) {
      const matches = cleaned.match(pattern) || [];
      if (matches.length > 0) {
        removed.push(...matches);
        cleaned = cleaned.replace(pattern, match => match.replace(/"[^"]+"/g, '"[REDACTED]"'));
      }
    }

    return { cleaned, removed };
  }

  private removeFilePathsAndStackTraces(message: string): { cleaned: string; removed: string[] } {
    const removed: string[] = [];
    let cleaned = message;

    // Remove file paths
    const pathPatterns = [
      /[\/\\][\w\-\.\/\\]+\.(js|ts|py|java|cpp|c|h|php|rb|go)(?::\d+)?/gi,
      /[A-Z]:[\/\\][\w\-\.\/\\]+/gi, // Windows paths
      /(?:\/usr\/|\/var\/|\/home\/|\/opt\/|\/etc\/)[^\s]+/gi, // Unix paths
    ];

    for (const pattern of pathPatterns) {
      const matches = cleaned.match(pattern) || [];
      if (matches.length > 0) {
        removed.push(...matches);
        cleaned = cleaned.replace(pattern, '[FILE_PATH]');
      }
    }

    // Remove stack trace lines
    if (this.config.hideStackTraces) {
      const stackTracePatterns = [
        /at\s+[\w\.]+\s*\([^)]+\)/gi,
        /^\s*at\s+.+$/gm,
        /Traceback\s*\(most recent call last\):/gi,
        /File\s*"[^"]+",\s*line\s*\d+/gi,
      ];

      for (const pattern of stackTracePatterns) {
        const matches = cleaned.match(pattern) || [];
        if (matches.length > 0) {
          removed.push(...matches);
          cleaned = cleaned.replace(pattern, '');
        }
      }
    }

    return { cleaned, removed };
  }

  private removeIPAddresses(message: string): { cleaned: string; removed: string[] } {
    const removed: string[] = [];
    let cleaned = message;

    // IPv4 addresses
    const ipv4Pattern = /\b(?:\d{1,3}\.){3}\d{1,3}\b/g;
    const ipv4Matches = cleaned.match(ipv4Pattern) || [];
    if (ipv4Matches.length > 0) {
      removed.push(...ipv4Matches);
      cleaned = cleaned.replace(ipv4Pattern, '[IP_ADDRESS]');
    }

    // IPv6 addresses (simplified)
    const ipv6Pattern = /\b(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}\b/gi;
    const ipv6Matches = cleaned.match(ipv6Pattern) || [];
    if (ipv6Matches.length > 0) {
      removed.push(...ipv6Matches);
      cleaned = cleaned.replace(ipv6Pattern, '[IPV6_ADDRESS]');
    }

    return { cleaned, removed };
  }

  private removeSensitiveInformation(message: string): { cleaned: string; removed: string[] } {
    const removed: string[] = [];
    let cleaned = message;

    // API keys and tokens
    const sensitivePatterns = [
      /[Aa]pi[_\s]*[Kk]ey[_\s]*[:=]\s*[^\s]+/gi,
      /[Tt]oken[_\s]*[:=]\s*[^\s]+/gi,
      /[Ss]ecret[_\s]*[:=]\s*[^\s]+/gi,
      /[Kk]ey[_\s]*[:=]\s*[A-Za-z0-9\+\/]{20,}/gi,
      /Bearer\s+[A-Za-z0-9\.\-_]+/gi,
    ];

    for (const pattern of sensitivePatterns) {
      const matches = cleaned.match(pattern) || [];
      if (matches.length > 0) {
        removed.push(...matches);
        cleaned = cleaned.replace(pattern, '[SENSITIVE_DATA]');
      }
    }

    // UUIDs (might be sensitive user IDs)
    const userIdPattern = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
    const userIdMatches = cleaned.match(userIdPattern) || [];
    if (userIdMatches.length > 0) {
      removed.push(...userIdMatches);
      cleaned = cleaned.replace(userIdPattern, '[USER_ID]');
    }

    return { cleaned, removed };
  }

  private finalCleanup(message: string): string {
    let cleaned = message;

    // Remove extra whitespace
    cleaned = cleaned.replace(/\s+/g, ' ').trim();

    // Remove empty brackets and cleanup
    cleaned = cleaned.replace(/\[\s*\]/g, '');
    cleaned = cleaned.replace(/\s+/g, ' ').trim();

    // Ensure message is not empty
    if (!cleaned || cleaned.length === 0) {
      cleaned = 'An error occurred.';
    }

    return cleaned;
  }
}

// PHASE 2 SECURITY: Convenience functions
const defaultSanitizer = new SecureErrorSanitizer();

export function sanitizeErrorForUser(
  error: any, 
  requestId?: string, 
  context?: { userId?: string; endpoint?: string }
): SanitizedErrorResponse {
  return defaultSanitizer.sanitizeError(error, requestId, context);
}

export function sanitizeErrorForDevelopment(
  error: any, 
  requestId?: string, 
  context?: { userId?: string; endpoint?: string }
): SanitizedErrorResponse {
  const devSanitizer = new SecureErrorSanitizer({ 
    productionMode: false, 
    hideStackTraces: false,
    hideFileNames: false 
  });
  return devSanitizer.sanitizeError(error, requestId, context);
}

export { SecureErrorSanitizer };