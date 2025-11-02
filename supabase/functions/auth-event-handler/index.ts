import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { getCorsHeaders } from '../_shared/cors.ts';
import { getSupabaseAdmin } from '../_shared/supabaseAdmin.ts';

// Webhook payload schema from Supabase Database Webhooks
// Note: email is optional/nullable to support phone-only auth (OTP)
const webhookSchema = z.object({
  type: z.enum(['INSERT', 'UPDATE', 'DELETE']),
  table: z.literal('users'),
  schema: z.literal('auth'),
  record: z
    .object({
      id: z.string().uuid(),
      email: z.string().email().optional().nullable(),
      phone: z.string().optional().nullable(),
      email_confirmed_at: z.string().nullable().optional(),
      encrypted_password: z.string().optional(),
      raw_user_meta_data: z.record(z.unknown()).nullable().optional(),
    })
    .passthrough()
    .nullable(),
  old_record: z
    .object({
      id: z.string().uuid(),
      email: z.string().email().optional().nullable(),
      phone: z.string().optional().nullable(),
      email_confirmed_at: z.string().nullable().optional(),
      encrypted_password: z.string().optional(),
      raw_user_meta_data: z.record(z.unknown()).nullable().optional(),
    })
    .passthrough()
    .nullable(),
});

type WebhookPayload = z.infer<typeof webhookSchema>;

async function enqueueEmail(
  eventType: string,
  userId: string,
  email: string,
  payload?: Record<string, unknown>,
) {
  const supabase = getSupabaseAdmin();
  const { error } = await supabase.rpc('enqueue_transactional_email', {
    p_event_type: eventType,
    p_user_id: userId,
    p_email: email,
    p_payload: payload ?? {},
  });

  if (error) {
    console.error(`Failed to enqueue ${eventType} email`, error);
    throw error;
  }

  console.log(`✅ Enqueued ${eventType} email for ${email}`);
}

function extractUserName(record: WebhookPayload['record']): string | undefined {
  if (!record?.raw_user_meta_data) return undefined;
  const metadata = record.raw_user_meta_data as Record<string, unknown>;
  return (metadata.full_name as string) ?? (metadata.name as string) ?? undefined;
}

async function handleInsert(payload: WebhookPayload) {
  // User signup → send welcome email (if email exists)
  // Note: With phone+OTP auth, users may sign up without email
  if (!payload.record) {
    console.error('INSERT webhook missing record');
    return;
  }

  const { id, email, phone } = payload.record;
  const name = extractUserName(payload.record);

  // Only send welcome email if user has email
  if (email && email.trim()) {
    await enqueueEmail('welcome', id, email, { name });
  } else {
    console.log(`📱 Phone-only signup for user ${id} (${phone ?? 'no phone'}), skipping email`);
  }
}

async function handleUpdate(payload: WebhookPayload) {
  if (!payload.record || !payload.old_record) {
    console.error('UPDATE webhook missing record or old_record');
    return;
  }

  const { id, email } = payload.record;
  const name = extractUserName(payload.record);

  // Check if email was ADDED (user signed up with phone, then added email later)
  const oldEmail = payload.old_record.email;
  const newEmail = payload.record.email;
  const emailWasAdded =
    (!oldEmail || !oldEmail.trim()) &&
    (newEmail && newEmail.trim());

  if (emailWasAdded && newEmail) {
    // User added email to existing account → send verification
    await enqueueEmail('email_verification', id, newEmail, { name });
    return;
  }

  // Note: Password change detection removed - not applicable with OTP auth
  // Note: Email confirmation detection removed - users are welcomed on signup

  // If no relevant change detected, skip
  console.log(`UPDATE on user ${id} but no email trigger detected`);
}

async function handleDelete(payload: WebhookPayload) {
  // Account deletion → send confirmation (if email exists)
  if (!payload.old_record) {
    console.error('DELETE webhook missing old_record');
    return;
  }

  const { id, email, phone } = payload.old_record;
  const name = extractUserName(payload.old_record);

  // Only send deletion confirmation if user has email
  if (email && email.trim()) {
    await enqueueEmail('account_deleted', id, email, { name });
  } else {
    console.log(`📱 Phone-only account deleted for user ${id} (${phone ?? 'no phone'}), skipping email`);
  }
}

serve(async (req: Request) => {
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

  let payload: WebhookPayload;
  try {
    const body = await req.json();
    payload = webhookSchema.parse(body);
  } catch (error) {
    const message = error instanceof z.ZodError
      ? error.issues[0]?.message ?? 'Invalid webhook payload'
      : 'Invalid webhook payload';
    console.error('Webhook validation failed:', message, error);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  try {
    const identifier = payload.record?.email ?? payload.record?.phone ?? payload.old_record?.email ?? payload.old_record?.phone ?? 'unknown user';
    console.log(`📨 Auth webhook: ${payload.type} on ${identifier}`);

    switch (payload.type) {
      case 'INSERT':
        await handleInsert(payload);
        break;
      case 'UPDATE':
        await handleUpdate(payload);
        break;
      case 'DELETE':
        await handleDelete(payload);
        break;
      default:
        console.log(`Unhandled webhook type: ${payload.type}`);
    }

    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('Auth event handler failed', error);
    return new Response(JSON.stringify({
      error: 'Auth event handler failed',
      message: error instanceof Error ? error.message : 'Unknown error',
    }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
