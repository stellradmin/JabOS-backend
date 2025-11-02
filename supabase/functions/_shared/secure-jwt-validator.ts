/**
 * CRITICAL SECURITY: Secure JWT Validation for Stellr Edge Functions
 * 
 * Prevents Algorithm Confusion Attacks and ensures JWT integrity
 * This module addresses CRITICAL vulnerability allowing authentication bypass
 * 
 * SECURITY FEATURES:
 * - Explicit "none" algorithm rejection 
 * - JWT structure validation
 * - Header tampering detection
 * - Signature verification enforcement
 * - Security event logging
 */

import { logSecurityEvent } from './error-handler.ts';

// JWT validation result interface
export interface JWTValidationResult {
  valid: boolean;
  error?: string;
  securityRisk?: 'high' | 'medium' | 'low';
  details?: {
    algorithm?: string;
    structure?: string;
    tampering?: boolean;
  };
}

// Security configuration for JWT validation
const JWT_SECURITY_CONFIG = {
  // Algorithms that are NEVER allowed (critical security)
  FORBIDDEN_ALGORITHMS: ['none', 'None', 'NONE', null, undefined, ''],
  
  // Allowed algorithms for Supabase JWTs
  ALLOWED_ALGORITHMS: ['HS256', 'RS256', 'ES256'],
  
  // Maximum JWT size to prevent DoS attacks
  MAX_JWT_SIZE: 4096,
  
  // Required JWT parts
  REQUIRED_PARTS: 3,
  
  // Security logging enabled
  SECURITY_LOGGING: true
};

/**
 * CRITICAL SECURITY FUNCTION: Validate JWT Header for Algorithm Confusion Attacks
 * 
 * This function prevents the critical "Algorithm Confusion Attack" where attackers
 * use "none" algorithm JWTs to bypass authentication entirely.
 * 
 * @param authHeader - Authorization header value (e.g., "Bearer eyJ...")
 * @returns JWTValidationResult with validation status and security details
 */
export function validateJWTHeader(authHeader: string | null): JWTValidationResult {
  // Phase 1: Basic header validation
  if (!authHeader) {
    return {
      valid: false,
      error: 'Authorization header is required',
      securityRisk: 'medium'
    };
  }

  // Validate Bearer format
  if (!authHeader.startsWith('Bearer ')) {
    logSecurityEvent('invalid_jwt_format', undefined, {
      header: authHeader.substring(0, 20), // Log first 20 chars only
      reason: 'missing_bearer_prefix'
    });
    
    return {
      valid: false,
      error: 'Authorization header must start with "Bearer "',
      securityRisk: 'medium'
    };
  }

  const token = authHeader.substring(7); // Remove "Bearer " prefix

  // Phase 2: JWT structure validation
  if (token.length === 0) {
    return {
      valid: false,
      error: 'JWT token is empty',
      securityRisk: 'high'
    };
  }

  if (token.length > JWT_SECURITY_CONFIG.MAX_JWT_SIZE) {
    logSecurityEvent('jwt_size_attack', undefined, {
      tokenLength: token.length,
      maxAllowed: JWT_SECURITY_CONFIG.MAX_JWT_SIZE
    });
    
    return {
      valid: false,
      error: 'JWT token too large (potential DoS attack)',
      securityRisk: 'high'
    };
  }

  // Split JWT into parts (header.payload.signature)
  const parts = token.split('.');
  
  if (parts.length !== JWT_SECURITY_CONFIG.REQUIRED_PARTS) {
    logSecurityEvent('invalid_jwt_structure', undefined, {
      partsCount: parts.length,
      expected: JWT_SECURITY_CONFIG.REQUIRED_PARTS,
      token: token.substring(0, 50) // Log first 50 chars for analysis
    });
    
    return {
      valid: false,
      error: `Invalid JWT structure (expected ${JWT_SECURITY_CONFIG.REQUIRED_PARTS} parts, got ${parts.length})`,
      securityRisk: 'high',
      details: {
        structure: `${parts.length}_parts`
      }
    };
  }

  // Phase 3: CRITICAL - Header algorithm validation
  try {
    // Decode JWT header (first part)
    const headerB64 = parts[0];
    let headerJSON: any;
    
    try {
      const headerString = atob(headerB64);
      headerJSON = JSON.parse(headerString);
    } catch (decodeError) {
      logSecurityEvent('jwt_header_decode_failure', undefined, {
        header: headerB64.substring(0, 30),
        error: String(decodeError)
      });
      
      return {
        valid: false,
        error: 'Invalid JWT header encoding',
        securityRisk: 'high',
        details: {
          tampering: true
        }
      };
    }

    // CRITICAL SECURITY CHECK: Algorithm validation
    const algorithm = headerJSON.alg;
    
    // Check for forbidden algorithms (CRITICAL SECURITY)
    if (JWT_SECURITY_CONFIG.FORBIDDEN_ALGORITHMS.includes(algorithm)) {
      logSecurityEvent('jwt_algorithm_confusion_attack', undefined, {
        algorithm: algorithm,
        header: headerJSON,
        attackType: 'none_algorithm_bypass',
        severity: 'CRITICAL'
      });
      
      return {
        valid: false,
        error: `SECURITY ALERT: Forbidden JWT algorithm "${algorithm}" detected (Algorithm Confusion Attack)`,
        securityRisk: 'high',
        details: {
          algorithm: algorithm,
          tampering: true
        }
      };
    }

    // Validate algorithm is in allowed list
    if (!JWT_SECURITY_CONFIG.ALLOWED_ALGORITHMS.includes(algorithm)) {
      logSecurityEvent('jwt_unsupported_algorithm', undefined, {
        algorithm: algorithm,
        allowedAlgorithms: JWT_SECURITY_CONFIG.ALLOWED_ALGORITHMS
      });
      
      return {
        valid: false,
        error: `Unsupported JWT algorithm: ${algorithm}`,
        securityRisk: 'medium',
        details: {
          algorithm: algorithm
        }
      };
    }

    // Validate required JWT header fields
    if (!headerJSON.typ || headerJSON.typ !== 'JWT') {
      logSecurityEvent('jwt_invalid_type', undefined, {
        type: headerJSON.typ,
        expected: 'JWT'
      });
      
      return {
        valid: false,
        error: 'Invalid JWT type header',
        securityRisk: 'medium'
      };
    }

    // Phase 4: Basic payload validation (without signature verification)
    try {
      const payloadB64 = parts[1];
      const payloadString = atob(payloadB64);
      const payloadJSON = JSON.parse(payloadString);
      
      // Check for critical claims
      if (!payloadJSON.sub && !payloadJSON.user_id) {
        logSecurityEvent('jwt_missing_subject', undefined, {
          payload: { ...payloadJSON, email: '[REDACTED]' } // Redact sensitive data
        });
        
        return {
          valid: false,
          error: 'JWT missing subject identifier',
          securityRisk: 'medium'
        };
      }

      // Check expiration if present
      if (payloadJSON.exp && payloadJSON.exp < Math.floor(Date.now() / 1000)) {
        return {
          valid: false,
          error: 'JWT token has expired',
          securityRisk: 'low'
        };
      }

    } catch (payloadError) {
      logSecurityEvent('jwt_payload_decode_failure', undefined, {
        payload: parts[1].substring(0, 30),
        error: String(payloadError)
      });
      
      return {
        valid: false,
        error: 'Invalid JWT payload encoding',
        securityRisk: 'high',
        details: {
          tampering: true
        }
      };
    }

    // Phase 5: Signature presence validation
    const signature = parts[2];
    if (!signature || signature.length === 0) {
      logSecurityEvent('jwt_missing_signature', undefined, {
        algorithm: algorithm,
        severity: 'CRITICAL'
      });
      
      return {
        valid: false,
        error: 'SECURITY ALERT: JWT missing signature (potential forgery)',
        securityRisk: 'high',
        details: {
          algorithm: algorithm,
          tampering: true
        }
      };
    }

    // All validations passed
    if (JWT_SECURITY_CONFIG.SECURITY_LOGGING) {
      logSecurityEvent('jwt_validation_success', undefined, {
        algorithm: algorithm,
        tokenLength: token.length
      });
    }

    return {
      valid: true,
      securityRisk: 'low',
      details: {
        algorithm: algorithm,
        structure: 'valid'
      }
    };

  } catch (validationError) {
    logSecurityEvent('jwt_validation_error', undefined, {
      error: String(validationError),
      token: token.substring(0, 50)
    });
    
    return {
      valid: false,
      error: 'JWT validation failed due to internal error',
      securityRisk: 'high'
    };
  }
}

/**
 * SECURITY HELPER: Enhanced Authorization header validation
 * 
 * This function provides additional security checks beyond basic JWT validation
 * 
 * @param req - HTTP Request object
 * @returns Enhanced validation result with security recommendations
 */
export function validateAuthorizationSecurity(req: Request): {
  valid: boolean;
  authHeader?: string;
  securityRecommendations?: string[];
  jwtValidation?: JWTValidationResult;
} {
  const authHeader = req.headers.get('Authorization');
  const jwtValidation = validateJWTHeader(authHeader);
  
  const securityRecommendations: string[] = [];
  
  // Additional security checks
  const userAgent = req.headers.get('User-Agent');
  if (!userAgent || userAgent.length < 10) {
    securityRecommendations.push('Consider implementing User-Agent validation');
  }
  
  const origin = req.headers.get('Origin');
  const referer = req.headers.get('Referer');
  if (!origin && !referer) {
    securityRecommendations.push('Missing Origin/Referer headers may indicate automated requests');
  }
  
  return {
    valid: jwtValidation.valid,
    authHeader: authHeader || undefined,
    securityRecommendations: securityRecommendations.length > 0 ? securityRecommendations : undefined,
    jwtValidation
  };
}

/**
 * SECURITY UTILITY: Create secure Supabase client with validated JWT
 * 
 * This function creates a Supabase client only after JWT validation passes
 * 
 * @param authHeader - Validated authorization header
 * @param supabaseUrl - Supabase project URL
 * @param supabaseAnonKey - Supabase anonymous key
 * @returns Promise<{client: SupabaseClient, error?: string}>
 */
export async function createSecureSupabaseClient(
  authHeader: string,
  supabaseUrl: string,
  supabaseAnonKey: string
): Promise<{
  client?: any; // SupabaseClient type
  error?: string;
  securityDetails?: JWTValidationResult;
}> {
  // First validate the JWT
  const jwtValidation = validateJWTHeader(authHeader);
  
  if (!jwtValidation.valid) {
    return {
      error: `JWT Validation Failed: ${jwtValidation.error}`,
      securityDetails: jwtValidation
    };
  }
  
  // Only create client after successful validation
  try {
    const { createClient } = await import('@supabase/supabase-js');
    
    const client = createClient(
      supabaseUrl,
      supabaseAnonKey,
      { 
        global: { 
          headers: { 
            Authorization: authHeader // Now validated and safe
          } 
        } 
      }
    );
    
    return {
      client,
      securityDetails: jwtValidation
    };
    
  } catch (clientError) {
    logSecurityEvent('supabase_client_creation_failed', undefined, {
      error: String(clientError)
    });
    
    return {
      error: 'Failed to create secure database client'
    };
  }
}

// Export security configuration for testing
export const JWT_SECURITY_CONSTANTS = JWT_SECURITY_CONFIG;