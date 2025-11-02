// ==========================================
// AGE VERIFICATION INITIATION SERVICE
// Start COPPA Compliant Age Verification Process
// Stellr Dating App - 18+ Only
// ==========================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders, createCorsResponse } from "../_shared/cors.ts";
import { validateSecureRequest } from "../_shared/security-validation.ts";
import { logStructuredEvent } from "../_shared/structured-logging.ts";
import { sanitizeErrorForClient } from "../_shared/secure-error-sanitizer.ts";

// ==========================================
// TYPES AND INTERFACES
// ==========================================

interface AgeVerificationRequest {
  userId: string;
  verificationMethod: 'self_declaration' | 'government_id' | 'credit_card' | 'phone_verification';
  selfDeclaredAge?: number;
  selfDeclaredOver18?: boolean;
  sessionMetadata?: {
    userAgent?: string;
    deviceFingerprint?: string;
    geolocation?: {
      latitude: number;
      longitude: number;
      accuracy?: number;
    };
    ipAddress?: string;
    referrer?: string;
  };
}

interface AgeVerificationResponse {
  success: boolean;
  attemptId?: string;
  status: 'started' | 'blocked' | 'error';
  nextStep?: 'document_upload' | 'credit_card_verification' | 'phone_verification' | 'manual_review';
  blockReason?: string;
  message: string;
  sessionId: string;
  requirements?: {
    acceptedDocuments?: string[];
    maxFileSize?: number;
    supportedFormats?: string[];
  };
}

// ==========================================
// AGE VERIFICATION INITIATOR CLASS
// ==========================================

class AgeVerificationInitiator {
  private supabase: any;

  constructor() {
    this.supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );
  }

  /**
   * PRINCIPLE 1: Single Responsibility - Initiate age verification process
   */
  async initiateVerification(request: AgeVerificationRequest, clientIP: string): Promise<AgeVerificationResponse> {
    const sessionId = crypto.randomUUID();
    
    try {
      // PRINCIPLE 6: Fail Fast & Defensive - Validate input early
      this.validateVerificationRequest(request);
      
      // PRINCIPLE 6: Fail Fast - Check for immediate disqualification
      if (request.verificationMethod === 'self_declaration' && 
          (request.selfDeclaredOver18 === false || (request.selfDeclaredAge && request.selfDeclaredAge < 18))) {
        return await this.handleUnderageDeclaration(request, sessionId, clientIP);
      }
      
      // Check if user already has verification in progress
      const existingAttempt = await this.checkExistingVerificationAttempt(request.userId);
      if (existingAttempt) {
        return this.createExistingAttemptResponse(existingAttempt, sessionId);
      }
      
      // Start verification attempt
      const attemptId = await this.startVerificationAttempt(request, sessionId, clientIP);
      
      // PRINCIPLE 4: Separation of Concerns - Route to appropriate verification method
      return await this.routeToVerificationMethod(request.verificationMethod, attemptId, sessionId);
      
    } catch (error) {
      await this.logVerificationError(request.userId, error, sessionId);
      return this.createErrorResponse(error, sessionId);
    }
  }

  /**
   * PRINCIPLE 6: Fail Fast & Defensive - Validate all inputs
   */
  private validateVerificationRequest(request: AgeVerificationRequest): void {
    if (!request.userId || typeof request.userId !== 'string') {
      throw new Error('Invalid or missing userId');
    }

    if (!request.verificationMethod || !this.isValidVerificationMethod(request.verificationMethod)) {
      throw new Error('Invalid verification method');
    }

    // Validate self-declaration specific fields
    if (request.verificationMethod === 'self_declaration') {
      if (request.selfDeclaredOver18 === undefined && request.selfDeclaredAge === undefined) {
        throw new Error('Self-declaration requires either selfDeclaredOver18 or selfDeclaredAge');
      }
      
      if (request.selfDeclaredAge !== undefined && 
          (typeof request.selfDeclaredAge !== 'number' || request.selfDeclaredAge < 0 || request.selfDeclaredAge > 150)) {
        throw new Error('Invalid selfDeclaredAge - must be between 0 and 150');
      }
    }

    // Validate session metadata if provided
    if (request.sessionMetadata) {
      this.validateSessionMetadata(request.sessionMetadata);
    }
  }

  /**
   * PRINCIPLE 6: Fail Fast - Immediately handle underage declarations
   */
  private async handleUnderageDeclaration(
    request: AgeVerificationRequest, 
    sessionId: string, 
    clientIP: string
  ): Promise<AgeVerificationResponse> {
    const declaredAge = request.selfDeclaredAge || (request.selfDeclaredOver18 === false ? 17 : null);
    
    // Log the underage declaration attempt
    await logStructuredEvent(this.supabase, {
      event_type: 'underage_self_declaration',
      severity: 'critical',
      user_id: request.userId,
      ip_address: clientIP,
      metadata: {
        declared_age: declaredAge,
        session_id: sessionId,
        user_agent: request.sessionMetadata?.userAgent,
        device_fingerprint: request.sessionMetadata?.deviceFingerprint
      }
    });
    
    // Create a blocked attempt record for audit purposes
    const attemptId = await this.createBlockedAttempt(request, sessionId, clientIP, 'underage_declaration');
    
    // Immediately handle underage user detection
    if (declaredAge !== null) {
      await this.supabase.rpc('handle_underage_user_detection', {
        p_user_id: request.userId,
        p_detection_method: 'self_declaration',
        p_detected_age: declaredAge,
        p_block_reason: 'User declared age under 18',
        p_ip_address: clientIP,
        p_device_fingerprint: request.sessionMetadata?.deviceFingerprint || null
      });
    }
    
    return {
      success: false,
      attemptId,
      status: 'blocked',
      blockReason: 'underage_declaration',
      message: 'Access denied. Stellr is only available to users 18 years of age or older.',
      sessionId
    };
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Query existing attempts
   */
  private async checkExistingVerificationAttempt(userId: string): Promise<any> {
    const { data, error } = await this.supabase
      .from('age_verification_attempts')
      .select('id, attempt_status, verification_method, created_at')
      .eq('user_id', userId)
      .in('attempt_status', ['pending', 'processing', 'requires_manual_review'])
      .order('created_at', { ascending: false })
      .limit(1);

    if (error) {
      throw new Error('Failed to check existing verification attempts: ' + error.message);
    }

    return data && data.length > 0 ? data[0] : null;
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Start verification attempt (command)
   */
  private async startVerificationAttempt(
    request: AgeVerificationRequest, 
    sessionId: string, 
    clientIP: string
  ): Promise<string> {
    const { data, error } = await this.supabase.rpc('start_age_verification', {
      p_user_id: request.userId,
      p_verification_method: request.verificationMethod,
      p_session_id: sessionId,
      p_ip_address: clientIP,
      p_user_agent: request.sessionMetadata?.userAgent || null,
      p_device_fingerprint: request.sessionMetadata?.deviceFingerprint || null,
      p_geolocation: request.sessionMetadata?.geolocation ? JSON.stringify(request.sessionMetadata.geolocation) : null
    });

    if (error) {
      throw new Error('Failed to start verification attempt: ' + error.message);
    }

    // Log verification attempt started
    await logStructuredEvent(this.supabase, {
      event_type: 'age_verification_started',
      severity: 'medium',
      user_id: request.userId,
      ip_address: clientIP,
      metadata: {
        attempt_id: data,
        verification_method: request.verificationMethod,
        session_id: sessionId
      }
    });

    return data;
  }

  /**
   * PRINCIPLE 4: Separation of Concerns - Route to appropriate verification method
   */
  private async routeToVerificationMethod(
    method: string, 
    attemptId: string, 
    sessionId: string
  ): Promise<AgeVerificationResponse> {
    switch (method) {
      case 'government_id':
        return this.createDocumentUploadResponse(attemptId, sessionId);
      
      case 'credit_card':
        return this.createCreditCardResponse(attemptId, sessionId);
      
      case 'phone_verification':
        return this.createPhoneVerificationResponse(attemptId, sessionId);
      
      case 'self_declaration':
        // Self-declaration passed, proceed to document verification
        return this.createDocumentUploadResponse(attemptId, sessionId);
      
      default:
        throw new Error(`Unsupported verification method: ${method}`);
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Create blocked attempt record (command)
   */
  private async createBlockedAttempt(
    request: AgeVerificationRequest,
    sessionId: string,
    clientIP: string,
    blockReason: string
  ): Promise<string> {
    const attemptId = crypto.randomUUID();
    
    const { error } = await this.supabase
      .from('age_verification_attempts')
      .insert({
        id: attemptId,
        user_id: request.userId,
        session_id: sessionId,
        verification_method: request.verificationMethod,
        attempt_status: 'blocked',
        ip_address: clientIP,
        user_agent: request.sessionMetadata?.userAgent,
        device_fingerprint: request.sessionMetadata?.deviceFingerprint,
        geolocation: request.sessionMetadata?.geolocation || null,
        metadata: {
          block_reason: blockReason,
          declared_age: request.selfDeclaredAge,
          declared_over_18: request.selfDeclaredOver18
        }
      });

    if (error) {
      throw new Error('Failed to create blocked attempt record: ' + error.message);
    }

    return attemptId;
  }

  // ==========================================
  // RESPONSE CREATORS (PRINCIPLE 3: Small, Focused Functions)
  // ==========================================

  private createDocumentUploadResponse(attemptId: string, sessionId: string): AgeVerificationResponse {
    return {
      success: true,
      attemptId,
      status: 'started',
      nextStep: 'document_upload',
      message: 'Please upload a government-issued photo ID to verify your age',
      sessionId,
      requirements: {
        acceptedDocuments: [
          'Driver\'s License',
          'Passport',
          'National ID Card',
          'State-issued ID',
          'Military ID'
        ],
        maxFileSize: 10 * 1024 * 1024, // 10MB
        supportedFormats: ['JPEG', 'PNG', 'PDF']
      }
    };
  }

  private createCreditCardResponse(attemptId: string, sessionId: string): AgeVerificationResponse {
    return {
      success: true,
      attemptId,
      status: 'started',
      nextStep: 'credit_card_verification',
      message: 'Please provide credit card information for age verification',
      sessionId,
      requirements: {
        acceptedDocuments: ['Valid credit card with matching name'],
        maxFileSize: 0,
        supportedFormats: []
      }
    };
  }

  private createPhoneVerificationResponse(attemptId: string, sessionId: string): AgeVerificationResponse {
    return {
      success: true,
      attemptId,
      status: 'started',
      nextStep: 'phone_verification',
      message: 'Please provide phone number for age verification',
      sessionId,
      requirements: {
        acceptedDocuments: ['Valid phone number with carrier age verification'],
        maxFileSize: 0,
        supportedFormats: []
      }
    };
  }

  private createExistingAttemptResponse(existingAttempt: any, sessionId: string): AgeVerificationResponse {
    const nextSteps: Record<string, string> = {
      'government_id': 'document_upload',
      'credit_card': 'credit_card_verification',
      'phone_verification': 'phone_verification'
    };

    return {
      success: true,
      attemptId: existingAttempt.id,
      status: 'started',
      nextStep: nextSteps[existingAttempt.verification_method] || 'manual_review',
      message: `Continuing existing ${existingAttempt.verification_method} verification`,
      sessionId
    };
  }

  private createErrorResponse(error: any, sessionId: string): AgeVerificationResponse {
    const sanitizedError = sanitizeErrorForClient(error);
    
    return {
      success: false,
      status: 'error',
      message: 'Failed to start age verification process',
      sessionId
    };
  }

  // ==========================================
  // HELPER METHODS (PRINCIPLE 3: Small, Focused Functions)
  // ==========================================

  private isValidVerificationMethod(method: string): boolean {
    const validMethods = ['self_declaration', 'government_id', 'credit_card', 'phone_verification'];
    return validMethods.includes(method);
  }

  private validateSessionMetadata(metadata: any): void {
    if (metadata.geolocation) {
      const { latitude, longitude, accuracy } = metadata.geolocation;
      
      if (typeof latitude !== 'number' || latitude < -90 || latitude > 90) {
        throw new Error('Invalid latitude in geolocation');
      }
      
      if (typeof longitude !== 'number' || longitude < -180 || longitude > 180) {
        throw new Error('Invalid longitude in geolocation');
      }
      
      if (accuracy !== undefined && (typeof accuracy !== 'number' || accuracy < 0)) {
        throw new Error('Invalid accuracy in geolocation');
      }
    }

    if (metadata.userAgent && typeof metadata.userAgent !== 'string') {
      throw new Error('Invalid userAgent format');
    }

    if (metadata.deviceFingerprint && typeof metadata.deviceFingerprint !== 'string') {
      throw new Error('Invalid deviceFingerprint format');
    }
  }

  private async logVerificationError(userId: string, error: any, sessionId: string): Promise<void> {
    try {
      await logStructuredEvent(this.supabase, {
        event_type: 'age_verification_error',
        severity: 'high',
        user_id: userId,
        metadata: {
          session_id: sessionId,
          error_message: error.message,
          error_stack: error.stack?.substring(0, 1000)
        }
      });
    } catch (logError) {
      console.error('Failed to log verification error:', logError);
    }
  }

  private getClientIP(request: Request): string {
    // Get client IP from various possible headers
    const xForwardedFor = request.headers.get('x-forwarded-for');
    const xRealIP = request.headers.get('x-real-ip');
    const cfConnectingIP = request.headers.get('cf-connecting-ip');
    
    if (xForwardedFor) {
      return xForwardedFor.split(',')[0].trim();
    }
    
    if (xRealIP) {
      return xRealIP;
    }
    
    if (cfConnectingIP) {
      return cfConnectingIP;
    }
    
    return 'unknown';
  }
}

// ==========================================
// MAIN HANDLER
// ==========================================

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return createCorsResponse();
  }

  // PRINCIPLE 6: Fail Fast & Defensive - Validate request method
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { 
      status: 405, 
      headers: corsHeaders 
    });
  }

  try {
    // PRINCIPLE 10: Security by Design - Validate secure request
    const authResult = await validateSecureRequest(req);
    if (!authResult.isValid) {
      return new Response(
        JSON.stringify({ 
          success: false,
          status: 'error',
          message: 'Unauthorized access',
          sessionId: crypto.randomUUID()
        }),
        { 
          status: 401, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Parse request body
    const requestBody: AgeVerificationRequest = await req.json();
    
    // Get client IP for security logging
    const clientIP = getClientIP(req);
    
    // Initialize verification process
    const initiator = new AgeVerificationInitiator();
    const response = await initiator.initiateVerification(requestBody, clientIP);

    return new Response(
      JSON.stringify(response),
      {
        status: response.success ? 200 : 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('Age verification initiation error:', error);
    
    const errorResponse: AgeVerificationResponse = {
      success: false,
      status: 'error',
      message: 'Internal server error during verification initiation',
      sessionId: crypto.randomUUID()
    };

    return new Response(
      JSON.stringify(errorResponse),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});

// ==========================================
// UTILITY FUNCTIONS
// ==========================================

function getClientIP(request: Request): string {
  const xForwardedFor = request.headers.get('x-forwarded-for');
  const xRealIP = request.headers.get('x-real-ip');
  const cfConnectingIP = request.headers.get('cf-connecting-ip');
  
  if (xForwardedFor) {
    return xForwardedFor.split(',')[0].trim();
  }
  
  if (xRealIP) {
    return xRealIP;
  }
  
  if (cfConnectingIP) {
    return cfConnectingIP;
  }
  
  return 'unknown';
}