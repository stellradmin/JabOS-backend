import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { getCorsHeaders, checkRateLimit, RATE_LIMITS } from '../_shared/cors.ts';
import { convertCityToCoordinates, validateCoordinates } from '../_shared/geocoding-service.ts';

serve(async (req: Request) => {
  const origin = req.headers.get('origin');
  const cors = getCorsHeaders(origin);

  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: cors });
  }

  try {
    // Rate limit by client identity
    const clientId =
      req.headers.get('authorization')?.split(' ')[1] ||
      req.headers.get('x-forwarded-for') ||
      'anonymous';
    const rate = await checkRateLimit(`geocode_city:${clientId}`, RATE_LIMITS.DEFAULT, 60_000);
    if (!rate.allowed) {
      return new Response(
        JSON.stringify({ error: 'Rate limit exceeded. Please try again later.' }),
        { status: 429, headers: { ...cors, 'content-type': 'application/json' } }
      );
    }

    let location: string | null = null;

    if (req.method === 'GET') {
      const url = new URL(req.url);
      location = url.searchParams.get('q');
    } else if (req.method === 'POST') {
      const body = await req.json().catch(() => ({}));
      location = (body?.location ?? body?.city ?? body?.q) as string | null;
    } else {
      return new Response(
        JSON.stringify({ error: 'Method not allowed' }),
        { status: 405, headers: { ...cors, 'content-type': 'application/json' } }
      );
    }

    if (!location || typeof location !== 'string' || !location.trim()) {
      return new Response(
        JSON.stringify({ error: 'Missing or invalid location parameter' }),
        { status: 400, headers: { ...cors, 'content-type': 'application/json' } }
      );
    }

    const coords = await convertCityToCoordinates(location.trim());

    if (!validateCoordinates(coords.lat, coords.lng)) {
      return new Response(
        JSON.stringify({ error: 'Invalid coordinates resolved' }),
        { status: 400, headers: { ...cors, 'content-type': 'application/json' } }
      );
    }

    const payload = {
      latitude: coords.lat,
      longitude: coords.lng,
      city: coords.city,
      country: coords.country || null,
      timezone: coords.tz || null,
    };

    return new Response(JSON.stringify(payload), {
      status: 200,
      headers: { ...cors, 'content-type': 'application/json' },
    });
  } catch (error) {
    return new Response(
      JSON.stringify({ error: 'Internal server error', message: error instanceof Error ? error.message : 'Unknown error' }),
      { status: 500, headers: { ...getCorsHeaders(req.headers.get('origin')), 'content-type': 'application/json' } }
    );
  }
});

// Health check (import keeps Deno from tree-shaking serve)
export { serve };

