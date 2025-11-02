/**
 * Get User Notifications Edge Function
 * 
 * Retrieves user's notification history with comprehensive filtering,
 * pagination, and real-time status updates.
 * 
 * Features:
 * - Pagination with cursor-based navigation
 * - Filtering by type, status, and date range
 * - Unread count calculation
 * - Performance optimized queries
 * - Comprehensive security validation
 * - Real-time read status updates
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
const NotificationFiltersSchema = z.object({
  // Pagination
  page: z.number().int().min(1).default(1),
  limit: z.number().int().min(1).max(100).default(20),
  cursor: z.string().uuid().optional(),
  
  // Filters
  type: z.enum([
    'new_match',
    'new_message', 
    'profile_view',
    'super_like',
    'date_reminder',
    'system_announcement',
    'security_alert'
  ]).optional(),
  status: z.enum(['pending', 'sent', 'delivered', 'read', 'failed']).optional(),
  priority: z.enum(['low', 'normal', 'high', 'critical']).optional(),
  
  // Date range
  from_date: z.string().datetime().optional(),
  to_date: z.string().datetime().optional(),
  
  // Options
  include_read: z.boolean().default(true),
  include_expired: z.boolean().default(false),
  mark_as_delivered: z.boolean().default(true),
});

type NotificationFilters = z.infer<typeof NotificationFiltersSchema>;

interface NotificationResponse {
  notifications: any[];
  pagination: {
    page: number;
    limit: number;
    total: number;
    hasMore: boolean;
    nextCursor: string | null;
  };
  unreadCount: number;
  summary: {
    byType: Record<string, number>;
    byStatus: Record<string, number>;
    byPriority: Record<string, number>;
  };
}

serve(async (req: Request) => {
  const logger = getLogger({ 
    functionName: 'get-user-notifications',
    requestId: crypto.randomUUID()
  });

  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/get-user-notifications', undefined, RateLimitCategory.DATA_ACCESS);
  if (rateLimitResult.blocked) {
    await logger.warn('Rate limit exceeded for get-user-notifications', {
      clientIP: req.headers.get('x-forwarded-for') || 'unknown'
    });
    return rateLimitResult.response;
  }

  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'GET' && req.method !== 'POST') {
    return createErrorResponse(
      { code: 'method_not_allowed', message: 'Only GET and POST methods allowed' },
      405,
      corsHeaders
    );
  }

  try {
    // CSRF protection for POST requests
    if (req.method === 'POST') {
      const csrfResult = await csrfMiddleware(req);
      if (!csrfResult.valid) {
        return csrfResult.response;
      }
    }

    // Validate JWT and get user
    const userAuthResult = await validateJWTHeader(req.headers.get('Authorization'));
    if (!userAuthResult.valid || !userAuthResult.payload?.sub) {
      logSecurityEvent('invalid_jwt_get_notifications', userAuthResult.payload?.sub, {
        endpoint: 'get-user-notifications',
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
    await logger.info('Processing notification retrieval request', { userId });

    // Parse filters from query params (GET) or body (POST)
    let filters: NotificationFilters;
    try {
      if (req.method === 'GET') {
        const url = new URL(req.url);
        const queryParams = Object.fromEntries(url.searchParams);
        
        // Convert string values to appropriate types
        const parsed = {
          ...queryParams,
          page: queryParams.page ? parseInt(queryParams.page) : undefined,
          limit: queryParams.limit ? parseInt(queryParams.limit) : undefined,
          include_read: queryParams.include_read !== 'false',
          include_expired: queryParams.include_expired === 'true',
          mark_as_delivered: queryParams.mark_as_delivered !== 'false',
        };
        
        filters = NotificationFiltersSchema.parse(parsed);
      } else {
        const requestData = await req.json();
        filters = NotificationFiltersSchema.parse(requestData);
      }
    } catch (error) {
      if (error instanceof ZodError) {
        await logger.warn('Invalid notification filters provided', {
          userId,
          errors: error.errors
        });
        return createValidationErrorResponse(error, corsHeaders);
      }
      throw error;
    }

    // Create secure Supabase client
    const supabase = await createSecureSupabaseClient(userAuthResult.token);

    // Build base query
    let query = supabase
      .from('user_notifications')
      .select(`
        id,
        type,
        title,
        body,
        priority,
        status,
        created_at,
        scheduled_for,
        delivered_at,
        read_at,
        expires_at,
        metadata,
        deep_link_url,
        interaction_count,
        last_interaction_at
      `)
      .eq('user_id', userId)
      .order('created_at', { ascending: false });

    // Apply filters
    if (filters.type) {
      query = query.eq('type', filters.type);
    }

    if (filters.status) {
      query = query.eq('status', filters.status);
    }

    if (filters.priority) {
      query = query.eq('priority', filters.priority);
    }

    if (filters.from_date) {
      query = query.gte('created_at', filters.from_date);
    }

    if (filters.to_date) {
      query = query.lte('created_at', filters.to_date);
    }

    if (!filters.include_read) {
      query = query.neq('status', 'read');
    }

    if (!filters.include_expired) {
      query = query.or('expires_at.is.null,expires_at.gt.now()');
    }

    // Apply cursor-based pagination
    if (filters.cursor) {
      // Get cursor notification timestamp
      const { data: cursorNotification } = await supabase
        .from('user_notifications')
        .select('created_at')
        .eq('id', filters.cursor)
        .eq('user_id', userId)
        .single();
      
      if (cursorNotification) {
        query = query.lt('created_at', cursorNotification.created_at);
      }
    }

    // Apply limit with extra one to check for more results
    query = query.limit(filters.limit + 1);

    // Execute query
    const { data: notifications, error: queryError } = await query;

    if (queryError) {
      await logger.error('Failed to fetch notifications', queryError, { userId });
      return createErrorResponse(
        { code: 'database_error', message: 'Failed to retrieve notifications' },
        500,
        corsHeaders
      );
    }

    // Check if there are more results
    const hasMore = notifications.length > filters.limit;
    const resultNotifications = hasMore ? notifications.slice(0, filters.limit) : notifications;
    const nextCursor = hasMore ? resultNotifications[resultNotifications.length - 1]?.id : null;

    // Get unread count
    const { data: unreadCountResult, error: countError } = await supabase
      .rpc('get_unread_notification_count', { p_user_id: userId });

    if (countError) {
      await logger.error('Failed to get unread count', countError, { userId });
      return createErrorResponse(
        { code: 'database_error', message: 'Failed to get notification counts' },
        500,
        corsHeaders
      );
    }

    const unreadCount = unreadCountResult || 0;

    // Get total count for pagination
    let totalQuery = supabase
      .from('user_notifications')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId);

    // Apply same filters for total count
    if (filters.type) totalQuery = totalQuery.eq('type', filters.type);
    if (filters.status) totalQuery = totalQuery.eq('status', filters.status);
    if (filters.priority) totalQuery = totalQuery.eq('priority', filters.priority);
    if (filters.from_date) totalQuery = totalQuery.gte('created_at', filters.from_date);
    if (filters.to_date) totalQuery = totalQuery.lte('created_at', filters.to_date);
    if (!filters.include_read) totalQuery = totalQuery.neq('status', 'read');
    if (!filters.include_expired) totalQuery = totalQuery.or('expires_at.is.null,expires_at.gt.now()');

    const { count: totalCount, error: totalError } = await totalQuery;

    if (totalError) {
      await logger.warn('Failed to get total count, continuing with partial data', {
        userId,
        error: totalError.message
      });
    }

    // Generate summary statistics
    const summary = {
      byType: {} as Record<string, number>,
      byStatus: {} as Record<string, number>,
      byPriority: {} as Record<string, number>
    };

    resultNotifications.forEach(notification => {
      summary.byType[notification.type] = (summary.byType[notification.type] || 0) + 1;
      summary.byStatus[notification.status] = (summary.byStatus[notification.status] || 0) + 1;
      summary.byPriority[notification.priority] = (summary.byPriority[notification.priority] || 0) + 1;
    });

    // Mark notifications as delivered if requested
    if (filters.mark_as_delivered && resultNotifications.length > 0) {
      const notificationIds = resultNotifications
        .filter(n => n.status === 'sent')
        .map(n => n.id);

      if (notificationIds.length > 0) {
        const { error: updateError } = await supabase
          .from('user_notifications')
          .update({ 
            status: 'delivered',
            delivered_at: new Date().toISOString()
          })
          .in('id', notificationIds)
          .eq('user_id', userId);

        if (updateError) {
          await logger.warn('Failed to mark notifications as delivered', {
            userId,
            notificationIds,
            error: updateError.message
          });
        } else {
          await logger.info('Marked notifications as delivered', {
            userId,
            count: notificationIds.length
          });
        }
      }
    }

    // Prepare response
    const response: NotificationResponse = {
      notifications: resultNotifications,
      pagination: {
        page: filters.page,
        limit: filters.limit,
        total: totalCount || 0,
        hasMore,
        nextCursor
      },
      unreadCount,
      summary
    };

    await logger.info('Successfully retrieved notifications', {
      userId,
      count: resultNotifications.length,
      unreadCount,
      hasMore
    });

    return createSuccessResponse(response, corsHeaders);

  } catch (error) {
    await logger.error('Unexpected error in get-user-notifications', error as Error, {
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