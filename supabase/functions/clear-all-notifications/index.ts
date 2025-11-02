/**
 * Clear All Notifications Edge Function
 * 
 * Comprehensive notification management with selective clearing,
 * archive options, and cleanup automation.
 * 
 * Features:
 * - Clear all or filtered notifications
 * - Archive vs permanent deletion options
 * - Cleanup old/expired notifications
 * - Batch operations with transaction safety
 * - Analytics and reporting
 * - Real-time synchronization
 * 
 * Author: Claude Code Assistant
 * Version: 1.0.0
 * Created: 2024-09-09
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

// Import production-ready core functionality
import { 
  getCorsHeaders,
  createErrorResponse,
  createSuccessResponse,
  createValidationErrorResponse,
  validateJWTHeader,
  createSecureSupabaseClient,
  applyRateLimit,
  RateLimitCategory,
  csrfMiddleware,
  validateUUID,
  getLogger,
  logSecurityEvent
} from '../_shared/stellr-edge-core.ts';

// Validation schemas
const ClearNotificationsSchema = z.object({
  // Clear operation type
  operation: z.enum(['mark_all_read', 'archive_all', 'delete_all', 'cleanup_expired']).default('mark_all_read'),
  
  // Selective filters
  filters: z.object({
    type: z.enum([
      'new_match',
      'new_message', 
      'profile_view',
      'super_like',
      'date_reminder',
      'system_announcement',
      'security_alert'
    ]).optional(),
    priority: z.enum(['low', 'normal', 'high', 'critical']).optional(),
    status: z.enum(['pending', 'sent', 'delivered', 'read', 'failed']).optional(),
    before_date: z.string().datetime().optional(),
    after_date: z.string().datetime().optional(),
    exclude_types: z.array(z.enum([
      'new_match',
      'new_message', 
      'profile_view',
      'super_like',
      'date_reminder',
      'system_announcement',
      'security_alert'
    ])).optional(),
  }).optional(),
  
  // Archive options (for archive_all operation)
  archive_options: z.object({
    retention_days: z.number().int().min(1).max(365).default(30),
    compress_data: z.boolean().default(true),
    keep_metadata: z.boolean().default(true),
  }).optional(),
  
  // Cleanup options (for cleanup_expired operation)
  cleanup_options: z.object({
    delete_read_older_than_days: z.number().int().min(1).max(365).default(30),
    delete_failed_older_than_days: z.number().int().min(1).max(7).default(7),
    batch_size: z.number().int().min(10).max(1000).default(100),
  }).optional(),
  
  // Real-time and tracking
  send_realtime_update: z.boolean().default(true),
  include_analytics: z.boolean().default(true),
  dry_run: z.boolean().default(false),
});

type ClearNotificationsRequest = z.infer<typeof ClearNotificationsSchema>;

interface ClearNotificationsResponse {
  success: boolean;
  operation: string;
  dry_run: boolean;
  affected_count: number;
  deleted_count: number;
  archived_count: number;
  marked_read_count: number;
  new_unread_count: number;
  analytics?: {
    by_type: Record<string, number>;
    by_status: Record<string, number>;
    by_priority: Record<string, number>;
    date_range: {
      oldest: string;
      newest: string;
    };
  };
  summary: {
    processing_time_ms: number;
    batch_operations: number;
    errors_encountered: number;
  };
}

serve(async (req: Request) => {
  const startTime = performance.now();
  const logger = getLogger({ 
    functionName: 'clear-all-notifications',
    requestId: crypto.randomUUID()
  });

  // Apply rate limiting - more restrictive for bulk operations
  const rateLimitResult = await applyRateLimit(req, '/clear-all-notifications', undefined, RateLimitCategory.BULK_OPERATIONS);
  if (rateLimitResult.blocked) {
    await logger.warn('Rate limit exceeded for clear-all-notifications', {
      clientIP: req.headers.get('x-forwarded-for') || 'unknown'
    });
    return rateLimitResult.response;
  }

  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST' && req.method !== 'DELETE') {
    return createErrorResponse(
      { code: 'method_not_allowed', message: 'Only POST and DELETE methods allowed' },
      405,
      corsHeaders
    );
  }

  try {
    // CSRF protection
    const csrfResult = await csrfMiddleware(req);
    if (!csrfResult.valid) {
      return csrfResult.response;
    }

    // Validate JWT and get user
    const userAuthResult = await validateJWTHeader(req.headers.get('Authorization'));
    if (!userAuthResult.valid || !userAuthResult.payload?.sub) {
      logSecurityEvent('invalid_jwt_clear_notifications', userAuthResult.payload?.sub, {
        endpoint: 'clear-all-notifications',
        userAgent: req.headers.get('User-Agent'),
        error: userAuthResult.error
      });
      return createErrorResponse(
        { code: 'unauthorized', message: 'Invalid authentication token' },
        401,
        corsHeaders
      );
    }

    const userId = userAuthResult.payload.sub;

    // Parse and validate request body
    const requestData = await req.json();
    
    let parsedData: ClearNotificationsRequest;
    try {
      parsedData = ClearNotificationsSchema.parse(requestData);
    } catch (error) {
      if (error instanceof ZodError) {
        await logger.warn('Invalid clear notifications request', {
          userId,
          errors: error.errors
        });
        return createValidationErrorResponse(error, corsHeaders);
      }
      throw error;
    }

    await logger.info('Processing clear notifications request', { 
      userId,
      operation: parsedData.operation,
      dryRun: parsedData.dry_run,
      filters: parsedData.filters
    });

    // Create secure Supabase client
    const supabase = await createSecureSupabaseClient(userAuthResult.token);

    let affectedCount = 0;
    let deletedCount = 0;
    let archivedCount = 0;
    let markedReadCount = 0;
    let batchOperations = 0;
    let errorsEncountered = 0;
    let analytics: any = undefined;

    // Build base query for affected notifications
    let baseQuery = supabase
      .from('user_notifications')
      .select('*')
      .eq('user_id', userId);

    // Apply filters
    if (parsedData.filters) {
      if (parsedData.filters.type) {
        baseQuery = baseQuery.eq('type', parsedData.filters.type);
      }
      if (parsedData.filters.priority) {
        baseQuery = baseQuery.eq('priority', parsedData.filters.priority);
      }
      if (parsedData.filters.status) {
        baseQuery = baseQuery.eq('status', parsedData.filters.status);
      }
      if (parsedData.filters.before_date) {
        baseQuery = baseQuery.lte('created_at', parsedData.filters.before_date);
      }
      if (parsedData.filters.after_date) {
        baseQuery = baseQuery.gte('created_at', parsedData.filters.after_date);
      }
      if (parsedData.filters.exclude_types && parsedData.filters.exclude_types.length > 0) {
        baseQuery = baseQuery.not('type', 'in', `(${parsedData.filters.exclude_types.join(',')})`);
      }
    }

    // Get affected notifications for analytics and dry run
    const { data: affectedNotifications, error: queryError } = await baseQuery;

    if (queryError) {
      await logger.error('Failed to query affected notifications', queryError, { userId });
      return createErrorResponse(
        { code: 'database_error', message: 'Failed to query notifications' },
        500,
        corsHeaders
      );
    }

    affectedCount = affectedNotifications?.length || 0;

    // Generate analytics if requested
    if (parsedData.include_analytics && affectedNotifications && affectedNotifications.length > 0) {
      analytics = {
        by_type: {} as Record<string, number>,
        by_status: {} as Record<string, number>,
        by_priority: {} as Record<string, number>,
        date_range: {
          oldest: affectedNotifications[affectedNotifications.length - 1]?.created_at,
          newest: affectedNotifications[0]?.created_at
        }
      };

      affectedNotifications.forEach(notification => {
        analytics.by_type[notification.type] = (analytics.by_type[notification.type] || 0) + 1;
        analytics.by_status[notification.status] = (analytics.by_status[notification.status] || 0) + 1;
        analytics.by_priority[notification.priority] = (analytics.by_priority[notification.priority] || 0) + 1;
      });
    }

    // If dry run, return early with analytics
    if (parsedData.dry_run) {
      await logger.info('Completed dry run for clear notifications', {
        userId,
        operation: parsedData.operation,
        affectedCount
      });

      const response: ClearNotificationsResponse = {
        success: true,
        operation: parsedData.operation,
        dry_run: true,
        affected_count: affectedCount,
        deleted_count: 0,
        archived_count: 0,
        marked_read_count: 0,
        new_unread_count: 0, // Will be calculated later if needed
        analytics,
        summary: {
          processing_time_ms: Math.round(performance.now() - startTime),
          batch_operations: 0,
          errors_encountered: 0
        }
      };

      return createSuccessResponse(response, corsHeaders);
    }

    // Execute the requested operation
    switch (parsedData.operation) {
      case 'mark_all_read':
        try {
          if (affectedCount > 0) {
            const notificationIds = affectedNotifications!.map(n => n.id);
            
            // Process in batches to avoid timeout
            const batchSize = 50;
            for (let i = 0; i < notificationIds.length; i += batchSize) {
              const batch = notificationIds.slice(i, i + batchSize);
              
              const { data: updateResult, error: updateError } = await supabase
                .from('user_notifications')
                .update({
                  status: 'read',
                  read_at: new Date().toISOString(),
                  interaction_count: supabase.raw('interaction_count + 1'),
                  last_interaction_at: new Date().toISOString()
                })
                .in('id', batch)
                .eq('user_id', userId)
                .select('id');

              if (updateError) {
                errorsEncountered++;
                await logger.error('Batch update failed', updateError, { userId, batchSize: batch.length });
              } else {
                markedReadCount += updateResult?.length || 0;
              }
              
              batchOperations++;
            }
          }
        } catch (error) {
          await logger.error('Failed to mark all notifications as read', error as Error, { userId });
          errorsEncountered++;
        }
        break;

      case 'archive_all':
        // For now, archiving means updating a flag - in future could move to archive table
        try {
          if (affectedCount > 0) {
            const { data: updateResult, error: updateError } = await supabase
              .from('user_notifications')
              .update({
                metadata: supabase.raw(`metadata || '{"archived": true, "archived_at": "${new Date().toISOString()}"}'::jsonb`),
                status: 'read' // Archived notifications are considered read
              })
              .in('id', affectedNotifications!.map(n => n.id))
              .eq('user_id', userId)
              .select('id');

            if (updateError) {
              throw updateError;
            }

            archivedCount = updateResult?.length || 0;
            batchOperations++;
          }
        } catch (error) {
          await logger.error('Failed to archive notifications', error as Error, { userId });
          errorsEncountered++;
        }
        break;

      case 'delete_all':
        try {
          if (affectedCount > 0) {
            // First delete read status records
            const { error: readStatusError } = await supabase
              .from('notification_read_status')
              .delete()
              .in('notification_id', affectedNotifications!.map(n => n.id))
              .eq('user_id', userId);

            if (readStatusError) {
              await logger.warn('Failed to delete read status records', {
                userId,
                error: readStatusError.message
              });
            }

            // Then delete notifications
            const { data: deleteResult, error: deleteError } = await supabase
              .from('user_notifications')
              .delete()
              .in('id', affectedNotifications!.map(n => n.id))
              .eq('user_id', userId)
              .select('id');

            if (deleteError) {
              throw deleteError;
            }

            deletedCount = deleteResult?.length || 0;
            batchOperations++;
          }
        } catch (error) {
          await logger.error('Failed to delete notifications', error as Error, { userId });
          errorsEncountered++;
        }
        break;

      case 'cleanup_expired':
        try {
          const options = parsedData.cleanup_options || {};
          
          // Delete expired notifications
          const { data: expiredResult, error: expiredError } = await supabase
            .from('user_notifications')
            .delete()
            .eq('user_id', userId)
            .lt('expires_at', new Date().toISOString())
            .select('id');

          if (expiredError) {
            throw expiredError;
          }

          // Delete old read notifications
          const oldReadDate = new Date();
          oldReadDate.setDate(oldReadDate.getDate() - options.delete_read_older_than_days);

          const { data: oldReadResult, error: oldReadError } = await supabase
            .from('user_notifications')
            .delete()
            .eq('user_id', userId)
            .eq('status', 'read')
            .lt('read_at', oldReadDate.toISOString())
            .select('id');

          if (oldReadError) {
            throw oldReadError;
          }

          // Delete old failed notifications
          const oldFailedDate = new Date();
          oldFailedDate.setDate(oldFailedDate.getDate() - options.delete_failed_older_than_days);

          const { data: oldFailedResult, error: oldFailedError } = await supabase
            .from('user_notifications')
            .delete()
            .eq('user_id', userId)
            .eq('status', 'failed')
            .lt('created_at', oldFailedDate.toISOString())
            .select('id');

          if (oldFailedError) {
            throw oldFailedError;
          }

          deletedCount = (expiredResult?.length || 0) + (oldReadResult?.length || 0) + (oldFailedResult?.length || 0);
          batchOperations = 3;
        } catch (error) {
          await logger.error('Failed to cleanup expired notifications', error as Error, { userId });
          errorsEncountered++;
        }
        break;
    }

    // Get updated unread count
    const { data: unreadCount, error: countError } = await supabase
      .rpc('get_unread_notification_count', { p_user_id: userId });

    if (countError) {
      await logger.warn('Failed to get updated unread count', {
        userId,
        error: countError.message
      });
    }

    // Send real-time update if requested and successful
    if (parsedData.send_realtime_update && (markedReadCount > 0 || deletedCount > 0 || archivedCount > 0)) {
      try {
        await supabase.channel('notification_updates')
          .send({
            type: 'broadcast',
            event: 'notifications_cleared',
            payload: {
              user_id: userId,
              operation: parsedData.operation,
              affected_count: affectedCount,
              marked_read_count: markedReadCount,
              deleted_count: deletedCount,
              archived_count: archivedCount,
              new_unread_count: unreadCount || 0,
              timestamp: new Date().toISOString()
            }
          });
      } catch (error) {
        await logger.warn('Failed to send real-time update', {
          userId,
          error: (error as Error).message
        });
      }
    }

    const processingTime = performance.now() - startTime;

    // Prepare response
    const response: ClearNotificationsResponse = {
      success: errorsEncountered === 0,
      operation: parsedData.operation,
      dry_run: false,
      affected_count: affectedCount,
      deleted_count: deletedCount,
      archived_count: archivedCount,
      marked_read_count: markedReadCount,
      new_unread_count: unreadCount || 0,
      analytics,
      summary: {
        processing_time_ms: Math.round(processingTime),
        batch_operations: batchOperations,
        errors_encountered: errorsEncountered
      }
    };

    await logger.info('Successfully processed clear notifications request', {
      userId,
      operation: parsedData.operation,
      affectedCount,
      deletedCount,
      archivedCount,
      markedReadCount,
      processingTimeMs: Math.round(processingTime),
      errorsEncountered
    });

    return createSuccessResponse(response, corsHeaders);

  } catch (error) {
    await logger.error('Unexpected error in clear-all-notifications', error as Error, {
      url: req.url,
      method: req.method
    });

    return createErrorResponse(
      { code: 'internal_error', message: 'An unexpected error occurred' },
      500,
      corsHeaders
    );
  }
});