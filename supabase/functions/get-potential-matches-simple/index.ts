/**
 * Simple Get Potential Matches Function (No Redis Required)
 *
 * This is a lightweight version that works without Redis/caching infrastructure.
 * Use this until Redis is properly configured for the optimized version.
 */

import { serve } from 'std/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { getCorsHeaders } from '../_shared/cors.ts';

const QueryParamsSchema = z.object({
  page: z.number().int().min(1).default(1),
  pageSize: z.number().int().min(1).max(50).default(20),
  cursor: z.string().optional(),
  zodiac_sign: z.string().max(20).optional(),
  activity_type: z.string().max(50).optional(),
  min_age: z.number().int().min(18).max(100).optional(),
  max_age: z.number().int().min(18).max(100).optional(),
  max_distance_km: z.number().int().min(1).max(500).optional(),
  refresh: z.boolean().optional()
});

serve(async (req: Request) => {
  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Get auth token
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing authorization header' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // Create Supabase client
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    );

    // Verify authentication
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'Authentication failed' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // Parse request
    let queryParams: any = {};
    if (req.method === 'GET') {
      const url = new URL(req.url);
      const params: Record<string, any> = {};
      url.searchParams.forEach((value, key) => {
        if (key === 'page' || key === 'pageSize' || key === 'min_age' || key === 'max_age' || key === 'max_distance_km') {
          params[key] = parseInt(value, 10);
        } else if (key === 'refresh') {
          params[key] = value === 'true';
        } else {
          params[key] = value;
        }
      });
      queryParams = params;
    } else if (req.method === 'POST') {
      queryParams = await req.json();
    }

    const validated = QueryParamsSchema.parse(queryParams);

    // Call database function
    const { data: matches, error: dbError } = await supabaseClient.rpc(
      'get_potential_matches_optimized',
      {
        viewer_id: user.id,
        exclude_user_ids: [],
        zodiac_filter: validated.zodiac_sign,
        min_age_filter: validated.min_age,
        max_age_filter: validated.max_age,
        max_distance_km: validated.max_distance_km,
        limit_count: validated.pageSize + 1, // Get one extra to check for more pages
        offset_count: validated.cursor ? 0 : (validated.page - 1) * validated.pageSize
      }
    );

    if (dbError) {
      console.error('Database error:', dbError);
      return new Response(JSON.stringify({ error: 'Failed to fetch matches', details: dbError.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // Process results
    const hasMore = matches && matches.length > validated.pageSize;
    const pageData = hasMore ? matches.slice(0, validated.pageSize) : (matches || []);

    return new Response(JSON.stringify({
      matches: pageData,
      pagination: {
        hasMore,
        nextCursor: hasMore ? `page_${validated.page + 1}` : undefined,
        pageSize: pageData.length,
        totalDisplayed: pageData.length
      }
    }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });

  } catch (error) {
    console.error('Error:', error);
    return new Response(JSON.stringify({
      error: error instanceof Error ? error.message : 'Unknown error'
    }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }
});
