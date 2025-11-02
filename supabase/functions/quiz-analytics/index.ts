import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { getCorsHeaders, checkRateLimit } from '../_shared/cors.ts';
import { getSupabaseAdmin } from '../_shared/supabaseAdmin.ts';

const schema = z.object({
  event: z.string().min(2).max(64),
  step: z.number().int().min(1).max(7).optional(),
  sessionId: z.string().min(4).max(64),
  properties: z.record(z.unknown()).optional(),
  email: z.string().email().optional(),
  timestamp: z.string().datetime().optional(),
});

serve(async (req) => {
  const origin = req.headers.get('origin');
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const ipAddress = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
    req.headers.get('cf-connecting-ip') ||
    'unknown';

  const rate = await checkRateLimit(`quiz-analytics:${ipAddress}`, 40, 60 * 1000);
  if (!rate.allowed) {
    return new Response(JSON.stringify({ error: 'Rate limit exceeded' }), {
      status: 429,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  let payload: z.infer<typeof schema>;
  try {
    const body = await req.json();
    payload = schema.parse(body);
  } catch (error) {
    const message = error instanceof z.ZodError ? error.issues[0]?.message ?? 'Invalid payload' : 'Invalid payload';
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  try {
    const supabase = getSupabaseAdmin();
    await supabase.from('quiz_lead_events').insert({
      session_id: payload.sessionId,
      event_type: payload.event,
      step: payload.step,
      properties: payload.properties ?? null,
      email: payload.email ?? null,
      ip_address: ipAddress !== 'unknown' ? ipAddress : null,
      occurred_at: payload.timestamp ?? new Date().toISOString(),
    });
  } catch (error) {
    console.error('Failed to persist quiz analytics', error);
    return new Response(JSON.stringify({ error: 'Unable to record event' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  return new Response(JSON.stringify({ success: true }), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});
