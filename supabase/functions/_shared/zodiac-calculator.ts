/**
 * Simple zodiac sign calculator based on birth date
 * This is a simplified version that only calculates sun sign without time/location
 */

export type ZodiacSign = 
  | 'Aries' | 'Taurus' | 'Gemini' | 'Cancer' 
  | 'Leo' | 'Virgo' | 'Libra' | 'Scorpio'
  | 'Sagittarius' | 'Capricorn' | 'Aquarius' | 'Pisces';

interface DateParts {
  month: number; // 1-12
  day: number;   // 1-31
}

/**
 * Calculate zodiac sign from birth date
 * @param dateString ISO date string (YYYY-MM-DD) or date object
 * @returns ZodiacSign or null if invalid date
 */
export function calculateZodiacSign(dateString: string): ZodiacSign | null {
  try {
    const date = new Date(dateString);
    
    // Validate date
    if (isNaN(date.getTime())) {
      return null;
    }
    
    const month = date.getMonth() + 1; // getMonth() returns 0-11
    const day = date.getDate();
    
    return getZodiacSignFromDate({ month, day });
  } catch (error) {
return null;
  }
}

/**
 * Get zodiac sign from month and day
 * Based on tropical zodiac dates (Western astrology)
 */
function getZodiacSignFromDate({ month, day }: DateParts): ZodiacSign {
  // Validate inputs
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    throw new Error('Invalid month or day');
  }

  // Zodiac sign date ranges (tropical zodiac)
  if ((month === 3 && day >= 21) || (month === 4 && day <= 19)) return 'Aries';
  if ((month === 4 && day >= 20) || (month === 5 && day <= 20)) return 'Taurus';
  if ((month === 5 && day >= 21) || (month === 6 && day <= 20)) return 'Gemini';
  if ((month === 6 && day >= 21) || (month === 7 && day <= 22)) return 'Cancer';
  if ((month === 7 && day >= 23) || (month === 8 && day <= 22)) return 'Leo';
  if ((month === 8 && day >= 23) || (month === 9 && day <= 22)) return 'Virgo';
  if ((month === 9 && day >= 23) || (month === 10 && day <= 22)) return 'Libra';
  if ((month === 10 && day >= 23) || (month === 11 && day <= 21)) return 'Scorpio';
  if ((month === 11 && day >= 22) || (month === 12 && day <= 21)) return 'Sagittarius';
  if ((month === 12 && day >= 22) || (month === 1 && day <= 19)) return 'Capricorn';
  if ((month === 1 && day >= 20) || (month === 2 && day <= 18)) return 'Aquarius';
  if ((month === 2 && day >= 19) || (month === 3 && day <= 20)) return 'Pisces';
  
  // This should never happen with valid dates, but fallback to Aries
  throw new Error(`Could not determine zodiac sign for ${month}/${day}`);
}

/**
 * Parse birth info object and calculate zodiac sign
 * @param birthInfo Object with date field
 * @returns ZodiacSign or null if invalid
 */
export function calculateZodiacFromBirthInfo(birthInfo: any): ZodiacSign | null {
  if (!birthInfo || typeof birthInfo !== 'object') {
    return null;
  }
  
  const { date } = birthInfo;
  if (!date || typeof date !== 'string') {
    return null;
  }
  
  return calculateZodiacSign(date);
}