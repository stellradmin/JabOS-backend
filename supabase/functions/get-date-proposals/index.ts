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
import { z, ZodError } from 'https://deno.land/x/zod@v3.22.4/mod.ts'; import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
// Zod often used directly

// Zod Schema for Query Parameters
const GetProposalsQuerySchema = z.object({
  type: z.enum(['user', 'conversation']),
  id: z.string().uuid(), // userId or conversationId
  statusFilter: z.string().optional(), // Should align with DateProposalStatus type values
  page: z.string().optional().default('1').transform(val => parseInt(val, 10)),
  pageSize: z.string().optional().default('10').transform(val => parseInt(val, 10)),
});

// CORS Headers
const corsHeaders = {
  'Access-Control-Allow-Origin': '*', // Adjust for production
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

const DATE_PROPOSALS_TABLE = 'date_proposals';
const PROPOSAL_FIELDS_TO_SELECT = '*, proposer_profile:proposer_id(display_name), recipient_profile:recipient_id(display_name)'; 

serve(async (req: Request) => {
  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/get-date-proposals', undefined, RateLimitCategory.MESSAGING);
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
      endpoint: 'get-date-proposals',
      userAgent: req.headers.get('User-Agent')
    });
    return createErrorResponse(
      { code: 'invalid_grant', message: 'Missing authorization' },
      { endpoint: 'get-date-proposals' },
      corsHeaders
    );
  }

  // CRITICAL SECURITY: Validate JWT to prevent "none" algorithm attacks
  const jwtValidation = validateJWTHeader(userAuthHeader);
  if (!jwtValidation.valid) {
    logSecurityEvent('jwt_validation_failed', undefined, {
      endpoint: 'get-date-proposals',
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
        endpoint: 'get-date-proposals',
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
      { endpoint: 'get-date-proposals', issue: 'missing_env_vars' },
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
      endpoint: 'get-date-proposals',
      error: secureClientResult.error,
      securityDetails: secureClientResult.securityDetails
    });
    
    return createErrorResponse(
      { code: 'server_error', message: 'Failed to create secure database connection' },
      { endpoint: 'get-date-proposals', phase: 'secure_client_init' },
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
    return new Response(JSON.stringify({ error: 'User not authenticated or token invalid' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401,
    });
  }

  try {
    const url = new URL(req.url);
    const queryParams = Object.fromEntries(url.searchParams.entries());
    const validatedParams = GetProposalsQuerySchema.parse(queryParams);

    const { type, id, statusFilter, page, pageSize } = validatedParams;
    const offset = (page - 1) * pageSize;

    let queryBuilder = supabaseClient.from(DATE_PROPOSALS_TABLE).select(PROPOSAL_FIELDS_TO_SELECT);

    if (type === 'user') {
      if (id !== user.id) {
         return new Response(JSON.stringify({ error: 'Can only fetch proposals for the authenticated user.' }), {
            headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403,
         });
      }
      
      // SECURITY FIX: Use separate queries instead of SQL injection vulnerable .or()
      // Get proposals where user is proposer
      const { data: proposerData, error: proposerError } = await supabaseClient
        .from(DATE_PROPOSALS_TABLE)
        .select(PROPOSAL_FIELDS_TO_SELECT)
        .eq('proposer_id', id)
        .order('created_at', { ascending: false })
        .range(offset, offset + pageSize - 1);
        
      // Get proposals where user is recipient
      const { data: recipientData, error: recipientError } = await supabaseClient
        .from(DATE_PROPOSALS_TABLE)
        .select(PROPOSAL_FIELDS_TO_SELECT)
        .eq('recipient_id', id)
        .order('created_at', { ascending: false })
        .range(offset, offset + pageSize - 1);
        
      if (proposerError || recipientError) {
        const error = proposerError || recipientError;
        return new Response(JSON.stringify({ error: error.message }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }, 
          status: 500
        });
      }
      
      // Combine and sort results
      const combinedData = [...(proposerData || []), ...(recipientData || [])]
        .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
        .slice(0, pageSize);
        
      // Apply status filter if needed
      const filteredData = statusFilter 
        ? combinedData.filter(proposal => proposal.status === statusFilter)
        : combinedData;
        
      return new Response(JSON.stringify({ 
        success: true, 
        data: filteredData,
        pagination: {
          page,
          pageSize,
          total: filteredData.length
        }
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    } else if (type === 'conversation') {
      queryBuilder = queryBuilder.eq('conversation_id', id);
      queryBuilder = queryBuilder.order('proposed_datetime', { ascending: false });
    } else {
      return new Response(JSON.stringify({ error: 'Invalid type parameter' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400,
      });
    }

    if (statusFilter) {
      queryBuilder = queryBuilder.eq('status', statusFilter);
    }

    queryBuilder = queryBuilder.range(offset, offset + pageSize - 1);

    const { data, error } = await queryBuilder;

    if (error) throw error;

    return new Response(JSON.stringify(data || []), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (e: any) {
const errorMessage = e instanceof Error ? e.message : 'An unexpected error occurred.';
    const errorDetails = e instanceof ZodError ? e.flatten() : undefined;
    return new Response(JSON.stringify({ error: errorMessage, details: errorDetails, type: e.name }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: e instanceof ZodError ? 400 : 500,
    });
  }
});
