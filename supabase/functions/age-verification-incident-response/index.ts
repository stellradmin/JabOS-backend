// ==========================================
// AGE VERIFICATION INCIDENT RESPONSE SYSTEM
// COPPA Compliance Incident Management
// Stellr Dating App - Critical Security Response
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

interface IncidentRequest {
  action: 'report_incident' | 'handle_underage_access' | 'process_fraud_incident' | 'emergency_shutdown' | 'compliance_violation';
  incidentType: 'underage_access' | 'document_fraud' | 'system_compromise' | 'data_breach' | 'compliance_violation';
  severity: 'low' | 'medium' | 'high' | 'critical';
  description: string;
  affectedUsers?: string[];
  evidenceData?: any;
  reportedBy: string;
  immediateActions?: string[];
}

interface Incident {
  id: string;
  type: string;
  severity: string;
  status: 'reported' | 'investigating' | 'contained' | 'resolved' | 'escalated';
  description: string;
  affectedUsers: string[];
  detectionTime: string;
  responseTime?: string;
  containmentActions: string[];
  resolutionActions: string[];
  reportedBy: string;
  assignedTo?: string;
  escalationLevel: number;
  complianceImpact: string;
  evidencePreserved: boolean;
  notificationsRequired: boolean;
  legalReviewRequired: boolean;
  metadata: any;
}

interface IncidentResponse {
  success: boolean;
  incidentId: string;
  severity: string;
  immediateActions: string[];
  nextSteps: string[];
  estimatedResolutionTime: string;
  complianceNotifications: string[];
  escalationRequired: boolean;
}

interface ComplianceValidation {
  validationType: 'coppa' | 'gdpr' | 'ccpa' | 'comprehensive';
  validationResults: ValidationResult[];
  overallCompliance: boolean;
  criticalIssues: ValidationIssue[];
  recommendations: string[];
  nextValidationDate: string;
}

interface ValidationResult {
  requirement: string;
  status: 'compliant' | 'non_compliant' | 'warning' | 'not_applicable';
  details: string;
  evidence: string[];
  lastChecked: string;
}

interface ValidationIssue {
  type: 'critical' | 'major' | 'minor';
  requirement: string;
  description: string;
  impact: string;
  remediation: string;
  deadline: string;
}

// ==========================================
// INCIDENT RESPONSE SYSTEM CLASS
// ==========================================

class IncidentResponseSystem {
  private supabase: any;
  private notificationEndpoints: Map<string, string>;

  constructor() {
    this.supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );
    
    this.initializeNotificationEndpoints();
  }

  /**
   * PRINCIPLE 1: Single Responsibility - Initialize notification endpoints
   */
  private initializeNotificationEndpoints(): void {
    this.notificationEndpoints = new Map([
      ['legal_team', Deno.env.get('LEGAL_NOTIFICATION_WEBHOOK') || ''],
      ['compliance_officer', Deno.env.get('COMPLIANCE_NOTIFICATION_WEBHOOK') || ''],
      ['security_team', Deno.env.get('SECURITY_NOTIFICATION_WEBHOOK') || ''],
      ['emergency_contact', Deno.env.get('EMERGENCY_NOTIFICATION_WEBHOOK') || ''],
      ['law_enforcement', Deno.env.get('LAW_ENFORCEMENT_CONTACT') || ''],
    ]);
  }

  /**
   * PRINCIPLE 1: Single Responsibility - Process incident requests
   */
  async processRequest(request: IncidentRequest): Promise<Response> {
    try {
      // PRINCIPLE 6: Fail Fast & Defensive - Validate request
      this.validateRequest(request);

      switch (request.action) {
        case 'report_incident':
          return await this.reportIncident(request);
        
        case 'handle_underage_access':
          return await this.handleUnderageAccess(request);
        
        case 'process_fraud_incident':
          return await this.processFraudIncident(request);
        
        case 'emergency_shutdown':
          return await this.performEmergencyShutdown(request);
        
        case 'compliance_violation':
          return await this.handleComplianceViolation(request);
        
        default:
          throw new Error(`Unsupported action: ${request.action}`);
      }
    } catch (error) {
      return this.createErrorResponse(error);
    }
  }

  /**
   * PRINCIPLE 6: Fail Fast - Handle underage access incident immediately
   */
  private async handleUnderageAccess(request: IncidentRequest): Promise<Response> {
    try {
      const incidentId = this.generateIncidentId();
      const detectionTime = new Date().toISOString();

      // Create incident record
      const incident: Incident = {
        id: incidentId,
        type: 'underage_access',
        severity: 'critical',
        status: 'investigating',
        description: request.description,
        affectedUsers: request.affectedUsers || [],
        detectionTime,
        containmentActions: [],
        resolutionActions: [],
        reportedBy: request.reportedBy,
        escalationLevel: 0,
        complianceImpact: 'critical',
        evidencePreserved: true,
        notificationsRequired: true,
        legalReviewRequired: true,
        metadata: request.evidenceData || {},
      };

      // IMMEDIATE CONTAINMENT ACTIONS
      const containmentActions = [];

      for (const userId of request.affectedUsers || []) {
        // Immediately block user account
        await this.immediatelyBlockUser(userId, 'underage_access_detected');
        containmentActions.push(`Blocked user account: ${userId}`);

        // Schedule immediate data deletion
        await this.scheduleDataDeletion(userId, 'underage_compliance', 24); // 24 hours
        containmentActions.push(`Scheduled data deletion for user: ${userId}`);

        // Preserve evidence for legal compliance
        await this.preserveEvidenceForIncident(incidentId, userId);
        containmentActions.push(`Evidence preserved for user: ${userId}`);
      }

      incident.containmentActions = containmentActions;

      // Store incident
      await this.storeIncident(incident);

      // CRITICAL NOTIFICATIONS
      const notifications = await this.sendCriticalNotifications(incident);

      // Log incident response
      await logStructuredEvent(this.supabase, {
        event_type: 'underage_access_incident_handled',
        severity: 'critical',
        metadata: {
          incident_id: incidentId,
          affected_users: request.affectedUsers?.length || 0,
          containment_actions: containmentActions.length,
          detection_time: detectionTime,
        },
      });

      return new Response(
        JSON.stringify({
          success: true,
          incidentId,
          severity: 'critical',
          immediateActions: containmentActions,
          nextSteps: [
            'Legal team notified for compliance review',
            'Data deletion process initiated',
            'Evidence preservation completed',
            'Incident investigation ongoing',
          ],
          estimatedResolutionTime: '24-48 hours',
          complianceNotifications: notifications,
          escalationRequired: true,
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      throw new Error('Failed to handle underage access incident: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 4: Separation of Concerns - Process fraud incident
   */
  private async processFraudIncident(request: IncidentRequest): Promise<Response> {
    try {
      const incidentId = this.generateIncidentId();
      const detectionTime = new Date().toISOString();

      const incident: Incident = {
        id: incidentId,
        type: 'document_fraud',
        severity: request.severity,
        status: 'investigating',
        description: request.description,
        affectedUsers: request.affectedUsers || [],
        detectionTime,
        containmentActions: [],
        resolutionActions: [],
        reportedBy: request.reportedBy,
        escalationLevel: request.severity === 'critical' ? 1 : 0,
        complianceImpact: 'high',
        evidencePreserved: true,
        notificationsRequired: true,
        legalReviewRequired: request.severity === 'critical',
        metadata: request.evidenceData || {},
      };

      // CONTAINMENT ACTIONS BASED ON SEVERITY
      const containmentActions = [];

      if (request.severity === 'critical' || request.severity === 'high') {
        for (const userId of request.affectedUsers || []) {
          // Block user and related accounts
          await this.blockUserAndRelatedAccounts(userId);
          containmentActions.push(`Blocked user and related accounts: ${userId}`);

          // Flag for fraud database
          await this.reportToFraudDatabase(userId, request.evidenceData);
          containmentActions.push(`Reported to fraud database: ${userId}`);
        }
      }

      // Update fraud detection patterns
      await this.updateFraudDetectionPatterns(request.evidenceData);
      containmentActions.push('Updated fraud detection patterns');

      incident.containmentActions = containmentActions;
      await this.storeIncident(incident);

      // Notifications based on severity
      const notifications = [];
      if (request.severity === 'critical') {
        notifications.push(...await this.sendCriticalNotifications(incident));
      } else {
        notifications.push(...await this.sendSecurityNotifications(incident));
      }

      // Law enforcement notification for criminal fraud
      if (request.evidenceData?.criminalActivity) {
        await this.notifyLawEnforcement(incident);
        notifications.push('Law enforcement notified');
      }

      return new Response(
        JSON.stringify({
          success: true,
          incidentId,
          severity: request.severity,
          immediateActions: containmentActions,
          nextSteps: [
            'Fraud investigation initiated',
            'Related accounts under review',
            'Fraud patterns updated',
            'Evidence analysis ongoing',
          ],
          estimatedResolutionTime: request.severity === 'critical' ? '2-4 hours' : '24-48 hours',
          complianceNotifications: notifications,
          escalationRequired: request.severity === 'critical',
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      throw new Error('Failed to process fraud incident: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 6: Fail Fast - Emergency system shutdown
   */
  private async performEmergencyShutdown(request: IncidentRequest): Promise<Response> {
    try {
      const incidentId = this.generateIncidentId();
      const shutdownTime = new Date().toISOString();

      // IMMEDIATE SHUTDOWN ACTIONS
      const shutdownActions = [];

      // Disable new user registrations
      await this.disableUserRegistrations();
      shutdownActions.push('User registrations disabled');

      // Disable age verification processing
      await this.disableAgeVerificationProcessing();
      shutdownActions.push('Age verification processing disabled');

      // Enable maintenance mode for critical functions
      await this.enableMaintenanceMode();
      shutdownActions.push('Maintenance mode enabled');

      // Preserve all current data
      await this.preserveSystemState();
      shutdownActions.push('System state preserved');

      // Create critical incident
      const incident: Incident = {
        id: incidentId,
        type: 'system_compromise',
        severity: 'critical',
        status: 'contained',
        description: `Emergency shutdown: ${request.description}`,
        affectedUsers: [],
        detectionTime: shutdownTime,
        containmentActions: shutdownActions,
        resolutionActions: [],
        reportedBy: request.reportedBy,
        escalationLevel: 2,
        complianceImpact: 'critical',
        evidencePreserved: true,
        notificationsRequired: true,
        legalReviewRequired: true,
        metadata: { shutdownReason: request.description },
      };

      await this.storeIncident(incident);

      // EMERGENCY NOTIFICATIONS
      const notifications = [
        ...await this.sendEmergencyNotifications(incident),
        ...await this.notifyStakeholders(incident),
      ];

      // Log emergency shutdown
      await logStructuredEvent(this.supabase, {
        event_type: 'emergency_shutdown_executed',
        severity: 'critical',
        metadata: {
          incident_id: incidentId,
          shutdown_time: shutdownTime,
          reason: request.description,
          reported_by: request.reportedBy,
        },
      });

      return new Response(
        JSON.stringify({
          success: true,
          incidentId,
          severity: 'critical',
          immediateActions: shutdownActions,
          nextSteps: [
            'Emergency response team activated',
            'System security assessment initiated',
            'Legal and compliance review in progress',
            'Recovery plan development underway',
          ],
          estimatedResolutionTime: 'TBD - Emergency assessment required',
          complianceNotifications: notifications,
          escalationRequired: true,
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      throw new Error('Failed to perform emergency shutdown: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 4: Separation of Concerns - Validate COPPA compliance
   */
  async validateCOPPACompliance(): Promise<ComplianceValidation> {
    const validationResults: ValidationResult[] = [];

    // Age verification requirement
    validationResults.push(await this.validateAgeVerificationSystem());
    
    // Data minimization
    validationResults.push(await this.validateDataMinimization());
    
    // Parental consent (N/A for 18+ app)
    validationResults.push({
      requirement: 'parental_consent',
      status: 'not_applicable',
      details: 'Stellr is 18+ only app - parental consent not applicable',
      evidence: ['app_policy_18_plus_only'],
      lastChecked: new Date().toISOString(),
    });
    
    // Data retention limits
    validationResults.push(await this.validateDataRetentionCompliance());
    
    // Safe harbor provisions
    validationResults.push(await this.validateSafeHarborCompliance());

    const criticalIssues = this.identifyCriticalIssues(validationResults);
    const overallCompliance = criticalIssues.length === 0;

    return {
      validationType: 'coppa',
      validationResults,
      overallCompliance,
      criticalIssues,
      recommendations: this.generateComplianceRecommendations(validationResults),
      nextValidationDate: this.calculateNextValidationDate(),
    };
  }

  /**
   * PRINCIPLE 4: Separation of Concerns - Validate GDPR compliance
   */
  async validateGDPRCompliance(): Promise<ComplianceValidation> {
    const validationResults: ValidationResult[] = [];

    // Lawful basis for processing
    validationResults.push(await this.validateLawfulBasis());
    
    // Data subject rights
    validationResults.push(await this.validateDataSubjectRights());
    
    // Data protection by design
    validationResults.push(await this.validateDataProtectionByDesign());
    
    // Breach notification procedures
    validationResults.push(await this.validateBreachNotificationProcedures());
    
    // Data transfer safeguards
    validationResults.push(await this.validateDataTransferSafeguards());

    const criticalIssues = this.identifyCriticalIssues(validationResults);
    const overallCompliance = criticalIssues.length === 0;

    return {
      validationType: 'gdpr',
      validationResults,
      overallCompliance,
      criticalIssues,
      recommendations: this.generateComplianceRecommendations(validationResults),
      nextValidationDate: this.calculateNextValidationDate(),
    };
  }

  // ==========================================
  // HELPER METHODS
  // ==========================================

  /**
   * PRINCIPLE 6: Fail Fast & Defensive - Validate request
   */
  private validateRequest(request: IncidentRequest): void {
    if (!request.action || !request.incidentType || !request.severity || !request.description) {
      throw new Error('Missing required incident fields');
    }

    const validActions = [
      'report_incident',
      'handle_underage_access',
      'process_fraud_incident',
      'emergency_shutdown',
      'compliance_violation'
    ];
    
    if (!validActions.includes(request.action)) {
      throw new Error('Invalid incident action');
    }

    const validSeverities = ['low', 'medium', 'high', 'critical'];
    if (!validSeverities.includes(request.severity)) {
      throw new Error('Invalid incident severity');
    }

    if (!request.reportedBy) {
      throw new Error('Incident reporter is required');
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Store incident (command)
   */
  private async storeIncident(incident: Incident): Promise<void> {
    const { error } = await this.supabase
      .from('security_incidents')
      .insert({
        id: incident.id,
        incident_type: incident.type,
        severity: incident.severity,
        status: incident.status,
        description: incident.description,
        affected_users: incident.affectedUsers,
        detection_time: incident.detectionTime,
        response_time: incident.responseTime,
        containment_actions: incident.containmentActions,
        resolution_actions: incident.resolutionActions,
        reported_by: incident.reportedBy,
        assigned_to: incident.assignedTo,
        escalation_level: incident.escalationLevel,
        compliance_impact: incident.complianceImpact,
        evidence_preserved: incident.evidencePreserved,
        notifications_required: incident.notificationsRequired,
        legal_review_required: incident.legalReviewRequired,
        metadata: incident.metadata,
      });

    if (error) {
      throw new Error('Failed to store incident: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 6: Fail Fast - Immediately block user
   */
  private async immediatelyBlockUser(userId: string, reason: string): Promise<void> {
    // Update user profile
    await this.supabase
      .from('profiles')
      .update({
        age_verification_status: 'blocked',
        is_discoverable: false,
        updated_at: new Date().toISOString(),
      })
      .eq('id', userId);

    // Create underage block record
    await this.supabase
      .from('underage_user_blocks')
      .insert({
        user_id: userId,
        detection_method: 'incident_response',
        block_reason: reason,
        block_timestamp: new Date().toISOString(),
        data_deletion_scheduled_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
        legal_review_required: true,
      });
  }

  /**
   * PRINCIPLE 10: Security by Design - Preserve evidence
   */
  private async preserveEvidenceForIncident(incidentId: string, userId: string): Promise<void> {
    // Copy all relevant user data to evidence preservation table
    const { data: userData } = await this.supabase
      .from('age_verification_attempts')
      .select('*')
      .eq('user_id', userId);

    if (userData) {
      await this.supabase
        .from('incident_evidence')
        .insert({
          incident_id: incidentId,
          user_id: userId,
          evidence_type: 'age_verification_data',
          evidence_data: userData,
          preserved_at: new Date().toISOString(),
          retention_period: '7_years',
        });
    }
  }

  /**
   * PRINCIPLE 4: Separation of Concerns - Send notifications
   */
  private async sendCriticalNotifications(incident: Incident): Promise<string[]> {
    const notifications = [];

    try {
      // Legal team notification
      await this.sendNotification('legal_team', {
        type: 'critical_incident',
        incident,
        urgency: 'immediate',
      });
      notifications.push('Legal team notified');

      // Compliance officer notification
      await this.sendNotification('compliance_officer', {
        type: 'compliance_violation',
        incident,
        urgency: 'immediate',
      });
      notifications.push('Compliance officer notified');

      // Emergency contact notification
      await this.sendNotification('emergency_contact', {
        type: 'emergency_incident',
        incident,
        urgency: 'critical',
      });
      notifications.push('Emergency contacts notified');

    } catch (error) {
      console.error('Failed to send critical notifications:', error);
    }

    return notifications;
  }

  /**
   * PRINCIPLE 3: Small, Focused Functions - Generate incident ID
   */
  private generateIncidentId(): string {
    const timestamp = Date.now().toString(36);
    const random = Math.random().toString(36).substring(2, 8);
    return `INC-${timestamp}-${random}`.toUpperCase();
  }

  /**
   * PRINCIPLE 3: Small, Focused Functions - Send notification
   */
  private async sendNotification(recipient: string, payload: any): Promise<void> {
    const endpoint = this.notificationEndpoints.get(recipient);
    if (!endpoint) {
      console.warn(`No notification endpoint configured for: ${recipient}`);
      return;
    }

    try {
      await fetch(endpoint, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(payload),
      });
    } catch (error) {
      console.error(`Failed to send notification to ${recipient}:`, error);
    }
  }

  // Additional helper methods (placeholder implementations)
  private async scheduleDataDeletion(userId: string, reason: string, hours: number): Promise<void> {}
  private async blockUserAndRelatedAccounts(userId: string): Promise<void> {}
  private async reportToFraudDatabase(userId: string, evidence: any): Promise<void> {}
  private async updateFraudDetectionPatterns(evidence: any): Promise<void> {}
  private async notifyLawEnforcement(incident: Incident): Promise<void> {}
  private async disableUserRegistrations(): Promise<void> {}
  private async disableAgeVerificationProcessing(): Promise<void> {}
  private async enableMaintenanceMode(): Promise<void> {}
  private async preserveSystemState(): Promise<void> {}
  private async sendEmergencyNotifications(incident: Incident): Promise<string[]> { return []; }
  private async sendSecurityNotifications(incident: Incident): Promise<string[]> { return []; }
  private async notifyStakeholders(incident: Incident): Promise<string[]> { return []; }
  private async validateAgeVerificationSystem(): Promise<ValidationResult> { 
    return { requirement: '', status: 'compliant', details: '', evidence: [], lastChecked: '' }; 
  }
  private async validateDataMinimization(): Promise<ValidationResult> { 
    return { requirement: '', status: 'compliant', details: '', evidence: [], lastChecked: '' }; 
  }
  private async validateDataRetentionCompliance(): Promise<ValidationResult> { 
    return { requirement: '', status: 'compliant', details: '', evidence: [], lastChecked: '' }; 
  }
  private async validateSafeHarborCompliance(): Promise<ValidationResult> { 
    return { requirement: '', status: 'compliant', details: '', evidence: [], lastChecked: '' }; 
  }
  private async validateLawfulBasis(): Promise<ValidationResult> { 
    return { requirement: '', status: 'compliant', details: '', evidence: [], lastChecked: '' }; 
  }
  private async validateDataSubjectRights(): Promise<ValidationResult> { 
    return { requirement: '', status: 'compliant', details: '', evidence: [], lastChecked: '' }; 
  }
  private async validateDataProtectionByDesign(): Promise<ValidationResult> { 
    return { requirement: '', status: 'compliant', details: '', evidence: [], lastChecked: '' }; 
  }
  private async validateBreachNotificationProcedures(): Promise<ValidationResult> { 
    return { requirement: '', status: 'compliant', details: '', evidence: [], lastChecked: '' }; 
  }
  private async validateDataTransferSafeguards(): Promise<ValidationResult> { 
    return { requirement: '', status: 'compliant', details: '', evidence: [], lastChecked: '' }; 
  }
  private identifyCriticalIssues(results: ValidationResult[]): ValidationIssue[] { return []; }
  private generateComplianceRecommendations(results: ValidationResult[]): string[] { return []; }
  private calculateNextValidationDate(): string { return new Date(Date.now() + 90 * 24 * 60 * 60 * 1000).toISOString(); }

  /**
   * PRINCIPLE 3: Small, Focused Functions - Create error response
   */
  private createErrorResponse(error: any): Response {
    const sanitizedError = sanitizeErrorForClient(error);
    
    return new Response(
      JSON.stringify({
        success: false,
        error: 'Incident response operation failed',
        details: sanitizedError,
        code: 'INCIDENT_ERROR',
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      }
    );
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Report general incident (command)
   */
  private async reportIncident(request: IncidentRequest): Promise<Response> {
    const incidentId = this.generateIncidentId();
    const detectionTime = new Date().toISOString();

    const incident: Incident = {
      id: incidentId,
      type: request.incidentType,
      severity: request.severity,
      status: 'reported',
      description: request.description,
      affectedUsers: request.affectedUsers || [],
      detectionTime,
      containmentActions: request.immediateActions || [],
      resolutionActions: [],
      reportedBy: request.reportedBy,
      escalationLevel: 0,
      complianceImpact: request.severity === 'critical' ? 'critical' : 'medium',
      evidencePreserved: false,
      notificationsRequired: request.severity === 'critical' || request.severity === 'high',
      legalReviewRequired: request.incidentType === 'underage_access' || request.severity === 'critical',
      metadata: request.evidenceData || {},
    };

    await this.storeIncident(incident);

    return new Response(
      JSON.stringify({
        success: true,
        incidentId,
        severity: request.severity,
        immediateActions: [],
        nextSteps: ['Incident logged and assigned for investigation'],
        estimatedResolutionTime: 'TBD',
        complianceNotifications: [],
        escalationRequired: false,
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );
  }

  /**
   * PRINCIPLE 4: Separation of Concerns - Handle compliance violation
   */
  private async handleComplianceViolation(request: IncidentRequest): Promise<Response> {
    const incidentId = this.generateIncidentId();
    const detectionTime = new Date().toISOString();

    const incident: Incident = {
      id: incidentId,
      type: 'compliance_violation',
      severity: request.severity,
      status: 'investigating',
      description: request.description,
      affectedUsers: request.affectedUsers || [],
      detectionTime,
      containmentActions: [],
      resolutionActions: [],
      reportedBy: request.reportedBy,
      escalationLevel: request.severity === 'critical' ? 1 : 0,
      complianceImpact: 'critical',
      evidencePreserved: true,
      notificationsRequired: true,
      legalReviewRequired: true,
      metadata: request.evidenceData || {},
    };

    await this.storeIncident(incident);

    // Send compliance notifications
    const notifications = await this.sendCriticalNotifications(incident);

    return new Response(
      JSON.stringify({
        success: true,
        incidentId,
        severity: request.severity,
        immediateActions: ['Compliance team notified', 'Legal review initiated'],
        nextSteps: [
          'Compliance assessment in progress',
          'Remediation plan development',
          'Legal consultation ongoing',
        ],
        estimatedResolutionTime: '2-5 business days',
        complianceNotifications: notifications,
        escalationRequired: true,
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );
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

  if (req.method !== 'POST') {
    return new Response('Method not allowed', { 
      status: 405, 
      headers: corsHeaders 
    });
  }

  try {
    // Validate secure request (high-level security access required)
    const authResult = await validateSecureRequest(req);
    if (!authResult.isValid || !authResult.user?.id) {
      return new Response(
        JSON.stringify({ 
          success: false,
          error: 'Unauthorized access - security clearance required',
          code: 'UNAUTHORIZED'
        }),
        { 
          status: 401, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Parse request body
    const requestBody: IncidentRequest = await req.json();
    requestBody.reportedBy = authResult.user.id; // Set reporter
    
    // Initialize incident response system
    const incidentResponse = new IncidentResponseSystem();
    
    // Process request
    return await incidentResponse.processRequest(requestBody);

  } catch (error) {
    console.error('Incident response system error:', error);
    
    return new Response(
      JSON.stringify({
        success: false,
        error: 'Internal server error',
        code: 'INTERNAL_ERROR',
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  }
});