/**
 * Astrological compatibility utilities (aspects-based, core bodies only)
 *
 * Implements synastry aspects across: Sun, Moon, Ascendant, Mercury, Venus, Mars
 * Uses orbs/angles and weights consistent with the original DB algorithm.
 */

export interface BodyObject {
  name: string;
  sign: string;
  degree?: number; // 0..29.99 within sign
  absoluteDegree?: number; // 0..360
}

export interface NatalChart {
  userID?: string;
  corePlacements?: Record<string, BodyObject>;
  CorePlacements?: Record<string, { Sign: string; Degree: number; AbsoluteDegree?: number }>;
  houses?: Record<string, string>;
  chartData?: { planets?: Array<{ name: string; sign: string; degree: number }> };
  placements?: Record<string, { sign: string; degree: number; absolute_degree?: number }>;
}

type Grade = 'A' | 'B' | 'C' | 'D' | 'F' | 'N/A';

const SIGN_OFFSETS: Record<string, number> = {
  Aries: 0, Taurus: 30, Gemini: 60, Cancer: 90,
  Leo: 120, Virgo: 150, Libra: 180, Scorpio: 210,
  Sagittarius: 240, Capricorn: 270, Aquarius: 300, Pisces: 330
};

const CORE_BODIES = ['Sun','Moon','Ascendant','Mercury','Venus','Mars'] as const;

const ASPECT_ANGLES: Record<string, number> = {
  CONJUNCTION: 0.0,
  SEXTILE: 60.0,
  SQUARE: 90.0,
  TRINE: 120.0,
  OPPOSITION: 180.0,
  QUINCUNX: 150.0
};

const ASPECT_ORBS: Record<string, number> = {
  CONJUNCTION: 8.0,
  OPPOSITION: 8.0,
  TRINE: 8.0,
  SQUARE: 8.0,
  SEXTILE: 6.0,
  QUINCUNX: 3.0
};

function toAbs(sign: string | undefined, deg: number | undefined): number | null {
  if (!sign || deg == null || Number.isNaN(deg)) return null;
  const offset = SIGN_OFFSETS[sign];
  if (offset == null) return null;
  const d = Math.max(0, Math.min(30, deg));
  return offset + d;
}

function getPlacement(chart: NatalChart, key: string): { sign?: string; degree?: number; abs?: number } | null {
  try {
    // 1) explicit placements map
    const p = chart.placements?.[key];
    if (p?.sign) {
      const abs = p.absolute_degree ?? toAbs(p.sign, p.degree);
      return { sign: p.sign, degree: p.degree, abs: abs ?? undefined };
    }
    // 2) corePlacements lower
    const c1 = chart.corePlacements?.[key];
    if (c1?.sign) return { sign: c1.sign, degree: c1.degree, abs: c1.absoluteDegree };
    // 3) CorePlacements capitalized
    const c2 = chart.CorePlacements?.[key as keyof NatalChart['CorePlacements']];
    if (c2?.Sign) return { sign: (c2 as any).Sign, degree: (c2 as any).Degree, abs: (c2 as any).AbsoluteDegree };
    // 4) chartData.planets array
    const planets = chart.chartData?.planets;
    if (Array.isArray(planets)) {
      const found = planets.find(x => (x?.name || '').toLowerCase() === key.toLowerCase());
      if (found?.sign) return { sign: found.sign, degree: found.degree, abs: toAbs(found.sign, found.degree) ?? undefined };
    }
  } catch {}
  return null;
}

function gradeFromScore(score: number): Grade {
  if (!Number.isFinite(score)) return 'N/A';
  if (score >= 90) return 'A';
  if (score >= 80) return 'B';
  if (score >= 70) return 'C';
  if (score >= 60) return 'D';
  return 'F';
}

export function calculateAstrologicalCompatibility(a: NatalChart, b: NatalChart): { score: number; grade: Grade } {
  let rawHarmony = 0.0;
  let totalWeight = 0.0;

  // Track processed pairs of body names to avoid duplicate body-name combinations
  const processed = new Set<string>();

  for (const bodyA of CORE_BODIES) {
    for (const bodyB of CORE_BODIES) {
      // Deduplicate name pair regardless of order
      const pairKey = bodyA <= bodyB ? `${bodyA}-${bodyB}` : `${bodyB}-${bodyA}`;
      if (processed.has(pairKey)) continue;
      processed.add(pairKey);

      const pA = getPlacement(a, bodyA);
      const pB = getPlacement(b, bodyB);
      if (!pA || !pB) continue;
      const degA = pA.abs ?? toAbs(pA.sign!, pA.degree!);
      const degB = pB.abs ?? toAbs(pB.sign!, pB.degree!);
      if (degA == null || degB == null) continue;

      let angleDiff = Math.abs(degA - degB);
      if (angleDiff > 180) angleDiff = 360 - angleDiff;

      // find first matching aspect within its orb (order doesn't matter here; DB sorted by orb asc)
      let chosenAspect: string | null = null;
      let diffFromTarget = 0;
      for (const [asp, orb] of Object.entries(ASPECT_ORBS)) {
        const target = ASPECT_ANGLES[asp];
        const delta = Math.abs(angleDiff - target);
        if (delta <= orb) {
          chosenAspect = asp;
          diffFromTarget = delta;
          break;
        }
      }
      if (!chosenAspect) continue;

      // base weight
      let baseWeight = 1.0;
      if (bodyA === 'Sun' || bodyA === 'Moon' || bodyA === 'Ascendant' || bodyB === 'Sun' || bodyB === 'Moon' || bodyB === 'Ascendant') {
        baseWeight = 1.5;
      }
      if ((bodyA === 'Sun' && bodyB === 'Moon') || (bodyA === 'Moon' && bodyB === 'Sun')) {
        baseWeight = 2.0;
      }
      if ((bodyA === 'Venus' && bodyB === 'Mars') || (bodyA === 'Mars' && bodyB === 'Venus')) {
        baseWeight = 1.7;
      }

      // tightness bonus
      const orb = ASPECT_ORBS[chosenAspect];
      let weight = baseWeight;
      if (orb > 0) {
        const tight = Math.max(0, Math.min(1, 1 - (diffFromTarget / orb)));
        weight = baseWeight * (1 + tight * 0.5);
      }

      // harmony contribution by aspect
      let harmony = 0.0;
      switch (chosenAspect) {
        case 'TRINE': harmony = 1.0; break;
        case 'SEXTILE': harmony = 0.7; break;
        case 'CONJUNCTION': harmony = 0.3; break;
        case 'OPPOSITION': harmony = -0.5; break;
        case 'SQUARE': harmony = -0.7; break;
        case 'QUINCUNX': harmony = -0.3; break;
        default: harmony = 0.0; break;
      }

      rawHarmony += harmony * weight;
      totalWeight += weight;
    }
  }

  let finalScore = 50.0;
  if (totalWeight > 0) {
    finalScore = 50.0 + (rawHarmony / totalWeight) * 25.0;
    finalScore = Math.max(0, Math.min(100, finalScore));
  }

  return { score: Math.round(finalScore), grade: gradeFromScore(finalScore) };
}
