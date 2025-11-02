import { serve } from 'std/http/server.ts';
import { createClient } from 'supabase';
import { verifyWebhookSignature, parseWebhookEvent, mapInquiryStatus, extractLivenessScore, getInquiry } from '../_shared/persona-api.ts';

serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  try {
    const signature = req.headers.get('Persona-Signature');
    const timestamp = req.headers.get('Persona-Timestamp');

    if (!signature || !timestamp) {
      console.error('[persona-webhook] Missing signature or timestamp');
      return new Response('Missing signature', { status: 401 });
    }

    const bodyText = await req.text();

    const isValid = await verifyWebhookSignature(bodyText, signature, timestamp);
    if (!isValid) {
      console.error('[persona-webhook] Invalid signature');
      return new Response('Invalid signature', { status: 401 });
    }

    const payload = JSON.parse(bodyText);
    const event = parseWebhookEvent(payload);

    if (!event) {
      console.error('[persona-webhook] Invalid event payload');
      return new Response('Invalid payload', { status: 400 });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const inquiryId = event.attributes.payload.data.id;

    await supabase.from('persona_webhook_events').insert({
      inquiry_id: inquiryId,
      event_type: event.attributes.name,
      event_data: payload,
      processed: false
    });

    const inquiry = await getInquiry(inquiryId);
    if (!inquiry) {
      console.error('[persona-webhook] Failed to fetch inquiry:', inquiryId);
      return new Response('OK', { status: 200 });
    }

    const referenceId = inquiry.attributes['reference-id'];
    const userId = referenceId.replace('user_', '');

    const status = mapInquiryStatus(inquiry.attributes.status);
    const livenessScore = extractLivenessScore(inquiry);

    await supabase.rpc('update_persona_verification_status', {
      p_user_id: userId,
      p_inquiry_id: inquiryId,
      p_status: status,
      p_liveness_score: livenessScore
    });

    await supabase.from('persona_webhook_events').update({
      processed: true,
      processed_at: new Date().toISOString(),
      user_id: userId
    }).eq('inquiry_id', inquiryId).eq('processed', false);

    console.log(`[persona-webhook] Processed event for user ${userId}: ${status}`);

    return new Response('OK', { status: 200 });
  } catch (error) {
    console.error('[persona-webhook] Error:', error);
    return new Response('Internal server error', { status: 500 });
  }
});
