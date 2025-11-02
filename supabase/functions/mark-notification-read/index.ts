/**
 * Mark Notification Read Edge Function
 * 
 * Handles marking notifications as read with comprehensive tracking,
 * batch operations, and real-time synchronization across devices.
 * 
 * Features:
 * - Single and batch notification marking
 * - Device tracking for cross-platform sync
 * - Analytics and interaction tracking
 * - Optimistic concurrency control
 * - Real-time status broadcasting
 * - Comprehensive audit trail
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
const MarkNotificationReadSchema = z.object({
  // Single notification
  notification_id: z.string().uuid().optional(),
  
  // Batch notifications
  notification_ids: z.array(z.string().uuid()).max(50).optional(),
  
  // Mark all options
  mark_all: z.boolean().default(false),
  mark_all_filter: z.object({
    type: z.enum([
      'new_match',
      'new_message', 
      'profile_view',
      'super_like',
      'date_reminder',
      'system_announcement',
      'security_alert'
    ]).optional(),
    before_date: z.string().datetime().optional(),
    priority: z.enum(['low', 'normal', 'high', 'critical']).optional(),
  }).optional(),
  
  // Device and session tracking
  device_type: z.enum(['mobile', 'web', 'tablet']).optional(),
  session_id: z.string().max(100).optional(),
  user_agent: z.string().max(500).optional(),
  
  // Options
  send_realtime_update: z.boolean().default(true),
  track_interaction: z.boolean().default(true),
}).refine((data) => {
  // Must specify either single notification, batch, or mark_all
  const hasNotificationId = !!data.notification_id;
  const hasNotificationIds = !!(data.notification_ids && data.notification_ids.length > 0);
  const hasMarkAll = data.mark_all;
  
  const optionCount = [hasNotificationId, hasNotificationIds, hasMarkAll].filter(Boolean).length;
  
  if (optionCount !== 1) {
    return false;
  }
  
  // If mark_all with filter, require filter object
  if (hasMarkAll && data.mark_all_filter === undefined) {
    // Allow mark_all without filter for "mark all as read"
    return true;
  }
  
  return true;
}, {
  message: "Must specify exactly one: notification_id, notification_ids, or mark_all"
});

type MarkNotificationReadRequest = z.infer<typeof MarkNotificationReadSchema>;

interface MarkNotificationReadResponse {
  success: boolean;
  marked_count: number;
  failed_count: number;
  new_unread_count: number;
  failed_notifications?: {
    id: string;
    error: string;
  }[];
  summary: {
    updated_notifications: any[];
    total_processing_time_ms: number;
  };
}

serve(async (req: Request) => {
  const startTime = performance.now();
  const logger = getLogger({ 
    functionName: 'mark-notification-read',
    requestId: crypto.randomUUID()
  });

  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/mark-notification-read', undefined, RateLimitCategory.PROFILE_UPDATES);
  if (rateLimitResult.blocked) {
    await logger.warn('Rate limit exceeded for mark-notification-read', {
      clientIP: req.headers.get('x-forwarded-for') || 'unknown'
    });
    return rateLimitResult.response;
  }

  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST' && req.method !== 'PUT') {
    return createErrorResponse(
      { code: 'method_not_allowed', message: 'Only POST and PUT methods allowed' },
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
      logSecurityEvent('invalid_jwt_mark_notification_read', userAuthResult.payload?.sub, {
        endpoint: 'mark-notification-read',
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
    
    // Add user agent if not provided
    if (!requestData.user_agent) {
      requestData.user_agent = req.headers.get('User-Agent');
    }

    let parsedData: MarkNotificationReadRequest;
    try {
      parsedData = MarkNotificationReadSchema.parse(requestData);
    } catch (error) {
      if (error instanceof ZodError) {
        await logger.warn('Invalid mark notification read request', {
          userId,
          errors: error.errors
        });
        return createValidationErrorResponse(error, corsHeaders);
      }
      throw error;
    }

    await logger.info('Processing mark notification read request', { 
      userId,
      type: parsedData.notification_id ? 'single' : 
            parsedData.notification_ids ? 'batch' : 'mark_all',
      count: parsedData.notification_ids?.length || 1
    });

    // Create secure Supabase client
    const supabase = await createSecureSupabaseClient(userAuthResult.token);

    let markedCount = 0;
    let failedCount = 0;
    const failedNotifications: { id: string; error: string }[] = [];
    const updatedNotifications: any[] = [];

    // Handle single notification
    if (parsedData.notification_id) {
      try {
        const { data: result, error } = await supabase
          .rpc('mark_notification_read', {
            p_notification_id: parsedData.notification_id,
            p_user_id: userId,
            p_device_type: parsedData.device_type,
            p_session_id: parsedData.session_id
          });

        if (error) {
          throw error;
        }

        if (result) {
          markedCount = 1;
          
          // Get updated notification for response
          const { data: notification } = await supabase
            .from('user_notifications')
            .select('*')
            .eq('id', parsedData.notification_id)
            .eq('user_id', userId)
            .single();
          
          if (notification) {
            updatedNotifications.push(notification);
          }
        } else {
          failedCount = 1;
          failedNotifications.push({
            id: parsedData.notification_id,
            error: 'Notification not found or already read'
          });
        }
      } catch (error) {
        await logger.error('Failed to mark single notification as read', error as Error, {
          userId,
          notificationId: parsedData.notification_id
        });
        failedCount = 1;
        failedNotifications.push({
          id: parsedData.notification_id,
          error: 'Database error'
        });
      }
    }

    // Handle batch notifications
    else if (parsedData.notification_ids && parsedData.notification_ids.length > 0) {
      for (const notificationId of parsedData.notification_ids) {
        try {
          const { data: result, error } = await supabase
            .rpc('mark_notification_read', {
              p_notification_id: notificationId,
              p_user_id: userId,
              p_device_type: parsedData.device_type,
              p_session_id: parsedData.session_id
            });

          if (error) {
            throw error;
          }

          if (result) {
            markedCount++;
            
            // Get updated notification for response
            const { data: notification } = await supabase
              .from('user_notifications')
              .select('*')
              .eq('id', notificationId)
              .eq('user_id', userId)
              .single();
            
            if (notification) {
              updatedNotifications.push(notification);
            }
          } else {
            failedCount++;
            failedNotifications.push({
              id: notificationId,
              error: 'Notification not found or already read'
            });
          }
        } catch (error) {
          await logger.error('Failed to mark batch notification as read', error as Error, {
            userId,
            notificationId
          });
          failedCount++;
          failedNotifications.push({
            id: notificationId,
            error: 'Database error'
          });
        }
      }
    }

    // Handle mark all
    else if (parsedData.mark_all) {
      try {
        if (parsedData.mark_all_filter) {
          // Mark filtered notifications
          let query = supabase
            .from('user_notifications')
            .update({ 
              status: 'read',
              read_at: new Date().toISOString(),
              interaction_count: supabase.raw('interaction_count + 1'),
              last_interaction_at: new Date().toISOString()
            })
            .eq('user_id', userId)
            .neq('status', 'read'); // Only unread notifications

          // Apply filters
          if (parsedData.mark_all_filter.type) {
            query = query.eq('type', parsedData.mark_all_filter.type);
          }
          if (parsedData.mark_all_filter.before_date) {
            query = query.lte('created_at', parsedData.mark_all_filter.before_date);
          }
          if (parsedData.mark_all_filter.priority) {
            query = query.eq('priority', parsedData.mark_all_filter.priority);
          }

          query = query.select('*');
          
          const { data: updatedRows, error } = await query;

          if (error) {
            throw error;
          }

          markedCount = updatedRows?.length || 0;
          updatedNotifications.push(...(updatedRows || []));

          // Insert read status records for batch
          if (updatedRows && updatedRows.length > 0 && parsedData.device_type) {
            const readStatusRecords = updatedRows.map(notification => ({
              notification_id: notification.id,
              user_id: userId,
              read_from_device: parsedData.device_type,
              session_id: parsedData.session_id,
              read_at: new Date().toISOString()
            }));

            const { error: readStatusError } = await supabase
              .from('notification_read_status')
              .upsert(readStatusRecords, { 
                onConflict: 'notification_id,user_id',
                ignoreDuplicates: false 
              });

            if (readStatusError) {
              await logger.warn('Failed to insert read status records for batch operation', {
                userId,
                error: readStatusError.message,
                count: readStatusRecords.length
              });
            }
          }
        } else {
          // Mark all notifications as read using function
          const { data: result, error } = await supabase
            .rpc('clear_all_user_notifications', { p_user_id: userId });

          if (error) {
            throw error;
          }

          markedCount = result || 0;
        }
      } catch (error) {
        await logger.error('Failed to mark all notifications as read', error as Error, {
          userId,
          filter: parsedData.mark_all_filter
        });
        failedCount = 1;
        failedNotifications.push({
          id: 'mark_all',
          error: 'Database error during batch operation'
        });
      }
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

    const processingTime = performance.now() - startTime;

    // Broadcast real-time update if requested and successful
    if (parsedData.send_realtime_update && markedCount > 0) {
      try {
        // Send real-time notification via Supabase channel
        await supabase.channel('notification_updates')
          .send({
            type: 'broadcast',
            event: 'notification_read',
            payload: {
              user_id: userId,
              marked_count: markedCount,
              new_unread_count: unreadCount || 0,
              updated_notifications: updatedNotifications.map(n => n.id),
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

    // Prepare response
    const response: MarkNotificationReadResponse = {
      success: markedCount > 0,
      marked_count: markedCount,
      failed_count: failedCount,
      new_unread_count: unreadCount || 0,
      failed_notifications: failedCount > 0 ? failedNotifications : undefined,
      summary: {
        updated_notifications: updatedNotifications,
        total_processing_time_ms: Math.round(processingTime)
      }
    };

    await logger.info('Successfully processed mark notification read request', {
      userId,
      markedCount,
      failedCount,
      processingTimeMs: Math.round(processingTime)
    });

    return createSuccessResponse(response, corsHeaders);

  } catch (error) {
    await logger.error('Unexpected error in mark-notification-read', error as Error, {
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