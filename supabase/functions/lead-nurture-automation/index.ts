import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { Resend } from 'npm:resend@2.1.0';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { getCorsHeaders } from '../_shared/cors.ts';
import { getSupabaseAdmin } from '../_shared/supabaseAdmin.ts';
import { renderEmail, ReengagementEmail } from '../_shared/emails/index.ts';

const requestSchema = z.object({
  dryRun: z.boolean().optional(),
  limit: z.number().int().min(1).max(50).optional(),
});

const nurtureCopy: Record<string, { highlight: string; incentive?: string; cadence: 'day1' | 'day3' | 'day7' | 'day14' | 'day30' }> = {
  day1: {
    highlight: 'Your compatibility feed just refreshed — see who matches your sun, moon, and rising energy.',
    incentive: 'Get featured matches if you reopen the app today.',
    cadence: 'day1',
  },
  day3: {
    highlight: 'We found new Stellr members sharing your vibe. Your cosmic profile is still active.',
    incentive: 'Share your profile to unlock an extra compatibility insight.',
    cadence: 'day3',
  },
  day7: {
    highlight: 'Your perfect match might be waiting. Grab your saved compatibility report before it rotates.',
    incentive: 'Turn notifications back on to catch next week’s drops first.',
    cadence: 'day7',
  },
  day14: {
    highlight: 'Stellr keeps evolving. Fresh prompts + astro pairings are ready when you are.',
    cadence: 'day14',
  },
  day30: {
    highlight: 'Last chance to keep your profile active. We’ll archive it soon to make room for new cosmic explorers.',
    incentive: 'Come back today and we’ll fast-track you into premium match pools for 48 hours.',
    cadence: 'day30',
  },
};

function getResend(): Resend {
  const key = Deno.env.get('RESEND_API_KEY');
  if (!key) throw new Error('RESEND_API_KEY missing');
  return new Resend(key);
}

function buildUnsubscribeUrl(email: string, source: string) {
  const base = Deno.env.get('STELLR_UNSUBSCRIBE_URL') ?? 'https://stellr.app/unsubscribe';
  const url = new URL(base);
  url.searchParams.set('email', email);
  url.searchParams.set('source', source);
  return url.toString();
}

async function fetchPending(limit: number) {
  const supabase = getSupabaseAdmin();
  const now = new Date().toISOString();
  const { data, error } = await supabase
    .from('quiz_nurture_queue')
    .select('id, quiz_lead_id, sequence_step, metadata')
    .eq('status', 'pending')
    .lte('scheduled_for', now)
    .order('scheduled_for', { ascending: true })
    .limit(limit);

  if (error) throw error;
  return data ?? [];
}

async function loadLead(leadId: string) {
  const supabase = getSupabaseAdmin();
  const { data, error } = await supabase
    .from('quiz_leads')
    .select('id, email, quiz_results, question_1_answer, question_2_answer, question_3_answer')
    .eq('id', leadId)
    .single();
  if (error) throw error;
  return data;
}

async function markQueue(id: number, status: 'sent' | 'error', message?: string) {
  const supabase = getSupabaseAdmin();
  await supabase
    .from('quiz_nurture_queue')
    .update({ status, processed_at: new Date().toISOString(), ...(message ? { metadata: { error: message } } : {}) })
    .eq('id', id);
}

async function processNurture(limit: number, dryRun = false) {
  const rows = await fetchPending(limit);
  if (rows.length === 0) return { processed: 0 };

  const resend = dryRun ? null : getResend();
  let count = 0;

  for (const row of rows) {
    const copy = nurtureCopy[row.sequence_step ?? ''];
    if (!copy) {
      await markQueue(row.id, 'error', 'No template copy found');
      continue;
    }

    try {
      const lead = await loadLead(row.quiz_lead_id);
      if (!lead?.email) {
        await markQueue(row.id, 'error', 'Lead missing email');
        continue;
      }

      const rendered = renderEmail(ReengagementEmail, {
        name: lead.quiz_results?.name ?? lead.email.split('@')[0],
        cadence: copy.cadence,
        highlight: copy.highlight,
        incentive: copy.incentive,
        downloadLink: Deno.env.get('STELLR_DOWNLOAD_URL') ?? 'https://stellr.app/download',
        unsubscribeUrl: buildUnsubscribeUrl(lead.email, `nurture_${row.sequence_step}`),
      });

      if (!dryRun && resend) {
        await resend.emails.send({
          from: Deno.env.get('STELLR_EMAIL_FROM') ?? 'team@stellr.app',
          to: lead.email,
          subject: copy.highlight,
          html: rendered.html,
          text: rendered.text,
          headers: {
            'List-Unsubscribe': `<${buildUnsubscribeUrl(lead.email, `nurture_${row.sequence_step}`)}>`,
          },
        });
      }

      await markQueue(row.id, 'sent');
      count += 1;
    } catch (error) {
      console.error('Failed processing nurture email', error);
      await markQueue(row.id, 'error', error instanceof Error ? error.message : 'Unknown error');
    }
  }

  return { processed: count };
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

  let payload: z.infer<typeof requestSchema>;
  try {
    const body = await req.json().catch(() => ({}));
    payload = requestSchema.parse(body);
  } catch (error) {
    const message = error instanceof z.ZodError ? error.issues[0]?.message ?? 'Invalid payload' : 'Invalid payload';
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  try {
    const result = await processNurture(payload.limit ?? 10, payload.dryRun ?? false);
    return new Response(JSON.stringify({ success: true, processed: result.processed, dryRun: payload.dryRun ?? false }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('Lead nurture automation failed', error);
    return new Response(JSON.stringify({ error: 'Lead nurture automation failed' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
