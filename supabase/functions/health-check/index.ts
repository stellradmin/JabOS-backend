import { serve } from 'std/http/server.ts';
import { getCorsHeaders } from '../_shared/cors.ts';
import { createSuccessResponse, createErrorResponse } from '../_shared/error-handler.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { 
  getHealthCheckManager, 
  quickHealthCheck,
  SystemHealthSummary,
  HealthStatus 
} from '../_shared/health-check-system.ts';
/**
 * Parse query parameters for health check options
 */
function parseHealthCheckParams(url: URL): { quick: boolean; detailed: boolean } {
  return {
    quick: url.searchParams.get('quick') === 'true',
    detailed: url.searchParams.get('detailed') === 'true',
  };
}

serve(async (req: Request) => {
  // Apply rate limiting
  const rateLimitResult = await applyRateLimit(req, '/health-check', undefined, RateLimitCategory.PROFILE_UPDATES);
  if (rateLimitResult.blocked) {
    return rateLimitResult.response;
  }


  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'GET') {
    return createErrorResponse(
      { code: 'method_not_allowed', message: 'Method not allowed' },
      { endpoint: 'health-check', method: req.method },
      corsHeaders
    );
  }

  try {
    const url = new URL(req.url);
    const params = parseHealthCheckParams(url);
    
    let healthStatus: SystemHealthSummary | { status: string; timestamp: number };
    let statusCode: number;

    if (params.quick) {
      // Quick health check for load balancers
      healthStatus = await quickHealthCheck();
      statusCode = healthStatus.status === HealthStatus.HEALTHY ? 200 : 
                   healthStatus.status === HealthStatus.DEGRADED ? 200 : 503;
    } else {
      // Comprehensive health check
      const manager = getHealthCheckManager();
      
      // Use cached results if available and recent
      let cachedHealth = await manager.getHealthSummary();
      
      if (!cachedHealth || Date.now() - cachedHealth.timestamp > 30000) {
        // Run fresh health checks
        cachedHealth = await manager.runAllChecks();
      }
      
      healthStatus = cachedHealth;
      statusCode = healthStatus.overall_status === HealthStatus.HEALTHY ? 200 :
                   healthStatus.overall_status === HealthStatus.DEGRADED ? 200 : 503;
    }

    // Add environment info
    const enrichedResponse = {
      ...healthStatus,
      version: Deno.env.get('BUILD_VERSION') || '1.0.0',
      environment: Deno.env.get('SENTRY_ENVIRONMENT') || 'development',
      node_info: {
        deno_version: Deno.version?.deno || 'unknown',
        typescript_version: Deno.version?.typescript || 'unknown',
        v8_version: Deno.version?.v8 || 'unknown',
      },
    };

    // Minimal response for quick checks
    if (params.quick && !params.detailed) {
      const response = new Response(
        JSON.stringify({
          status: healthStatus.status,
          timestamp: healthStatus.timestamp,
        }),
        {
          status: statusCode,
          headers: {
            ...corsHeaders,
            'Content-Type': 'application/json',
            'Cache-Control': 'no-cache, no-store, must-revalidate',
          },
        }
      );
      return response;
    }

    return new Response(
      JSON.stringify(enrichedResponse, null, 2),
      {
        status: statusCode,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'X-Health-Timestamp': new Date().toISOString(),
          'X-Health-Status': healthStatus.status || 'unknown',
        },
      }
    );

  } catch (error) {
    const errorResponse = createErrorResponse(
      error,
      { endpoint: 'health-check', phase: 'execution' },
      corsHeaders
    );

    return errorResponse;
  }
});
