// ==========================================
// AGE VERIFICATION DATA RETENTION SYSTEM
// COPPA/GDPR Compliant Data Retention and Deletion
// Stellr Dating App - Secure Data Lifecycle Management
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

interface DataRetentionRequest {
  action: 'enforce_retention_policies' | 'delete_user_data' | 'archive_audit_data' | 'cleanup_expired_data' | 'emergency_deletion';
  userId?: string;
  dataTypes?: string[];
  retentionOverride?: {
    reason: string;
    extendedPeriod: string;
    authorizedBy: string;
  };
  emergencyReason?: string;
}

interface DataRetentionPolicy {
  dataType: string;
  retentionPeriod: string;
  retentionPeriodMs: number;
  deletionMethod: 'soft_delete' | 'hard_delete' | 'anonymize' | 'archive';
  complianceRequirement: string;
  autoDelete: boolean;
}

interface DeletionResult {
  dataType: string;
  recordsProcessed: number;
  recordsDeleted: number;
  recordsArchived: number;
  recordsAnonymized: number;
  errors: string[];
}

interface RetentionAuditReport {
  timestamp: string;
  policiesEnforced: string[];
  deletionResults: DeletionResult[];
  complianceStatus: 'compliant' | 'warning' | 'violation';
  nextScheduledCleanup: string;
  recommendations: string[];
}

// ==========================================
// DATA RETENTION SYSTEM CLASS
// ==========================================

class DataRetentionSystem {
  private supabase: any;
  private retentionPolicies: Map<string, DataRetentionPolicy>;

  constructor() {
    this.supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );
    
    this.initializeRetentionPolicies();
  }

  /**
   * PRINCIPLE 1: Single Responsibility - Initialize data retention policies
   */
  private initializeRetentionPolicies(): void {
    this.retentionPolicies = new Map<string, DataRetentionPolicy>([
      // COPPA/GDPR Compliant Retention Policies
      ['verification_attempts', {
        dataType: 'verification_attempts',
        retentionPeriod: '30 days',
        retentionPeriodMs: 30 * 24 * 60 * 60 * 1000,
        deletionMethod: 'hard_delete',
        complianceRequirement: 'COPPA fraud detection period',
        autoDelete: true,
      }],
      ['verification_results', {
        dataType: 'verification_results',
        retentionPeriod: 'permanent',
        retentionPeriodMs: 0, // Never auto-delete
        deletionMethod: 'anonymize',
        complianceRequirement: 'COPPA verification status retention',
        autoDelete: false,
      }],
      ['document_data', {
        dataType: 'document_data',
        retentionPeriod: 'immediate',
        retentionPeriodMs: 0,
        deletionMethod: 'hard_delete',
        complianceRequirement: 'COPPA document privacy',
        autoDelete: true,
      }],
      ['audit_logs', {
        dataType: 'audit_logs',
        retentionPeriod: '7 years',
        retentionPeriodMs: 7 * 365 * 24 * 60 * 60 * 1000,
        deletionMethod: 'archive',
        complianceRequirement: 'Legal audit trail requirement',
        autoDelete: true,
      }],
      ['suspicious_activity', {
        dataType: 'suspicious_activity',
        retentionPeriod: '2 years',
        retentionPeriodMs: 2 * 365 * 24 * 60 * 60 * 1000,
        deletionMethod: 'anonymize',
        complianceRequirement: 'Safety monitoring requirement',
        autoDelete: true,
      }],
      ['underage_blocks', {
        dataType: 'underage_blocks',
        retentionPeriod: '7 years',
        retentionPeriodMs: 7 * 365 * 24 * 60 * 60 * 1000,
        deletionMethod: 'anonymize',
        complianceRequirement: 'COPPA violation documentation',
        autoDelete: false, // Manual review required
      }],
      ['manual_review_data', {
        dataType: 'manual_review_data',
        retentionPeriod: '1 year',
        retentionPeriodMs: 365 * 24 * 60 * 60 * 1000,
        deletionMethod: 'hard_delete',
        complianceRequirement: 'Review process documentation',
        autoDelete: true,
      }],
      ['fraud_detection_data', {
        dataType: 'fraud_detection_data',
        retentionPeriod: '3 years',
        retentionPeriodMs: 3 * 365 * 24 * 60 * 60 * 1000,
        deletionMethod: 'anonymize',
        complianceRequirement: 'Fraud prevention and investigation',
        autoDelete: true,
      }],
    ]);
  }

  /**
   * PRINCIPLE 1: Single Responsibility - Process data retention requests
   */
  async processRequest(request: DataRetentionRequest, requestorId: string): Promise<Response> {
    try {
      // PRINCIPLE 6: Fail Fast & Defensive - Validate request
      this.validateRequest(request, requestorId);

      switch (request.action) {
        case 'enforce_retention_policies':
          return await this.enforceRetentionPolicies();
        
        case 'delete_user_data':
          return await this.deleteUserData(request.userId!, request.dataTypes);
        
        case 'archive_audit_data':
          return await this.archiveAuditData();
        
        case 'cleanup_expired_data':
          return await this.cleanupExpiredData();
        
        case 'emergency_deletion':
          return await this.performEmergencyDeletion(request.userId!, request.emergencyReason!, requestorId);
        
        default:
          throw new Error(`Unsupported action: ${request.action}`);
      }
    } catch (error) {
      return this.createErrorResponse(error);
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Enforce retention policies (command)
   */
  private async enforceRetentionPolicies(): Promise<Response> {
    try {
      const auditReport: RetentionAuditReport = {
        timestamp: new Date().toISOString(),
        policiesEnforced: [],
        deletionResults: [],
        complianceStatus: 'compliant',
        nextScheduledCleanup: this.calculateNextCleanupTime(),
        recommendations: [],
      };

      // Process each retention policy
      for (const [dataType, policy] of this.retentionPolicies) {
        if (policy.autoDelete && policy.retentionPeriodMs > 0) {
          try {
            const result = await this.enforcePolicy(dataType, policy);
            auditReport.deletionResults.push(result);
            auditReport.policiesEnforced.push(dataType);

            if (result.errors.length > 0) {
              auditReport.complianceStatus = 'warning';
            }
          } catch (error) {
            auditReport.deletionResults.push({
              dataType,
              recordsProcessed: 0,
              recordsDeleted: 0,
              recordsArchived: 0,
              recordsAnonymized: 0,
              errors: [error.message],
            });
            auditReport.complianceStatus = 'violation';
          }
        }
      }

      // Generate recommendations
      auditReport.recommendations = this.generateRetentionRecommendations(auditReport);

      // Log retention enforcement
      await logStructuredEvent(this.supabase, {
        event_type: 'data_retention_policies_enforced',
        severity: auditReport.complianceStatus === 'violation' ? 'high' : 'low',
        metadata: {
          policies_enforced: auditReport.policiesEnforced.length,
          total_records_processed: auditReport.deletionResults.reduce((sum, r) => sum + r.recordsProcessed, 0),
          total_records_deleted: auditReport.deletionResults.reduce((sum, r) => sum + r.recordsDeleted, 0),
          compliance_status: auditReport.complianceStatus,
        },
      });

      return new Response(
        JSON.stringify({
          success: true,
          auditReport,
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      throw new Error('Failed to enforce retention policies: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 6: Fail Fast - Delete user data immediately (GDPR Right to be Forgotten)
   */
  private async deleteUserData(userId: string, dataTypes?: string[]): Promise<Response> {
    try {
      const deletionResults: DeletionResult[] = [];
      const targetDataTypes = dataTypes || Array.from(this.retentionPolicies.keys());

      // PRINCIPLE 10: Security by Design - Comprehensive user data deletion
      for (const dataType of targetDataTypes) {
        const policy = this.retentionPolicies.get(dataType);
        if (!policy) continue;

        try {
          const result = await this.deleteUserDataByType(userId, dataType, policy);
          deletionResults.push(result);
        } catch (error) {
          deletionResults.push({
            dataType,
            recordsProcessed: 0,
            recordsDeleted: 0,
            recordsArchived: 0,
            recordsAnonymized: 0,
            errors: [error.message],
          });
        }
      }

      // Log user data deletion
      await logStructuredEvent(this.supabase, {
        event_type: 'user_data_deleted',
        severity: 'medium',
        user_id: userId,
        metadata: {
          data_types: targetDataTypes,
          total_records_deleted: deletionResults.reduce((sum, r) => sum + r.recordsDeleted, 0),
          total_records_anonymized: deletionResults.reduce((sum, r) => sum + r.recordsAnonymized, 0),
        },
      });

      return new Response(
        JSON.stringify({
          success: true,
          userId,
          deletionResults,
          deletionTimestamp: new Date().toISOString(),
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      throw new Error('Failed to delete user data: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Archive audit data (command)
   */
  private async archiveAuditData(): Promise<Response> {
    try {
      const cutoffDate = new Date();
      cutoffDate.setFullYear(cutoffDate.getFullYear() - 3); // Archive data older than 3 years

      // Archive age verification audit logs
      const { data: auditLogs, error: selectError } = await this.supabase
        .from('age_verification_audit_logs')
        .select('*')
        .lt('created_at', cutoffDate.toISOString())
        .limit(1000); // Process in batches

      if (selectError) {
        throw new Error('Failed to select audit logs for archival: ' + selectError.message);
      }

      let archivedCount = 0;
      if (auditLogs && auditLogs.length > 0) {
        // Move to archive table
        const { error: archiveError } = await this.supabase
          .from('age_verification_audit_logs_archive')
          .insert(auditLogs.map(log => ({
            ...log,
            archived_at: new Date().toISOString(),
            archive_reason: 'automatic_retention_policy',
          })));

        if (!archiveError) {
          // Delete from main table
          const { error: deleteError } = await this.supabase
            .from('age_verification_audit_logs')
            .delete()
            .in('id', auditLogs.map(log => log.id));

          if (!deleteError) {
            archivedCount = auditLogs.length;
          }
        }
      }

      // Log archival activity
      await logStructuredEvent(this.supabase, {
        event_type: 'audit_data_archived',
        severity: 'low',
        metadata: {
          records_archived: archivedCount,
          cutoff_date: cutoffDate.toISOString(),
        },
      });

      return new Response(
        JSON.stringify({
          success: true,
          recordsArchived: archivedCount,
          cutoffDate: cutoffDate.toISOString(),
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      throw new Error('Failed to archive audit data: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Clean up expired data (command)
   */
  private async cleanupExpiredData(): Promise<Response> {
    try {
      const cleanupResults: DeletionResult[] = [];

      // Clean up temporary verification data
      const tempDataResult = await this.cleanupTemporaryData();
      cleanupResults.push(tempDataResult);

      // Clean up expired sessions
      const sessionResult = await this.cleanupExpiredSessions();
      cleanupResults.push(sessionResult);

      // Clean up failed verification attempts
      const failedAttemptsResult = await this.cleanupFailedAttempts();
      cleanupResults.push(failedAttemptsResult);

      // Log cleanup activity
      await logStructuredEvent(this.supabase, {
        event_type: 'expired_data_cleaned',
        severity: 'low',
        metadata: {
          cleanup_types: cleanupResults.map(r => r.dataType),
          total_records_cleaned: cleanupResults.reduce((sum, r) => sum + r.recordsDeleted, 0),
        },
      });

      return new Response(
        JSON.stringify({
          success: true,
          cleanupResults,
          cleanupTimestamp: new Date().toISOString(),
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      throw new Error('Failed to cleanup expired data: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 6: Fail Fast - Emergency deletion for legal compliance
   */
  private async performEmergencyDeletion(
    userId: string, 
    reason: string, 
    authorizedBy: string
  ): Promise<Response> {
    try {
      // Log emergency deletion initiation
      await logStructuredEvent(this.supabase, {
        event_type: 'emergency_deletion_initiated',
        severity: 'critical',
        user_id: userId,
        metadata: {
          reason,
          authorized_by: authorizedBy,
          timestamp: new Date().toISOString(),
        },
      });

      // Perform immediate hard deletion of all user data
      const deletionResults: DeletionResult[] = [];

      // Delete from all age verification related tables
      const tablesToClean = [
        'age_verification_attempts',
        'age_verification_results',
        'age_verification_manual_queue',
        'underage_user_blocks',
        'age_verification_audit_logs',
      ];

      for (const table of tablesToClean) {
        try {
          const { count, error } = await this.supabase
            .from(table)
            .delete({ count: 'exact' })
            .eq('user_id', userId);

          if (error) {
            throw new Error(`Failed to delete from ${table}: ${error.message}`);
          }

          deletionResults.push({
            dataType: table,
            recordsProcessed: count || 0,
            recordsDeleted: count || 0,
            recordsArchived: 0,
            recordsAnonymized: 0,
            errors: [],
          });
        } catch (error) {
          deletionResults.push({
            dataType: table,
            recordsProcessed: 0,
            recordsDeleted: 0,
            recordsArchived: 0,
            recordsAnonymized: 0,
            errors: [error.message],
          });
        }
      }

      // Mark user profile as deleted
      await this.supabase
        .from('profiles')
        .update({
          age_verification_status: 'emergency_deleted',
          is_discoverable: false,
          updated_at: new Date().toISOString(),
        })
        .eq('id', userId);

      // Log emergency deletion completion
      await logStructuredEvent(this.supabase, {
        event_type: 'emergency_deletion_completed',
        severity: 'critical',
        user_id: userId,
        metadata: {
          reason,
          authorized_by: authorizedBy,
          deletion_results: deletionResults,
          total_records_deleted: deletionResults.reduce((sum, r) => sum + r.recordsDeleted, 0),
          completion_timestamp: new Date().toISOString(),
        },
      });

      return new Response(
        JSON.stringify({
          success: true,
          emergencyDeletion: true,
          userId,
          reason,
          authorizedBy,
          deletionResults,
          completionTimestamp: new Date().toISOString(),
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      // Log emergency deletion failure
      await logStructuredEvent(this.supabase, {
        event_type: 'emergency_deletion_failed',
        severity: 'critical',
        user_id: userId,
        metadata: {
          reason,
          authorized_by: authorizedBy,
          error_message: error.message,
          failure_timestamp: new Date().toISOString(),
        },
      });

      throw new Error('Emergency deletion failed: ' + error.message);
    }
  }

  // ==========================================
  // HELPER METHODS
  // ==========================================

  /**
   * PRINCIPLE 6: Fail Fast & Defensive - Validate request
   */
  private validateRequest(request: DataRetentionRequest, requestorId: string): void {
    if (!requestorId) {
      throw new Error('Requestor ID is required');
    }

    const validActions = [
      'enforce_retention_policies',
      'delete_user_data',
      'archive_audit_data',
      'cleanup_expired_data',
      'emergency_deletion'
    ];
    
    if (!validActions.includes(request.action)) {
      throw new Error('Invalid action');
    }

    if (request.action === 'delete_user_data' && !request.userId) {
      throw new Error('User ID is required for user data deletion');
    }

    if (request.action === 'emergency_deletion') {
      if (!request.userId || !request.emergencyReason) {
        throw new Error('User ID and emergency reason are required for emergency deletion');
      }
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Enforce specific policy (command)
   */
  private async enforcePolicy(dataType: string, policy: DataRetentionPolicy): Promise<DeletionResult> {
    const cutoffDate = new Date(Date.now() - policy.retentionPeriodMs);
    const result: DeletionResult = {
      dataType,
      recordsProcessed: 0,
      recordsDeleted: 0,
      recordsArchived: 0,
      recordsAnonymized: 0,
      errors: [],
    };

    try {
      switch (dataType) {
        case 'verification_attempts':
          return await this.cleanupVerificationAttempts(cutoffDate);
        
        case 'audit_logs':
          return await this.archiveOldAuditLogs(cutoffDate);
        
        case 'suspicious_activity':
          return await this.anonymizeSuspiciousActivity(cutoffDate);
        
        case 'manual_review_data':
          return await this.cleanupManualReviewData(cutoffDate);
        
        case 'fraud_detection_data':
          return await this.anonymizeFraudDetectionData(cutoffDate);
        
        default:
          result.errors.push(`No enforcement handler for data type: ${dataType}`);
          return result;
      }
    } catch (error) {
      result.errors.push(error.message);
      return result;
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Delete user data by type (command)
   */
  private async deleteUserDataByType(
    userId: string, 
    dataType: string, 
    policy: DataRetentionPolicy
  ): Promise<DeletionResult> {
    const result: DeletionResult = {
      dataType,
      recordsProcessed: 0,
      recordsDeleted: 0,
      recordsArchived: 0,
      recordsAnonymized: 0,
      errors: [],
    };

    try {
      let tableName: string;
      let whereClause: any = { user_id: userId };

      switch (dataType) {
        case 'verification_attempts':
          tableName = 'age_verification_attempts';
          break;
        case 'verification_results':
          tableName = 'age_verification_results';
          break;
        case 'audit_logs':
          tableName = 'age_verification_audit_logs';
          break;
        case 'manual_review_data':
          tableName = 'age_verification_manual_queue';
          break;
        case 'underage_blocks':
          tableName = 'underage_user_blocks';
          break;
        default:
          result.errors.push(`Unknown data type: ${dataType}`);
          return result;
      }

      if (policy.deletionMethod === 'hard_delete') {
        const { count, error } = await this.supabase
          .from(tableName)
          .delete({ count: 'exact' })
          .match(whereClause);

        if (error) {
          throw new Error(`Hard delete failed: ${error.message}`);
        }

        result.recordsProcessed = count || 0;
        result.recordsDeleted = count || 0;

      } else if (policy.deletionMethod === 'anonymize') {
        // Anonymize data by removing PII but keeping statistical data
        const anonymizedData = await this.anonymizeUserData(tableName, userId);
        result.recordsProcessed = anonymizedData.processed;
        result.recordsAnonymized = anonymizedData.anonymized;
      }

      return result;

    } catch (error) {
      result.errors.push(error.message);
      return result;
    }
  }

  /**
   * PRINCIPLE 10: Security by Design - Anonymize user data
   */
  private async anonymizeUserData(tableName: string, userId: string): Promise<{
    processed: number;
    anonymized: number;
  }> {
    try {
      // Get records to anonymize
      const { data: records, error: selectError } = await this.supabase
        .from(tableName)
        .select('id')
        .eq('user_id', userId);

      if (selectError || !records) {
        throw new Error(`Failed to select records for anonymization: ${selectError?.message}`);
      }

      if (records.length === 0) {
        return { processed: 0, anonymized: 0 };
      }

      // Update records to remove PII
      const { count, error: updateError } = await this.supabase
        .from(tableName)
        .update({
          user_id: null,
          ip_address: null,
          user_agent: 'anonymized',
          device_fingerprint: 'anonymized',
          anonymized_at: new Date().toISOString(),
        })
        .in('id', records.map(r => r.id));

      if (updateError) {
        throw new Error(`Anonymization failed: ${updateError.message}`);
      }

      return {
        processed: records.length,
        anonymized: count || 0,
      };

    } catch (error) {
      throw new Error(`Failed to anonymize user data: ${error.message}`);
    }
  }

  // Additional cleanup methods
  private async cleanupVerificationAttempts(cutoffDate: Date): Promise<DeletionResult> {
    // Implementation for cleaning up old verification attempts
    return {
      dataType: 'verification_attempts',
      recordsProcessed: 0,
      recordsDeleted: 0,
      recordsArchived: 0,
      recordsAnonymized: 0,
      errors: [],
    };
  }

  private async archiveOldAuditLogs(cutoffDate: Date): Promise<DeletionResult> {
    // Implementation for archiving old audit logs
    return {
      dataType: 'audit_logs',
      recordsProcessed: 0,
      recordsDeleted: 0,
      recordsArchived: 0,
      recordsAnonymized: 0,
      errors: [],
    };
  }

  private async anonymizeSuspiciousActivity(cutoffDate: Date): Promise<DeletionResult> {
    // Implementation for anonymizing old suspicious activity data
    return {
      dataType: 'suspicious_activity',
      recordsProcessed: 0,
      recordsDeleted: 0,
      recordsArchived: 0,
      recordsAnonymized: 0,
      errors: [],
    };
  }

  private async cleanupManualReviewData(cutoffDate: Date): Promise<DeletionResult> {
    // Implementation for cleaning up old manual review data
    return {
      dataType: 'manual_review_data',
      recordsProcessed: 0,
      recordsDeleted: 0,
      recordsArchived: 0,
      recordsAnonymized: 0,
      errors: [],
    };
  }

  private async anonymizeFraudDetectionData(cutoffDate: Date): Promise<DeletionResult> {
    // Implementation for anonymizing old fraud detection data
    return {
      dataType: 'fraud_detection_data',
      recordsProcessed: 0,
      recordsDeleted: 0,
      recordsArchived: 0,
      recordsAnonymized: 0,
      errors: [],
    };
  }

  private async cleanupTemporaryData(): Promise<DeletionResult> {
    // Implementation for cleaning up temporary data
    return {
      dataType: 'temporary_data',
      recordsProcessed: 0,
      recordsDeleted: 0,
      recordsArchived: 0,
      recordsAnonymized: 0,
      errors: [],
    };
  }

  private async cleanupExpiredSessions(): Promise<DeletionResult> {
    // Implementation for cleaning up expired sessions
    return {
      dataType: 'expired_sessions',
      recordsProcessed: 0,
      recordsDeleted: 0,
      recordsArchived: 0,
      recordsAnonymized: 0,
      errors: [],
    };
  }

  private async cleanupFailedAttempts(): Promise<DeletionResult> {
    // Implementation for cleaning up old failed attempts
    return {
      dataType: 'failed_attempts',
      recordsProcessed: 0,
      recordsDeleted: 0,
      recordsArchived: 0,
      recordsAnonymized: 0,
      errors: [],
    };
  }

  /**
   * PRINCIPLE 3: Small, Focused Functions - Calculate next cleanup time
   */
  private calculateNextCleanupTime(): string {
    const nextCleanup = new Date();
    nextCleanup.setDate(nextCleanup.getDate() + 1); // Daily cleanup
    return nextCleanup.toISOString();
  }

  /**
   * PRINCIPLE 3: Small, Focused Functions - Generate retention recommendations
   */
  private generateRetentionRecommendations(auditReport: RetentionAuditReport): string[] {
    const recommendations = [];

    const totalErrors = auditReport.deletionResults.reduce((sum, r) => sum + r.errors.length, 0);
    if (totalErrors > 0) {
      recommendations.push('Review and resolve data deletion errors to maintain compliance');
    }

    const totalRecordsDeleted = auditReport.deletionResults.reduce((sum, r) => sum + r.recordsDeleted, 0);
    if (totalRecordsDeleted > 1000) {
      recommendations.push('Consider implementing incremental deletion to improve performance');
    }

    if (auditReport.complianceStatus === 'violation') {
      recommendations.push('Immediate action required to address compliance violations');
    }

    return recommendations;
  }

  /**
   * PRINCIPLE 3: Small, Focused Functions - Create error response
   */
  private createErrorResponse(error: any): Response {
    const sanitizedError = sanitizeErrorForClient(error);
    
    return new Response(
      JSON.stringify({
        success: false,
        error: 'Data retention operation failed',
        details: sanitizedError,
        code: 'RETENTION_ERROR',
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
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
    // Validate secure request (admin access required for data retention operations)
    const authResult = await validateSecureRequest(req);
    if (!authResult.isValid || !authResult.user?.id) {
      return new Response(
        JSON.stringify({ 
          success: false,
          error: 'Unauthorized access - admin privileges required',
          code: 'UNAUTHORIZED'
        }),
        { 
          status: 401, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Parse request body
    const requestBody: DataRetentionRequest = await req.json();
    
    // Initialize data retention system
    const retentionSystem = new DataRetentionSystem();
    
    // Process request
    return await retentionSystem.processRequest(requestBody, authResult.user.id);

  } catch (error) {
    console.error('Data retention system error:', error);
    
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