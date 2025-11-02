/**
 * Daily Invite Reset Edge Function
 *
 * Scheduled to run daily at 00:00 UTC via Supabase cron job
 * Resets daily invite counts for all users based on their subscription tier
 *
 * Free users: 5 invites/day
 * Premium users: 20 invites/day
 *
 * Prerequisites:
 * - Configured as cron job in Supabase Dashboard
 * - Schedule: Daily at 00:00 UTC (0 0 * * *)
 */

import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';
import { getCorsHeaders } from '../_shared/cors.ts';
import { logger, LogCategory, createRequestContext, createTimerContext } from '../_shared/structured-logging.ts';

serve(async (req: Request) => {
  const timer = createTimerContext();
  const requestContext = createRequestContext(req);

  logger.info(LogCategory.CRON, 'Daily invite reset job started', {
    ...requestContext,
    function: 'daily-invite-reset',
  });

  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  // Security headers
  const securityHeaders = {
    ...corsHeaders,
    'X-Frame-Options': 'DENY',
    'X-Content-Type-Options': 'nosniff',
    'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  };

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: securityHeaders });
  }

  // Environment variables
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  if (!supabaseUrl || !supabaseServiceKey) {
    logger.critical(LogCategory.CRON, 'Missing Supabase configuration', {
      ...requestContext,
      configurationError: true,
    });
    return new Response(
      JSON.stringify({ error: 'Server configuration error' }),
      {
        headers: { ...securityHeaders, 'Content-Type': 'application/json' },
        status: 500,
      }
    );
  }

  // Initialize Supabase admin client
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    // Get today's date in YYYY-MM-DD format
    const today = new Date().toISOString().split('T')[0];

    logger.info(LogCategory.CRON, 'Fetching users needing invite reset', {
      ...requestContext,
      today,
    });

    // Get all users who need their invites reset
    // (users whose last_invite_reset_date is not today)
    const { data: usersToReset, error: fetchError } = await supabase
      .from('profiles')
      .select('id, subscription_status, daily_invites_remaining, last_invite_reset_date')
      .or(`last_invite_reset_date.is.null,last_invite_reset_date.neq.${today}`);

    if (fetchError) {
      throw fetchError;
    }

    if (!usersToReset || usersToReset.length === 0) {
      logger.info(LogCategory.CRON, 'No users need invite reset', {
        ...requestContext,
        duration: timer.getElapsed(),
      });
      return new Response(
        JSON.stringify({
          success: true,
          resetCount: 0,
          message: 'No users needed reset',
        }),
        {
          headers: { ...securityHeaders, 'Content-Type': 'application/json' },
        }
      );
    }

    logger.info(LogCategory.CRON, `Found ${usersToReset.length} users to reset`, {
      ...requestContext,
      userCount: usersToReset.length,
    });

    // Reset invites for each user
    let resetCount = 0;
    let errorCount = 0;
    const errors: any[] = [];

    for (const user of usersToReset) {
      try {
        // Determine invite limit based on subscription status
        const isPremium = user.subscription_status === 'premium' ||
                         user.subscription_status === 'premium_cancelled';
        const inviteLimit = isPremium ? 20 : 5;

        // Update user's invite count
        const { error: updateError } = await supabase
          .from('profiles')
          .update({
            daily_invites_remaining: inviteLimit,
            last_invite_reset_date: today,
            updated_at: new Date().toISOString(),
          })
          .eq('id', user.id);

        if (updateError) {
          errorCount++;
          errors.push({
            userId: user.id,
            error: updateError.message,
          });
          logger.error(LogCategory.CRON, 'Failed to reset invites for user', {
            ...requestContext,
            userId: user.id,
            error: updateError.message,
          });
        } else {
          resetCount++;
          logger.debug(LogCategory.CRON, 'Reset invites for user', {
            ...requestContext,
            userId: user.id,
            newLimit: inviteLimit,
            isPremium,
          });
        }
      } catch (userError: any) {
        errorCount++;
        errors.push({
          userId: user.id,
          error: userError.message,
        });
        logger.error(LogCategory.CRON, 'Exception resetting user invites', {
          ...requestContext,
          userId: user.id,
          error: userError.message,
        });
      }
    }

    logger.info(LogCategory.CRON, 'Daily invite reset completed', {
      ...requestContext,
      function: 'daily-invite-reset',
      duration: timer.getElapsed(),
      totalUsers: usersToReset.length,
      resetCount,
      errorCount,
    });

    return new Response(
      JSON.stringify({
        success: true,
        resetCount,
        errorCount,
        totalUsers: usersToReset.length,
        errors: errors.length > 0 ? errors : undefined,
        timestamp: new Date().toISOString(),
      }),
      {
        headers: { ...securityHeaders, 'Content-Type': 'application/json' },
      }
    );
  } catch (error: any) {
    logger.critical(LogCategory.CRON, 'Daily invite reset failed', {
      ...requestContext,
      function: 'daily-invite-reset',
      duration: timer.getElapsed(),
      errorMessage: error.message,
      errorStack: error.stack,
    }, error);

    return new Response(
      JSON.stringify({
        success: false,
        error: 'Daily invite reset failed',
        details: error.message,
      }),
      {
        headers: { ...securityHeaders, 'Content-Type': 'application/json' },
        status: 500,
      }
    );
  }
});

/**
 * DEPLOYMENT INSTRUCTIONS:
 *
 * 1. Deploy function:
 *    supabase functions deploy daily-invite-reset
 *
 * 2. Configure cron job in Supabase Dashboard:
 *    - Go to Edge Functions > daily-invite-reset
 *    - Click "Cron Jobs"
 *    - Add new cron job:
 *      - Schedule: 0 0 * * * (Daily at midnight UTC)
 *      - HTTP Method: POST
 *      - HTTP Headers: Authorization: Bearer [anon key]
 *
 * 3. Test manually:
 *    curl -X POST https://[project-ref].supabase.co/functions/v1/daily-invite-reset \
 *      -H "Authorization: Bearer [anon-key]"
 */
