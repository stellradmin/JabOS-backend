// ==========================================
// AGE VERIFICATION MANUAL REVIEW SYSTEM
// Admin Dashboard for Manual Document Review
// COPPA Compliance - Stellr Dating App
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

interface ManualReviewRequest {
  action: 'get_queue' | 'get_submission' | 'process_review' | 'escalate_review';
  submissionId?: string;
  decision?: 'approved' | 'rejected' | 'needs_more_info';
  reviewerNotes?: string;
  reviewerId?: string;
  escalationReason?: string;
}

interface ManualReviewSubmission {
  id: string;
  submissionId: string;
  userId: string;
  priority: 'low' | 'medium' | 'high' | 'critical';
  documentType: string;
  extractedData: any;
  aiConfidence: number;
  flagReasons: string[];
  documentHash: string;
  status: 'pending' | 'in_review' | 'completed' | 'escalated';
  assignedReviewerId?: string;
  submissionTime: string;
  reviewStartedAt?: string;
  escalationLevel: number;
  complianceReviewRequired: boolean;
}

interface ReviewDecision {
  submissionId: string;
  decision: 'approved' | 'rejected' | 'needs_more_info';
  reviewerNotes: string;
  reviewerId: string;
  reviewTime: string;
  complianceFlags?: string[];
}

// ==========================================
// MANUAL REVIEW SYSTEM CLASS
// ==========================================

class ManualReviewSystem {
  private supabase: any;

  constructor() {
    this.supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );
  }

  /**
   * PRINCIPLE 1: Single Responsibility - Process manual review requests
   */
  async processRequest(request: ManualReviewRequest, reviewerId: string): Promise<Response> {
    try {
      // PRINCIPLE 6: Fail Fast & Defensive - Validate request
      this.validateRequest(request, reviewerId);

      switch (request.action) {
        case 'get_queue':
          return await this.getReviewQueue(reviewerId);
        
        case 'get_submission':
          return await this.getSubmissionDetails(request.submissionId!, reviewerId);
        
        case 'process_review':
          return await this.processReviewDecision({
            submissionId: request.submissionId!,
            decision: request.decision!,
            reviewerNotes: request.reviewerNotes!,
            reviewerId,
            reviewTime: new Date().toISOString(),
          });
        
        case 'escalate_review':
          return await this.escalateReview(request.submissionId!, reviewerId, request.escalationReason!);
        
        default:
          throw new Error(`Unsupported action: ${request.action}`);
      }
    } catch (error) {
      return this.createErrorResponse(error);
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Get review queue (query)
   */
  private async getReviewQueue(reviewerId: string): Promise<Response> {
    try {
      // Get reviewer's permissions
      const reviewerPermissions = await this.getReviewerPermissions(reviewerId);
      
      // Build query based on permissions
      let query = this.supabase
        .from('age_verification_manual_queue')
        .select(`
          id,
          submission_id,
          user_id,
          priority,
          document_type,
          ai_confidence,
          flag_reasons,
          status,
          assigned_reviewer_id,
          submission_time,
          review_started_at,
          escalation_level,
          compliance_review_required
        `)
        .eq('status', 'pending')
        .order('priority', { ascending: false })
        .order('submission_time', { ascending: true });

      // Apply permission filters
      if (!reviewerPermissions.canViewAll) {
        query = query.eq('assigned_reviewer_id', reviewerId);
      }

      const { data: queue, error } = await query.limit(50);

      if (error) {
        throw new Error('Failed to fetch review queue: ' + error.message);
      }

      // Get queue statistics
      const stats = await this.getQueueStatistics(reviewerId);

      return new Response(
        JSON.stringify({
          success: true,
          queue: queue || [],
          statistics: stats,
          reviewerPermissions,
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      throw new Error('Failed to get review queue: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Get submission details (query)
   */
  private async getSubmissionDetails(submissionId: string, reviewerId: string): Promise<Response> {
    try {
      // Get submission details
      const { data: submission, error: submissionError } = await this.supabase
        .from('age_verification_manual_queue')
        .select(`
          *,
          verification_attempt:age_verification_attempts!submission_id(
            id,
            user_id,
            verification_method,
            ip_address,
            user_agent,
            device_fingerprint,
            geolocation,
            created_at
          )
        `)
        .eq('submission_id', submissionId)
        .single();

      if (submissionError) {
        throw new Error('Submission not found: ' + submissionError.message);
      }

      // Verify reviewer access
      const hasAccess = await this.verifyReviewerAccess(submissionId, reviewerId);
      if (!hasAccess) {
        throw new Error('Access denied to this submission');
      }

      // Get related fraud detection data
      const { data: fraudData } = await this.supabase
        .from('document_fraud_detection')
        .select('*')
        .eq('document_hash', submission.document_hash);

      // Get user's verification history
      const { data: verificationHistory } = await this.supabase
        .from('age_verification_attempts')
        .select('id, verification_method, attempt_status, created_at')
        .eq('user_id', submission.user_id)
        .order('created_at', { ascending: false })
        .limit(10);

      // Mark as in review if not already
      if (submission.status === 'pending') {
        await this.supabase
          .from('age_verification_manual_queue')
          .update({
            status: 'in_review',
            assigned_reviewer_id: reviewerId,
            review_started_at: new Date().toISOString(),
          })
          .eq('submission_id', submissionId);
      }

      return new Response(
        JSON.stringify({
          success: true,
          submission: {
            ...submission,
            fraudData: fraudData || [],
            verificationHistory: verificationHistory || [],
          },
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      throw new Error('Failed to get submission details: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Process review decision (command)
   */
  private async processReviewDecision(decision: ReviewDecision): Promise<Response> {
    try {
      // Begin transaction
      const { data: submission, error: getError } = await this.supabase
        .from('age_verification_manual_queue')
        .select('*, verification_attempt:age_verification_attempts!submission_id(user_id)')
        .eq('submission_id', decision.submissionId)
        .single();

      if (getError || !submission) {
        throw new Error('Submission not found');
      }

      const userId = submission.verification_attempt.user_id;

      // PRINCIPLE 6: Fail Fast - Handle underage or rejected cases immediately
      if (decision.decision === 'rejected') {
        await this.handleRejectedVerification(decision.submissionId, userId, decision.reviewerNotes);
      } else if (decision.decision === 'approved') {
        await this.handleApprovedVerification(decision.submissionId, userId);
      }

      // Update review queue record
      await this.supabase
        .from('age_verification_manual_queue')
        .update({
          status: 'completed',
          decision: decision.decision,
          reviewer_notes: decision.reviewerNotes,
          review_completed_at: decision.reviewTime,
          assigned_reviewer_id: decision.reviewerId,
        })
        .eq('submission_id', decision.submissionId);

      // Log the review decision
      await logStructuredEvent(this.supabase, {
        event_type: 'manual_review_decision',
        severity: 'medium',
        user_id: userId,
        metadata: {
          submission_id: decision.submissionId,
          decision: decision.decision,
          reviewer_id: decision.reviewerId,
          review_time: decision.reviewTime,
        },
      });

      // Send notification to user
      await this.sendReviewNotification(userId, decision.decision, decision.reviewerNotes);

      return new Response(
        JSON.stringify({
          success: true,
          message: `Review completed with decision: ${decision.decision}`,
          decision: decision.decision,
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      throw new Error('Failed to process review decision: ' + error.message);
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Escalate review (command)
   */
  private async escalateReview(submissionId: string, reviewerId: string, reason: string): Promise<Response> {
    try {
      const { data: submission, error } = await this.supabase
        .from('age_verification_manual_queue')
        .select('escalation_level')
        .eq('submission_id', submissionId)
        .single();

      if (error || !submission) {
        throw new Error('Submission not found');
      }

      const newEscalationLevel = submission.escalation_level + 1;

      // Update escalation
      await this.supabase
        .from('age_verification_manual_queue')
        .update({
          status: 'escalated',
          escalation_level: newEscalationLevel,
          reviewer_notes: `Escalated by ${reviewerId}: ${reason}`,
          priority: newEscalationLevel >= 2 ? 'critical' : 'high',
        })
        .eq('submission_id', submissionId);

      // Log escalation
      await logStructuredEvent(this.supabase, {
        event_type: 'manual_review_escalated',
        severity: 'high',
        metadata: {
          submission_id: submissionId,
          reviewer_id: reviewerId,
          escalation_reason: reason,
          escalation_level: newEscalationLevel,
        },
      });

      return new Response(
        JSON.stringify({
          success: true,
          message: 'Review escalated successfully',
          escalationLevel: newEscalationLevel,
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      );

    } catch (error) {
      throw new Error('Failed to escalate review: ' + error.message);
    }
  }

  // ==========================================
  // HELPER METHODS
  // ==========================================

  /**
   * PRINCIPLE 6: Fail Fast & Defensive - Validate request
   */
  private validateRequest(request: ManualReviewRequest, reviewerId: string): void {
    if (!reviewerId) {
      throw new Error('Reviewer ID is required');
    }

    const validActions = ['get_queue', 'get_submission', 'process_review', 'escalate_review'];
    if (!validActions.includes(request.action)) {
      throw new Error('Invalid action');
    }

    if (request.action === 'get_submission' && !request.submissionId) {
      throw new Error('Submission ID is required for get_submission');
    }

    if (request.action === 'process_review') {
      if (!request.submissionId || !request.decision || !request.reviewerNotes) {
        throw new Error('Missing required fields for process_review');
      }

      const validDecisions = ['approved', 'rejected', 'needs_more_info'];
      if (!validDecisions.includes(request.decision)) {
        throw new Error('Invalid decision');
      }
    }

    if (request.action === 'escalate_review') {
      if (!request.submissionId || !request.escalationReason) {
        throw new Error('Missing required fields for escalate_review');
      }
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Get reviewer permissions (query)
   */
  private async getReviewerPermissions(reviewerId: string): Promise<{
    canViewAll: boolean;
    canApprove: boolean;
    canReject: boolean;
    canEscalate: boolean;
    maxEscalationLevel: number;
  }> {
    try {
      const { data: userRoles, error } = await this.supabase
        .from('user_roles')
        .select('role:roles(name, permissions)')
        .eq('user_id', reviewerId)
        .eq('is_active', true);

      if (error || !userRoles || userRoles.length === 0) {
        return {
          canViewAll: false,
          canApprove: false,
          canReject: false,
          canEscalate: false,
          maxEscalationLevel: 0,
        };
      }

      const roles = userRoles.map(ur => ur.role);
      const isAdmin = roles.some(r => r.name === 'super_admin' || r.name === 'admin');
      const isModerator = roles.some(r => r.name === 'moderator');

      return {
        canViewAll: isAdmin,
        canApprove: isAdmin || isModerator,
        canReject: isAdmin || isModerator,
        canEscalate: isAdmin || isModerator,
        maxEscalationLevel: isAdmin ? 3 : 2,
      };

    } catch (error) {
      console.error('Failed to get reviewer permissions:', error);
      return {
        canViewAll: false,
        canApprove: false,
        canReject: false,
        canEscalate: false,
        maxEscalationLevel: 0,
      };
    }
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Get queue statistics (query)
   */
  private async getQueueStatistics(reviewerId: string): Promise<any> {
    try {
      const { data: stats, error } = await this.supabase
        .rpc('get_manual_review_statistics', { reviewer_id: reviewerId });

      if (error) {
        console.error('Failed to get queue statistics:', error);
        return {
          totalPending: 0,
          highPriority: 0,
          assignedToMe: 0,
          averageReviewTime: 0,
        };
      }

      return stats;

    } catch (error) {
      console.error('Failed to get queue statistics:', error);
      return {
        totalPending: 0,
        highPriority: 0,
        assignedToMe: 0,
        averageReviewTime: 0,
      };
    }
  }

  /**
   * PRINCIPLE 10: Security by Design - Verify reviewer access
   */
  private async verifyReviewerAccess(submissionId: string, reviewerId: string): Promise<boolean> {
    try {
      const permissions = await this.getReviewerPermissions(reviewerId);
      
      if (permissions.canViewAll) {
        return true;
      }

      // Check if assigned to this reviewer
      const { data, error } = await this.supabase
        .from('age_verification_manual_queue')
        .select('assigned_reviewer_id')
        .eq('submission_id', submissionId)
        .single();

      if (error) {
        return false;
      }

      return data.assigned_reviewer_id === reviewerId || data.assigned_reviewer_id === null;

    } catch (error) {
      console.error('Failed to verify reviewer access:', error);
      return false;
    }
  }

  /**
   * PRINCIPLE 6: Fail Fast - Handle rejected verification
   */
  private async handleRejectedVerification(submissionId: string, userId: string, reason: string): Promise<void> {
    // Update verification attempt
    await this.supabase
      .from('age_verification_attempts')
      .update({ attempt_status: 'failed' })
      .eq('id', submissionId);

    // Update user profile
    await this.supabase
      .from('profiles')
      .update({
        age_verification_status: 'failed',
        is_discoverable: false,
      })
      .eq('id', userId);

    // Log rejection
    await logStructuredEvent(this.supabase, {
      event_type: 'age_verification_rejected',
      severity: 'medium',
      user_id: userId,
      metadata: {
        submission_id: submissionId,
        rejection_reason: reason,
      },
    });
  }

  /**
   * PRINCIPLE 8: Command Query Separation - Handle approved verification (command)
   */
  private async handleApprovedVerification(submissionId: string, userId: string): Promise<void> {
    // Update verification attempt
    await this.supabase
      .from('age_verification_attempts')
      .update({ attempt_status: 'success' })
      .eq('id', submissionId);

    // Update user profile
    await this.supabase
      .from('profiles')
      .update({
        age_verified: true,
        age_verification_status: 'verified',
        age_verification_completed_at: new Date().toISOString(),
        is_discoverable: true,
      })
      .eq('id', userId);

    // Log approval
    await logStructuredEvent(this.supabase, {
      event_type: 'age_verification_approved',
      severity: 'low',
      user_id: userId,
      metadata: {
        submission_id: submissionId,
      },
    });
  }

  /**
   * PRINCIPLE 4: Separation of Concerns - Send review notification
   */
  private async sendReviewNotification(userId: string, decision: string, notes: string): Promise<void> {
    try {
      // This would integrate with your notification system
      // For now, just log the notification
      await logStructuredEvent(this.supabase, {
        event_type: 'review_notification_sent',
        severity: 'low',
        user_id: userId,
        metadata: {
          decision,
          notes: notes.substring(0, 100), // Truncate for logging
        },
      });
    } catch (error) {
      console.error('Failed to send review notification:', error);
    }
  }

  /**
   * PRINCIPLE 3: Small, Focused Functions - Create error response
   */
  private createErrorResponse(error: any): Response {
    const sanitizedError = sanitizeErrorForClient(error);
    
    return new Response(
      JSON.stringify({
        success: false,
        error: 'Manual review operation failed',
        details: sanitizedError,
        code: 'REVIEW_ERROR',
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
    if (!authResult.isValid || !authResult.user?.id) {
      return new Response(
        JSON.stringify({ 
          success: false,
          error: 'Unauthorized access',
          code: 'UNAUTHORIZED'
        }),
        { 
          status: 401, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Parse request body
    const requestBody: ManualReviewRequest = await req.json();
    
    // Initialize review system
    const reviewSystem = new ManualReviewSystem();
    
    // Process request
    return await reviewSystem.processRequest(requestBody, authResult.user.id);

  } catch (error) {
    console.error('Manual review system error:', error);
    
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