// ==========================================
// ⚠️ DEPRECATED - LEGACY AGE VERIFICATION ⚠️
// ==========================================
//
// ⚠️ THIS FUNCTION IS DEPRECATED AND NOT USED IN PRODUCTION ⚠️
//
// Legacy document processing with mock OCR implementations.
//
// REPLACED BY: Persona Identity Verification
// - create-persona-inquiry: Creates verification sessions
// - persona-webhook: Processes verification results
// - Full liveness detection and document verification
//
// This function remains for reference only and should be removed
// in a future cleanup. It contains mock implementations and is
// not suitable for production use.
//
// Status: DEPRECATED (as of 2025-10-25)
// Migration: Complete (Persona fully integrated)
// ==========================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders, createCorsResponse } from "../_shared/cors.ts";
import { validateSecureRequest } from "../_shared/security-validation.ts";
import { logStructuredEvent } from "../_shared/structured-logging.ts";
import { sanitizeErrorForClient } from "../_shared/secure-error-sanitizer.ts";
import { validateInput } from "../_shared/input-validation.ts";

// ==========================================
// TYPES AND INTERFACES
// ==========================================

interface DocumentProcessingRequest {
  attemptId: string;
  documentData: string; // Base64 encoded document
  documentType: 'drivers_license' | 'passport' | 'national_id' | 'state_id' | 'military_id';
  sessionId: string;
  metadata?: {
    fileName?: string;
    fileSize?: number;
    deviceInfo?: string;
  };
}

interface OCRResult {
  success: boolean;
  extractedData: {
    dateOfBirth?: string;
    fullName?: string;
    documentNumber?: string;
    expiryDate?: string;
    issuingAuthority?: string;
    country?: string;
  };
  confidence: number;
  processingTime: number;
  errors?: string[];
}

interface FraudDetectionResult {
  isFraudulent: boolean;
  fraudScore: number; // 0-100
  fraudIndicators: string[];
  confidence: number;
  riskLevel: 'low' | 'medium' | 'high' | 'critical';
}

interface AgeVerificationResult {
  isValid: boolean;
  age: number | null;
  isOver18: boolean;
  birthDate: Date | null;
  confidence: number;
  validationErrors: string[];
}

interface DocumentAuthenticityResult {
  isAuthentic: boolean;
  confidence: number;
  securityFeatures: {
    watermark: boolean;
    hologram: boolean;
    microtext: boolean;
    uvFeatures: boolean;
  };
  suspiciousIndicators: string[];
}

// ==========================================
// SECURE DOCUMENT PROCESSOR CLASS
// ==========================================

class SecureDocumentProcessor {
  private supabase: any;
  private processingStartTime: number;

  constructor() {
    this.supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );
    this.processingStartTime = Date.now();
  }

  /**
   * PRINCIPLE 1: Single Responsibility - Process and verify age from document
   */
  async processDocument(request: DocumentProcessingRequest): Promise<Response> {
    const startTime = Date.now();
    let documentBuffer: Uint8Array | null = null;
    
    try {
      // Validate input according to PRINCIPLE 6: Fail Fast & Defensive
      this.validateDocumentRequest(request);
      
      // Convert base64 to buffer for processing
      documentBuffer = this.decodeDocumentData(request.documentData);
      
      // PRINCIPLE 4: Separation of Concerns - Each step has single responsibility
      const ocrResult = await this.performOCR(documentBuffer, request.documentType);
      const authenticityResult = await this.validateDocumentAuthenticity(documentBuffer, ocrResult);
      const fraudResult = await this.detectFraud(documentBuffer, ocrResult, request.attemptId);
      const ageResult = await this.verifyAge(ocrResult.extractedData);
      
      // PRINCIPLE 6: Fail Fast - Immediately reject underage or fraudulent documents
      if (ageResult.age !== null && ageResult.age < 18) {
        await this.handleUnderageDetection(request.attemptId, ageResult.age);
        return this.createRejectionResponse('underage_detected', 'User is under 18 years old');
      }
      
      if (fraudResult.isFraudulent || fraudResult.fraudScore > 80) {
        await this.handleFraudDetection(request.attemptId, fraudResult);
        return this.createRejectionResponse('fraud_detected', 'Document appears to be fraudulent');
      }
      
      // Determine if manual review is required
      const requiresManualReview = this.shouldRequireManualReview(
        ocrResult, authenticityResult, fraudResult, ageResult
      );
      
      // Complete verification process
      const verificationSuccess = await this.completeVerification(
        request.attemptId,
        ocrResult,
        authenticityResult,
        fraudResult,
        ageResult,
        requiresManualReview,
        Date.now() - startTime
      );
      
      // Return appropriate response
      if (requiresManualReview) {
        return this.createManualReviewResponse(request.attemptId);
      } else if (verificationSuccess) {
        return this.createSuccessResponse(ageResult.age!);
      } else {
        return this.createRejectionResponse('verification_failed', 'Document verification failed');
      }
      
    } catch (error) {
      await this.logProcessingError(request.attemptId, error);
      return this.createErrorResponse(error);
    } finally {
      // PRINCIPLE 10: Security by Design - Immediately destroy document data
      if (documentBuffer) {
        this.secureDelete(documentBuffer);
      }
      this.secureDelete(request.documentData);
    }
  }

  /**
   * PRINCIPLE 6: Fail Fast & Defensive - Validate all inputs early
   */
  private validateDocumentRequest(request: DocumentProcessingRequest): void {
    if (!request.attemptId || !request.documentData || !request.documentType || !request.sessionId) {
      throw new Error('Missing required fields in document processing request');
    }

    // Validate document type
    const validTypes = ['drivers_license', 'passport', 'national_id', 'state_id', 'military_id'];
    if (!validTypes.includes(request.documentType)) {
      throw new Error(`Invalid document type: ${request.documentType}`);
    }

    // Validate base64 data
    if (!this.isValidBase64(request.documentData)) {
      throw new Error('Invalid document data format');
    }

    // Check file size limits (10MB max)
    const sizeEstimate = (request.documentData.length * 3) / 4;
    if (sizeEstimate > 10 * 1024 * 1024) {
      throw new Error('Document file too large (max 10MB)');
    }
  }

  /**
   * PRINCIPLE 10: Security by Design - Secure base64 decoding with validation
   */
  private decodeDocumentData(base64Data: string): Uint8Array {
    try {
      // Remove data URL prefix if present
      const cleanBase64 = base64Data.replace(/^data:[^;]+;base64,/, '');
      
      // Decode and validate
      const buffer = Uint8Array.from(atob(cleanBase64), c => c.charCodeAt(0));
      
      // Validate file signature (PDF, JPEG, PNG)
      if (!this.isValidFileType(buffer)) {
        throw new Error('Unsupported or invalid file format');
      }
      
      return buffer;
    } catch (error) {
      throw new Error('Failed to decode document data: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 3: Small, Focused Functions - OCR processing
   */
  private async performOCR(documentBuffer: Uint8Array, documentType: string): Promise<OCRResult> {
    const startTime = Date.now();
    
    try {
      // Use AWS Textract for OCR (most secure and accurate for IDs)
      const ocrResponse = await this.callAWSTextract(documentBuffer, documentType);
      
      const extractedData = this.parseOCRResponse(ocrResponse, documentType);
      const confidence = this.calculateOCRConfidence(ocrResponse);
      
      return {
        success: true,
        extractedData,
        confidence,
        processingTime: Date.now() - startTime
      };
    } catch (error) {
      return {
        success: false,
        extractedData: {},
        confidence: 0,
        processingTime: Date.now() - startTime,
        errors: [error.message]
      };
    }
  }

  /**
   * PRINCIPLE 4: Separation of Concerns - Document authenticity validation
   */
  private async validateDocumentAuthenticity(
    documentBuffer: Uint8Array, 
    ocrResult: OCRResult
  ): Promise<DocumentAuthenticityResult> {
    try {
      // Check for digital manipulation
      const manipulationScore = await this.detectDigitalManipulation(documentBuffer);
      
      // Validate document structure and layout
      const structureValid = await this.validateDocumentStructure(documentBuffer, ocrResult);
      
      // Check security features presence
      const securityFeatures = await this.detectSecurityFeatures(documentBuffer);
      
      const confidence = Math.min(
        1 - manipulationScore,
        structureValid ? 0.9 : 0.3,
        this.calculateSecurityFeatureScore(securityFeatures)
      );
      
      const suspiciousIndicators = [];
      if (manipulationScore > 0.3) suspiciousIndicators.push('digital_manipulation_detected');
      if (!structureValid) suspiciousIndicators.push('invalid_document_structure');
      if (!securityFeatures.watermark) suspiciousIndicators.push('missing_watermark');
      
      return {
        isAuthentic: confidence > 0.7 && suspiciousIndicators.length === 0,
        confidence,
        securityFeatures,
        suspiciousIndicators
      };
    } catch (error) {
      return {
        isAuthentic: false,
        confidence: 0,
        securityFeatures: {
          watermark: false,
          hologram: false,
          microtext: false,
          uvFeatures: false
        },
        suspiciousIndicators: ['authenticity_check_failed']
      };
    }
  }

  /**
   * PRINCIPLE 4: Separation of Concerns - Fraud detection
   */
  private async detectFraud(
    documentBuffer: Uint8Array,
    ocrResult: OCRResult,
    attemptId: string
  ): Promise<FraudDetectionResult> {
    try {
      const fraudIndicators: string[] = [];
      let fraudScore = 0;
      
      // Check for duplicate document usage
      const documentHash = await this.generateDocumentHash(documentBuffer);
      const duplicateCheck = await this.checkDuplicateUsage(documentHash);
      if (duplicateCheck.isDuplicate) {
        fraudIndicators.push('duplicate_document_usage');
        fraudScore += 40;
      }
      
      // Check extracted data consistency
      const consistencyScore = this.validateDataConsistency(ocrResult.extractedData);
      if (consistencyScore < 0.7) {
        fraudIndicators.push('inconsistent_data_extraction');
        fraudScore += 20;
      }
      
      // Check against known fraud patterns
      const patternMatch = await this.checkFraudPatterns(ocrResult.extractedData);
      if (patternMatch.isMatch) {
        fraudIndicators.push('known_fraud_pattern');
        fraudScore += 50;
      }
      
      // Age consistency checks
      if (ocrResult.extractedData.dateOfBirth) {
        const ageConsistency = this.validateAgeConsistency(ocrResult.extractedData.dateOfBirth);
        if (!ageConsistency.isConsistent) {
          fraudIndicators.push('age_inconsistency');
          fraudScore += 30;
        }
      }
      
      const riskLevel = this.calculateRiskLevel(fraudScore);
      
      // Store fraud detection result for future reference
      if (fraudScore > 50 || fraudIndicators.length > 2) {
        await this.storeFraudDetectionResult(documentHash, fraudIndicators, fraudScore);
      }
      
      return {
        isFraudulent: fraudScore > 60,
        fraudScore,
        fraudIndicators,
        confidence: Math.min(0.95, fraudScore / 100 + 0.1),
        riskLevel
      };
    } catch (error) {
      // Default to suspicious on error
      return {
        isFraudulent: true,
        fraudScore: 80,
        fraudIndicators: ['fraud_detection_error'],
        confidence: 0.9,
        riskLevel: 'high'
      };
    }
  }

  /**
   * PRINCIPLE 3: Small, Focused Functions - Age verification
   */
  private async verifyAge(extractedData: any): Promise<AgeVerificationResult> {
    const validationErrors: string[] = [];
    
    try {
      if (!extractedData.dateOfBirth) {
        validationErrors.push('Date of birth not found in document');
        return {
          isValid: false,
          age: null,
          isOver18: false,
          birthDate: null,
          confidence: 0,
          validationErrors
        };
      }
      
      // Parse birth date with multiple format support
      const birthDate = this.parseBirthDate(extractedData.dateOfBirth);
      if (!birthDate) {
        validationErrors.push('Invalid date of birth format');
        return {
          isValid: false,
          age: null,
          isOver18: false,
          birthDate: null,
          confidence: 0,
          validationErrors
        };
      }
      
      // Calculate age precisely
      const age = this.calculateAge(birthDate);
      
      // Validate age is reasonable (0-150)
      if (age < 0 || age > 150) {
        validationErrors.push('Unrealistic age calculated');
        return {
          isValid: false,
          age: null,
          isOver18: false,
          birthDate: null,
          confidence: 0,
          validationErrors
        };
      }
      
      // Check if birth date is in the future
      if (birthDate > new Date()) {
        validationErrors.push('Birth date cannot be in the future');
        return {
          isValid: false,
          age: null,
          isOver18: false,
          birthDate: null,
          confidence: 0,
          validationErrors
        };
      }
      
      return {
        isValid: true,
        age,
        isOver18: age >= 18,
        birthDate,
        confidence: 0.95,
        validationErrors
      };
    } catch (error) {
      validationErrors.push('Age verification processing error');
      return {
        isValid: false,
        age: null,
        isOver18: false,
        birthDate: null,
        confidence: 0,
        validationErrors
      };
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Complete verification (command)
   */
  private async completeVerification(
    attemptId: string,
    ocrResult: OCRResult,
    authenticityResult: DocumentAuthenticityResult,
    fraudResult: FraudDetectionResult,
    ageResult: AgeVerificationResult,
    requiresManualReview: boolean,
    processingTimeMs: number
  ): Promise<boolean> {
    try {
      const { data, error } = await this.supabase.rpc('complete_age_verification', {
        p_attempt_id: attemptId,
        p_is_verified: ageResult.isValid && ageResult.isOver18 && authenticityResult.isAuthentic && !fraudResult.isFraudulent,
        p_verified_age: ageResult.age,
        p_verification_confidence: Math.min(
          ocrResult.confidence,
          authenticityResult.confidence,
          ageResult.confidence,
          1 - (fraudResult.fraudScore / 100)
        ),
        p_document_type: ocrResult.extractedData.documentNumber ? 'government_id' : 'unknown',
        p_issuing_authority: ocrResult.extractedData.issuingAuthority || null,
        p_document_expiry_date: ocrResult.extractedData.expiryDate || null,
        p_verification_provider: 'aws_textract',
        p_fraud_score: fraudResult.fraudScore,
        p_fraud_indicators: JSON.stringify(fraudResult.fraudIndicators),
        p_requires_manual_review: requiresManualReview,
        p_manual_review_reason: this.getManualReviewReason(ocrResult, authenticityResult, fraudResult, ageResult),
        p_processing_time_ms: processingTimeMs
      });

      if (error) {
        throw new Error('Failed to complete verification: ' + error.message);
      }

      return data;
    } catch (error) {
      await this.logProcessingError(attemptId, error);
      throw error;
    }
  }

  /**
   * PRINCIPLE 6: Fail Fast & Defensive - Handle underage detection immediately
   */
  private async handleUnderageDetection(attemptId: string, age: number): Promise<void> {
    try {
      // Get attempt details
      const { data: attempt } = await this.supabase
        .from('age_verification_attempts')
        .select('user_id, ip_address, device_fingerprint')
        .eq('id', attemptId)
        .single();

      if (attempt) {
        // Call the underage handler function
        await this.supabase.rpc('handle_underage_user_detection', {
          p_user_id: attempt.user_id,
          p_detection_method: 'id_verification',
          p_detected_age: age,
          p_block_reason: 'Age verification revealed user is under 18',
          p_ip_address: attempt.ip_address,
          p_device_fingerprint: attempt.device_fingerprint
        });

        // Log critical security event
        await logStructuredEvent(this.supabase, {
          event_type: 'underage_user_blocked',
          severity: 'critical',
          user_id: attempt.user_id,
          metadata: {
            detection_method: 'id_verification',
            detected_age: age,
            attempt_id: attemptId
          }
        });
      }
    } catch (error) {
      console.error('Failed to handle underage detection:', error);
      // Continue processing to ensure user is still blocked
    }
  }

  /**
   * PRINCIPLE 10: Security by Design - Handle fraud detection
   */
  private async handleFraudDetection(attemptId: string, fraudResult: FraudDetectionResult): Promise<void> {
    try {
      // Log fraud event
      await logStructuredEvent(this.supabase, {
        event_type: 'document_fraud_detected',
        severity: 'high',
        metadata: {
          attempt_id: attemptId,
          fraud_score: fraudResult.fraudScore,
          fraud_indicators: fraudResult.fraudIndicators,
          risk_level: fraudResult.riskLevel
        }
      });

      // Update attempt status
      await this.supabase
        .from('age_verification_attempts')
        .update({ 
          attempt_status: 'blocked',
          updated_at: new Date().toISOString()
        })
        .eq('id', attemptId);
    } catch (error) {
      console.error('Failed to handle fraud detection:', error);
    }
  }

  /**
   * PRINCIPLE 10: Security by Design - Secure memory cleanup
   */
  private secureDelete(data: any): void {
    if (typeof data === 'string') {
      // Overwrite string memory
      data = '\0'.repeat(data.length);
    } else if (data instanceof Uint8Array) {
      // Overwrite buffer memory
      data.fill(0);
    }
    data = null;
  }

  // ==========================================
  // HELPER METHODS
  // ==========================================

  private isValidBase64(str: string): boolean {
    try {
      const cleanStr = str.replace(/^data:[^;]+;base64,/, '');
      return btoa(atob(cleanStr)) === cleanStr;
    } catch {
      return false;
    }
  }

  private isValidFileType(buffer: Uint8Array): boolean {
    // Check file signatures
    const signatures = {
      jpeg: [0xFF, 0xD8, 0xFF],
      png: [0x89, 0x50, 0x4E, 0x47],
      pdf: [0x25, 0x50, 0x44, 0x46]
    };

    for (const [type, sig] of Object.entries(signatures)) {
      if (buffer.length >= sig.length) {
        const match = sig.every((byte, i) => buffer[i] === byte);
        if (match) return true;
      }
    }
    return false;
  }

  private calculateAge(birthDate: Date): number {
    const today = new Date();
    let age = today.getFullYear() - birthDate.getFullYear();
    const monthDiff = today.getMonth() - birthDate.getMonth();
    
    if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < birthDate.getDate())) {
      age--;
    }
    
    return age;
  }

  private parseBirthDate(dateString: string): Date | null {
    // Support multiple date formats
    const formats = [
      /(\d{2})\/(\d{2})\/(\d{4})/,  // MM/DD/YYYY
      /(\d{2})-(\d{2})-(\d{4})/,   // MM-DD-YYYY
      /(\d{4})\/(\d{2})\/(\d{2})/,  // YYYY/MM/DD
      /(\d{4})-(\d{2})-(\d{2})/    // YYYY-MM-DD
    ];

    for (const format of formats) {
      const match = dateString.match(format);
      if (match) {
        const [, part1, part2, part3] = match;
        
        // Try different date interpretations
        const attempts = [
          new Date(parseInt(part3), parseInt(part1) - 1, parseInt(part2)), // MM/DD/YYYY
          new Date(parseInt(part1), parseInt(part2) - 1, parseInt(part3))  // YYYY/MM/DD
        ];

        for (const date of attempts) {
          if (!isNaN(date.getTime())) {
            return date;
          }
        }
      }
    }

    return null;
  }

  private shouldRequireManualReview(
    ocrResult: OCRResult,
    authenticityResult: DocumentAuthenticityResult,
    fraudResult: FraudDetectionResult,
    ageResult: AgeVerificationResult
  ): boolean {
    return (
      ocrResult.confidence < 0.8 ||
      authenticityResult.confidence < 0.7 ||
      fraudResult.fraudScore > 40 ||
      !ageResult.isValid ||
      fraudResult.riskLevel === 'high' ||
      authenticityResult.suspiciousIndicators.length > 1
    );
  }

  private getManualReviewReason(
    ocrResult: OCRResult,
    authenticityResult: DocumentAuthenticityResult,
    fraudResult: FraudDetectionResult,
    ageResult: AgeVerificationResult
  ): string {
    const reasons = [];
    
    if (ocrResult.confidence < 0.8) reasons.push('low_ocr_confidence');
    if (authenticityResult.confidence < 0.7) reasons.push('questionable_authenticity');
    if (fraudResult.fraudScore > 40) reasons.push('elevated_fraud_score');
    if (!ageResult.isValid) reasons.push('age_verification_issues');
    if (fraudResult.riskLevel === 'high') reasons.push('high_risk_indicators');
    
    return reasons.join(', ') || 'comprehensive_review_required';
  }

  private calculateRiskLevel(fraudScore: number): 'low' | 'medium' | 'high' | 'critical' {
    if (fraudScore >= 80) return 'critical';
    if (fraudScore >= 60) return 'high';
    if (fraudScore >= 30) return 'medium';
    return 'low';
  }

  // Response creators following PRINCIPLE 3: Small, Focused Functions
  private createSuccessResponse(age: number): Response {
    return new Response(
      JSON.stringify({
        success: true,
        verified: true,
        age,
        isOver18: age >= 18,
        requiresManualReview: false,
        message: 'Age verification completed successfully'
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200
      }
    );
  }

  private createManualReviewResponse(attemptId: string): Response {
    return new Response(
      JSON.stringify({
        success: true,
        verified: false,
        requiresManualReview: true,
        attemptId,
        message: 'Document submitted for manual review',
        estimatedReviewTime: '24-48 hours'
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 202
      }
    );
  }

  private createRejectionResponse(reason: string, message: string): Response {
    return new Response(
      JSON.stringify({
        success: false,
        verified: false,
        requiresManualReview: false,
        reason,
        message,
        blocked: reason === 'underage_detected'
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400
      }
    );
  }

  private createErrorResponse(error: any): Response {
    const sanitizedError = sanitizeErrorForClient(error);
    return new Response(
      JSON.stringify({
        success: false,
        error: 'Document processing failed',
        details: sanitizedError,
        code: 'PROCESSING_ERROR'
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500
      }
    );
  }

  private async logProcessingError(attemptId: string, error: any): Promise<void> {
    try {
      await logStructuredEvent(this.supabase, {
        event_type: 'document_processing_error',
        severity: 'high',
        metadata: {
          attempt_id: attemptId,
          error_message: error.message,
          error_stack: error.stack?.substring(0, 1000)
        }
      });
    } catch (logError) {
      console.error('Failed to log processing error:', logError);
    }
  }

  // Placeholder methods for external service integrations
  private async callAWSTextract(buffer: Uint8Array, documentType: string): Promise<any> {
    // Implementation would integrate with AWS Textract
    // For now, return mock data for development
    return {
      extractedText: "Sample extracted text",
      confidence: 0.95,
      fields: {}
    };
  }

  private parseOCRResponse(response: any, documentType: string): any {
    // Parse OCR response based on document type
    return {
      dateOfBirth: '1995-05-15',
      fullName: 'Sample User',
      documentNumber: 'D123456789'
    };
  }

  private calculateOCRConfidence(response: any): number {
    return response.confidence || 0.8;
  }

  private async detectDigitalManipulation(buffer: Uint8Array): Promise<number> {
    // Implement digital manipulation detection
    return 0.1; // Mock low manipulation score
  }

  private async validateDocumentStructure(buffer: Uint8Array, ocrResult: OCRResult): Promise<boolean> {
    // Validate document structure
    return true; // Mock valid structure
  }

  private async detectSecurityFeatures(buffer: Uint8Array): Promise<any> {
    // Detect security features
    return {
      watermark: true,
      hologram: false,
      microtext: true,
      uvFeatures: false
    };
  }

  private calculateSecurityFeatureScore(features: any): number {
    const featureCount = Object.values(features).filter(Boolean).length;
    return featureCount / Object.keys(features).length;
  }

  private async generateDocumentHash(buffer: Uint8Array): Promise<string> {
    const hashBuffer = await crypto.subtle.digest('SHA-256', buffer);
    return Array.from(new Uint8Array(hashBuffer))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');
  }

  private async checkDuplicateUsage(hash: string): Promise<{ isDuplicate: boolean }> {
    const { data } = await this.supabase
      .from('document_fraud_detection')
      .select('id')
      .eq('document_hash', hash)
      .limit(1);
    
    return { isDuplicate: data && data.length > 0 };
  }

  private validateDataConsistency(extractedData: any): number {
    // Validate data consistency
    let score = 1.0;
    
    if (!extractedData.dateOfBirth) score -= 0.3;
    if (!extractedData.fullName) score -= 0.2;
    if (!extractedData.documentNumber) score -= 0.2;
    
    return Math.max(0, score);
  }

  private async checkFraudPatterns(extractedData: any): Promise<{ isMatch: boolean }> {
    // Check against known fraud patterns
    return { isMatch: false };
  }

  private validateAgeConsistency(dateOfBirth: string): { isConsistent: boolean } {
    // Validate age consistency
    const birthDate = this.parseBirthDate(dateOfBirth);
    const age = birthDate ? this.calculateAge(birthDate) : null;
    
    return {
      isConsistent: age !== null && age >= 0 && age <= 150
    };
  }

  private async storeFraudDetectionResult(hash: string, indicators: string[], score: number): Promise<void> {
    await this.supabase
      .from('document_fraud_detection')
      .upsert({
        document_hash: hash,
        fraud_type: indicators[0] || 'general_fraud',
        detection_method: 'ai_analysis',
        confidence_score: score / 100,
        detection_count: 1,
        metadata: { indicators, score }
      });
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

  // PRINCIPLE 6: Fail Fast & Defensive - Validate request early
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
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Parse and validate request body
    const requestBody = await req.json();
    const processor = new SecureDocumentProcessor();
    
    // Process document
    return await processor.processDocument(requestBody);

  } catch (error) {
    console.error('Age verification document processing error:', error);
    
    return new Response(
      JSON.stringify({
        success: false,
        error: 'Internal server error',
        code: 'INTERNAL_ERROR'
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});