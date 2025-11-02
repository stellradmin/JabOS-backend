import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { Resend } from 'npm:resend@2.1.0';
import { Origin, Horoscope } from 'https://esm.sh/circular-natal-horoscope-js@1.1.0';
import { getCorsHeaders, checkRateLimit } from '../_shared/cors.ts';
import { getSupabaseAdmin } from '../_shared/supabaseAdmin.ts';
import { convertCityToCoordinates } from '../_shared/geocoding-service.ts';
import {
  BirthDateSchema,
  TimeSchema,
  LocationSchema,
  EmailSchema,
} from '../_shared/zod-schemas.ts';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { renderEmail, QuizResultsEmail } from '../_shared/emails/index.ts';

const TOTAL_ALLOWED_PER_HOUR = 3;
const RATE_LIMIT_WINDOW = 60 * 60 * 1000;
const ZODIAC_SIGNS = [
  'Aries', 'Taurus', 'Gemini', 'Cancer', 'Leo', 'Virgo',
  'Libra', 'Scorpio', 'Sagittarius', 'Capricorn', 'Aquarius', 'Pisces'
] as const;

type Zodiac = (typeof ZODIAC_SIGNS)[number];

const elementBySign: Record<Zodiac, 'fire' | 'earth' | 'air' | 'water'> = {
  Aries: 'fire',
  Leo: 'fire',
  Sagittarius: 'fire',
  Taurus: 'earth',
  Virgo: 'earth',
  Capricorn: 'earth',
  Gemini: 'air',
  Libra: 'air',
  Aquarius: 'air',
  Cancer: 'water',
  Scorpio: 'water',
  Pisces: 'water',
};

const elementHighlights: Record<'fire' | 'earth' | 'air' | 'water', string> = {
  fire: 'Fire signs match your pace and keep the spark blazing.',
  earth: 'Earth signs ground your big visions in something real.',
  air: 'Air signs riff with you mentally and keep ideas flowing.',
  water: 'Water signs feel you deeply and mirror your emotional depth.',
};

type PreferenceAnswers = {
  question1: string;
  question2: string;
  question3: string;
};

type Placements = {
  sunSign: Zodiac;
  moonSign: Zodiac;
  risingSign: Zodiac;
};

const preferenceCopy: Record<PreferenceAnswers[keyof PreferenceAnswers], string> = {
  'emotional-alignment': 'You crave partners who can show up with heart and emotional presence.',
  'intellectual-sparks': 'You light up around people who challenge your thinking and keep the conversation electric.',
  'adventure-energy': 'You thrive in relationships that feel like an ongoing quest with new experiences.',
  'steady-support': 'You warm up to people who are consistent, reliable, and ready for the long haul.',
  'cosmic-cozy': 'Your dream date feels low-key, intentional, and full of mood-setting details.',
  'city-explore': 'You fall for the ones who want to wander a city and stumble into unexpected moments.',
  'creative-flow': 'You vibe with someone who sees beauty everywhere and wants to create something together.',
  'outdoor-magic': 'Fresh air, stars overhead, and grounded conversation is your love language.',
  'daily-checkins': 'You value regular touch points that reinforce closeness.',
  'deep-drops': 'You want conversations that go way beneath the surface.',
  'shared-memes': 'Playful energy and humor keep your connections magnetic.',
  'intentional-updates': 'You love thoughtful messages that arrive exactly when they’re meant to.',
};

const quizSchema = z.object({
  birthDate: BirthDateSchema,
  birthTime: z
    .union([TimeSchema, z.literal(''), z.undefined()])
    .transform((time) => (time && time.length ? time : '12:00')),
  birthLocation: LocationSchema,
  geo: z
    .object({
      latitude: z.number(),
      longitude: z.number(),
      timezone: z.string().nullable().optional(),
      city: z.string().nullable().optional(),
      country: z.string().nullable().optional(),
    })
    .nullable()
    .optional(),
  question1: z.string().min(2).max(120),
  question2: z.string().min(2).max(120),
  question3: z.string().min(2).max(120),
  email: EmailSchema,
  consentGranted: z.literal(true, {
    errorMap: () => ({ message: 'Consent required to send results' }),
  }),
  sessionId: z.string().min(6).max(64),
}).strict();

type QuizPayload = z.infer<typeof quizSchema>;

function parseTime(timeString: string): { hour: number; minute: number } {
  const [hourPart, minutePart] = timeString.split(':');
  const hour = Number(hourPart);
  const minute = Number(minutePart ?? '0');
  if (Number.isNaN(hour) || Number.isNaN(minute)) {
    return { hour: 12, minute: 0 };
  }
  return { hour, minute };
}

function resolvePlacements(
  birthDate: string,
  birthTime: string,
  latitude: number,
  longitude: number,
  timezone?: string | null,
): Placements {
  const [yearStr, monthStr, dayStr] = birthDate.split('-');
  const { hour, minute } = parseTime(birthTime);
  const origin = new Origin({
    year: Number(yearStr),
    month: Number(monthStr) - 1,
    date: Number(dayStr),
    hour,
    minute,
    latitude,
    longitude,
    ...(timezone ? { timezone } : {}),
  });

  const horoscope = new Horoscope({
    origin,
    houseSystem: 'whole-sign',
    zodiac: 'tropical',
    aspectPoints: ['bodies', 'points', 'angles'],
    aspectWithPoints: ['bodies', 'points', 'angles'],
    aspectTypes: ['major'],
    customOrbs: {},
    language: 'en',
  }) as any;

  const placements = {
    sunSign: 'Aries' as Zodiac,
    moonSign: 'Cancer' as Zodiac,
    risingSign: 'Leo' as Zodiac,
  };

  const getSign = (degrees: number | undefined): Zodiac => {
    if (typeof degrees !== 'number' || Number.isNaN(degrees)) {
      return 'Aries';
    }
    const index = Math.floor(degrees / 30) % 12;
    return ZODIAC_SIGNS[index];
  };

  const sun = horoscope?.CelestialBodies?.sun?.ChartPosition?.Ecliptic?.DecimalDegrees;
  const moon = horoscope?.CelestialBodies?.moon?.ChartPosition?.Ecliptic?.DecimalDegrees;
  const asc = horoscope?.Ascendant?.ChartPosition?.Ecliptic?.DecimalDegrees;

  placements.sunSign = getSign(sun);
  placements.moonSign = getSign(moon);
  placements.risingSign = getSign(asc);

  return placements;
}

function buildInsights(placements: Placements, answers: PreferenceAnswers): string[] {
  const base: string[] = [
    `Your ${placements.sunSign} sun fuels how you show up in relationships — bold, unmistakable energy that draws people in.`,
    preferenceCopy[answers.question1] ?? '',
    `With a ${placements.moonSign} moon, emotional safety and rhythm matter. ${preferenceCopy[answers.question3] ?? ''}`.trim(),
    `Your ${placements.risingSign} rising sets the vibe that people feel first, syncing perfectly with your "${answers.question2}" first-date style.`,
  ];

  return base.filter((line) => line.length > 0);
}

function buildCompatibilityHighlights(placements: Placements, answers: PreferenceAnswers): string[] {
  const element = elementBySign[placements.sunSign];
  const recommendedElements =
    element === 'fire'
      ? ['Sagittarius', 'Aries', 'Leo']
      : element === 'earth'
      ? ['Taurus', 'Virgo', 'Capricorn']
      : element === 'air'
      ? ['Libra', 'Aquarius', 'Gemini']
      : ['Cancer', 'Scorpio', 'Pisces'];

  const highlightA = `Top matches: ${recommendedElements.join(', ')}. ${elementHighlights[element]}`;
  const highlightB =
    answers.question1 === 'emotional-alignment'
      ? 'Seek signs with soft moon placements—Cancer, Pisces, or Taurus—for instant emotional resonance.'
      : answers.question1 === 'intellectual-sparks'
      ? 'Air sign moons (Gemini, Libra, Aquarius) will keep conversations endless and inspired.'
      : answers.question1 === 'adventure-energy'
      ? 'Fire sign risings (Aries, Leo, Sagittarius) will match your appetite for movement and spontaneity.'
      : 'Earth sign suns (Taurus, Virgo, Capricorn) help you build the secure base you love.';
  const highlightC =
    answers.question3 === 'shared-memes'
      ? 'Send playful check-ins — Gemini or Sagittarius placements love that meme energy.'
      : answers.question3 === 'deep-drops'
      ? 'Water moons thrive on late-night emotional deep-dives. Don’t be afraid to go there.'
      : answers.question3 === 'daily-checkins'
      ? 'Capricorn and Virgo placements show up consistently. They’ll meet your energy.'
      : 'Lead with intentionality — Libra and Aquarius placements adore well-timed updates.';

  return [highlightA, highlightB, highlightC];
}

function getResendClient(): Resend {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  if (!apiKey) {
    throw new Error('RESEND_API_KEY is not configured');
  }
  return new Resend(apiKey);
}

const downloadLinks = {
  ios: Deno.env.get('STELLR_IOS_APP_URL') ?? 'https://stellr.app/download/ios',
  android: Deno.env.get('STELLR_ANDROID_APP_URL') ?? 'https://stellr.app/download/android',
};

function buildUnsubscribeUrl(email: string, source: string): string {
  const base = Deno.env.get('STELLR_UNSUBSCRIBE_URL') ?? 'https://stellr.app/unsubscribe';
  const url = new URL(base);
  url.searchParams.set('email', email);
  url.searchParams.set('source', source);
  return url.toString();
}

async function enqueueNurtureFlow(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  leadId: string,
  options?: { initialStatus?: 'sent' | 'error'; metadata?: Record<string, unknown> | null },
) {
  const now = new Date();
  const initialStatus = options?.initialStatus ?? 'sent';
  const day0Metadata = options?.metadata ?? null;
  const schedule = [
    { sequence_step: 'day0', offsetHours: 0 },
    { sequence_step: 'day1', offsetHours: 24 },
    { sequence_step: 'day3', offsetHours: 72 },
    { sequence_step: 'day7', offsetHours: 168 },
  ];

  const rows = schedule.map((item) => {
    const scheduledFor = new Date(now.getTime() + item.offsetHours * 60 * 60 * 1000).toISOString();
    if (item.sequence_step === 'day0') {
      return {
        quiz_lead_id: leadId,
        sequence_step: item.sequence_step,
        scheduled_for: scheduledFor,
        status: initialStatus,
        processed_at: initialStatus === 'sent' ? now.toISOString() : null,
        metadata: day0Metadata,
      };
    }
    return {
      quiz_lead_id: leadId,
      sequence_step: item.sequence_step,
      scheduled_for: scheduledFor,
      status: 'pending',
      metadata: null,
    };
  });

  const { error } = await supabase.from('quiz_nurture_queue').insert(rows);
  if (error) {
    console.error('Failed to enqueue nurture sequence', error);
  }
}

async function logQuizEvent(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  event: {
    session_id: string;
    event_type: string;
    step?: number;
    properties?: Record<string, unknown>;
    email?: string;
    ip_address?: string | null;
  },
) {
  const { error } = await supabase.from('quiz_lead_events').insert({
    session_id: event.session_id,
    event_type: event.event_type,
    step: event.step,
    properties: event.properties ?? null,
    email: event.email,
    ip_address: event.ip_address ?? null,
  });
  if (error) {
    console.error('Failed to log quiz event', error);
  }
}

serve(async (req: Request) => {
  const origin = req.headers.get('origin');
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const ipAddress = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
    req.headers.get('cf-connecting-ip') ||
    'unknown';
  const userAgent = req.headers.get('user-agent') ?? 'unknown';

  const rate = await checkRateLimit(`quiz-submit:${ipAddress}`, TOTAL_ALLOWED_PER_HOUR, RATE_LIMIT_WINDOW);
  if (!rate.allowed) {
    return new Response(JSON.stringify({
      success: false,
      error: 'Looks like you’ve hit the quiz limit. Try again in a bit.',
    }), {
      status: 429,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json',
        'x-ratelimit-limit': String(TOTAL_ALLOWED_PER_HOUR),
        'x-ratelimit-remaining': String(Math.max(rate.remaining, 0)),
      },
    });
  }

  let parsed: QuizPayload;
  try {
    const body = await req.json();
    parsed = quizSchema.parse(body);
  } catch (error) {
    const message = error instanceof z.ZodError ? error.issues[0]?.message ?? 'Invalid payload' : 'Invalid payload';
    return new Response(JSON.stringify({ success: false, error: message }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  let geo = parsed.geo;
  try {
    if (!geo || typeof geo.latitude !== 'number' || typeof geo.longitude !== 'number') {
      const { lat, lng, tz, city, country } = await convertCityToCoordinates(parsed.birthLocation);
      geo = {
        latitude: lat,
        longitude: lng,
        timezone: tz ?? null,
        city: city ?? parsed.birthLocation,
        country: country ?? null,
      };
    }
  } catch (error) {
    console.error('Geocoding failed', error);
    return new Response(JSON.stringify({ success: false, error: 'Could not resolve that location.' }), {
      status: 422,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  let placements: Placements;
  try {
    placements = resolvePlacements(
      parsed.birthDate,
      parsed.birthTime,
      Number(geo.latitude),
      Number(geo.longitude),
      geo.timezone ?? null,
    );
  } catch (error) {
    console.error('Failed to calculate placements', error);
    return new Response(JSON.stringify({ success: false, error: 'Unable to calculate chart placements right now.' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const answers: PreferenceAnswers = {
    question1: parsed.question1,
    question2: parsed.question2,
    question3: parsed.question3,
  };

  const insights = buildInsights(placements, answers);
  const compatibilityHighlights = buildCompatibilityHighlights(placements, answers);

  const supabase = getSupabaseAdmin();

  let leadId: string | null = null;
  try {
    const { data, error } = await supabase
      .from('quiz_leads')
      .insert({
        email: parsed.email,
        birth_date: parsed.birthDate,
        birth_time: parsed.birthTime,
        birth_location: parsed.birthLocation,
        birth_lat: geo.latitude,
        birth_lng: geo.longitude,
        timezone: geo.timezone,
        question_1_answer: parsed.question1,
        question_2_answer: parsed.question2,
        question_3_answer: parsed.question3,
        session_id: parsed.sessionId,
        quiz_results: {
          sunSign: placements.sunSign,
          moonSign: placements.moonSign,
          risingSign: placements.risingSign,
          insights,
          compatibilityHighlights,
        },
        ip_address: ipAddress !== 'unknown' ? ipAddress : null,
        user_agent: userAgent,
      })
      .select('id')
      .single();

    if (error) {
      if ((error as { code?: string }).code === '23505') {
        await logQuizEvent(supabase, {
          session_id: parsed.sessionId,
          event_type: 'duplicate_email',
          email: parsed.email,
          ip_address: ipAddress,
        });
        return new Response(JSON.stringify({
          success: false,
          error: 'We already sent results to that email. Check your inbox, spam, or try a different address.',
        }), {
          status: 409,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
      throw error;
    }

    leadId = data?.id ?? null;
  } catch (error) {
    console.error('Failed to persist quiz lead', error);
    return new Response(JSON.stringify({ success: false, error: 'Unable to save your quiz right now.' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  await logQuizEvent(supabase, {
    session_id: parsed.sessionId,
    event_type: 'submission_success',
    step: 6,
    email: parsed.email,
    ip_address: ipAddress,
    properties: {
      sun: placements.sunSign,
      moon: placements.moonSign,
      rising: placements.risingSign,
    },
  });

  const unsubscribeUrl = buildUnsubscribeUrl(parsed.email, 'website_quiz');

  let emailDispatched = false;
  let emailErrorMessage: string | undefined;

  try {
    const resend = getResendClient();
    const rendered = renderEmail(QuizResultsEmail, {
      name: parsed.email.split('@')[0],
      sunSign: placements.sunSign,
      moonSign: placements.moonSign,
      risingSign: placements.risingSign,
      personalityInsights: insights,
      compatibilityHighlights,
      downloadLink: downloadLinks.ios,
      shareLink: `${Deno.env.get('STELLR_SHARE_RESULTS_URL') ?? 'https://stellr.app/share'}?email=${encodeURIComponent(parsed.email)}`,
      unsubscribeUrl,
    });

    await resend.emails.send({
      from: Deno.env.get('STELLR_EMAIL_FROM') ?? 'cosmic@stellr.app',
      to: parsed.email,
      subject: `✨ ${parsed.email.split('@')[0]}, your cosmic love language revealed`,
      html: rendered.html,
      text: rendered.text,
      headers: {
        'List-Unsubscribe': `<${unsubscribeUrl}>`,
      },
    });
    emailDispatched = true;
  } catch (error) {
    console.error('Failed to send Resend email', error);
    emailErrorMessage = error instanceof Error ? error.message : 'Unknown error';
    await logQuizEvent(supabase, {
      session_id: parsed.sessionId,
      event_type: 'email_dispatch_failed',
      email: parsed.email,
      ip_address: ipAddress,
      properties: {
        error: emailErrorMessage,
      },
    });
  }

  if (leadId) {
    await enqueueNurtureFlow(supabase, leadId, {
      initialStatus: emailDispatched ? 'sent' : 'error',
      metadata: emailDispatched ? null : { error: emailErrorMessage ?? 'unknown_error' },
    });
  }

  return new Response(JSON.stringify({
    success: true,
    emailDispatched,
    message: emailDispatched ? undefined : 'We could not confirm delivery to your inbox. We will retry automatically.',
    result: {
      sunSign: placements.sunSign,
      moonSign: placements.moonSign,
      risingSign: placements.risingSign,
      insights: insights.join(' '),
      highlights: compatibilityHighlights,
      downloadLinks,
    },
  }), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});
