import { serve } from 'std/http/server.ts';
import { getCorsHeaders } from '../_shared/cors.ts';
import { createErrorResponse, createSuccessResponse } from '../_shared/error-handler.ts';
import { getSupabaseAdmin } from '../_shared/supabaseAdmin.ts';
import { logger } from '../_shared/logger.ts';

interface SupabaseSingleResponse<T> {
  data: T | null;
  error: { message: string } | null;
}

const ENDPOINT = 'send-alerts';
const DEFAULT_CRITICAL_ERROR_THRESHOLD = 10;

interface ThresholdRow {
  metric_name: string;
  warning_threshold: number | null;
  critical_threshold: number | null;
  metadata: Record<string, unknown> | null;
}

interface OperationalSnapshot {
  value: number;
  recorded_at: string;
  metadata?: Record<string, unknown> | null;
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

  const webhookUrl = Deno.env.get('SLACK_WEBHOOK_URL');
  if (!webhookUrl) {
    logger.warn('send-alerts invoked without SLACK_WEBHOOK_URL set');
    return createSuccessResponse({ success: true, alerts_sent: 0, warning: 'missing_webhook' }, { headers: corsHeaders });
  }

  const supabase = getSupabaseAdmin();
  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();

  try {
    const thresholdsResponse = await supabase.from('dashboard_thresholds').select('*');
    if (thresholdsResponse.error) {
      throw thresholdsResponse.error;
    }
    const thresholds = (thresholdsResponse.data ?? []) as ThresholdRow[];

    const metricSnapshots: Record<string, OperationalSnapshot> = {};
    await Promise.all(
      thresholds.map(async (threshold) => {
        const snapshot = (await supabase
          .from('operational_metrics')
          .select('value, recorded_at, metadata')
          .eq('metric_name', threshold.metric_name)
          .order('recorded_at', { ascending: false })
          .limit(1)
          .maybeSingle()) as SupabaseSingleResponse<OperationalSnapshot>;

        if (!snapshot.error && snapshot.data) {
          metricSnapshots[threshold.metric_name] = snapshot.data;
        }
      })
    );

    const alerts: string[] = [];

    thresholds.forEach((threshold) => {
      const snapshot = metricSnapshots[threshold.metric_name];
      if (!snapshot) return;

      const { value } = snapshot;
      const meta = threshold.metadata as Record<string, unknown> | null;
      const direction = (meta?.direction as string | undefined) ?? 'above';

      const isCritical = threshold.critical_threshold !== null && (
        direction === 'below' ? value <= threshold.critical_threshold : value >= threshold.critical_threshold
      );
      const isWarning = !isCritical && threshold.warning_threshold !== null && (
        direction === 'below' ? value <= threshold.warning_threshold : value >= threshold.warning_threshold
      );

      if (isCritical) {
        alerts.push(
          `:rotating_light: *${threshold.metric_name.replace(/_/g, ' ')}* at ${value.toFixed(2)} (critical threshold ${threshold.critical_threshold})`
        );
      } else if (isWarning) {
        alerts.push(
          `:warning: *${threshold.metric_name.replace(/_/g, ' ')}* at ${value.toFixed(2)} (warning threshold ${threshold.warning_threshold})`
        );
      }
    });

    const criticalErrorsResponse = await supabase
      .from('error_logs')
      .select('id', { count: 'exact', head: true })
      .eq('severity', 'critical')
      .gte('created_at', oneHourAgo);
    if (criticalErrorsResponse.error) {
      throw criticalErrorsResponse.error;
    }
    const criticalErrorsCount = criticalErrorsResponse.count ?? 0;
    if (criticalErrorsCount >= DEFAULT_CRITICAL_ERROR_THRESHOLD) {
      alerts.push(`:rotating_light: *Critical errors* reached ${criticalErrorsCount} in the last hour.`);
    }

    if (alerts.length === 0) {
      return createSuccessResponse({ success: true, alerts_sent: 0, message: 'No alerts triggered.' }, { headers: corsHeaders });
    }

    const payload = {
      text: `Stellr monitoring alerts (${new Date().toISOString()} UTC)\n${alerts.join('\n')}`,
    };

    const webhookResponse = await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    if (!webhookResponse.ok) {
      const errorText = await webhookResponse.text();
      throw new Error(`Failed to dispatch Slack alert: ${webhookResponse.status} ${errorText}`);
    }

    logger.info('send-alerts dispatched alerts', { count: alerts.length });

    return createSuccessResponse({ success: true, alerts_sent: alerts.length, alerts }, { headers: corsHeaders });
  } catch (error) {
    logger.error('send-alerts error', { error });
    return createErrorResponse(error, { endpoint: ENDPOINT }, corsHeaders);
  }
});
