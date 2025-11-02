import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';
import { corsHeaders } from '../_shared/cors.ts';
import { validateUser } from '../_shared/security-validation.ts';
import { UltraHighPerformanceMatchingEngine, getUltraHighPerformanceMatchingEngine } from '../_shared/ultra-high-performance-matching-engine.ts';
import type { 
  BatchCompatibilityResponse, 
  OptimizedCompatibilityResult 
} from '../_shared/ultra-high-performance-matching-engine.ts';

// Initialize Supabase client
const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const supabase = createClient(supabaseUrl, supabaseServiceKey);

interface CompatibilityRequest {
  user_id?: string;
  candidate_ids?: string[];
  single_candidate_id?: string;
  options?: {
    use_cache?: boolean;
    max_batch_size?: number;
    timeout_ms?: number;
    limit?: number;
    min_compatibility?: number;
    max_distance_km?: number;
  };
}

interface CompatibilityResponse {
  success: boolean;
  data?: {
    results?: OptimizedCompatibilityResult[];
    matches?: OptimizedCompatibilityResult[];
    single_result?: OptimizedCompatibilityResult;
    performance_metrics?: any;
    cache_stats?: any;
    processing_time_ms?: number;
    total_found?: number;
    cache_hit_rate?: number;
  };
  error?: string;
  performance?: {
    response_time_ms: number;
    cache_used: boolean;
    batch_size: number;
  };
}

Deno.serve(async (req: Request) => {
  const startTime = performance.now();
  
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Validate request method
    if (req.method !== 'POST') {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Method not allowed. Use POST.' 
        }),
        {
          status: 405,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Parse and validate request
    const request: CompatibilityRequest = await req.json();
    const { user_id, candidate_ids, single_candidate_id, options = {} } = request;

    // Validate user authentication
    const authHeader = req.headers.get('authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Authorization header required' 
        }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Extract and validate user from token
    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    
    if (authError || !user) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Invalid authentication token' 
        }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    const authenticated_user_id = user_id || user.id;

    // Additional security validation
    const validationResult = await validateUser(authenticated_user_id, supabase);
    if (!validationResult.isValid) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'User validation failed' 
        }),
        {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Initialize the high-performance matching engine
    const engine = getUltraHighPerformanceMatchingEngine();
    let response: CompatibilityResponse;

    // Handle different types of requests
    if (single_candidate_id) {
      // Single compatibility calculation
      const result = await engine.calculateSingleCompatibility(
        authenticated_user_id,
        single_candidate_id,
        options.use_cache ?? true
      );

      response = {
        success: true,
        data: {
          single_result: result
        },
        performance: {
          response_time_ms: Math.round(performance.now() - startTime),
          cache_used: result.cached,
          batch_size: 1
        }
      };

    } else if (candidate_ids && candidate_ids.length > 0) {
      // Batch compatibility calculation
      const batchResponse = await engine.calculateBatchCompatibility({
        user_id: authenticated_user_id,
        candidate_ids,
        use_cache: options.use_cache ?? true,
        max_batch_size: options.max_batch_size,
        timeout_ms: options.timeout_ms
      });

      response = {
        success: true,
        data: {
          results: batchResponse.results,
          performance_metrics: batchResponse.performance_metrics,
          cache_stats: batchResponse.cache_stats,
          processing_time_ms: batchResponse.processing_time_ms
        },
        performance: {
          response_time_ms: Math.round(performance.now() - startTime),
          cache_used: batchResponse.cache_stats.hit_rate > 0,
          batch_size: batchResponse.results.length
        }
      };

    } else {
      // Get optimized potential matches
      const matchesResponse = await engine.getOptimizedPotentialMatches(
        authenticated_user_id,
        {
          limit: options.limit,
          min_compatibility: options.min_compatibility,
          use_cache: options.use_cache,
          max_distance_km: options.max_distance_km
        }
      );

      response = {
        success: true,
        data: {
          matches: matchesResponse.matches,
          total_found: matchesResponse.total_found,
          processing_time_ms: matchesResponse.processing_time_ms,
          cache_hit_rate: matchesResponse.cache_hit_rate
        },
        performance: {
          response_time_ms: Math.round(performance.now() - startTime),
          cache_used: matchesResponse.cache_hit_rate > 0,
          batch_size: matchesResponse.matches.length
        }
      };
    }

    // Log performance metrics if response time is concerning
    const totalResponseTime = Math.round(performance.now() - startTime);
    if (totalResponseTime > 500) {
      console.warn(`Slow compatibility calculation: ${totalResponseTime}ms for user ${authenticated_user_id}`);
      
      // Log to database for monitoring
      try {
        await supabase.rpc('log_compatibility_performance', {
          p_user_id: authenticated_user_id,
          p_batch_size: response.performance?.batch_size || 0,
          p_calculation_time_ms: totalResponseTime,
          p_cache_hit_rate: response.data?.cache_hit_rate || 0,
          p_error_count: 0
        });
      } catch (logError) {
        console.error('Failed to log performance metrics:', logError);
      }
    }

    // Add performance warning if target not met
    if (totalResponseTime > 500) {
      response.data = {
        ...response.data,
        performance_warning: `Response time ${totalResponseTime}ms exceeded 500ms target`
      };
    }

    return new Response(
      JSON.stringify(response),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    const errorResponseTime = Math.round(performance.now() - startTime);
    console.error('Compatibility calculation error:', error);

    // Log error for monitoring
    try {
      const authHeader = req.headers.get('authorization');
      if (authHeader) {
        const token = authHeader.replace('Bearer ', '');
        const { data: { user } } = await supabase.auth.getUser(token);
        
        if (user) {
          await supabase.rpc('log_compatibility_performance', {
            p_user_id: user.id,
            p_batch_size: 0,
            p_calculation_time_ms: errorResponseTime,
            p_cache_hit_rate: 0,
            p_error_count: 1
          });
        }
      }
    } catch (logError) {
      console.error('Failed to log error metrics:', logError);
    }

    const errorResponse: CompatibilityResponse = {
      success: false,
      error: error instanceof Error ? error.message : 'Internal server error',
      performance: {
        response_time_ms: errorResponseTime,
        cache_used: false,
        batch_size: 0
      }
    };

    return new Response(
      JSON.stringify(errorResponse),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});

/* USAGE EXAMPLES:

1. Single compatibility calculation:
POST /functions/v1/get-optimized-compatibility
{
  "single_candidate_id": "candidate-uuid",
  "options": {
    "use_cache": true
  }
}

2. Batch compatibility calculation:
POST /functions/v1/get-optimized-compatibility
{
  "candidate_ids": ["uuid1", "uuid2", "uuid3"],
  "options": {
    "use_cache": true,
    "max_batch_size": 25,
    "timeout_ms": 400
  }
}

3. Get optimized potential matches:
POST /functions/v1/get-optimized-compatibility
{
  "options": {
    "limit": 20,
    "min_compatibility": 70,
    "use_cache": true,
    "max_distance_km": 50
  }
}

Expected response format:
{
  "success": true,
  "data": {
    "results": [...],  // For batch calculations
    "matches": [...],  // For potential matches
    "single_result": {...},  // For single calculations
    "performance_metrics": {...},
    "processing_time_ms": 234
  },
  "performance": {
    "response_time_ms": 456,
    "cache_used": true,
    "batch_size": 20
  }
}

Performance targets:
- Single compatibility: <100ms
- Batch compatibility: <500ms
- Potential matches: <200ms
- Cache hit rate: >60%
*/