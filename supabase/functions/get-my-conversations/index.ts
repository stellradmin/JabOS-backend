import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';

// deno-lint-ignore-file no-explicit-any
import { serve } from 'std/http/server.ts';
import { SupabaseClient } from '@supabase/supabase-js';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
import { createErrorResponse, logSecurityEvent } from '../_shared/error-handler.ts';

// CORS Headers
const corsHeaders = {
  'Access-Control-Allow-Origin': '*', // Adjust for production
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS', 
};

interface ConversationParticipant {
  id: string;
  display_name: string | null;
  avatar_url: string | null; 
}

interface ConversationDetails {
  id: string; 
  created_at: string;
  updated_at: string | null;
  last_message_at: string | null; 
  last_message_preview: string | null; 
  other_participant: ConversationParticipant;
  unread_count?: number; 
  match_id: string | null; 
}

serve(async (req: Request) => {
  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/get-my-conversations', undefined, RateLimitCategory.MESSAGING);
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
      endpoint: 'get-my-conversations',
      userAgent: req.headers.get('User-Agent')
    });
    return createErrorResponse(
      { code: 'invalid_grant', message: 'Missing authorization' },
      { endpoint: 'get-my-conversations' },
      corsHeaders
    );
  }

  // CRITICAL SECURITY: Validate JWT to prevent "none" algorithm attacks
  const jwtValidation = validateJWTHeader(userAuthHeader);
  if (!jwtValidation.valid) {
    logSecurityEvent('jwt_validation_failed', undefined, {
      endpoint: 'get-my-conversations',
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
        endpoint: 'get-my-conversations',
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
      { endpoint: 'get-my-conversations', issue: 'missing_env_vars' },
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
      endpoint: 'get-my-conversations',
      error: secureClientResult.error,
      securityDetails: secureClientResult.securityDetails
    });
    
    return createErrorResponse(
      { code: 'server_error', message: 'Failed to create secure database connection' },
      { endpoint: 'get-my-conversations', phase: 'secure_client_init' },
      corsHeaders
    );
  }

  supabaseClient = secureClientResult.client as SupabaseClient;

  } catch (e: any) {
    return createErrorResponse(
      { code: 'server_error', message: 'Failed to initialize Supabase client' },
      { endpoint: 'get-my-conversations' },
      corsHeaders
    );
  }
  
  const { data: { user }, error: userError } = await supabaseClient.auth.getUser();

  if (userError || !user) {
    return new Response(JSON.stringify({ error: 'User not authenticated or token invalid' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401,
    });
  }

  try {
    const { data: rpcData, error: rpcError } = await supabaseClient.rpc(
      'get_user_conversations_with_details',
      { p_user_id: user.id }
    );

    if (rpcError) {
throw rpcError;
    }

    if (!rpcData) {
      return new Response(JSON.stringify([]), { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      });
    }
    
    const detailedConversations: ConversationDetails[] = rpcData.map((row: any) => ({
      id: row.conversation_id,
      created_at: row.conversation_created_at,
      updated_at: row.conversation_updated_at,
      last_message_at: row.last_message_at,
      last_message_preview: row.last_message_preview,
      match_id: row.match_id,
      other_participant: {
        id: row.other_participant_id,
        display_name: row.other_participant_display_name,
        avatar_url: row.other_participant_avatar_url,
      },
    }));

    return new Response(JSON.stringify(detailedConversations), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (e: any) {
return new Response(JSON.stringify({ error: e.message, type: e.name }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }
});
