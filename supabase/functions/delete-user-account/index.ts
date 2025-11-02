import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';


import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { validateJWTHeader, createSecureSupabaseClient } from '../_shared/secure-jwt-validator.ts';
import { 
  validateSensitiveRequest, 
  REQUEST_SIZE_LIMITS, 
  createValidationErrorResponse,
  validateUUID,
  validateTextInput,
  ValidationError
} from '../_shared/security-validation.ts';
// Simple CORS Headers (following pattern of working functions)
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

serve(async (req: Request) => {
  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/delete-user-account', undefined, RateLimitCategory.PROFILE_UPDATES);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }


  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return new Response(
      JSON.stringify({ error: 'Method not allowed' }),
      { 
        status: 405, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }

  try {
    // Get environment variables with better error handling
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

    // Debug logging removed for security
if (!supabaseUrl) {
return new Response(
        JSON.stringify({ error: 'Server configuration error: Missing Supabase URL' }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    if (!supabaseServiceRoleKey) {
return new Response(
        JSON.stringify({ error: 'Server configuration error: Missing service role key' }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    if (!supabaseAnonKey) {
return new Response(
        JSON.stringify({ error: 'Server configuration error: Missing anon key' }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Create admin client for admin operations
    const supabaseAdmin = createClient(supabaseUrl, supabaseServiceRoleKey);

    // SECURITY: Log service role usage for audit monitoring
    const clientIp = req.headers.get('cf-connecting-ip') || req.headers.get('x-forwarded-for') || '127.0.0.1';
    const requestId = req.headers.get('cf-ray') || `req_${Date.now()}_${Math.random().toString(36).substring(7)}`;
    // Debug logging removed for security
// Authentication - get user from request

  // CRITICAL SECURITY: Secure JWT validation to prevent Algorithm Confusion Attack
  const userAuthHeader = req.headers.get('Authorization');
  if (!userAuthHeader) {
    logSecurityEvent('missing_auth_header', undefined, {
      endpoint: 'delete-user-account',
      userAgent: req.headers.get('User-Agent')
    });
    return createErrorResponse(
      { code: 'invalid_grant', message: 'Missing authorization' },
      { endpoint: 'delete-user-account' },
      corsHeaders
    );
  }

  // CRITICAL SECURITY: Validate JWT to prevent "none" algorithm attacks
  const jwtValidation = validateJWTHeader(userAuthHeader);
  if (!jwtValidation.valid) {
    logSecurityEvent('jwt_validation_failed', undefined, {
      endpoint: 'delete-user-account',
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
        endpoint: 'delete-user-account',
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
      { endpoint: 'delete-user-account', issue: 'missing_env_vars' },
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
      endpoint: 'delete-user-account',
      error: secureClientResult.error,
      securityDetails: secureClientResult.securityDetails
    });
    
    return createErrorResponse(
      { code: 'server_error', message: 'Failed to create secure database connection' },
      { endpoint: 'delete-user-account', phase: 'secure_client_init' },
      corsHeaders
    );
  }

  const supabaseClient = secureClientResult.client;

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    // Debug logging removed for security

    if (userError || !user) {
      const errorMessage = userError ? `Authentication failed: ${userError.message}` : 'User not authenticated - no user found';
return new Response(
        JSON.stringify({ 
          error: errorMessage,
          details: 'Please ensure you are logged in and try again. If the problem persists, log out and log back in.'
        }),
        { 
          status: 401, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Parse and validate request body
    const body = await req.json();
    const { confirmation } = body;

    if (confirmation !== 'DELETE') {
      return new Response(
        JSON.stringify({ error: 'Invalid confirmation. Please type "DELETE" to confirm.' }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    const userId = user.id;
    // Debug logging removed for security
// Get the public.users.id that corresponds to auth.users.id
    // Some tables reference public.users(id) while others reference auth.users(id)
    let publicUserId = null;
    try {
      const { data: userData } = await supabaseAdmin
        .from('users')
        .select('id')
        .eq('auth_user_id', userId)
        .single();
      
      if (userData) {
        publicUserId = userData.id;
        // Debug logging removed for security
} else {
        // Debug logging removed for security
}
    } catch (error) {
}

    // Test admin permissions first
    try {
      const { data: testUser, error: testError } = await supabaseAdmin.auth.admin.getUserById(userId);
      // Debug logging removed for security
if (testError) {
return new Response(
          JSON.stringify({ 
            error: 'Server permission error: Cannot access user management',
            details: testError.message
          }),
          { 
            status: 500, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' }
          }
        );
      }
    } catch (permError) {
return new Response(
        JSON.stringify({ 
          error: 'Server permission error: Admin client failed',
          details: permError.message
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Track deletion progress for debugging
    const deletionLog = [];

    try {
      // 1. Delete messages (as sender)
      // SECURITY: Log service role usage for messages deletion
      await supabaseAdmin.rpc('log_service_role_usage', {
        function_name: 'delete-user-account',
        operation_type: 'DELETE_USER_ACCOUNT',
        table_accessed: 'messages',
        user_context: userId,
        justification: 'Account deletion requires service role to delete user messages across conversations',
        client_ip: clientIp,
        request_id: requestId
      });

      const { error: messagesError, count: messagesCount } = await supabaseAdmin
        .from('messages')
        .delete({ count: 'exact' })
        .eq('sender_id', userId);
      if (messagesError) {
        throw new Error(`Failed to delete messages: ${messagesError.message}`);
      }
      deletionLog.push(`Deleted ${messagesCount || 0} messages`);
      // Debug logging removed for security
      // 2. Delete conversations where user is participant
      await supabaseAdmin.rpc('log_service_role_usage', {
        function_name: 'delete-user-account',
        operation_type: 'DELETE_USER_ACCOUNT',
        table_accessed: 'conversations',
        user_context: userId,
        justification: 'Account deletion requires service role to delete user conversations with multiple participants',
        client_ip: clientIp,
        request_id: requestId
      });

      // Delete conversations where user is user1_id
      const { error: conv1Error, count: conv1Count } = await supabaseAdmin
        .from('conversations')
        .delete({ count: 'exact' })
        .eq('user1_id', userId);
      
      // Delete conversations where user is user2_id
      const { error: conv2Error, count: conv2Count } = await supabaseAdmin
        .from('conversations')
        .delete({ count: 'exact' })
        .eq('user2_id', userId);
        
      const conversationsError = conv1Error || conv2Error;
      const conversationsCount = (conv1Count || 0) + (conv2Count || 0);
      if (conversationsError) {
        throw new Error(`Failed to delete conversations: ${conversationsError.message}`);
      }
      deletionLog.push(`Deleted ${conversationsCount || 0} conversations`);
      // Debug logging removed for security
      // 3. Delete matches (uses public.users.id)
      if (publicUserId) {
        await supabaseAdmin.rpc('log_service_role_usage', {
          function_name: 'delete-user-account',
          operation_type: 'DELETE_USER_ACCOUNT',
          table_accessed: 'matches',
          user_context: userId,
          justification: 'Account deletion requires service role to delete user matches across platform',
          client_ip: clientIp,
          request_id: requestId
        });

        // Delete matches where user is user1_id
        const { error: match1Error, count: match1Count } = await supabaseAdmin
          .from('matches')
          .delete({ count: 'exact' })
          .eq('user1_id', publicUserId);
          
        // Delete matches where user is user2_id
        const { error: match2Error, count: match2Count } = await supabaseAdmin
          .from('matches')
          .delete({ count: 'exact' })
          .eq('user2_id', publicUserId);
          
        const matchesError = match1Error || match2Error;
        const matchesCount = (match1Count || 0) + (match2Count || 0);
        if (matchesError) {
          throw new Error(`Failed to delete matches: ${matchesError.message}`);
        }
        deletionLog.push(`Deleted ${matchesCount || 0} matches`);
      } else {
        deletionLog.push('Skipped matches deletion (no public user ID)');
      }

      // 4. Delete match requests (uses public.users.id)
      if (publicUserId) {
        await supabaseAdmin.rpc('log_service_role_usage', {
          function_name: 'delete-user-account',
          operation_type: 'DELETE_USER_ACCOUNT',
          table_accessed: 'match_requests',
          user_context: userId,
          justification: 'Account deletion requires service role to delete user match requests',
          client_ip: clientIp,
          request_id: requestId
        });

        // Delete match requests where user is requester
        const { error: req1Error, count: req1Count } = await supabaseAdmin
          .from('match_requests')
          .delete({ count: 'exact' })
          .eq('requester_id', publicUserId);
          
        // Delete match requests where user is matched_user
        const { error: req2Error, count: req2Count } = await supabaseAdmin
          .from('match_requests')
          .delete({ count: 'exact' })
          .eq('matched_user_id', publicUserId);
          
        const matchRequestsError = req1Error || req2Error;
        const matchRequestsCount = (req1Count || 0) + (req2Count || 0);
        if (matchRequestsError) {
          throw new Error(`Failed to delete match requests: ${matchRequestsError.message}`);
        }
        deletionLog.push(`Deleted ${matchRequestsCount || 0} match requests`);
      } else {
        deletionLog.push('Skipped match requests deletion (no public user ID)');
      }

      // 5. Delete swipes
      await supabaseAdmin.rpc('log_service_role_usage', {
        function_name: 'delete-user-account',
        operation_type: 'DELETE_USER_ACCOUNT',
        table_accessed: 'swipes',
        user_context: userId,
        justification: 'Account deletion requires service role to delete user swipe history',
        client_ip: clientIp,
        request_id: requestId
      });

      // Delete swipes where user is swiper
      const { error: swipe1Error, count: swipe1Count } = await supabaseAdmin
        .from('swipes')
        .delete({ count: 'exact' })
        .eq('swiper_id', userId);
        
      // Delete swipes where user is swiped
      const { error: swipe2Error, count: swipe2Count } = await supabaseAdmin
        .from('swipes')
        .delete({ count: 'exact' })
        .eq('swiped_id', userId);
        
      const swipesError = swipe1Error || swipe2Error;
      const swipesCount = (swipe1Count || 0) + (swipe2Count || 0);
      if (swipesError) {
        throw new Error(`Failed to delete swipes: ${swipesError.message}`);
      }
      deletionLog.push(`Deleted ${swipesCount || 0} swipes`);
      // Debug logging removed for security
// 6. Delete issue reports
      // Debug logging removed for security
const { error: issueReportsError, count: issueReportsCount } = await supabaseAdmin
        .from('issue_reports')
        .delete({ count: 'exact' })
        .eq('user_id', userId);
      if (issueReportsError) {
// Don't throw error for optional cleanup
      } else {
        deletionLog.push(`Deleted ${issueReportsCount || 0} issue reports`);
        // Debug logging removed for security
}

      // 7. Delete audit logs
      // Debug logging removed for security
const { error: auditLogsError, count: auditLogsCount } = await supabaseAdmin
        .from('audit_logs')
        .delete({ count: 'exact' })
        .eq('user_id', userId);
      if (auditLogsError) {
// Don't throw error for optional cleanup
      } else {
        deletionLog.push(`Deleted ${auditLogsCount || 0} audit logs`);
        // Debug logging removed for security
}

      // 8. Delete profile
      await supabaseAdmin.rpc('log_service_role_usage', {
        function_name: 'delete-user-account',
        operation_type: 'DELETE_USER_ACCOUNT',
        table_accessed: 'profiles',
        user_context: userId,
        justification: 'Account deletion requires service role to delete user profile data',
        client_ip: clientIp,
        request_id: requestId
      });

      const { error: profileError, count: profileCount } = await supabaseAdmin
        .from('profiles')
        .delete({ count: 'exact' })
        .eq('id', userId);
      if (profileError) {
        throw new Error(`Failed to delete profile: ${profileError.message}`);
      }
      deletionLog.push(`Deleted ${profileCount || 0} profile records`);
      // Debug logging removed for security
      // 9. Delete user record (using auth_user_id field)
      await supabaseAdmin.rpc('log_service_role_usage', {
        function_name: 'delete-user-account',
        operation_type: 'DELETE_USER_ACCOUNT',
        table_accessed: 'users',
        user_context: userId,
        justification: 'Account deletion requires service role to delete user table record',
        client_ip: clientIp,
        request_id: requestId
      });

      const { error: userRecordError, count: userRecordCount } = await supabaseAdmin
        .from('users')
        .delete({ count: 'exact' })
        .eq('auth_user_id', userId);
      if (userRecordError) {
        throw new Error(`Failed to delete user record: ${userRecordError.message}`);
      }
      deletionLog.push(`Deleted ${userRecordCount || 0} user records`);
      // Debug logging removed for security
      // 10. Delete auth user (CRITICAL FINAL STEP)
      await supabaseAdmin.rpc('log_service_role_usage', {
        function_name: 'delete-user-account',
        operation_type: 'DELETE_USER_ACCOUNT',
        table_accessed: 'auth.users',
        user_context: userId,
        justification: 'Account deletion requires service role to delete auth user - only admin can perform this operation',
        client_ip: clientIp,
        request_id: requestId
      });

      const { error: authDeleteError } = await supabaseAdmin.auth.admin.deleteUser(userId);
      if (authDeleteError) {
        throw new Error(`CRITICAL: Failed to delete auth user: ${authDeleteError.message}`);
      }
      deletionLog.push('Deleted auth user');
      // Debug logging removed for security
// 11. Verify auth user was actually deleted
      // Debug logging removed for security
const { data: verifyUser, error: verifyError } = await supabaseAdmin.auth.admin.getUserById(userId);
      if (verifyUser && verifyUser.user) {
        throw new Error(`CRITICAL: Auth user still exists after deletion attempt`);
      }
      if (verifyError && !verifyError.message.includes('not found')) {
}
      deletionLog.push('Verified auth user deletion');
      // Debug logging removed for security
} catch (error) {
// Ensure proper JSON error response with detailed information
      const errorResponse = {
        success: false,
        error: 'Account deletion failed',
        details: error.message || 'An unknown error occurred',
        deletionLog: deletionLog,
        step: deletionLog.length + 1,
        userId: userId,
        timestamp: new Date().toISOString()
      };
      
      // Return appropriate HTTP status code based on error type
      let statusCode = 500;
      if (error.message.includes('not authenticated') || error.message.includes('Invalid JWT')) {
        statusCode = 401;
      } else if (error.message.includes('permission') || error.message.includes('authorization')) {
        statusCode = 403;
      } else if (error.message.includes('not found')) {
        statusCode = 404;
      }
      
      return new Response(
        JSON.stringify(errorResponse),
        { 
          status: statusCode, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Log successful deletion for audit purposes
    // Debug logging removed for security

    // Return success response with consistent format
    const successResponse = {
      success: true,
      message: 'Account successfully deleted',
      deletionLog: deletionLog,
      userId: userId,
      timestamp: new Date().toISOString()
    };

    return new Response(
      JSON.stringify(successResponse),
      { 
        status: 200, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
// Return consistent error format for unexpected errors
    const criticalErrorResponse = {
      success: false,
      error: 'Critical error during account deletion',
      details: error instanceof Error ? error.message : 'Unknown system error',
      timestamp: new Date().toISOString()
    };
    
    return new Response(
      JSON.stringify(criticalErrorResponse),
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});
