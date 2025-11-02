/**
 * Comprehensive Input Validation System
 * 
 * This module provides robust input validation to prevent:
 * - SQL injection attacks
 * - XSS attacks
 * - Parameter manipulation
 * - Data type confusion
 * - Buffer overflow attacks
 * - Path traversal attacks
 */

import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

// UUID validation regex (RFC 4122 compliant)
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// Safe string validation (no SQL injection patterns)
const SAFE_STRING_REGEX = /^[a-zA-Z0-9\s\-_.,!?()]+$/;

// Email validation
const EMAIL_REGEX = /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/;

// Phone number validation (international format)
const PHONE_REGEX = /^\+?[1-9]\d{1,14}$/;

// Security validation errors
export class SecurityValidationError extends Error {
  constructor(public field: string, public reason: string, public securityRisk: 'low' | 'medium' | 'high' | 'critical') {
    super(`Security validation failed for ${field}: ${reason}`);
    this.name = 'SecurityValidationError';
  }
}

/**
 * Validate UUID format with security checks
 */
export function validateSecureUUID(value: unknown, fieldName: string = 'UUID'): string {
  if (typeof value !== 'string') {
    throw new SecurityValidationError(fieldName, 'Must be a string', 'medium');
  }

  if (value.length === 0) {
    throw new SecurityValidationError(fieldName, 'Cannot be empty', 'medium');
  }

  if (value.length > 36) {
    throw new SecurityValidationError(fieldName, 'UUID too long - potential buffer overflow', 'high');
  }

  // PHASE 3 SECURITY: Enhanced buffer overflow protection
  if (value.length > 1000) { // Extreme length check
    throw new SecurityValidationError(fieldName, 'Input extremely long - potential buffer overflow attack', 'critical');
  }

  // Check for SQL injection patterns
  const sqlPatterns = [
    /'/g, /"/g, /;/g, /--/g, /\/\*/g, /\*\//g,
    /union/gi, /select/gi, /insert/gi, /update/gi, /delete/gi, /drop/gi,
    /exec/gi, /execute/gi, /declare/gi, /cast/gi, /char/gi
  ];

  for (const pattern of sqlPatterns) {
    if (pattern.test(value)) {
      throw new SecurityValidationError(fieldName, 'Contains SQL injection patterns', 'critical');
    }
  }

  // Check for XSS patterns
  const xssPatterns = [
    /<script/gi, /<\/script/gi, /javascript:/gi, /onload=/gi, /onerror=/gi,
    /onclick=/gi, /onmouseover=/gi, /<iframe/gi, /<object/gi, /<embed/gi
  ];

  for (const pattern of xssPatterns) {
    if (pattern.test(value)) {
      throw new SecurityValidationError(fieldName, 'Contains XSS patterns', 'critical');
    }
  }

  if (!UUID_REGEX.test(value)) {
    throw new SecurityValidationError(fieldName, 'Invalid UUID format', 'high');
  }

  return value;
}

/**
 * Validate safe string with XSS and injection protection
 */
export function validateSecureString(
  value: unknown, 
  fieldName: string = 'string', 
  options: {
    maxLength?: number;
    minLength?: number;
    allowEmpty?: boolean;
    allowSpecialChars?: boolean;
  } = {}
): string {
  if (typeof value !== 'string') {
    throw new SecurityValidationError(fieldName, 'Must be a string', 'medium');
  }

  const {
    maxLength = 1000,
    minLength = 0,
    allowEmpty = false,
    allowSpecialChars = false
  } = options;

  if (!allowEmpty && value.length === 0) {
    throw new SecurityValidationError(fieldName, 'Cannot be empty', 'medium');
  }

  if (value.length > maxLength) {
    throw new SecurityValidationError(fieldName, `String too long (max ${maxLength}) - potential buffer overflow`, 'high');
  }

  if (value.length < minLength) {
    throw new SecurityValidationError(fieldName, `String too short (min ${minLength})`, 'low');
  }

  // Check for SQL injection patterns
  const sqlPatterns = [
    /'/g, /"/g, /;/g, /--/g, /\/\*/g, /\*\//g,
    /union/gi, /select/gi, /insert/gi, /update/gi, /delete/gi, /drop/gi,
    /exec/gi, /execute/gi, /declare/gi, /cast/gi, /char/gi, /xp_/gi
  ];

  for (const pattern of sqlPatterns) {
    if (pattern.test(value)) {
      throw new SecurityValidationError(fieldName, 'Contains SQL injection patterns', 'critical');
    }
  }

  // Check for XSS patterns
  const xssPatterns = [
    /<script/gi, /<\/script/gi, /javascript:/gi, /onload=/gi, /onerror=/gi,
    /onclick=/gi, /onmouseover=/gi, /<iframe/gi, /<object/gi, /<embed/gi,
    /alert\(/gi, /confirm\(/gi, /prompt\(/gi, /eval\(/gi
  ];

  for (const pattern of xssPatterns) {
    if (pattern.test(value)) {
      throw new SecurityValidationError(fieldName, 'Contains XSS patterns', 'critical');
    }
  }

  // Check for path traversal patterns
  const pathTraversalPatterns = [
    /\.\./g, /\.\/\./g, /\.\.\/+/g, /\.\.\\+/g, /\%2e\%2e/gi,
    /\%252e\%252e/gi, /\%c0\%ae/gi
  ];

  for (const pattern of pathTraversalPatterns) {
    if (pattern.test(value)) {
      throw new SecurityValidationError(fieldName, 'Contains path traversal patterns', 'high');
    }
  }

  if (!allowSpecialChars && !SAFE_STRING_REGEX.test(value)) {
    throw new SecurityValidationError(fieldName, 'Contains unsafe characters', 'medium');
  }

  return value;
}

/**
 * Validate email with security checks
 */
export function validateSecureEmail(value: unknown, fieldName: string = 'email'): string {
  const email = validateSecureString(value, fieldName, { maxLength: 254, allowSpecialChars: true });

  if (!EMAIL_REGEX.test(email)) {
    throw new SecurityValidationError(fieldName, 'Invalid email format', 'medium');
  }

  return email.toLowerCase();
}

/**
 * Validate integer with range checks
 */
export function validateSecureInteger(
  value: unknown, 
  fieldName: string = 'integer',
  options: {
    min?: number;
    max?: number;
  } = {}
): number {
  const { min = Number.MIN_SAFE_INTEGER, max = Number.MAX_SAFE_INTEGER } = options;

  if (typeof value === 'string') {
    const parsed = parseInt(value, 10);
    if (isNaN(parsed)) {
      throw new SecurityValidationError(fieldName, 'Not a valid integer', 'medium');
    }
    value = parsed;
  }

  if (typeof value !== 'number') {
    throw new SecurityValidationError(fieldName, 'Must be a number', 'medium');
  }

  if (!Number.isInteger(value)) {
    throw new SecurityValidationError(fieldName, 'Must be an integer', 'medium');
  }

  if (value < min) {
    throw new SecurityValidationError(fieldName, `Value too small (min ${min})`, 'medium');
  }

  if (value > max) {
    throw new SecurityValidationError(fieldName, `Value too large (max ${max})`, 'medium');
  }

  return value;
}

/**
 * Validate boolean with security checks
 */
export function validateSecureBoolean(value: unknown, fieldName: string = 'boolean'): boolean {
  if (typeof value === 'boolean') {
    return value;
  }

  if (typeof value === 'string') {
    if (value.toLowerCase() === 'true') return true;
    if (value.toLowerCase() === 'false') return false;
  }

  throw new SecurityValidationError(fieldName, 'Must be a boolean', 'medium');
}

/**
 * Comprehensive request body validator
 */
export function validateRequestBody<T>(
  body: unknown,
  schema: z.ZodSchema<T>,
  maxSize: number = 1024 * 1024 // 1MB default
): T {
  // Check if body exists
  if (!body) {
    throw new SecurityValidationError('request_body', 'Request body is required', 'medium');
  }

  // Check body size (if it's a string)
  if (typeof body === 'string' && body.length > maxSize) {
    throw new SecurityValidationError('request_body', 'Request body too large', 'high');
  }

  try {
    return schema.parse(body);
  } catch (error) {
    if (error instanceof z.ZodError) {
      const firstError = error.errors[0];
      throw new SecurityValidationError(
        firstError.path.join('.'),
        firstError.message,
        'medium'
      );
    }
    throw error;
  }
}

/**
 * Sanitize HTML content to prevent XSS
 */
export function sanitizeHTML(html: string): string {
  return html
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;')
    .replace(/\//g, '&#x2F;');
}

/**
 * Create secure error response without exposing system details
 */
export function createSecureErrorResponse(
  error: SecurityValidationError | Error,
  requestContext?: string
): Response {
  const isSecurityError = error instanceof SecurityValidationError;

  // Log security errors for monitoring
  if (isSecurityError && error.securityRisk === 'critical') {
    console.error(`CRITICAL SECURITY VIOLATION: ${error.message}`, {
      context: requestContext,
      timestamp: new Date().toISOString(),
      field: error.field,
      risk: error.securityRisk
    });
  }

  // Create safe error message for user
  const userMessage = isSecurityError && error.securityRisk === 'critical'
    ? 'Security violation detected'
    : 'Invalid input provided';

  return new Response(
    JSON.stringify({
      error: userMessage,
      code: 'VALIDATION_ERROR',
      timestamp: new Date().toISOString()
    }),
    {
      status: 400,
      headers: {
        'Content-Type': 'application/json',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'X-XSS-Protection': '1; mode=block'
      }
    }
  );
}

/**
 * Common validation schemas
 */
export const CommonSchemas = {
  UUID: z.string().refine(
    (val) => {
      try {
        validateSecureUUID(val);
        return true;
      } catch {
        return false;
      }
    },
    'Invalid UUID format'
  ),

  SafeString: z.string().refine(
    (val) => {
      try {
        validateSecureString(val);
        return true;
      } catch {
        return false;
      }
    },
    'Contains unsafe characters'
  ),

  Email: z.string().refine(
    (val) => {
      try {
        validateSecureEmail(val);
        return true;
      } catch {
        return false;
      }
    },
    'Invalid email format'
  ),

  Age: z.number().int().min(18).max(100),

  Pagination: z.object({
    page: z.number().int().min(1).max(1000).default(1),
    pageSize: z.number().int().min(1).max(100).default(10)
  })
};

/**
 * Express middleware for automatic input validation
 */
export function createValidationMiddleware<T>(schema: z.ZodSchema<T>) {
  return async (req: Request): Promise<{ valid: true; data: T } | { valid: false; response: Response }> => {
    try {
      let body: unknown;
      
      if (req.method === 'POST' || req.method === 'PUT' || req.method === 'PATCH') {
        body = await req.json();
      } else if (req.method === 'GET') {
        const url = new URL(req.url);
        body = Object.fromEntries(url.searchParams.entries());
      }

      const validatedData = validateRequestBody(body, schema);
      return { valid: true, data: validatedData };
    } catch (error) {
      return { 
        valid: false, 
        response: createSecureErrorResponse(error as Error, req.url) 
      };
    }
  };
}

/**
 * PHASE 3 SECURITY: Comprehensive Buffer Overflow Protection
 */
export class BufferOverflowProtection {
  // Maximum safe input lengths for different data types
  private static readonly MAX_LENGTHS = {
    UUID: 36,
    EMAIL: 254, // RFC 5321 limit
    NAME: 100,
    DESCRIPTION: 2000,
    MESSAGE: 5000,
    BIO: 1000,
    URL: 2048, // RFC 2616 recommendation
    TOKEN: 512,
    SEARCH_QUERY: 100,
    PHONE: 20,
    PASSWORD: 128, // Max for bcrypt
    GENERAL_STRING: 1000,
    JSON_FIELD: 10000,
    FILE_PATH: 4096, // Max path length
    USER_AGENT: 512,
    IP_ADDRESS: 45, // IPv6 with brackets
  };

  // Memory consumption limits
  private static readonly MEMORY_LIMITS = {
    MAX_REQUEST_SIZE: 10 * 1024 * 1024, // 10MB
    MAX_ARRAY_LENGTH: 1000,
    MAX_OBJECT_KEYS: 100,
    MAX_NESTING_DEPTH: 10,
    MAX_STRING_CONCATENATION: 50000, // For building responses
  };

  /**
   * Validate input length against buffer overflow attacks
   */
  static validateLength(
    input: string | any[],
    maxLength: number,
    fieldName: string = 'input',
    context: 'strict' | 'normal' | 'lenient' = 'normal'
  ): void {
    const length = typeof input === 'string' ? input.length : input.length;
    
    // Context-based multipliers
    const multiplier = context === 'strict' ? 0.5 : context === 'lenient' ? 2 : 1;
    const effectiveMax = Math.floor(maxLength * multiplier);

    if (length > effectiveMax) {
      const riskLevel = this.assessBufferOverflowRisk(length, effectiveMax);
      throw new SecurityValidationError(
        fieldName,
        `Input length ${length} exceeds maximum ${effectiveMax} - potential buffer overflow`,
        riskLevel
      );
    }

    // Additional check for extremely long inputs
    if (length > this.MEMORY_LIMITS.MAX_STRING_CONCATENATION) {
      throw new SecurityValidationError(
        fieldName,
        'Input exceeds maximum safe processing length',
        'critical'
      );
    }
  }

  /**
   * Assess buffer overflow risk based on input size
   */
  private static assessBufferOverflowRisk(
    actualLength: number,
    maxLength: number
  ): 'low' | 'medium' | 'high' | 'critical' {
    const ratio = actualLength / maxLength;
    
    if (ratio > 10) return 'critical';
    if (ratio > 5) return 'high';
    if (ratio > 2) return 'medium';
    return 'low';
  }

  /**
   * Validate memory consumption for complex objects
   */
  static validateMemoryConsumption(
    data: any,
    context: string = 'unknown'
  ): {
    isWithinLimits: boolean;
    memoryEstimate: number;
    violations: string[];
  } {
    const violations: string[] = [];
    let memoryEstimate = 0;

    try {
      const serialized = JSON.stringify(data);
      memoryEstimate = serialized.length * 2; // Rough estimate (UTF-16)

      if (memoryEstimate > this.MEMORY_LIMITS.MAX_REQUEST_SIZE) {
        violations.push(`Memory consumption ${memoryEstimate} exceeds limit ${this.MEMORY_LIMITS.MAX_REQUEST_SIZE}`);
      }

      // Check object complexity
      const complexity = this.analyzeObjectComplexity(data);
      if (complexity.depth > this.MEMORY_LIMITS.MAX_NESTING_DEPTH) {
        violations.push(`Object nesting depth ${complexity.depth} exceeds limit ${this.MEMORY_LIMITS.MAX_NESTING_DEPTH}`);
      }

      if (complexity.totalKeys > this.MEMORY_LIMITS.MAX_OBJECT_KEYS) {
        violations.push(`Total object keys ${complexity.totalKeys} exceeds limit ${this.MEMORY_LIMITS.MAX_OBJECT_KEYS}`);
      }

      if (complexity.maxArrayLength > this.MEMORY_LIMITS.MAX_ARRAY_LENGTH) {
        violations.push(`Array length ${complexity.maxArrayLength} exceeds limit ${this.MEMORY_LIMITS.MAX_ARRAY_LENGTH}`);
      }

    } catch (error) {
      violations.push('Unable to serialize data for memory analysis');
      memoryEstimate = 0;
    }

    return {
      isWithinLimits: violations.length === 0,
      memoryEstimate,
      violations
    };
  }

  /**
   * Analyze object complexity for memory assessment
   */
  private static analyzeObjectComplexity(obj: any, depth = 0): {
    depth: number;
    totalKeys: number;
    maxArrayLength: number;
  } {
    if (depth > 50) { // Prevent infinite recursion
      return { depth: 50, totalKeys: 0, maxArrayLength: 0 };
    }

    let maxDepth = depth;
    let totalKeys = 0;
    let maxArrayLength = 0;

    if (Array.isArray(obj)) {
      maxArrayLength = Math.max(maxArrayLength, obj.length);
      for (const item of obj) {
        if (typeof item === 'object' && item !== null) {
          const childComplexity = this.analyzeObjectComplexity(item, depth + 1);
          maxDepth = Math.max(maxDepth, childComplexity.depth);
          totalKeys += childComplexity.totalKeys;
          maxArrayLength = Math.max(maxArrayLength, childComplexity.maxArrayLength);
        }
      }
    } else if (typeof obj === 'object' && obj !== null) {
      const keys = Object.keys(obj);
      totalKeys += keys.length;
      
      for (const key of keys) {
        if (typeof obj[key] === 'object' && obj[key] !== null) {
          const childComplexity = this.analyzeObjectComplexity(obj[key], depth + 1);
          maxDepth = Math.max(maxDepth, childComplexity.depth);
          totalKeys += childComplexity.totalKeys;
          maxArrayLength = Math.max(maxArrayLength, childComplexity.maxArrayLength);
        }
      }
    }

    return {
      depth: maxDepth,
      totalKeys,
      maxArrayLength
    };
  }

  /**
   * Create safe string builder with overflow protection
   */
  static createSafeStringBuilder(maxLength = this.MEMORY_LIMITS.MAX_STRING_CONCATENATION) {
    let buffer = '';
    let currentLength = 0;

    return {
      append: (str: string): boolean => {
        if (currentLength + str.length > maxLength) {
          return false; // Prevent overflow
        }
        buffer += str;
        currentLength += str.length;
        return true;
      },
      
      length: (): number => currentLength,
      
      toString: (): string => buffer,
      
      reset: (): void => {
        buffer = '';
        currentLength = 0;
      },

      remainingCapacity: (): number => maxLength - currentLength
    };
  }

  /**
   * Safe array operations with overflow protection
   */
  static createSafeArray<T>(maxLength = this.MEMORY_LIMITS.MAX_ARRAY_LENGTH) {
    const items: T[] = [];

    return {
      push: (item: T): boolean => {
        if (items.length >= maxLength) {
          return false; // Prevent overflow
        }
        items.push(item);
        return true;
      },

      length: (): number => items.length,
      
      toArray: (): T[] => [...items], // Safe copy
      
      remainingCapacity: (): number => maxLength - items.length,
      
      isFull: (): boolean => items.length >= maxLength
    };
  }

  /**
   * Get buffer overflow protection constants
   */
  static getProtectionLimits() {
    return {
      MAX_LENGTHS: { ...this.MAX_LENGTHS },
      MEMORY_LIMITS: { ...this.MEMORY_LIMITS }
    };
  }
}

/**
 * PHASE 3 SECURITY: Enhanced request body validation with buffer overflow protection
 */
export function validateRequestBodyWithBufferProtection<T>(
  body: unknown,
  schema: z.ZodSchema<T>,
  options: {
    maxSize?: number;
    maxComplexity?: boolean;
    context?: 'strict' | 'normal' | 'lenient';
  } = {}
): T {
  const {
    maxSize = 1024 * 1024, // 1MB default
    maxComplexity = true,
    context = 'normal'
  } = options;

  // Check if body exists
  if (!body) {
    throw new SecurityValidationError('request_body', 'Request body is required', 'medium');
  }

  // Memory consumption validation
  if (maxComplexity) {
    const memoryCheck = BufferOverflowProtection.validateMemoryConsumption(body, 'request_validation');
    if (!memoryCheck.isWithinLimits) {
      throw new SecurityValidationError(
        'request_body', 
        `Memory consumption violations: ${memoryCheck.violations.join(', ')}`,
        'high'
      );
    }
  }

  // Size validation for string bodies
  if (typeof body === 'string') {
    BufferOverflowProtection.validateLength(body, maxSize, 'request_body', context);
  }

  try {
    return schema.parse(body);
  } catch (error) {
    if (error instanceof z.ZodError) {
      const firstError = error.errors[0];
      throw new SecurityValidationError(
        firstError.path.join('.'),
        firstError.message,
        'medium'
      );
    }
    throw error;
  }
}

export default {
  validateSecureUUID,
  validateSecureString,
  validateSecureEmail,
  validateSecureInteger,
  validateSecureBoolean,
  validateRequestBody,
  validateRequestBodyWithBufferProtection,
  sanitizeHTML,
  createSecureErrorResponse,
  SecurityValidationError,
  CommonSchemas,
  createValidationMiddleware,
  BufferOverflowProtection
};