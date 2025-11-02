import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { getSupabaseAdmin } from '../_shared/supabaseAdmin.ts';
import { getCorsHeaders } from '../_shared/cors.ts';

interface ResendEventPayload {
  type?: string;
  data?: {
    email_id?: string;
    to?: string[];
    from?: string;
    subject?: string;
    status?: string;
    created_at?: string;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

async function verifySignature(body: string, header: string | null, secret: string | undefined): Promise<boolean> {
  if (!secret) return true;
  if (!header) return false;

  try {
    const params = header.split(';').reduce<Record<string, string>>((acc, part) => {
      const [key, value] = part.trim().split('=');
      if (key && value) acc[key] = value;
      return acc;
    }, {});

    const payload = `${params['t'] ?? ''}.${body}`;
    const signature = params['v1'] ?? params['s'] ?? header;
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      'raw',
      encoder.encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['verify'],
    );

    const signatureBytes = Uint8Array.from(atob(signature), (c) => c.charCodeAt(0));
    return await crypto.subtle.verify('HMAC', key, signatureBytes, encoder.encode(payload));
  } catch (error) {
    console.error('Failed to verify Resend signature', error);
    return false;
  }
}

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

  const rawBody = await req.text();
  const secret = Deno.env.get('RESEND_WEBHOOK_SECRET');
  const signatureHeader = req.headers.get('resend-signature') ?? req.headers.get('x-resend-signature');

  const signatureValid = await verifySignature(rawBody, signatureHeader, secret);
  if (!signatureValid) {
    return new Response(JSON.stringify({ error: 'Invalid signature' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  let payload: ResendEventPayload;
  try {
    payload = JSON.parse(rawBody);
  } catch (error) {
    console.error('Invalid Resend webhook payload', error);
    return new Response(JSON.stringify({ error: 'Invalid payload' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  try {
    const supabase = getSupabaseAdmin();
    await supabase.from('resend_event_log').insert({
      event_type: payload.type ?? 'unknown',
      email: payload.data?.to?.[0] ?? null,
      message_id: payload.data?.email_id ?? null,
      payload,
    });
  } catch (error) {
    console.error('Failed to persist Resend event', error);
    return new Response(JSON.stringify({ error: 'Failed to persist event' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  return new Response(JSON.stringify({ success: true }), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});
