/**
 * CRITICAL SECURITY: Request Size Limits and Input Validation
 * 
 * Comprehensive security validation for all Edge Functions
 * Implements request size limits, file upload restrictions, and input sanitization
 */

// Request size limits (in bytes)
export const REQUEST_SIZE_LIMITS = {
  SMALL: 1024,          // 1KB - Small text requests (auth, simple queries)
  MEDIUM: 10240,        // 10KB - Medium requests (profile updates, messages)
  LARGE: 102400,        // 100KB - Large requests (with images)
  FILE_UPLOAD: 1048576, // 1MB - File uploads (profile photos)
  MAXIMUM: 5242880,     // 5MB - Absolute maximum for any request
};

// Content length limits for text fields
export const CONTENT_LIMITS = {
  USERNAME: 50,
  EMAIL: 254,
  PASSWORD: 128,
  DISPLAY_NAME: 100,
  BIO: 500,
  MESSAGE: 1000,
  LOCATION: 100,
  INTERESTS: 50, // Per interest
  MAX_INTERESTS: 10,
  SEARCH_QUERY: 200,
  UUID: 36,
  PHONE: 20,
  REASON: 500, // For reports, feedback
};

// File upload restrictions
export const FILE_RESTRICTIONS = {
  ALLOWED_IMAGE_TYPES: ['image/jpeg', 'image/jpg', 'image/png', 'image/webp'],
  ALLOWED_VIDEO_TYPES: ['video/mp4', 'video/webm'],
  MAX_FILE_SIZE: REQUEST_SIZE_LIMITS.FILE_UPLOAD,
  MAX_FILES_PER_REQUEST: 5,
  MAX_FILENAME_LENGTH: 255,
};

// UUID validation regex
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// Email validation regex (RFC 5322 compliant)
const EMAIL_REGEX = /^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;

/**
 * Validate request size against specified limit
 */
export async function validateRequestSize(
  request: Request, 
  maxSize: number = REQUEST_SIZE_LIMITS.MEDIUM
): Promise<{ valid: boolean; error?: string; size?: number }> {
  try {
    // Check Content-Length header first (most efficient)
    const contentLength = request.headers.get('Content-Length');
    if (contentLength) {
      const size = parseInt(contentLength, 10);
      if (isNaN(size)) {
        return { valid: false, error: 'Invalid Content-Length header' };
      }
      if (size > maxSize) {
        return { 
          valid: false, 
          error: `Request too large: ${size} bytes. Maximum allowed: ${maxSize} bytes`,
          size
        };
      }
      if (size > REQUEST_SIZE_LIMITS.MAXIMUM) {
        return {
          valid: false,
          error: `Request exceeds absolute maximum size: ${REQUEST_SIZE_LIMITS.MAXIMUM} bytes`,
          size
        };
      }
      return { valid: true, size };
    }

    // If no Content-Length, we need to read the body to check size
    // This is less efficient but necessary for security
    const bodyText = await request.text();
    const size = new TextEncoder().encode(bodyText).length;
    
    if (size > maxSize) {
      return { 
        valid: false, 
        error: `Request too large: ${size} bytes. Maximum allowed: ${maxSize} bytes`,
        size
      };
    }
    
    if (size > REQUEST_SIZE_LIMITS.MAXIMUM) {
      return {
        valid: false,
        error: `Request exceeds absolute maximum size: ${REQUEST_SIZE_LIMITS.MAXIMUM} bytes`,
        size
      };
    }

    return { valid: true, size };
  } catch (error) {
    return { 
      valid: false, 
      error: `Failed to validate request size: ${error.message}` 
    };
  }
}

/**
 * Validate and parse JSON with size limits
 */
export async function validateAndParseJSON<T = any>(
  request: Request,
  maxSize: number = REQUEST_SIZE_LIMITS.MEDIUM
): Promise<{ valid: boolean; data?: T; error?: string; size?: number }> {
  
  // First validate request size
  const sizeCheck = await validateRequestSize(request, maxSize);
  if (!sizeCheck.valid) {
    return { valid: false, error: sizeCheck.error, size: sizeCheck.size };
  }

  try {
    // Parse JSON
    const bodyText = await request.text();
    if (!bodyText.trim()) {
      return { valid: false, error: 'Empty request body' };
    }

    let data: T;
    try {
      data = JSON.parse(bodyText);
    } catch (parseError) {
      return { 
        valid: false, 
        error: `Invalid JSON: ${parseError.message}`,
        size: sizeCheck.size
      };
    }

    // Additional validation for nested objects
    if (typeof data === 'object' && data !== null) {
      const stringified = JSON.stringify(data);
      if (stringified.length > maxSize) {
        return {
          valid: false,
          error: `Parsed JSON too large: ${stringified.length} characters`,
          size: stringified.length
        };
      }
    }

    return { valid: true, data, size: sizeCheck.size };
  } catch (error) {
    return { 
      valid: false, 
      error: `Failed to parse request: ${error.message}`,
      size: sizeCheck.size
    };
  }
}

/**
 * Validate UUID format
 */
export function validateUUID(value: string): { valid: boolean; error?: string } {
  if (!value || typeof value !== 'string') {
    return { valid: false, error: 'UUID is required and must be a string' };
  }
  
  if (value.length !== 36) {
    return { valid: false, error: 'UUID must be exactly 36 characters long' };
  }
  
  if (!UUID_REGEX.test(value)) {
    return { valid: false, error: 'Invalid UUID format' };
  }
  
  return { valid: true };
}

/**
 * Validate email format
 */
export function validateEmail(email: string): { valid: boolean; error?: string } {
  if (!email || typeof email !== 'string') {
    return { valid: false, error: 'Email is required and must be a string' };
  }
  
  if (email.length > CONTENT_LIMITS.EMAIL) {
    return { valid: false, error: `Email too long. Maximum ${CONTENT_LIMITS.EMAIL} characters` };
  }
  
  if (!EMAIL_REGEX.test(email)) {
    return { valid: false, error: 'Invalid email format' };
  }
  
  return { valid: true };
}

/**
 * Validate and sanitize text input
 */
export function validateTextInput(
  value: string,
  fieldName: string,
  maxLength: number,
  required: boolean = true
): { valid: boolean; sanitized?: string; error?: string } {
  
  if (!value || typeof value !== 'string') {
    if (required) {
      return { valid: false, error: `${fieldName} is required and must be a string` };
    }
    return { valid: true, sanitized: '' };
  }
  
  // Trim whitespace
  const trimmed = value.trim();
  
  if (required && !trimmed) {
    return { valid: false, error: `${fieldName} cannot be empty` };
  }
  
  if (trimmed.length > maxLength) {
    return { 
      valid: false, 
      error: `${fieldName} too long. Maximum ${maxLength} characters, got ${trimmed.length}` 
    };
  }
  
  // Basic XSS prevention - remove potentially dangerous characters
  const sanitized = trimmed
    .replace(/[<>]/g, '') // Remove < and >
    .replace(/javascript:/gi, '') // Remove javascript: protocol
    .replace(/data:/gi, '') // Remove data: protocol
    .replace(/vbscript:/gi, '') // Remove vbscript: protocol
    .replace(/on\w+=/gi, ''); // Remove event handlers like onclick=
  
  return { valid: true, sanitized };
}

/**
 * Validate array input with size limits
 */
export function validateArrayInput<T>(
  value: T[],
  fieldName: string,
  maxLength: number,
  itemValidator?: (item: T) => { valid: boolean; error?: string }
): { valid: boolean; error?: string } {
  
  if (!Array.isArray(value)) {
    return { valid: false, error: `${fieldName} must be an array` };
  }
  
  if (value.length > maxLength) {
    return { 
      valid: false, 
      error: `${fieldName} array too long. Maximum ${maxLength} items, got ${value.length}` 
    };
  }
  
  if (itemValidator) {
    for (let i = 0; i < value.length; i++) {
      const validation = itemValidator(value[i]);
      if (!validation.valid) {
        return { 
          valid: false, 
          error: `${fieldName}[${i}]: ${validation.error}` 
        };
      }
    }
  }
  
  return { valid: true };
}

/**
 * Validate file upload
 */
export function validateFileUpload(
  file: { type: string; size: number; name?: string },
  allowedTypes: string[] = FILE_RESTRICTIONS.ALLOWED_IMAGE_TYPES
): { valid: boolean; error?: string } {
  
  if (!file || typeof file !== 'object') {
    return { valid: false, error: 'File information is required' };
  }
  
  if (!file.type || typeof file.type !== 'string') {
    return { valid: false, error: 'File type is required' };
  }
  
  if (!allowedTypes.includes(file.type.toLowerCase())) {
    return { 
      valid: false, 
      error: `File type not allowed: ${file.type}. Allowed types: ${allowedTypes.join(', ')}` 
    };
  }
  
  if (typeof file.size !== 'number' || file.size <= 0) {
    return { valid: false, error: 'Invalid file size' };
  }
  
  if (file.size > FILE_RESTRICTIONS.MAX_FILE_SIZE) {
    return { 
      valid: false, 
      error: `File too large: ${file.size} bytes. Maximum allowed: ${FILE_RESTRICTIONS.MAX_FILE_SIZE} bytes` 
    };
  }
  
  if (file.name && file.name.length > FILE_RESTRICTIONS.MAX_FILENAME_LENGTH) {
    return { 
      valid: false, 
      error: `Filename too long. Maximum ${FILE_RESTRICTIONS.MAX_FILENAME_LENGTH} characters` 
    };
  }
  
  return { valid: true };
}

/**
 * Comprehensive request validation for sensitive endpoints
 */
export async function validateSensitiveRequest(
  request: Request,
  options: {
    maxSize?: number;
    requireAuth?: boolean;
    allowedMethods?: string[];
    requireJSON?: boolean;
  } = {}
): Promise<{ valid: boolean; data?: any; error?: string; size?: number }> {
  
  const {
    maxSize = REQUEST_SIZE_LIMITS.MEDIUM,
    requireAuth = true,
    allowedMethods = ['POST'],
    requireJSON = true
  } = options;
  
  // Check HTTP method
  if (!allowedMethods.includes(request.method)) {
    return { 
      valid: false, 
      error: `Method not allowed: ${request.method}. Allowed methods: ${allowedMethods.join(', ')}` 
    };
  }
  
  // Check authentication header if required
  if (requireAuth) {
    const authHeader = request.headers.get('Authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return { valid: false, error: 'Authentication required' };
    }
  }
  
  // Check Content-Type for JSON requests
  if (requireJSON && request.method !== 'GET') {
    const contentType = request.headers.get('Content-Type');
    if (!contentType || !contentType.includes('application/json')) {
      return { valid: false, error: 'Content-Type must be application/json' };
    }
  }
  
  // Validate request size and parse JSON if required
  if (requireJSON && request.method !== 'GET') {
    return await validateAndParseJSON(request, maxSize);
  } else {
    const sizeCheck = await validateRequestSize(request, maxSize);
    return { 
      valid: sizeCheck.valid, 
      error: sizeCheck.error, 
      size: sizeCheck.size 
    };
  }
}

/**
 * Rate limiting validation based on request characteristics
 */
export function calculateRateLimit(
  endpoint: string,
  requestSize: number,
  hasFiles: boolean = false
): { limit: number; windowMs: number } {
  
  // Stricter limits for larger requests and file uploads
  if (hasFiles || requestSize > REQUEST_SIZE_LIMITS.LARGE) {
    return { limit: 10, windowMs: 60000 }; // 10 requests per minute
  }
  
  // Endpoint-specific rate limits
  if (endpoint.includes('auth') || endpoint.includes('login')) {
    return { limit: 5, windowMs: 60000 }; // 5 auth attempts per minute
  }
  
  if (endpoint.includes('message') || endpoint.includes('send')) {
    return { limit: 30, windowMs: 60000 }; // 30 messages per minute
  }
  
  if (endpoint.includes('match') || endpoint.includes('swipe')) {
    return { limit: 100, windowMs: 60000 }; // 100 swipes per minute
  }
  
  // Default rate limit
  return { limit: 60, windowMs: 60000 }; // 60 requests per minute
}

/**
 * Security headers for responses based on content type
 */
export function getResponseSecurityHeaders(
  contentType: string = 'application/json',
  hasUserData: boolean = false
): Record<string, string> {
  
  const baseHeaders: Record<string, string> = {
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
  };
  
  // Additional headers for responses with user data
  if (hasUserData) {
    baseHeaders['Cache-Control'] = 'no-store, no-cache, must-revalidate, private';
    baseHeaders['Pragma'] = 'no-cache';
    baseHeaders['Expires'] = '0';
  }
  
  // Content-specific headers
  if (contentType.includes('image')) {
    baseHeaders['Content-Security-Policy'] = "default-src 'none'; img-src 'self'";
  } else if (contentType.includes('json')) {
    baseHeaders['Content-Security-Policy'] = "default-src 'none'";
  }
  
  return baseHeaders;
}

// Export validation error types
export interface ValidationError {
  field: string;
  error: string;
  value?: any;
}

/**
 * Create standardized validation error response
 */
export function createValidationErrorResponse(
  errors: ValidationError[],
  statusCode: number = 400
): Response {
  const corsHeaders = getCorsHeaders();
  const securityHeaders = getResponseSecurityHeaders('application/json', false);
  
  return new Response(
    JSON.stringify({
      error: 'Validation failed',
      details: errors,
      timestamp: new Date().toISOString(),
    }),
    {
      status: statusCode,
      headers: {
        ...corsHeaders,
        ...securityHeaders,
        'Content-Type': 'application/json',
      },
    }
  );
}

// Import CORS headers for error responses
import { getCorsHeaders } from './cors.ts';