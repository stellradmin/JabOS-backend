import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { Resend } from 'npm:resend@2.1.0';
import { getCorsHeaders } from '../_shared/cors.ts';
import { getSupabaseAdmin } from '../_shared/supabaseAdmin.ts';
import {
  renderEmail,
  WelcomeEmail,
  EmailVerificationEmail,
  PasswordResetEmail,
  PasswordChangedEmail,
  AccountDeletionEmail,
  WeeklyMatchDigestEmail,
} from '../_shared/emails/index.ts';

const dispatcherSchema = z.object({
  mode: z.enum(['process_queue', 'send_event']).default('process_queue'),
  event: z
    .object({
      event_type: z.string(),
      email: z.string().email(),
      user_id: z.string().uuid().optional(),
      template_version: z.string().optional(),
      payload: z.record(z.unknown()).optional(),
    })
    .optional(),
});

type QueueRow = {
  id: number;
  user_id: string;
  email: string;
  event_type: string;
  template_version: string | null;
  payload: Record<string, unknown> | null;
};

function getResend(): Resend {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  if (!apiKey) {
    throw new Error('RESEND_API_KEY is missing');
  }
  return new Resend(apiKey);
}

function buildUnsubscribeUrl(email: string, source: string) {
  const base = Deno.env.get('STELLR_UNSUBSCRIBE_URL') ?? 'https://stellr.app/unsubscribe';
  const url = new URL(base);
  url.searchParams.set('email', email);
  url.searchParams.set('source', source);
  return url.toString();
}

function renderTransactionalTemplate(event: QueueRow | { event_type: string; email: string; payload?: Record<string, unknown> | null }): {
  subject: string;
  html: string;
  text: string;
} {
  const payload = (event.payload ?? {}) as Record<string, unknown>;
  const name = (payload.name as string | undefined) ?? event.email.split('@')[0];
  const unsubscribeUrl = buildUnsubscribeUrl(event.email, event.event_type);

  switch (event.event_type) {
    case 'welcome': {
      const rendered = renderEmail(WelcomeEmail, {
        name,
        downloadLink: Deno.env.get('STELLR_DOWNLOAD_URL') ?? 'https://stellr.app/download',
        unsubscribeUrl,
      });
      return {
        subject: `Welcome to Stellr, ${name}!`,
        html: rendered.html,
        text: rendered.text,
      };
    }
    case 'email_verification':
    case 'magic_link': {
      const verificationUrl = (payload.verification_url as string | undefined) ?? '#';
      const code = payload.code as string | undefined;
      const rendered = renderEmail(EmailVerificationEmail, {
        name,
        verificationUrl,
        verificationCode: code,
        unsubscribeUrl,
      });
      return {
        subject: `Verify your Stellr account`,
        html: rendered.html,
        text: rendered.text,
      };
    }
    case 'password_reset': {
      const resetUrl = (payload.reset_url as string | undefined) ?? '#';
      const expires = Number(payload.expires_in_minutes ?? 30);
      const rendered = renderEmail(PasswordResetEmail, {
        name,
        resetUrl,
        expiresInMinutes: expires,
        unsubscribeUrl,
      });
      return {
        subject: 'Reset your Stellr password',
        html: rendered.html,
        text: rendered.text,
      };
    }
    case 'password_changed': {
      const rendered = renderEmail(PasswordChangedEmail, {
        name,
        unsubscribeUrl,
      });
      return {
        subject: 'Your Stellr password was updated',
        html: rendered.html,
        text: rendered.text,
      };
    }
    case 'account_deleted': {
      const rendered = renderEmail(AccountDeletionEmail, {
        name,
        unsubscribeUrl,
        feedbackLink: (payload.feedback_link as string | undefined) ?? 'https://stellr.app/feedback',
      });
      return {
        subject: 'Your Stellr account has been deleted',
        html: rendered.html,
        text: rendered.text,
      };
    }
    case 'weekly_match_digest': {
      const matches = (payload.matches as Array<Record<string, unknown>> | undefined) ?? [];
      const rendered = renderEmail(WeeklyMatchDigestEmail, {
        name,
        matches: matches.map((match) => ({
          name: String(match.name ?? 'New Match'),
          sunSign: String(match.sunSign ?? 'Unknown'),
          compatibilityScore: Number(match.compatibilityScore ?? 70),
          highlight: String(match.highlight ?? 'High cosmic alignment'),
          profileUrl: String(match.profileUrl ?? '#'),
        })),
        exploreLink: (payload.explore_link as string | undefined) ?? 'https://stellr.app/download',
        unsubscribeUrl,
      });
      return {
        subject: 'Your Stellr match digest is here',
        html: rendered.html,
        text: rendered.text,
      };
    }
    default:
      throw new Error(`Unsupported transactional event type: ${event.event_type}`);
  }
}

async function augmentQueueRow(row: QueueRow): Promise<QueueRow> {
  const payload: Record<string, unknown> = { ...(row.payload ?? {}) };

  if ((row.event_type === 'email_verification' || row.event_type === 'magic_link') && !payload.verification_url) {
    const supabase = getSupabaseAdmin();
    const redirectTo = Deno.env.get('STELLR_VERIFY_REDIRECT_URL') ?? 'https://stellr.app/download';
    const { data, error } = await supabase.auth.admin.generateLink({
      type: 'magiclink',
      email: row.email,
      options: { redirectTo },
    });
    if (error) throw error;
    payload.verification_url = data?.properties?.action_link ?? data?.action_link ?? payload.verification_url ?? '#';
    payload.code = data?.properties?.email_otp ?? payload.code;
  }

  if (row.event_type === 'password_reset' && !payload.reset_url) {
    const supabase = getSupabaseAdmin();
    const redirectTo = Deno.env.get('STELLR_RESET_REDIRECT_URL') ?? 'https://stellr.app/reset-password';
    const { data, error } = await supabase.auth.admin.generateLink({
      type: 'recovery',
      email: row.email,
      options: { redirectTo },
    });
    if (error) throw error;
    payload.reset_url = data?.properties?.action_link ?? data?.action_link ?? '#';
    payload.expires_in_minutes = payload.expires_in_minutes ?? 30;
  }

  return { ...row, payload };
}

async function processQueueItem(resend: Resend, row: QueueRow) {
  const supabase = getSupabaseAdmin();
  const { data: lockedRows, error: lockError } = await supabase
    .from('transactional_email_queue')
    .update({ status: 'processing', processed_at: new Date().toISOString() })
    .eq('id', row.id)
    .eq('status', 'pending')
    .select('id');

  if (lockError) {
    throw lockError;
  }

  if (!lockedRows || lockedRows.length === 0) {
    return { skipped: true };
  }

  try {
    const enrichedRow = await augmentQueueRow(row);
    const rendered = renderTransactionalTemplate(enrichedRow);
    await resend.emails.send({
      from: Deno.env.get('STELLR_EMAIL_FROM') ?? 'team@stellr.app',
      to: enrichedRow.email,
      subject: rendered.subject,
      html: rendered.html,
      text: rendered.text,
      headers: {
        'List-Unsubscribe': `<${buildUnsubscribeUrl(enrichedRow.email, enrichedRow.event_type)}>`,
      },
    });

    await supabase
      .from('transactional_email_queue')
      .update({ status: 'sent' })
      .eq('id', row.id);

    return { skipped: false };
  } catch (error) {
    console.error('Failed to send transactional email', error);
    await supabase
      .from('transactional_email_queue')
      .update({ status: 'error', error_message: error instanceof Error ? error.message : 'Unknown error' })
      .eq('id', row.id);
    throw error;
  }
}

async function processQueueBatch(limit = 10) {
  const supabase = getSupabaseAdmin();
  const { data: rows, error } = await supabase
    .from('transactional_email_queue')
    .select('id, user_id, email, event_type, template_version, payload')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
    .limit(limit);

  if (error) {
    throw error;
  }

  if (!rows || rows.length === 0) {
    return { processed: 0 };
  }

  const resend = getResend();
  let processed = 0;
  for (const row of rows) {
    try {
      const result = await processQueueItem(resend, row as QueueRow);
      if (!result.skipped) {
        processed += 1;
      }
    } catch (error) {
      console.error('Transactional email processing error', error);
    }
  }

  return { processed };
}

async function sendImmediateEvent(event: { event_type: string; email: string; payload?: Record<string, unknown> | null; user_id?: string }) {
  const resend = getResend();
  const enriched = await augmentQueueRow({
    id: 0,
    user_id: event.user_id ?? '',
    email: event.email,
    event_type: event.event_type,
    template_version: null,
    payload: event.payload ?? null,
  });
  const rendered = renderTransactionalTemplate(enriched);

  await resend.emails.send({
    from: Deno.env.get('STELLR_EMAIL_FROM') ?? 'team@stellr.app',
    to: enriched.email,
    subject: rendered.subject,
    html: rendered.html,
    text: rendered.text,
    headers: {
      'List-Unsubscribe': `<${buildUnsubscribeUrl(enriched.email, enriched.event_type)}>`,
    },
  });
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

  let payload: z.infer<typeof dispatcherSchema>;
  try {
    const body = await req.json();
    payload = dispatcherSchema.parse(body ?? {});
  } catch (error) {
    const message = error instanceof z.ZodError ? error.issues[0]?.message ?? 'Invalid payload' : 'Invalid payload';
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  try {
    if (payload.mode === 'process_queue') {
      const result = await processQueueBatch();
      return new Response(JSON.stringify({ success: true, processed: result.processed }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (!payload.event) {
      return new Response(JSON.stringify({ error: 'Event data required for send_event mode' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    await sendImmediateEvent(payload.event);
    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('Transactional dispatcher failed', error);
    return new Response(JSON.stringify({ error: 'Dispatcher failed' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
