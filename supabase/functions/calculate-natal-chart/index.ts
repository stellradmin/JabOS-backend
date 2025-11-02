import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { corsHeaders } from '../_shared/cors.ts';
import { Origin, Horoscope } from 'https://esm.sh/circular-natal-horoscope-js@1.1.0';

interface NatalChartRequest {
  birthDate: string; // YYYY-MM-DD or other common formats
  birthTime: string; // HH:MM or HH:MM AM/PM
  latitude: number;
  longitude: number;
  timezone?: string; // optional IANA TZ name
}

interface PlanetPosition {
  name: string;
  sign: string;
  degree: number;
}

interface NatalChartResponse {
  sunSign: string;
  moonSign: string;
  risingSign: string;
  planets: PlanetPosition[];
  houses: Array<{ house: number; sign: string; degree: number }>;
  aspects: Array<{ planet1: string; planet2: string; aspect: string; degrees: number; orb: number }>;
}

const ZODIAC_SIGNS = [
  'Aries', 'Taurus', 'Gemini', 'Cancer', 'Leo', 'Virgo',
  'Libra', 'Scorpio', 'Sagittarius', 'Capricorn', 'Aquarius', 'Pisces'
];

function parseTimeString(s: string): { hour: number; minute: number } | null {
  const a = (s || '').trim();
  if (!a) return null;
  // 1) h:mm AM/PM or h:mmAM
  let m = a.match(/^(\d{1,2}):(\d{2})\s*([AP]M)$/i);
  if (m) {
    let h = parseInt(m[1], 10);
    const min = parseInt(m[2], 10);
    const p = m[3].toUpperCase();
    if (p === 'PM' && h < 12) h += 12;
    if (p === 'AM' && h === 12) h = 0;
    if (h >= 0 && h <= 23 && min >= 0 && min <= 59) return { hour: h, minute: min };
    return null;
  }
  // 2) h AM/PM or hAM
  m = a.match(/^(\d{1,2})\s*([AP]M)$/i);
  if (m) {
    let h = parseInt(m[1], 10);
    const p = m[2].toUpperCase();
    if (p === 'PM' && h < 12) h += 12;
    if (p === 'AM' && h === 12) h = 0;
    if (h >= 0 && h <= 23) return { hour: h, minute: 0 };
    return null;
  }
  // 3) 24h h:mm
  m = a.match(/^(\d{1,2}):(\d{2})$/);
  if (m) {
    const h = parseInt(m[1], 10);
    const min = parseInt(m[2], 10);
    if (h >= 0 && h <= 23 && min >= 0 && min <= 59) return { hour: h, minute: min };
    return null;
  }
  // 4) 24h h
  m = a.match(/^(\d{1,2})$/);
  if (m) {
    const h = parseInt(m[1], 10);
    if (h >= 0 && h <= 23) return { hour: h, minute: 0 };
  }
  return null;
}

function parseDateString(birthDate: string): { year: number; month0: number; day: number } {
  // Accept strict formats aligned with frontend: YYYY-MM-DD, MMM D, YYYY, MMMM D, YYYY, M/D/YYYY, MM/DD/YYYY
  const isoMatch = birthDate.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (isoMatch) {
    return { year: Number(isoMatch[1]), month0: Number(isoMatch[2]) - 1, day: Number(isoMatch[3]) };
  }

  const mdyyyy = birthDate.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (mdyyyy) {
    return { year: Number(mdyyyy[3]), month0: Number(mdyyyy[1]) - 1, day: Number(mdyyyy[2]) };
  }

  const monthNames = ['january','february','march','april','may','june','july','august','september','october','november','december'];
  const monthAbbr = ['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'];
  let named = birthDate.match(/^([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})$/);
  if (named) {
    const name = named[1].toLowerCase();
    let idx = monthNames.indexOf(name);
    if (idx === -1) idx = monthAbbr.indexOf(name.slice(0,3));
    if (idx === -1) throw new Error('Invalid month name');
    return { year: Number(named[3]), month0: idx, day: Number(named[2]) };
  }

  throw new Error('Invalid date format');
}

serve(async (req: Request) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { birthDate, birthTime, latitude, longitude, timezone } = await req.json() as NatalChartRequest;

    // Validate input
    if (!birthDate || !birthTime || typeof latitude !== 'number' || typeof longitude !== 'number') {
      return new Response(
        JSON.stringify({ 
          error: 'Missing required parameters: birthDate, birthTime, latitude, longitude' 
        }),
        { 
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Strict date parsing aligned with frontend
    const { year, month0, day } = parseDateString(birthDate);

    // Parse time components (strict but wide coverage; default to noon if empty)
    const t = parseTimeString(birthTime) ?? { hour: 12, minute: 0 };

    // Validate coordinates
    if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
      return new Response(
        JSON.stringify({ 
          error: 'Invalid coordinates' 
        }),
        { 
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    console.log(`Calculating natal chart (accurate) for: ${birthDate} ${birthTime} at ${latitude}, ${longitude}`);

    // Build Origin (library expects month 0-11)
    const origin = new Origin({
      year,
      month: month0,
      date: day,
      hour: t.hour,
      minute: t.minute,
      latitude,
      longitude,
      ...(timezone ? { timezone } : {}),
    });

    // Compute Horoscope
    const horoscope = new Horoscope({
      origin,
      houseSystem: 'whole-sign', // we don't render houses
      zodiac: 'tropical',
      aspectPoints: ['bodies','points','angles'],
      aspectWithPoints: ['bodies','points','angles'],
      aspectTypes: ['major'],
      customOrbs: {},
      language: 'en'
    });

    const desiredBodies = ['sun','moon','mercury','venus','mars','jupiter','saturn','uranus','neptune','pluto'];

    const planets: PlanetPosition[] = desiredBodies.map((key) => {
      const item = (horoscope as any).CelestialBodies[key];
      const deg = item?.ChartPosition?.Ecliptic?.DecimalDegrees as number | undefined;
      if (typeof deg !== 'number') return null as any;
      const signIdx = Math.floor(deg / 30) % 12;
      const degree = deg % 30;
      const name = key.charAt(0).toUpperCase() + key.slice(1);
      return { name, sign: ZODIAC_SIGNS[signIdx], degree: Math.round(degree * 100) / 100 };
    }).filter(Boolean);

    const sunSign = planets.find(p => p.name === 'Sun')?.sign || 'Aries';
    const moonSign = planets.find(p => p.name === 'Moon')?.sign || 'Taurus';
    const ascDeg = (horoscope as any).Ascendant?.ChartPosition?.Ecliptic?.DecimalDegrees as number | undefined;
    const risingSign = typeof ascDeg === 'number' ? ZODIAC_SIGNS[Math.floor(ascDeg / 30) % 12] : sunSign;

    const response: NatalChartResponse = {
      sunSign,
      moonSign,
      risingSign,
      planets,
      houses: [], // not used in our UI
      aspects: [] // we don’t need aspects for profile display
    };

    return new Response(JSON.stringify(response), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });

  } catch (error) {
    console.error('Error calculating natal chart:', error);
    
    return new Response(
      JSON.stringify({ 
        error: 'Failed to calculate natal chart',
        details: error.message
      }),
      { 
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});

// Health check endpoint
// GET /calculate-natal-chart
export { serve };
