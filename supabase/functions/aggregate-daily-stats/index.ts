import { serve } from 'std/http/server.ts';
import { getCorsHeaders } from '../_shared/cors.ts';
import { createErrorResponse, createSuccessResponse } from '../_shared/error-handler.ts';
import { getSupabaseAdmin } from '../_shared/supabaseAdmin.ts';
import { logger } from '../_shared/logger.ts';

const ENDPOINT = 'aggregate-daily-stats';

function clampWindowMinutes(value: number): number {
  if (Number.isNaN(value) || value <= 0) return 5;
  return Math.min(60, Math.max(1, value));
}

serve(async (req: Request) => {
  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return createErrorResponse(
      { code: 'method_not_allowed', message: 'Only POST is supported' },
      { endpoint: ENDPOINT, method: req.method },
      corsHeaders,
    );
  }

  const url = new URL(req.url);
  const windowMinutes = clampWindowMinutes(Number(url.searchParams.get('window_minutes') ?? '5'));
  const now = new Date();
  const since = new Date(now.getTime() - windowMinutes * 60 * 1000).toISOString();
  const today = new Date().toISOString().split('T')[0];

  const supabase = getSupabaseAdmin();

  try {
    const [activeUsersQuery, matchesQuery, criticalErrorsQuery, matchRateQuery] = await Promise.all([
      supabase
        .from('analytics_events')
        .select('user_id', { count: 'distinct', head: true })
        .gte('created_at', since),
      supabase
        .from('matches')
        .select('id', { count: 'exact', head: true })
        .is('deleted_at', null)
        .gte('matched_at', since),
      supabase
        .from('error_logs')
        .select('id', { count: 'exact', head: true })
        .eq('severity', 'critical')
        .gte('created_at', since),
      supabase
        .from('daily_metrics')
        .select('value, metadata')
        .eq('metric_type', 'match_rate')
        .eq('metric_date', today)
        .maybeSingle(),
    ]);

    if (activeUsersQuery.error) throw activeUsersQuery.error;
    if (matchesQuery.error) throw matchesQuery.error;
    if (criticalErrorsQuery.error) throw criticalErrorsQuery.error;
    if (matchRateQuery.error) throw matchRateQuery.error;

    const activeUsers = activeUsersQuery.count ?? 0;
    const matches = matchesQuery.count ?? 0;
    const criticalErrors = criticalErrorsQuery.count ?? 0;
    const todaysMatchRate = matchRateQuery.data?.value ?? 0;

    const inserts = [
      {
        metric_name: 'active_users',
        value: activeUsers,
        unit: 'users',
        metadata: {
          window_minutes: windowMinutes,
        },
      },
      {
        metric_name: 'matches_created',
        value: matches,
        unit: 'matches',
        metadata: {
          window_minutes: windowMinutes,
        },
      },
      {
        metric_name: 'critical_errors',
        value: criticalErrors,
        unit: 'errors',
        metadata: {
          window_minutes: windowMinutes,
        },
      },
      {
        metric_name: 'match_rate_today',
        value: typeof todaysMatchRate === 'number' ? todaysMatchRate : Number(todaysMatchRate ?? 0),
        unit: 'ratio',
        metadata: {
          source: 'daily_metrics',
        },
      },
    ].map((record) => ({ ...record, recorded_at: new Date().toISOString() }));

    const insertResponse = await supabase.from('operational_metrics').insert(inserts);
    if (insertResponse.error) {
      throw insertResponse.error;
    }

    const result = {
      success: true,
      window_minutes: windowMinutes,
      snapshot: {
        active_users: activeUsers,
        matches_created: matches,
        critical_errors: criticalErrors,
        match_rate_today: todaysMatchRate,
      },
    };

    logger.info('aggregate-daily-stats success', result);

    return createSuccessResponse(result, { headers: corsHeaders });
  } catch (error) {
    logger.error('aggregate-daily-stats error', { error });
    return createErrorResponse(error, { endpoint: ENDPOINT }, corsHeaders);
  }
});
