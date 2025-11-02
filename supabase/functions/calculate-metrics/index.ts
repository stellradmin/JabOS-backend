import { serve } from 'std/http/server.ts';
import { getCorsHeaders } from '../_shared/cors.ts';
import { createErrorResponse, createSuccessResponse } from '../_shared/error-handler.ts';
import { getSupabaseAdmin } from '../_shared/supabaseAdmin.ts';
import { logger } from '../_shared/logger.ts';

const ENDPOINT = 'calculate-metrics';

function startOfTodayUTC(): string {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())).toISOString();
}

function currentDate(): string {
  return new Date().toISOString().split('T')[0];
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

  const supabase = getSupabaseAdmin();
  const todayIsoDate = currentDate();
  const since = startOfTodayUTC();

  try {
    const [matchQuery, activeUsersQuery, sentMessagesQuery] = await Promise.all([
      supabase
        .from('matches')
        .select('id, matched_at')
        .is('deleted_at', null)
        .gte('matched_at', since),
      supabase
        .from('analytics_events')
        .select('user_id', { count: 'distinct', head: true })
        .gte('created_at', since),
      supabase
        .from('analytics_events')
        .select('id', { count: 'exact', head: true })
        .eq('event_name', 'message_sent')
        .gte('created_at', since),
    ]);

    if (matchQuery.error) throw matchQuery.error;
    if (activeUsersQuery.error) throw activeUsersQuery.error;
    if (sentMessagesQuery.error) throw sentMessagesQuery.error;

    const totalMatches = matchQuery.data?.length ?? 0;
    const activeUsers = activeUsersQuery.count ?? 0;
    const messagesSent = sentMessagesQuery.count ?? 0;
    const matchRate = activeUsers > 0 ? totalMatches / activeUsers : 0;

    const [avgTimeResponse, matchQualityResponse] = await Promise.all([
      supabase.rpc('calculate_avg_time_to_match'),
      supabase.rpc('calculate_match_quality_score'),
    ]);

    if (avgTimeResponse.error) throw avgTimeResponse.error;
    if (matchQualityResponse.error) throw matchQualityResponse.error;

    const avgTimeToMatch = avgTimeResponse.data as string | null;
    const matchQualityScore = Number(matchQualityResponse.data ?? 0);

    const upsertPayload = [
      {
        metric_date: todayIsoDate,
        metric_type: 'match_rate',
        value: matchRate,
        metadata: {
          total_matches: totalMatches,
          active_users: activeUsers,
          messages_sent: messagesSent,
        },
        updated_at: new Date().toISOString(),
      },
      {
        metric_date: todayIsoDate,
        metric_type: 'messages_sent',
        value: messagesSent,
        metadata: {},
        updated_at: new Date().toISOString(),
      },
    ];

    const dailyMetricsUpsert = await supabase.from('daily_metrics').upsert(upsertPayload, {
      onConflict: 'metric_date,metric_type',
    });

    if (dailyMetricsUpsert.error) {
      throw dailyMetricsUpsert.error;
    }

    const matchMetricsInsert = await supabase.from('match_metrics').insert({
      metric_date: todayIsoDate,
      total_matches: totalMatches,
      avg_time_to_match: avgTimeToMatch,
      match_quality_score: matchQualityScore,
      metadata: {
        messages_sent: messagesSent,
        active_users: activeUsers,
      },
    });

    if (matchMetricsInsert.error) {
      throw matchMetricsInsert.error;
    }

    const responseBody = {
      success: true,
      metrics: {
        total_matches: totalMatches,
        active_users: activeUsers,
        match_rate: matchRate,
        messages_sent: messagesSent,
        avg_time_to_match: avgTimeToMatch,
        match_quality_score: matchQualityScore,
      },
    };

    logger.info('calculate-metrics success', responseBody.metrics);

    return createSuccessResponse(responseBody, { headers: corsHeaders });
  } catch (error) {
    logger.error('calculate-metrics error', { error });
    return createErrorResponse(error, { endpoint: ENDPOINT }, corsHeaders);
  }
});
