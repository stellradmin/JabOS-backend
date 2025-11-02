import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';

console.log('[BOOT] Test function loading...');

serve(async (req: Request) => {
  console.log('[REQUEST] Received:', req.method);

  try {
    // Test 1: Environment variables
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    console.log('[TEST] Env vars:', { hasUrl: !!supabaseUrl, hasKey: !!serviceKey });

    // Test 2: Auth
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'No auth' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    const client = createClient(supabaseUrl!, serviceKey!);
    const { data: { user }, error } = await client.auth.getUser(authHeader.replace('Bearer ', ''));

    console.log('[TEST] Auth result:', { hasUser: !!user, error: error?.message });

    if (error || !user) {
      return new Response(JSON.stringify({ error: 'Auth failed' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // Test 3: Database query
    const { data, error: dbError } = await client
      .from('profiles')
      .select('id, display_name')
      .eq('id', user.id)
      .single();

    console.log('[TEST] DB result:', { hasData: !!data, error: dbError?.message });

    return new Response(
      JSON.stringify({
        success: true,
        userId: user.id,
        profile: data
      }),
      {
        status: 200,
        headers: { 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('[ERROR]', error);
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : 'Unknown',
        stack: error instanceof Error ? error.stack : undefined
      }),
      {
        status: 500,
        headers: { 'Content-Type': 'application/json' }
      }
    );
  }
});

console.log('[BOOT] Test function ready');
