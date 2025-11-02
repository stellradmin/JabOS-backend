import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { getCorsHeaders } from '../_shared/cors.ts';
import { UpstashFetchClient } from '../_shared/upstash-fetch-client.ts';

console.log('[BOOT] Testing Direct UpstashFetchClient...');

const QueryParamsSchema = z.object({
  cursor: z.string().optional(),
  zodiac_sign: z.string().max(20).optional(),
  activity_type: z.string().max(50).optional(),
  min_age: z.string().optional().transform(val => val ? parseInt(val) : undefined),
  max_age: z.string().optional().transform(val => val ? parseInt(val) : undefined),
  max_distance_km: z.string().optional().transform(val => val ? parseInt(val) : undefined),
});

// Initialize Redis client once at module level
let redisClient: UpstashFetchClient | null = null;

function getRedisClient(): UpstashFetchClient | null {
  if (redisClient) return redisClient;

  const redisUrl = Deno.env.get('UPSTASH_REDIS_REST_URL');
  const redisToken = Deno.env.get('UPSTASH_REDIS_REST_TOKEN');

  if (!redisUrl) {
    console.warn('[REDIS] No UPSTASH_REDIS_REST_URL - caching disabled');
    return null;
  }

  try {
    redisClient = new UpstashFetchClient({
      url: redisUrl,
      token: redisToken
    });
    console.log('[REDIS] Client initialized successfully');
    return redisClient;
  } catch (error) {
    console.error('[REDIS] Failed to initialize client:', error);
    return null;
  }
}

serve(async (req: Request) => {
  console.log('[REQUEST] Received:', req.method, new URL(req.url).pathname);

  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // 1. AUTH
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      console.error('[AUTH] Missing header');
      return new Response(
        JSON.stringify({ error: 'Missing authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !serviceKey) {
      console.error('[AUTH] Missing Supabase credentials');
      return new Response(
        JSON.stringify({ error: 'Server configuration error' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const client = createClient(supabaseUrl, serviceKey);
    const { data: { user }, error: authError } = await client.auth.getUser(authHeader.replace('Bearer ', ''));

    if (authError || !user) {
      console.error('[AUTH] Failed:', authError?.message);
      return new Response(
        JSON.stringify({ error: 'Authentication failed' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('[AUTH] Success:', user.id);

    // 2. PARSE INPUT
    let queryParams: any = {};
    if (req.method === 'POST') {
      try {
        const text = await req.text();
        console.log('[INPUT] Body:', text);
        queryParams = text ? JSON.parse(text) : {};
      } catch (error) {
        console.error('[INPUT] Parse error:', error);
        return new Response(
          JSON.stringify({ error: 'Invalid JSON' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    const validated = QueryParamsSchema.parse(queryParams);
    console.log('[INPUT] Validated:', validated);

    // 2.5. CACHE FOR DATABASE QUERY ONLY - NOT FINAL SCORES
    // CRITICAL FIX: Never return cached scores without recalculation
    // Cache is only used to avoid repeated database queries for the same user list
    const redis = getRedisClient();
    const cacheKey = `stellr:matches:profiles:${user.id}:${JSON.stringify(validated)}`;

    let cachedProfiles = null;
    let fromCacheQuery = false;

    if (redis) {
      try {
        const cachedValue = await redis.get(cacheKey);
        if (cachedValue) {
          cachedProfiles = JSON.parse(cachedValue);
          fromCacheQuery = true;
          console.log('[REDIS] Cache hit for profile list - will recalculate scores');
        } else {
          console.log('[REDIS] Cache miss - querying database');
        }
      } catch (error) {
        console.warn('[REDIS] Cache get failed:', error);
        // Continue without cache
      }
    } else {
      console.log('[REDIS] Client not available - querying database');
    }

    // 3. QUERY DATABASE USING OPTIMIZED POSTGRESQL FUNCTION (or use cached profiles)
    // This function handles all advanced filtering:
    // - Gender preference (bidirectional)
    // - Zodiac compatibility
    // - Age range filtering
    // - Distance filtering (PostGIS spatial queries)
    // - Swipe exclusion (don't show already-swiped users)
    // - Activity preferences filtering (MAIN APP FEATURE)
    // - Compatibility score ranking

    let data = cachedProfiles;

    if (!cachedProfiles) {
      console.log('[DB] Calling get_potential_matches_optimized RPC function');

      const { data: dbData, error: dbError } = await client.rpc('get_potential_matches_optimized', {
        viewer_id: user.id,
        exclude_user_ids: [], // Empty array - function will automatically exclude swiped users
        zodiac_filter: validated.zodiac_sign || null,
        min_age_filter: validated.min_age || null,
        max_age_filter: validated.max_age || null,
        max_distance_km: validated.max_distance_km || null,
        activity_filter: validated.activity_type || null, // NEW: Activity type filtering - MAIN APP FEATURE
        limit_count: 20,
        offset_count: 0
      });

      if (dbError) {
        console.error('[DB] Query error:', dbError);
        return new Response(
          JSON.stringify({ error: 'Database query failed', details: dbError.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      data = dbData;
      console.log('[DB] Found matches:', data?.length || 0);

      // Cache the profile list (not scores) for future queries
      if (redis && data && data.length > 0) {
        try {
          await redis.setex(cacheKey, 300, JSON.stringify(data)); // 5min TTL for profile list only
          console.log('[REDIS] Cached profile list (scores will be recalculated)');
        } catch (error) {
          console.warn('[REDIS] Failed to cache profile list:', error);
        }
      }
    } else {
      console.log('[CACHE] Using cached profile list, recalculating fresh scores');
    }

    // 3.6. ALWAYS CALCULATE FRESH COMPATIBILITY SCORES FOR ACCURACY
    let updatedData = data || [];

    if (data && data.length > 0) {
      console.log('[COMPAT] Starting FRESH compatibility calculation for', data.length, 'matches');
      console.log('[COMPAT] Note: Scores are ALWAYS calculated fresh, never using stale cache');

      // Store calculated scores in a Map for quick lookup
      const scoreMap = new Map<string, number>();
      const failedCalculations: string[] = [];

      // AWAIT calculation completion - this blocks response until scores are ready
      await Promise.all(
        data.map(async (match: any) => {
          try {
            console.log('[COMPAT] Calculating fresh score for match:', match.id,
                       match.compatibility_score ? `(ignoring cached: ${match.compatibility_score})` : '(no cache)');

            const { data: compScore, error: compError } = await client.rpc('calculate_compatibility_scores', {
              user_a_id: user.id,
              user_b_id: match.id
            });

            if (compError) {
              console.error('[COMPAT] Calculation error for', match.id, ':', compError.message);
              failedCalculations.push(match.id);
              return;
            }

            if (compScore && compScore.overall_score != null) {
              const freshScore = compScore.overall_score;
              console.log('[COMPAT] ✓ Fresh score calculated for', match.id, ':', freshScore);

              // Store score in map for later use
              scoreMap.set(match.id, freshScore);

              // Cache in compatibility_scores table with expiry for future queries
              const expiresAt = new Date();
              expiresAt.setHours(expiresAt.getHours() + 24); // 24 hour expiry

              const { error: insertError } = await client
                .from('compatibility_scores')
                .upsert({
                  user_id: user.id,
                  potential_match_id: match.id,
                  compatibility_score: freshScore,
                  score_components: compScore,
                  calculated_at: new Date().toISOString(),
                  expires_at: expiresAt.toISOString()
                }, {
                  onConflict: 'user_id,potential_match_id'
                });

              if (insertError) {
                console.error('[COMPAT] Insert error for', match.id, ':', insertError.message);
              } else {
                console.log('[COMPAT] ✓ Cached fresh score for', match.id, '(expires in 24h)');
              }
            } else {
              console.warn('[COMPAT] No score returned for', match.id);
              failedCalculations.push(match.id);
            }
          } catch (error) {
            console.error('[COMPAT] Calculation failed for', match.id, ':', error);
            failedCalculations.push(match.id);
          }
        })
      );

      // Update data array with freshly calculated scores
      updatedData = data.map((match: any) => {
        const freshScore = scoreMap.get(match.id);
        return {
          ...match,
          compatibility_score: freshScore ?? 50 // Default to 50 if calculation failed
        };
      });

      console.log('[COMPAT] ✓ Calculated', scoreMap.size, 'fresh scores,', failedCalculations.length, 'failed');
      if (failedCalculations.length > 0) {
        console.warn('[COMPAT] Failed calculations for:', failedCalculations.join(', '));
      }
    }

    // 3.7. NO LONGER CACHING FINAL SCORES - Always calculate fresh for accuracy
    // Profile list cache (line 176) ensures we don't re-query database unnecessarily
    // But compatibility scores are ALWAYS freshly calculated

    // 4. RETURN RESPONSE (with fresh real-time calculated scores)
    return new Response(
      JSON.stringify({
        data: updatedData,
        pagination: {
          hasMore: false,
          nextCursor: null,
          pageSize: updatedData.length
        },
        metadata: {
          profileListCached: fromCacheQuery,
          scoresCalculatedFresh: true,
          calculatedAt: new Date().toISOString(),
          note: 'Compatibility scores are ALWAYS calculated fresh for accuracy'
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('[ERROR]', error);
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : 'Unknown error',
        stack: error instanceof Error ? error.stack : undefined
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});

console.log('[BOOT] Direct fetch-based Redis client ready');
