import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';

import { serve } from 'std/http/server.ts'; // Using import map
import { createClient, SupabaseClient } from '@supabase/supabase-js'; // Using import map
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts'; // Zod often used directly
import { sendPushNotification } from '../_shared/sendPushNotification.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
// Using import map

// Zod Schemas for Input Validation
const CreatePayloadSchema = z.object({
  match_id: z.string().uuid(),
  proposer_id: z.string().uuid(),
  recipient_id: z.string().uuid(),
  conversation_id: z.string().uuid().optional().nullable(),
  proposed_datetime: z.string().datetime(), 
  location: z.string().optional().nullable(),
  notes: z.string().optional().nullable(),
  activity_details: z.object({ 
    type: z.string(), 
    relatedZodiacSign: z.string().optional().nullable(), 
    customTitle: z.string().optional().nullable(),
    customDescription: z.string().optional().nullable(),
  }),
});

const UpdateStatusPayloadSchema = z.object({
  proposal_id: z.string().uuid(),
  status: z.enum(['accepted', 'rejected', 'cancelled_by_proposer', 'cancelled_by_recipient', 'completed']),
});

const RequestBodySchema = z.union([
  z.object({ action: z.literal('create'), payload: CreatePayloadSchema }),
  z.object({ action: z.literal('updateStatus'), payload: UpdateStatusPayloadSchema }),
]);

const corsHeaders = {
  'Access-Control-Allow-Origin': '*', 
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

serve(async (req: Request) => {
  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/manage-date-proposal', undefined, RateLimitCategory.MESSAGING);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }


  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  let supabaseClient: SupabaseClient;
  try {

  // CRITICAL SECURITY: Secure JWT validation to prevent Algorithm Confusion Attack
  const userAuthHeader = req.headers.get('Authorization');
  if (!userAuthHeader) {
    logSecurityEvent('missing_auth_header', undefined, {
      endpoint: 'manage-date-proposal',
      userAgent: req.headers.get('User-Agent')
    });
    return createErrorResponse(
      { code: 'invalid_grant', message: 'Missing authorization' },
      { endpoint: 'manage-date-proposal' },
      corsHeaders
    );
  }

  // CRITICAL SECURITY: Validate JWT to prevent "none" algorithm attacks
  const jwtValidation = validateJWTHeader(userAuthHeader);
  if (!jwtValidation.valid) {
    logSecurityEvent('jwt_validation_failed', undefined, {
      endpoint: 'manage-date-proposal',
      error: jwtValidation.error,
      securityRisk: jwtValidation.securityRisk,
      userAgent: req.headers.get('User-Agent')
    });
    
    return createErrorResponse(
      { 
        code: 'invalid_grant', 
        message: jwtValidation.securityRisk === 'high' 
          ? 'Security violation detected' 
          : 'Invalid authorization token'
      },
      { 
        endpoint: 'manage-date-proposal',
        securityViolation: jwtValidation.securityRisk === 'high',
        jwtError: jwtValidation.error
      },
      corsHeaders
    );
  }

  // Create secure Supabase client after JWT validation
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

  if (!supabaseUrl || !supabaseAnonKey) {
    return createErrorResponse(
      { code: 'server_error', message: 'Server configuration error' },
      { endpoint: 'manage-date-proposal', issue: 'missing_env_vars' },
      corsHeaders
    );
  }

  const secureClientResult = await createSecureSupabaseClient(
    userAuthHeader,
    supabaseUrl,
    supabaseAnonKey
  );

  if (secureClientResult.error || !secureClientResult.client) {
    logSecurityEvent('secure_client_creation_failed', undefined, {
      endpoint: 'manage-date-proposal',
      error: secureClientResult.error,
      securityDetails: secureClientResult.securityDetails
    });
    
    return createErrorResponse(
      { code: 'server_error', message: 'Failed to create secure database connection' },
      { endpoint: 'manage-date-proposal', phase: 'secure_client_init' },
      corsHeaders
    );
  }

  const supabaseClient = secureClientResult.client;

  } catch (e: any) {
return new Response(JSON.stringify({ error: 'Failed to initialize Supabase client' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500,
    });
  }
  
  const { data: { user }, error: userError } = await supabaseClient.auth.getUser();

  if (userError || !user) {
    return new Response(JSON.stringify({ error: 'User not authenticated' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 401,
    });
  }

  const body = await req.json();
  const validationResult = RequestBodySchema.safeParse(body);

  if (!validationResult.success) {
    return new Response(JSON.stringify({ error: 'Invalid request body', details: validationResult.error.flatten() }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    });
  }

  const { action, payload } = validationResult.data;

  try {
    if (action === 'create') {
      const createPayload = payload as z.infer<typeof CreatePayloadSchema>;
      if (createPayload.proposer_id !== user.id) {
        return new Response(JSON.stringify({ error: 'Proposer ID must match authenticated user.' }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403
        });
      }

      const proposalToInsert = {
        match_id: createPayload.match_id,
        proposer_id: createPayload.proposer_id,
        recipient_id: createPayload.recipient_id,
        conversation_id: createPayload.conversation_id || null,
        proposed_datetime: createPayload.proposed_datetime,
        location: createPayload.location || null,
        notes: createPayload.notes || null,
        activity_details: createPayload.activity_details,
      };

      const { data, error } = await supabaseClient
        .from('date_proposals')
        .insert(proposalToInsert)
        .select()
        .single();

      if (error) throw error;
      if (!data) throw new Error('Failed to create date proposal: No data returned.');

      try {
        const { data: recipientProfileData } = await supabaseClient.from('profiles').select('push_token, display_name').eq('id', createPayload.recipient_id).single();
        const { data: proposerProfileData } = await supabaseClient.from('profiles').select('display_name').eq('id', createPayload.proposer_id).single();
        if (recipientProfileData?.push_token) {
          await sendPushNotification(
            recipientProfileData.push_token, 'New Date Proposal! 📅',
            `${proposerProfileData?.display_name || 'Someone'} has proposed a date.`,
            { type: 'new_date_proposal', proposalId: data.id, conversationId: createPayload.conversation_id || undefined }
          );
        }
}
      return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 201 });

    } else if (action === 'updateStatus') {
      const updatePayload = payload as z.infer<typeof UpdateStatusPayloadSchema>;
      const { data: currentProposal, error: fetchError } = await supabaseClient.from('date_proposals').select('proposer_id, recipient_id, conversation_id, status, proposed_datetime').eq('id', updatePayload.proposal_id).single();
      if (fetchError || !currentProposal) throw fetchError || new Error(`Proposal not found: ${updatePayload.proposal_id}`);

      const isProposer = currentProposal.proposer_id === user.id;
      const isRecipient = currentProposal.recipient_id === user.id;
      if ((updatePayload.status === 'cancelled_by_proposer' && !isProposer) || (updatePayload.status === 'cancelled_by_recipient' && !isRecipient) || ((updatePayload.status === 'accepted' || updatePayload.status === 'rejected') && !isRecipient)) {
        throw new Error('Permission denied for this status update.');
      }

      const { data, error } = await supabaseClient.rpc('update_date_proposal_status_rpc', {
        proposal_id_input: updatePayload.proposal_id, new_status_input: updatePayload.status, acting_user_id: user.id
      });
      
      if (error) throw error;
      if (!data) throw new Error('Failed to update status: No data from RPC.');

      try {
        let userToNotifyId: string | null = null; let notificationBody = '';
        const updatedProposal = data as any; // Assuming RPC returns the updated proposal
        const proposerName = (await supabaseClient.from('profiles').select('display_name').eq('id', updatedProposal.proposer_id).single()).data?.display_name || 'Your match';
        const recipientName = (await supabaseClient.from('profiles').select('display_name').eq('id', updatedProposal.recipient_id).single()).data?.display_name || 'Your match';
        const formattedDate = new Date(updatedProposal.proposed_datetime).toLocaleDateString();

        switch (updatePayload.status) {
          case 'accepted': userToNotifyId = updatedProposal.proposer_id; notificationBody = `🎉 ${recipientName} accepted your date proposal for ${formattedDate}!`; break;
          case 'rejected': userToNotifyId = updatedProposal.proposer_id; notificationBody = `🙁 ${recipientName} declined your date proposal for ${formattedDate}.`; break;
          case 'cancelled_by_proposer': userToNotifyId = updatedProposal.recipient_id; notificationBody = `ℹ️ ${proposerName} cancelled their date proposal for ${formattedDate}.`; break;
          case 'cancelled_by_recipient': userToNotifyId = updatedProposal.proposer_id; notificationBody = `ℹ️ ${recipientName} cancelled your date proposal for ${formattedDate}.`; break;
        }
        if (userToNotifyId && notificationBody) {
          const { data: targetProfile } = await supabaseClient.from('profiles').select('push_token').eq('id', userToNotifyId).single();
          if (targetProfile?.push_token) await sendPushNotification(targetProfile.push_token, 'Date Proposal Updated!', notificationBody, { type: 'date_proposal_status_update', proposalId: updatePayload.proposal_id, conversationId: updatedProposal.conversation_id || undefined, newStatus: updatePayload.status });
        }
}
      return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 });
    }

    return new Response(JSON.stringify({ error: 'Invalid action' }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 });
  } catch (e: any) {
const errorMessage = e instanceof Error ? e.message : 'An unexpected error occurred.';
    const errorDetails = e instanceof ZodError ? e.flatten() : undefined;
    return new Response(JSON.stringify({ error: errorMessage, details: errorDetails, type: e.name }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: e instanceof ZodError ? 400 : 500,
    });
  }
});
