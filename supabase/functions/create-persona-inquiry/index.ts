import { serve } from 'std/http/server.ts';
import { createClient } from 'supabase';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { getCorsHeaders } from '../_shared/cors.ts';
import { createInquiry } from '../_shared/persona-api.ts';

const RequestSchema = z.object({
  userId: z.string().uuid(),
  templateId: z.string().optional(),
  referenceId: z.string(),
  fields: z.record(z.any()).optional()
});

serve(async (req: Request) => {
  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Missing authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);

    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const body = await req.json();
    const parsed = RequestSchema.parse(body);

    if (parsed.userId !== user.id) {
      return new Response(
        JSON.stringify({ error: 'Forbidden' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const inquiry = await createInquiry({
      referenceId: parsed.referenceId,
      templateId: parsed.templateId,
      fields: parsed.fields || {}
    });

    if (!inquiry) {
      return new Response(
        JSON.stringify({ error: 'Failed to create Persona inquiry' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    await supabase.from('profiles').update({
      persona_inquiry_id: inquiry.id,
      persona_verification_status: 'in_progress',
      updated_at: new Date().toISOString()
    }).eq('id', parsed.userId);

    return new Response(
      JSON.stringify({
        success: true,
        inquiryId: inquiry.id,
        sessionToken: inquiry.attributes['session-token']
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('[create-persona-inquiry] Error:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
