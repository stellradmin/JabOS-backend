import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';
import { getCorsHeaders, checkRateLimit, RATE_LIMITS } from '../_shared/cors.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { logger, LogCategory, createRequestContext, createTimerContext } from '../_shared/structured-logging.ts';
import { syncRevenueCatSubscriber } from '../_shared/revenuecat-api.ts';

/**
 * RevenueCat Webhook Handler
 *
 * Receives subscription lifecycle events from RevenueCat and updates our database.
 * Follows RevenueCat best practice: Respond 200 immediately, then async fetch latest data from API.
 *
 * Event Types Handled:
 * - INITIAL_PURCHASE: New subscription
 * - RENEWAL: Subscription renewed
 * - CANCELLATION: User cancelled (but still active until expiration)
 * - BILLING_ISSUE: Payment failed, grace period started
 * - EXPIRATION: Subscription expired
 * - PRODUCT_CHANGE: Upgraded/downgraded
 * - TRANSFER: Subscription transferred between users
 */

serve(async (req: Request) => {
  const timer = createTimerContext();
  const requestContext = createRequestContext(req);

  logger.info(LogCategory.WEBHOOK, 'RevenueCat webhook request received', {
    ...requestContext,
    function: 'revenuecat-webhook',
    method: req.method
  });

  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/revenuecat-webhook', undefined, RateLimitCategory.PAYMENTS);
  if (rateLimitResult.blocked) {
    logger.rateLimitExceeded('/revenuecat-webhook', requestContext.clientIP!, requestContext);
    return rateLimitResult.response;
  }

  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  // Security headers for webhook endpoint
  const securityHeaders = {
    ...corsHeaders,
    'X-Frame-Options': 'DENY',
    'X-Content-Type-Options': 'nosniff',
    'X-XSS-Protection': '1; mode=block',
    'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
    'Content-Security-Policy': "default-src 'none'; script-src 'none'; object-src 'none'",
    'Referrer-Policy': 'no-referrer'
  };

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: securityHeaders });
  }

  // Environment variables
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const revenuecatAuthHeader = Deno.env.get('REVENUECAT_WEBHOOK_AUTH_KEY');
  const revenuecatApiKey = Deno.env.get('REVENUECAT_SECRET_KEY');

  if (!supabaseUrl || !supabaseServiceKey) {
    logger.critical(LogCategory.WEBHOOK, 'Missing Supabase configuration', {
      ...requestContext,
      configurationError: true
    });
    return new Response(JSON.stringify({ error: 'Server configuration error' }), {
      headers: { ...securityHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }

  if (!revenuecatAuthHeader || !revenuecatApiKey) {
    logger.critical(LogCategory.WEBHOOK, 'Missing RevenueCat configuration', {
      ...requestContext,
      configurationError: true
    });
    return new Response(JSON.stringify({ error: 'Webhook configuration error' }), {
      headers: { ...securityHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }

  // Initialize Supabase admin client
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    // Verify authorization header (set in RevenueCat dashboard)
    const authHeader = req.headers.get('Authorization');
    if (!authHeader || authHeader !== `Bearer ${revenuecatAuthHeader}`) {
      logger.warn(LogCategory.SECURITY, 'RevenueCat webhook authentication failed', {
        ...requestContext,
        securityEvent: true,
        reason: 'Invalid authorization header'
      });
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        headers: { ...securityHeaders, 'Content-Type': 'application/json' },
        status: 401,
      });
    }

    // Parse webhook payload
    const payload = await req.json();
    const eventType = payload.event?.type;
    const eventId = payload.event?.id;
    const appUserId = payload.event?.app_user_id;

    if (!eventType || !eventId || !appUserId) {
      logger.warn(LogCategory.WEBHOOK, 'Invalid RevenueCat webhook payload', {
        ...requestContext,
        eventType,
        eventId,
        appUserId
      });
      return new Response(JSON.stringify({ error: 'Invalid payload' }), {
        headers: { ...securityHeaders, 'Content-Type': 'application/json' },
        status: 400,
      });
    }

    // Event deduplication - check if already processed
    const { data: existingEvent } = await supabase
      .from('revenuecat_webhook_events')
      .select('id, processed_at')
      .eq('event_id', eventId)
      .single();

    if (existingEvent) {
      logger.info(LogCategory.WEBHOOK, 'RevenueCat event already processed', {
        ...requestContext,
        eventId,
        eventType,
        processedAt: existingEvent.processed_at
      });
      return new Response(JSON.stringify({
        received: true,
        message: 'Event already processed',
        processedAt: existingEvent.processed_at
      }), {
        headers: { ...securityHeaders, 'Content-Type': 'application/json' },
        status: 200,
      });
    }

    // Log webhook event for audit trail
    const { error: insertError } = await supabase
      .from('revenuecat_webhook_events')
      .insert({
        event_id: eventId,
        event_type: eventType,
        app_user_id: appUserId,
        product_id: payload.event?.product_id || null,
        entitlement_id: payload.event?.entitlement_ids?.[0] || null,
        store: payload.event?.store || null,
        event_timestamp: payload.event?.event_timestamp_ms ? new Date(payload.event.event_timestamp_ms).toISOString() : new Date().toISOString(),
        raw_payload: payload,
        processed: false
      });

    if (insertError && !insertError.message.includes('duplicate')) {
      logger.error(LogCategory.WEBHOOK, 'Failed to log RevenueCat webhook event', {
        ...requestContext,
        eventId,
        eventType,
        error: insertError.message
      });
    }

    // REVENUECAT BEST PRACTICE:
    // Respond 200 immediately, then process async
    // This prevents timeout issues and ensures RevenueCat doesn't retry

    // Find user by app_user_id (should match Supabase user ID)
    const { data: userData } = await supabase
      .from('users')
      .select('id')
      .eq('auth_user_id', appUserId)
      .single();

    if (!userData) {
      logger.warn(LogCategory.WEBHOOK, 'User not found for RevenueCat event', {
        ...requestContext,
        appUserId,
        eventType
      });
      // Still return 200 to prevent retries
      return new Response(JSON.stringify({ received: true }), {
        headers: { ...securityHeaders, 'Content-Type': 'application/json' },
        status: 200,
      });
    }

    // REVENUECAT BEST PRACTICE:
    // Use webhook as trigger, then fetch latest data from API
    // This ensures we always have the most current subscription state
    try {
      await syncRevenueCatSubscriber(supabase, appUserId, revenuecatApiKey);

      // Mark webhook as processed
      await supabase
        .from('revenuecat_webhook_events')
        .update({
          processed: true,
          processed_at: new Date().toISOString(),
          user_id: userData.id
        })
        .eq('event_id', eventId);

      logger.info(LogCategory.WEBHOOK, 'RevenueCat webhook processed successfully', {
        ...requestContext,
        function: 'revenuecat-webhook',
        eventType,
        eventId,
        appUserId,
        duration: timer.getElapsed()
      });
    } catch (syncError: any) {
      logger.error(LogCategory.WEBHOOK, 'Failed to sync RevenueCat subscriber', {
        ...requestContext,
        eventId,
        appUserId,
        error: syncError.message
      });

      // Still return 200 to prevent retries (we logged the event for manual review)
    }

    return new Response(JSON.stringify({ received: true }), {
      headers: { ...securityHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error: any) {
    logger.critical(LogCategory.WEBHOOK, 'RevenueCat webhook handler failed', {
      ...requestContext,
      function: 'revenuecat-webhook',
      duration: timer.getElapsed(),
      errorMessage: error.message,
      errorStack: error.stack
    }, error);

    return new Response(JSON.stringify({
      error: 'Webhook handler failed',
      details: error.message
    }), {
      headers: { ...securityHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }
});

// Webhook processing now uses syncRevenueCatSubscriber() from revenuecat-api.ts
// This follows RevenueCat's recommended pattern: use webhook as trigger, then fetch latest data from API
