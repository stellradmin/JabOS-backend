/**
 * ENHANCED RATE LIMITING for Stellr Security System
 * 
 * Production-ready rate limiting enhancements with enum support
 * Implements advanced threat detection and prevention
 */

import { applyRateLimit as baseApplyRateLimit } from './rate-limit-middleware.ts';
import { logSecurityEvent, SecurityEventType, SecuritySeverity } from './security-monitoring.ts';
import { generateRequestFingerprint, analyzeBehavior, RequestFingerprint } from './security-enhancements-v2.ts';

// Enhanced rate limit categories as enum for type safety
export enum RateLimitCategory {
  AUTHENTICATION = 'AUTHENTICATION',
  MATCHING = 'MATCHING',
  COMPATIBILITY = 'COMPATIBILITY', 
  PROFILE_UPDATES = 'PROFILE_UPDATES',
  MESSAGING = 'MESSAGING',
  FILE_UPLOADS = 'FILE_UPLOADS',
  PAYMENTS = 'PAYMENTS',
  DEFAULT = 'DEFAULT',
  EXEMPT = 'EXEMPT'
}

// Enhanced rate limiting with behavioral analysis
interface RateLimitResult {
  blocked: boolean;
  response?: Response;
  remaining?: number;
  resetTime?: number;
  category?: RateLimitCategory;
  fingerprint?: RequestFingerprint;
  behaviorAnalysis?: any;
}

// Store recent fingerprints for behavior analysis (in-memory for Edge Function)
const recentFingerprints = new Map<string, RequestFingerprint[]>();

/**
 * Enhanced rate limiting with security fingerprinting
 */
export async function applyRateLimit(
  request: Request,
  endpoint: string,
  userId?: string,
  category?: RateLimitCategory
): Promise<RateLimitResult> {
  
  // Generate request fingerprint for advanced analysis
  const fingerprint = generateRequestFingerprint(request);
  
  // Store fingerprint for behavior analysis
  const identifier = userId || fingerprint.ip;
  if (!recentFingerprints.has(identifier)) {
    recentFingerprints.set(identifier, []);
  }
  
  const userFingerprints = recentFingerprints.get(identifier)!;
  userFingerprints.push(fingerprint);
  
  // Keep only last 20 fingerprints and only for last hour
  const oneHourAgo = Date.now() - 60 * 60 * 1000;
  const recentFingerprints_filtered = userFingerprints
    .filter(fp => fp.timestamp > oneHourAgo)
    .slice(-20);
  recentFingerprints.set(identifier, recentFingerprints_filtered);
  
  // Behavioral analysis for bot detection
  let behaviorAnalysis = null;
  if (recentFingerprints_filtered.length >= 5) {
    behaviorAnalysis = analyzeBehavior(recentFingerprints_filtered);
    
    // Block suspicious behavior
    if (!behaviorAnalysis.isHuman && behaviorAnalysis.riskScore > 5) {
      await logSecurityEvent(
        SecurityEventType.SUSPICIOUS_PATTERN,
        SecuritySeverity.HIGH,
        {
          endpoint,
          behaviorAnalysis,
          fingerprint,
          reason: 'automated_behavior_detected'
        },
        {
          userId,
          ip: fingerprint.ip,
          userAgent: fingerprint.userAgent,
          endpoint
        }
      );
      
      return {
        blocked: true,
        response: new Response(
          JSON.stringify({
            error: 'Suspicious activity detected',
            message: 'Request blocked due to automated behavior patterns',
            requestId: fingerprint.id,
            timestamp: new Date().toISOString()
          }),
          {
            status: 429,
            headers: {
              'Content-Type': 'application/json',
              'Retry-After': '300', // 5 minutes
              'X-Security-Block': 'behavioral'
            }
          }
        ),
        fingerprint,
        behaviorAnalysis
      };
    }
  }
  
  // Apply standard rate limiting
  const standardResult = await baseApplyRateLimit(request, endpoint, userId);
  
  return {
    blocked: !standardResult.allowed,
    response: standardResult.response,
    remaining: standardResult.rateLimitInfo?.remaining,
    resetTime: standardResult.rateLimitInfo?.resetTime,
    category: category || RateLimitCategory.DEFAULT,
    fingerprint,
    behaviorAnalysis
  };
}

/**
 * Cleanup old fingerprints to prevent memory leaks
 * DISABLED: setInterval at module level causes BOOT_ERROR in Edge Functions
 */
// setInterval(() => {
//   const oneHourAgo = Date.now() - 60 * 60 * 1000;
//
//   for (const [identifier, fingerprints] of recentFingerprints.entries()) {
//     const recent = fingerprints.filter(fp => fp.timestamp > oneHourAgo);
//
//     if (recent.length === 0) {
//       recentFingerprints.delete(identifier);
//     } else {
//       recentFingerprints.set(identifier, recent);
//     }
//   }
// }, 15 * 60 * 1000); // Cleanup every 15 minutes