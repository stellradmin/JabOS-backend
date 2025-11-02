/**
 * Geocoding Service for Converting Birth Cities to Coordinates
 * Used for accurate natal chart calculations
 */

interface Coordinates {
  lat: number;
  lng: number;
  city: string;
  country?: string;
  tz?: string;
}

/**
 * Simple geocoding service using a basic city database
 * In production, this could be replaced with a proper geocoding API
 */
const CITY_COORDINATES: { [city: string]: { lat: number; lng: number; country: string; tz: string } } = {
  // Major US Cities
  "new york": { lat: 40.7128, lng: -74.0060, country: "USA", tz: "America/New_York" },
  "new york city": { lat: 40.7128, lng: -74.0060, country: "USA", tz: "America/New_York" },
  "nyc": { lat: 40.7128, lng: -74.0060, country: "USA", tz: "America/New_York" },
  "los angeles": { lat: 34.0522, lng: -118.2437, country: "USA", tz: "America/Los_Angeles" },
  "chicago": { lat: 41.8781, lng: -87.6298, country: "USA", tz: "America/Chicago" },
  "houston": { lat: 29.7604, lng: -95.3698, country: "USA", tz: "America/Chicago" },
  "phoenix": { lat: 33.4484, lng: -112.0740, country: "USA", tz: "America/Phoenix" },
  "philadelphia": { lat: 39.9526, lng: -75.1652, country: "USA", tz: "America/New_York" },
  "san antonio": { lat: 29.4241, lng: -98.4936, country: "USA", tz: "America/Chicago" },
  "san diego": { lat: 32.7157, lng: -117.1611, country: "USA", tz: "America/Los_Angeles" },
  "dallas": { lat: 32.7767, lng: -96.7970, country: "USA", tz: "America/Chicago" },
  "san jose": { lat: 37.3382, lng: -121.8863, country: "USA", tz: "America/Los_Angeles" },
  "austin": { lat: 30.2672, lng: -97.7431, country: "USA", tz: "America/Chicago" },
  "jacksonville": { lat: 30.3322, lng: -81.6557, country: "USA", tz: "America/New_York" },
  "fort worth": { lat: 32.7555, lng: -97.3308, country: "USA", tz: "America/Chicago" },
  "columbus": { lat: 39.9612, lng: -82.9988, country: "USA", tz: "America/New_York" },
  "charlotte": { lat: 35.2271, lng: -80.8431, country: "USA", tz: "America/New_York" },
  "san francisco": { lat: 37.7749, lng: -122.4194, country: "USA", tz: "America/Los_Angeles" },
  "indianapolis": { lat: 39.7684, lng: -86.1581, country: "USA", tz: "America/Indiana/Indianapolis" },
  "seattle": { lat: 47.6062, lng: -122.3321, country: "USA", tz: "America/Los_Angeles" },
  "denver": { lat: 39.7392, lng: -104.9903, country: "USA", tz: "America/Denver" },
  "washington": { lat: 38.9072, lng: -77.0369, country: "USA", tz: "America/New_York" },
  "boston": { lat: 42.3601, lng: -71.0589, country: "USA", tz: "America/New_York" },
  "el paso": { lat: 31.7619, lng: -106.4850, country: "USA", tz: "America/Denver" },
  "detroit": { lat: 42.3314, lng: -83.0458, country: "USA", tz: "America/Detroit" },
  "nashville": { lat: 36.1627, lng: -86.7816, country: "USA", tz: "America/Chicago" },
  "portland": { lat: 45.5152, lng: -122.6784, country: "USA", tz: "America/Los_Angeles" },
  "memphis": { lat: 35.1495, lng: -90.0490, country: "USA", tz: "America/Chicago" },
  "oklahoma city": { lat: 35.4676, lng: -97.5164, country: "USA", tz: "America/Chicago" },
  "las vegas": { lat: 36.1699, lng: -115.1398, country: "USA", tz: "America/Los_Angeles" },
  "louisville": { lat: 38.2527, lng: -85.7585, country: "USA", tz: "America/Kentucky/Louisville" },
  "baltimore": { lat: 39.2904, lng: -76.6122, country: "USA", tz: "America/New_York" },
  "milwaukee": { lat: 43.0389, lng: -87.9065, country: "USA", tz: "America/Chicago" },
  "albuquerque": { lat: 35.0844, lng: -106.6504, country: "USA", tz: "America/Denver" },
  "tucson": { lat: 32.2226, lng: -110.9747, country: "USA", tz: "America/Phoenix" },
  "fresno": { lat: 36.7378, lng: -119.7871, country: "USA", tz: "America/Los_Angeles" },
  "mesa": { lat: 33.4152, lng: -111.8315, country: "USA", tz: "America/Phoenix" },
  "sacramento": { lat: 38.5816, lng: -121.4944, country: "USA", tz: "America/Los_Angeles" },
  "atlanta": { lat: 33.7490, lng: -84.3880, country: "USA", tz: "America/New_York" },
  "kansas city": { lat: 39.0997, lng: -94.5786, country: "USA", tz: "America/Chicago" },
  "colorado springs": { lat: 38.8339, lng: -104.8214, country: "USA", tz: "America/Denver" },
  "miami": { lat: 25.7617, lng: -80.1918, country: "USA", tz: "America/New_York" },
  "raleigh": { lat: 35.7796, lng: -78.6382, country: "USA", tz: "America/New_York" },
  "omaha": { lat: 41.2524, lng: -95.9980, country: "USA", tz: "America/Chicago" },
  "long beach": { lat: 33.7701, lng: -118.1937, country: "USA", tz: "America/Los_Angeles" },
  "virginia beach": { lat: 36.8529, lng: -75.9780, country: "USA", tz: "America/New_York" },
  "oakland": { lat: 37.8044, lng: -122.2712, country: "USA", tz: "America/Los_Angeles" },
  "minneapolis": { lat: 44.9778, lng: -93.2650, country: "USA", tz: "America/Chicago" },
  "tulsa": { lat: 36.1539, lng: -95.9928, country: "USA", tz: "America/Chicago" },
  "tampa": { lat: 27.9506, lng: -82.4572, country: "USA", tz: "America/New_York" },
  "arlington": { lat: 32.7357, lng: -97.1081, country: "USA", tz: "America/Chicago" },
  
  // International Cities
  "london": { lat: 51.5074, lng: -0.1278, country: "UK", tz: "Europe/London" },
  "paris": { lat: 48.8566, lng: 2.3522, country: "France", tz: "Europe/Paris" },
  "tokyo": { lat: 35.6762, lng: 139.6503, country: "Japan", tz: "Asia/Tokyo" },
  "berlin": { lat: 52.5200, lng: 13.4050, country: "Germany", tz: "Europe/Berlin" },
  "rome": { lat: 41.9028, lng: 12.4964, country: "Italy", tz: "Europe/Rome" },
  "madrid": { lat: 40.4168, lng: -3.7038, country: "Spain", tz: "Europe/Madrid" },
  "barcelona": { lat: 41.3851, lng: 2.1734, country: "Spain", tz: "Europe/Madrid" },
  "amsterdam": { lat: 52.3676, lng: 4.9041, country: "Netherlands", tz: "Europe/Amsterdam" },
  "sydney": { lat: -33.8688, lng: 151.2093, country: "Australia", tz: "Australia/Sydney" },
  "melbourne": { lat: -37.8136, lng: 144.9631, country: "Australia", tz: "Australia/Melbourne" },
  "toronto": { lat: 43.6532, lng: -79.3832, country: "Canada", tz: "America/Toronto" },
  "vancouver": { lat: 49.2827, lng: -123.1207, country: "Canada", tz: "America/Vancouver" },
  "montreal": { lat: 45.5017, lng: -73.5673, country: "Canada", tz: "America/Toronto" },
  "mexico city": { lat: 19.4326, lng: -99.1332, country: "Mexico", tz: "America/Mexico_City" },
  "sao paulo": { lat: -23.5505, lng: -46.6333, country: "Brazil", tz: "America/Sao_Paulo" },
  "rio de janeiro": { lat: -22.9068, lng: -43.1729, country: "Brazil", tz: "America/Sao_Paulo" },
  "buenos aires": { lat: -34.6118, lng: -58.3960, country: "Argentina", tz: "America/Argentina/Buenos_Aires" },
  "mumbai": { lat: 19.0760, lng: 72.8777, country: "India", tz: "Asia/Kolkata" },
  "delhi": { lat: 28.7041, lng: 77.1025, country: "India", tz: "Asia/Kolkata" },
  "bangalore": { lat: 12.9716, lng: 77.5946, country: "India", tz: "Asia/Kolkata" },
  "beijing": { lat: 39.9042, lng: 116.4074, country: "China", tz: "Asia/Shanghai" },
  "shanghai": { lat: 31.2304, lng: 121.4737, country: "China", tz: "Asia/Shanghai" },
  "hong kong": { lat: 22.3193, lng: 114.1694, country: "Hong Kong", tz: "Asia/Hong_Kong" },
  "singapore": { lat: 1.3521, lng: 103.8198, country: "Singapore", tz: "Asia/Singapore" },
  "dubai": { lat: 25.2048, lng: 55.2708, country: "UAE", tz: "Asia/Dubai" },
  "cairo": { lat: 30.0444, lng: 31.2357, country: "Egypt", tz: "Africa/Cairo" },
  "moscow": { lat: 55.7558, lng: 37.6176, country: "Russia", tz: "Europe/Moscow" },
  "istanbul": { lat: 41.0082, lng: 28.9784, country: "Turkey", tz: "Europe/Istanbul" },
  
  // Canadian Cities
  "calgary": { lat: 51.0447, lng: -114.0719, country: "Canada", tz: "America/Edmonton" },
  "ottawa": { lat: 45.4215, lng: -75.6972, country: "Canada", tz: "America/Toronto" },
  "edmonton": { lat: 53.5461, lng: -113.4938, country: "Canada", tz: "America/Edmonton" },
  "winnipeg": { lat: 49.8951, lng: -97.1384, country: "Canada", tz: "America/Winnipeg" },
  "quebec city": { lat: 46.8139, lng: -71.2080, country: "Canada", tz: "America/Toronto" }
};

/**
 * Convert city name to coordinates
 */
export async function convertCityToCoordinates(cityName: string): Promise<Coordinates> {
  if (!cityName || typeof cityName !== 'string') {
    throw new Error('City name is required');
  }
  
  // Normalize city name for lookup
  const normalizedCity = cityName.toLowerCase().trim();
  
  // Try exact match first
  if (normalizedCity in CITY_COORDINATES) {
    const coords = CITY_COORDINATES[normalizedCity];
    return {
      lat: coords.lat,
      lng: coords.lng,
      city: cityName,
      country: coords.country,
      tz: coords.tz || inferTimezone(coords.lat, coords.lng, coords.country)
    };
  }
  
  // Try partial matches
  for (const [city, coords] of Object.entries(CITY_COORDINATES)) {
    if (city.includes(normalizedCity) || normalizedCity.includes(city)) {
      return {
        lat: coords.lat,
        lng: coords.lng,
        city: cityName,
        country: coords.country,
        tz: coords.tz || inferTimezone(coords.lat, coords.lng, coords.country)
      };
    }
  }
  
  // Fallback to major city (New York) if no match found
  console.warn(`City "${cityName}" not found in database, using New York as fallback`);
  const fallback = CITY_COORDINATES["new york"];
  return {
    lat: fallback.lat,
    lng: fallback.lng,
    city: cityName,
    country: "USA",
    tz: fallback.tz || inferTimezone(fallback.lat, fallback.lng, "USA")
  };
}

/**
 * Add a city to the coordinates database (for dynamic expansion)
 */
export function addCityCoordinates(city: string, lat: number, lng: number, country: string): void {
  CITY_COORDINATES[city.toLowerCase()] = { lat, lng, country };
}

/**
 * Get all available cities
 */
export function getAvailableCities(): string[] {
  return Object.keys(CITY_COORDINATES);
}

/**
 * Validate coordinates
 */
export function validateCoordinates(lat: number, lng: number): boolean {
  return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
}

/**
 * Lightweight timezone inference by country/longitude bands (best-effort)
 * Not authoritative; intended as a fallback when city tz is missing.
 */
export function inferTimezone(lat: number, lng: number, country?: string): string {
  const c = (country || '').toLowerCase();

  // United States (rough longitudinal bands; special-case Arizona)
  if (c === 'usa' || c === 'united states' || c === 'us') {
    // Arizona (approx)
    if (lat >= 31 && lat <= 37 && lng >= -115 && lng <= -108) return 'America/Phoenix';
    if (lng <= -114) return 'America/Los_Angeles';       // Pacific
    if (lng > -114 && lng <= -104) return 'America/Denver'; // Mountain
    if (lng > -104 && lng <= -90) return 'America/Chicago';  // Central
    return 'America/New_York'; // Eastern
  }

  // Canada
  if (c === 'canada') {
    if (lng <= -120) return 'America/Vancouver'; // Pacific
    if (lng > -120 && lng <= -110) return 'America/Edmonton'; // Mountain
    if (lng > -110 && lng <= -95) return 'America/Winnipeg'; // Central
    return 'America/Toronto'; // Eastern/Quebec/Ontario
  }

  // Brazil
  if (c === 'brazil') {
    return 'America/Sao_Paulo';
  }

  // Mexico
  if (c === 'mexico') {
    if (lng <= -106) return 'America/Tijuana';
    if (lng > -106 && lng <= -97) return 'America/Chihuahua';
    if (lng > -97 && lng <= -92) return 'America/Mexico_City';
    return 'America/Mexico_City';
  }

  // UK, EU (coarse)
  if (c === 'uk' || c === 'united kingdom') return 'Europe/London';
  if (c === 'france') return 'Europe/Paris';
  if (c === 'germany') return 'Europe/Berlin';
  if (c === 'spain') return 'Europe/Madrid';
  if (c === 'netherlands') return 'Europe/Amsterdam';
  if (c === 'italy') return 'Europe/Rome';

  // Asia
  if (c === 'india') return 'Asia/Kolkata';
  if (c === 'japan') return 'Asia/Tokyo';
  if (c === 'china') return 'Asia/Shanghai';
  if (c === 'singapore') return 'Asia/Singapore';
  if (c === 'uae' || c === 'united arab emirates') return 'Asia/Dubai';

  // Australia
  if (c === 'australia') {
    if (lng >= 150) return 'Australia/Sydney';
    return 'Australia/Melbourne';
  }

  // Default fallback: pick a common tz by longitude
  if (lng <= -150) return 'Etc/GMT+10';
  if (lng <= -120) return 'America/Los_Angeles';
  if (lng <= -90) return 'America/Chicago';
  if (lng <= -60) return 'America/New_York';
  if (lng <= -30) return 'Atlantic/Azores';
  if (lng <= 0) return 'Europe/London';
  if (lng <= 30) return 'Europe/Berlin';
  if (lng <= 60) return 'Europe/Moscow';
  if (lng <= 90) return 'Asia/Dubai';
  if (lng <= 120) return 'Asia/Karachi';
  if (lng <= 150) return 'Asia/Shanghai';
  return 'Asia/Tokyo';
}
