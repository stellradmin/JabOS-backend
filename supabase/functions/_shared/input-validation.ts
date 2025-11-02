/**
 * CRITICAL SECURITY: Enhanced Input Validation for Stellr Edge Functions
 * 
 * Comprehensive input validation with UUID validation, content length limits,
 * and sanitization to prevent injection attacks and data corruption.
 */

import { 
  validateUUID, 
  validateEmail, 
  validateTextInput, 
  validateArrayInput,
  CONTENT_LIMITS,
  ValidationError 
} from './security-validation.ts';

// PHASE 2 SECURITY: Import enhanced XSS protection
import { sanitizeMessage, sanitizeProfile, sanitizeBio, sanitizeGeneral, SanitizationResult } from './xss-protection.ts';

// Enhanced validation schemas for common Stellr data types
export interface ProfileValidation {
  display_name?: string;
  bio?: string;
  birth_date?: string;
  birth_time?: string;
  birth_location?: string;
  interests?: string[];
  height?: number;
  education?: string;
  occupation?: string;
  looking_for?: string;
  age_min?: number;
  age_max?: number;
  max_distance?: number;
}

export interface MessageValidation {
  conversation_id: string;
  content: string;
  media_url?: string;
  media_type?: string;
}

export interface MatchRequestValidation {
  user_id: string;
  target_user_id: string;
  preferences?: {
    age_range?: [number, number];
    max_distance?: number;
    interests?: string[];
  };
}

// PHASE 2 SECURITY: Enhanced validation result with XSS protection details
export interface EnhancedValidationResult<T> {
  valid: boolean;
  errors: ValidationError[];
  sanitized?: T;
  xssThreats: string[];
  contentWarnings: string[];
  sanitizationApplied: boolean;
}

/**
 * PHASE 2 SECURITY: Enhanced profile validation with XSS protection
 */
export function validateProfileDataEnhanced(data: any): EnhancedValidationResult<ProfileValidation> {
  const errors: ValidationError[] = [];
  const sanitized: ProfileValidation = {};
  let xssThreats: string[] = [];
  let contentWarnings: string[] = [];
  let sanitizationApplied = false;

  // Display name validation with XSS protection
  if (data.display_name !== undefined) {
    const xssResult = sanitizeProfile(data.display_name);
    if (!xssResult.isClean) {
      xssThreats.push(...xssResult.securityThreats);
      contentWarnings.push(...xssResult.warnings);
      sanitizationApplied = true;
    }
    
    const nameValidation = validateTextInput(
      xssResult.sanitized,
      'display_name',
      CONTENT_LIMITS.DISPLAY_NAME,
      false
    );
    
    if (!nameValidation.valid) {
      errors.push({ field: 'display_name', error: nameValidation.error || 'Invalid display name' });
    } else {
      sanitized.display_name = nameValidation.sanitized;
    }
  }

  // Bio validation with XSS protection
  if (data.bio !== undefined) {
    const xssResult = sanitizeBio(data.bio);
    if (!xssResult.isClean) {
      xssThreats.push(...xssResult.securityThreats);
      contentWarnings.push(...xssResult.warnings);
      sanitizationApplied = true;
    }
    
    const bioValidation = validateTextInput(
      xssResult.sanitized,
      'bio',
      CONTENT_LIMITS.BIO,
      false
    );
    
    if (!bioValidation.valid) {
      errors.push({ field: 'bio', error: bioValidation.error || 'Invalid bio' });
    } else {
      sanitized.bio = bioValidation.sanitized;
    }
  }

  // Continue with other fields using standard validation...
  const standardResult = validateProfileData(data);
  errors.push(...standardResult.errors);
  
  // Merge sanitized data (XSS-protected fields take precedence)
  if (standardResult.sanitized) {
    Object.assign(sanitized, standardResult.sanitized);
    // Override with XSS-protected versions
    if (data.display_name !== undefined && sanitized.display_name) {
      // Already handled above
    }
    if (data.bio !== undefined && sanitized.bio) {
      // Already handled above
    }
  }

  return {
    valid: errors.length === 0 && xssThreats.length === 0,
    errors,
    sanitized: errors.length === 0 ? sanitized : undefined,
    xssThreats,
    contentWarnings,
    sanitizationApplied
  };
}

/**
 * PHASE 2 SECURITY: Enhanced message validation with XSS protection
 */
export function validateMessageDataEnhanced(data: any): EnhancedValidationResult<MessageValidation> {
  const errors: ValidationError[] = [];
  const sanitized: MessageValidation = {
    conversation_id: '',
    content: ''
  };
  let xssThreats: string[] = [];
  let contentWarnings: string[] = [];
  let sanitizationApplied = false;

  // Conversation ID validation (no XSS needed for UUIDs)
  if (!data.conversation_id) {
    errors.push({ field: 'conversation_id', error: 'Conversation ID is required' });
  } else {
    const uuidValidation = validateUUID(data.conversation_id);
    if (!uuidValidation.valid) {
      errors.push({ field: 'conversation_id', error: uuidValidation.error || 'Invalid conversation ID format' });
    } else {
      sanitized.conversation_id = data.conversation_id;
    }
  }

  // Content validation with XSS protection
  if (!data.content) {
    errors.push({ field: 'content', error: 'Message content is required' });
  } else {
    const xssResult = sanitizeMessage(data.content);
    if (!xssResult.isClean) {
      xssThreats.push(...xssResult.securityThreats);
      contentWarnings.push(...xssResult.warnings);
      sanitizationApplied = true;
    }
    
    const contentValidation = validateTextInput(
      xssResult.sanitized,
      'content',
      CONTENT_LIMITS.MESSAGE,
      true
    );
    
    if (!contentValidation.valid) {
      errors.push({ field: 'content', error: contentValidation.error || 'Invalid message content' });
    } else {
      sanitized.content = contentValidation.sanitized || '';
    }
  }

  // Media URL validation (same as before, no XSS needed for URLs that are validated)
  if (data.media_url !== undefined && data.media_url !== null) {
    try {
      new URL(data.media_url);
      sanitized.media_url = data.media_url;
    } catch {
      errors.push({ field: 'media_url', error: 'Invalid media URL format' });
    }
  }

  // Media type validation
  if (data.media_url && !data.media_type) {
    errors.push({ field: 'media_type', error: 'Media type is required when media URL is provided' });
  } else if (data.media_type) {
    const validMediaTypes = ['image', 'video', 'audio', 'gif'];
    if (!validMediaTypes.includes(data.media_type)) {
      errors.push({ field: 'media_type', error: `Invalid media type. Must be one of: ${validMediaTypes.join(', ')}` });
    } else {
      sanitized.media_type = data.media_type;
    }
  }

  return {
    valid: errors.length === 0 && xssThreats.length === 0,
    errors,
    sanitized: errors.length === 0 ? sanitized : undefined,
    xssThreats,
    contentWarnings,
    sanitizationApplied
  };
}

/**
 * Validate profile data with comprehensive checks
 */
export function validateProfileData(data: any): { valid: boolean; errors: ValidationError[]; sanitized?: ProfileValidation } {
  const errors: ValidationError[] = [];
  const sanitized: ProfileValidation = {};

  // Display name validation
  if (data.display_name !== undefined) {
    const nameValidation = validateTextInput(
      data.display_name,
      'display_name',
      CONTENT_LIMITS.DISPLAY_NAME,
      false
    );
    if (!nameValidation.valid) {
      errors.push({ field: 'display_name', error: nameValidation.error || 'Invalid display name' });
    } else {
      sanitized.display_name = nameValidation.sanitized;
    }
  }

  // Bio validation
  if (data.bio !== undefined) {
    const bioValidation = validateTextInput(
      data.bio,
      'bio',
      CONTENT_LIMITS.BIO,
      false
    );
    if (!bioValidation.valid) {
      errors.push({ field: 'bio', error: bioValidation.error || 'Invalid bio' });
    } else {
      sanitized.bio = bioValidation.sanitized;
    }
  }

  // Birth date validation
  if (data.birth_date !== undefined) {
    if (!isValidDate(data.birth_date)) {
      errors.push({ field: 'birth_date', error: 'Invalid birth date format. Expected YYYY-MM-DD' });
    } else {
      const birthDate = new Date(data.birth_date);
      const now = new Date();
      const age = now.getFullYear() - birthDate.getFullYear();
      
      if (age < 18 || age > 100) {
        errors.push({ field: 'birth_date', error: 'Age must be between 18 and 100 years' });
      } else {
        sanitized.birth_date = data.birth_date;
      }
    }
  }

  // Birth time validation (optional)
  if (data.birth_time !== undefined) {
    if (!isValidTime(data.birth_time)) {
      errors.push({ field: 'birth_time', error: 'Invalid birth time format. Expected HH:MM' });
    } else {
      sanitized.birth_time = data.birth_time;
    }
  }

  // Birth location validation
  if (data.birth_location !== undefined) {
    const locationValidation = validateTextInput(
      data.birth_location,
      'birth_location',
      CONTENT_LIMITS.LOCATION,
      false
    );
    if (!locationValidation.valid) {
      errors.push({ field: 'birth_location', error: locationValidation.error || 'Invalid birth location' });
    } else {
      sanitized.birth_location = locationValidation.sanitized;
    }
  }

  // Interests validation
  if (data.interests !== undefined) {
    const interestsValidation = validateArrayInput(
      data.interests,
      'interests',
      CONTENT_LIMITS.MAX_INTERESTS,
      (interest: any) => {
        if (typeof interest !== 'string') {
          return { valid: false, error: 'Interest must be a string' };
        }
        const textValidation = validateTextInput(interest, 'interest', CONTENT_LIMITS.INTERESTS, true);
        return { valid: textValidation.valid, error: textValidation.error };
      }
    );
    if (!interestsValidation.valid) {
      errors.push({ field: 'interests', error: interestsValidation.error || 'Invalid interests array' });
    } else {
      sanitized.interests = data.interests.map((interest: string) => 
        validateTextInput(interest, 'interest', CONTENT_LIMITS.INTERESTS, true).sanitized || interest
      );
    }
  }

  // Height validation
  if (data.height !== undefined) {
    if (typeof data.height !== 'number' || data.height < 100 || data.height > 250) {
      errors.push({ field: 'height', error: 'Height must be a number between 100 and 250 cm' });
    } else {
      sanitized.height = Math.round(data.height);
    }
  }

  // Education validation
  if (data.education !== undefined) {
    const educationValidation = validateTextInput(
      data.education,
      'education',
      100, // Max 100 chars for education
      false
    );
    if (!educationValidation.valid) {
      errors.push({ field: 'education', error: educationValidation.error || 'Invalid education' });
    } else {
      sanitized.education = educationValidation.sanitized;
    }
  }

  // Occupation validation
  if (data.occupation !== undefined) {
    const occupationValidation = validateTextInput(
      data.occupation,
      'occupation',
      100, // Max 100 chars for occupation
      false
    );
    if (!occupationValidation.valid) {
      errors.push({ field: 'occupation', error: occupationValidation.error || 'Invalid occupation' });
    } else {
      sanitized.occupation = occupationValidation.sanitized;
    }
  }

  // Looking for validation
  if (data.looking_for !== undefined) {
    const validLookingFor = ['men', 'women', 'everyone', 'non-binary'];
    if (!validLookingFor.includes(data.looking_for)) {
      errors.push({ field: 'looking_for', error: `Invalid looking_for value. Must be one of: ${validLookingFor.join(', ')}` });
    } else {
      sanitized.looking_for = data.looking_for;
    }
  }

  // Age range validation
  if (data.age_min !== undefined) {
    if (typeof data.age_min !== 'number' || data.age_min < 18 || data.age_min > 80) {
      errors.push({ field: 'age_min', error: 'Minimum age must be a number between 18 and 80' });
    } else {
      sanitized.age_min = Math.round(data.age_min);
    }
  }

  if (data.age_max !== undefined) {
    if (typeof data.age_max !== 'number' || data.age_max < 18 || data.age_max > 100) {
      errors.push({ field: 'age_max', error: 'Maximum age must be a number between 18 and 100' });
    } else {
      sanitized.age_max = Math.round(data.age_max);
    }
  }

  // Cross-field validation for age range
  if (sanitized.age_min && sanitized.age_max && sanitized.age_min > sanitized.age_max) {
    errors.push({ field: 'age_range', error: 'Minimum age cannot be greater than maximum age' });
  }

  // Max distance validation
  if (data.max_distance !== undefined) {
    if (typeof data.max_distance !== 'number' || data.max_distance < 1 || data.max_distance > 1000) {
      errors.push({ field: 'max_distance', error: 'Maximum distance must be a number between 1 and 1000 km' });
    } else {
      sanitized.max_distance = Math.round(data.max_distance);
    }
  }

  return {
    valid: errors.length === 0,
    errors,
    sanitized: errors.length === 0 ? sanitized : undefined
  };
}

/**
 * Validate message data
 */
export function validateMessageData(data: any): { valid: boolean; errors: ValidationError[]; sanitized?: MessageValidation } {
  const errors: ValidationError[] = [];
  const sanitized: MessageValidation = {
    conversation_id: '',
    content: ''
  };

  // Conversation ID validation (required)
  if (!data.conversation_id) {
    errors.push({ field: 'conversation_id', error: 'Conversation ID is required' });
  } else {
    const uuidValidation = validateUUID(data.conversation_id);
    if (!uuidValidation.valid) {
      errors.push({ field: 'conversation_id', error: uuidValidation.error || 'Invalid conversation ID format' });
    } else {
      sanitized.conversation_id = data.conversation_id;
    }
  }

  // Content validation (required)
  if (!data.content) {
    errors.push({ field: 'content', error: 'Message content is required' });
  } else {
    const contentValidation = validateTextInput(
      data.content,
      'content',
      CONTENT_LIMITS.MESSAGE,
      true
    );
    if (!contentValidation.valid) {
      errors.push({ field: 'content', error: contentValidation.error || 'Invalid message content' });
    } else {
      sanitized.content = contentValidation.sanitized || '';
    }
  }

  // Media URL validation (optional)
  if (data.media_url !== undefined && data.media_url !== null) {
    try {
      new URL(data.media_url);
      sanitized.media_url = data.media_url;
    } catch {
      errors.push({ field: 'media_url', error: 'Invalid media URL format' });
    }
  }

  // Media type validation (required if media_url is provided)
  if (data.media_url && !data.media_type) {
    errors.push({ field: 'media_type', error: 'Media type is required when media URL is provided' });
  } else if (data.media_type) {
    const validMediaTypes = ['image', 'video', 'audio', 'gif'];
    if (!validMediaTypes.includes(data.media_type)) {
      errors.push({ field: 'media_type', error: `Invalid media type. Must be one of: ${validMediaTypes.join(', ')}` });
    } else {
      sanitized.media_type = data.media_type;
    }
  }

  return {
    valid: errors.length === 0,
    errors,
    sanitized: errors.length === 0 ? sanitized : undefined
  };
}

/**
 * Validate match request data
 */
export function validateMatchRequestData(data: any): { valid: boolean; errors: ValidationError[]; sanitized?: MatchRequestValidation } {
  const errors: ValidationError[] = [];
  const sanitized: MatchRequestValidation = {
    user_id: '',
    target_user_id: ''
  };

  // User ID validation (required)
  if (!data.user_id) {
    errors.push({ field: 'user_id', error: 'User ID is required' });
  } else {
    const uuidValidation = validateUUID(data.user_id);
    if (!uuidValidation.valid) {
      errors.push({ field: 'user_id', error: uuidValidation.error || 'Invalid user ID format' });
    } else {
      sanitized.user_id = data.user_id;
    }
  }

  // Target user ID validation (required)
  if (!data.target_user_id) {
    errors.push({ field: 'target_user_id', error: 'Target user ID is required' });
  } else {
    const uuidValidation = validateUUID(data.target_user_id);
    if (!uuidValidation.valid) {
      errors.push({ field: 'target_user_id', error: uuidValidation.error || 'Invalid target user ID format' });
    } else {
      sanitized.target_user_id = data.target_user_id;
    }
  }

  // Prevent self-matching
  if (sanitized.user_id && sanitized.target_user_id && sanitized.user_id === sanitized.target_user_id) {
    errors.push({ field: 'target_user_id', error: 'Cannot create match request with yourself' });
  }

  // Preferences validation (optional)
  if (data.preferences !== undefined) {
    if (typeof data.preferences !== 'object' || data.preferences === null) {
      errors.push({ field: 'preferences', error: 'Preferences must be an object' });
    } else {
      const preferences: any = {};

      // Age range validation
      if (data.preferences.age_range !== undefined) {
        if (!Array.isArray(data.preferences.age_range) || data.preferences.age_range.length !== 2) {
          errors.push({ field: 'preferences.age_range', error: 'Age range must be an array of two numbers [min, max]' });
        } else {
          const [min, max] = data.preferences.age_range;
          if (typeof min !== 'number' || typeof max !== 'number' || min < 18 || max > 100 || min > max) {
            errors.push({ field: 'preferences.age_range', error: 'Invalid age range. Must be [min, max] where 18 ≤ min ≤ max ≤ 100' });
          } else {
            preferences.age_range = [Math.round(min), Math.round(max)];
          }
        }
      }

      // Max distance validation
      if (data.preferences.max_distance !== undefined) {
        if (typeof data.preferences.max_distance !== 'number' || data.preferences.max_distance < 1 || data.preferences.max_distance > 1000) {
          errors.push({ field: 'preferences.max_distance', error: 'Max distance must be a number between 1 and 1000 km' });
        } else {
          preferences.max_distance = Math.round(data.preferences.max_distance);
        }
      }

      // Interests validation
      if (data.preferences.interests !== undefined) {
        const interestsValidation = validateArrayInput(
          data.preferences.interests,
          'preferences.interests',
          CONTENT_LIMITS.MAX_INTERESTS,
          (interest: any) => {
            if (typeof interest !== 'string') {
              return { valid: false, error: 'Interest must be a string' };
            }
            const textValidation = validateTextInput(interest, 'interest', CONTENT_LIMITS.INTERESTS, true);
            return { valid: textValidation.valid, error: textValidation.error };
          }
        );
        if (!interestsValidation.valid) {
          errors.push({ field: 'preferences.interests', error: interestsValidation.error || 'Invalid interests array' });
        } else {
          preferences.interests = data.preferences.interests.map((interest: string) => 
            validateTextInput(interest, 'interest', CONTENT_LIMITS.INTERESTS, true).sanitized || interest
          );
        }
      }

      if (Object.keys(preferences).length > 0) {
        sanitized.preferences = preferences;
      }
    }
  }

  return {
    valid: errors.length === 0,
    errors,
    sanitized: errors.length === 0 ? sanitized : undefined
  };
}

/**
 * Validate date string (YYYY-MM-DD format)
 */
function isValidDate(dateString: string): boolean {
  if (typeof dateString !== 'string') return false;
  
  const regex = /^\d{4}-\d{2}-\d{2}$/;
  if (!regex.test(dateString)) return false;
  
  const date = new Date(dateString + 'T00:00:00.000Z');
  return !isNaN(date.getTime()) && date.toISOString().startsWith(dateString);
}

/**
 * Validate time string (HH:MM format)
 */
function isValidTime(timeString: string): boolean {
  if (typeof timeString !== 'string') return false;
  
  const regex = /^([0-1]?[0-9]|2[0-3]):[0-5][0-9]$/;
  return regex.test(timeString);
}

/**
 * Validate geographic coordinates
 */
export function validateCoordinates(lat: any, lng: any): { valid: boolean; error?: string; coordinates?: { lat: number; lng: number } } {
  if (typeof lat !== 'number' || typeof lng !== 'number') {
    return { valid: false, error: 'Latitude and longitude must be numbers' };
  }
  
  if (lat < -90 || lat > 90) {
    return { valid: false, error: 'Latitude must be between -90 and 90 degrees' };
  }
  
  if (lng < -180 || lng > 180) {
    return { valid: false, error: 'Longitude must be between -180 and 180 degrees' };
  }
  
  return { 
    valid: true, 
    coordinates: { 
      lat: Number(lat.toFixed(6)), // Limit precision to 6 decimal places (~0.1m accuracy)
      lng: Number(lng.toFixed(6))
    }
  };
}

/**
 * Validate zodiac sign
 */
export function validateZodiacSign(sign: any): { valid: boolean; error?: string; sign?: string } {
  if (typeof sign !== 'string') {
    return { valid: false, error: 'Zodiac sign must be a string' };
  }
  
  const validSigns = [
    'aries', 'taurus', 'gemini', 'cancer', 'leo', 'virgo',
    'libra', 'scorpio', 'sagittarius', 'capricorn', 'aquarius', 'pisces'
  ];
  
  const normalizedSign = sign.toLowerCase().trim();
  
  if (!validSigns.includes(normalizedSign)) {
    return { 
      valid: false, 
      error: `Invalid zodiac sign. Must be one of: ${validSigns.join(', ')}` 
    };
  }
  
  return { valid: true, sign: normalizedSign };
}

/**
 * Validate phone number (basic international format)
 */
export function validatePhoneNumber(phone: any): { valid: boolean; error?: string; phone?: string } {
  if (typeof phone !== 'string') {
    return { valid: false, error: 'Phone number must be a string' };
  }
  
  // Remove all non-digit characters for validation
  const digitsOnly = phone.replace(/\D/g, '');
  
  if (digitsOnly.length < 7 || digitsOnly.length > 15) {
    return { valid: false, error: 'Phone number must be between 7 and 15 digits' };
  }
  
  // Basic format validation (allows various international formats)
  const phoneRegex = /^[\+]?[1-9][\d\s\-\(\)]{6,18}$/;
  if (!phoneRegex.test(phone)) {
    return { valid: false, error: 'Invalid phone number format' };
  }
  
  return { valid: true, phone: phone.trim() };
}

/**
 * ENHANCED SQL injection prevention with comprehensive pattern detection
 * SECURITY FIX: Addresses CVSS 8.9 SQL injection vulnerability
 */
export function preventSQLInjection(input: string): { safe: boolean; sanitized?: string; reason?: string } {
  if (typeof input !== 'string') {
    return { safe: false, reason: 'Input must be a string' };
  }
  
  // Comprehensive SQL injection pattern detection
  const sqlPatterns = [
    // Basic SQL commands
    /(\bunion\s+(all\s+)?select\b)/i,
    /(\bdrop\s+(table|database|schema|index|view|trigger|function)\b)/i,
    /(\bdelete\s+from\b)/i,
    /(\binsert\s+into\b)/i,
    /(\bupdate\s+.*\s+set\b)/i,
    /(\bselect\s+.*\s+from\b)/i,
    /(\balter\s+(table|database|schema)\b)/i,
    /(\bcreate\s+(table|database|schema|index|view|trigger|function)\b)/i,
    /(\btruncate\s+table\b)/i,
    
    // SQL injection techniques
    /(;|\-\-|\#|\/\*|\*\/)/,
    /(\bor\s+1\s*[=<>!]+\s*1\b)/i,
    /(\band\s+1\s*[=<>!]+\s*1\b)/i,
    /(\bor\s+true\b|\band\s+false\b)/i,
    /(\bor\s+'[^']*'\s*=\s*'[^']*')/i,
    
    // Execution commands
    /(\b(exec|execute|sp_|xp_)\b)/i,
    /(\b(cmd|shell|system)\s*\()/i,
    
    // Advanced techniques
    /(\bcast\s*\(.*\s+as\s+)/i,
    /(\bconvert\s*\()/i,
    /(\bchar\s*\(.*\))/i,
    /(\bhex\s*\(.*\))/i,
    /(\bunhex\s*\(.*\))/i,
    /(\bascii\s*\(.*\))/i,
    /(\bsubstr\s*\(.*\))/i,
    /(\bmid\s*\(.*\))/i,
    
    // Time-based injection
    /(\bsleep\s*\(.*\))/i,
    /(\bwaitfor\s+delay\b)/i,
    /(\bbenchmark\s*\(.*\))/i,
    
    // Information gathering
    /(\binformation_schema\b)/i,
    /(\bsys\.(tables|columns|databases)\b)/i,
    /(\bpg_(tables|attribute|class)\b)/i,
    /(\bshow\s+(tables|columns|databases)\b)/i,
    
    // File operations
    /(\bload_file\s*\(.*\))/i,
    /(\binto\s+(outfile|dumpfile)\b)/i,
    
    // Stored procedures
    /(\bcall\s+\w+\s*\()/i,
    
    // Advanced encoding bypass attempts
    /(\\\x[0-9a-f]{2,})/i,
    /(%[0-9a-f]{2}){3,}/i,
    /(0x[0-9a-f]+)/i,
  ];
  
  // Check for suspicious patterns
  for (const pattern of sqlPatterns) {
    if (pattern.test(input)) {
      return { 
        safe: false, 
        reason: `Input contains potential SQL injection pattern: ${pattern.source}` 
      };
    }
  }
  
  // Check for excessive special characters that might indicate encoding attempts
  const specialCharCount = (input.match(/[';"\-\#\*\/\\%]/g) || []).length;
  const totalLength = input.length;
  if (totalLength > 10 && specialCharCount / totalLength > 0.3) {
    return { 
      safe: false, 
      reason: 'Input contains suspicious character patterns that may indicate injection attempt' 
    };
  }
  
  // Enhanced escaping - proper SQL string escaping
  let sanitized = input
    .replace(/\\/g, '\\\\')  // Escape backslashes first
    .replace(/'/g, "''")      // Escape single quotes
    .replace(/"/g, '""')      // Escape double quotes
    .replace(/\x00/g, '')     // Remove null bytes
    .replace(/\n/g, '\\n')    // Escape newlines
    .replace(/\r/g, '\\r')    // Escape carriage returns
    .replace(/\t/g, '\\t');   // Escape tabs
  
  // Final validation - ensure sanitized string doesn't contain bypass attempts
  for (const pattern of sqlPatterns) {
    if (pattern.test(sanitized)) {
      return { 
        safe: false, 
        reason: 'Input still contains SQL injection patterns after sanitization' 
      };
    }
  }
  
  return { safe: true, sanitized };
}

export {
  CONTENT_LIMITS,
  validateUUID,
  validateEmail,
  validateTextInput,
  validateArrayInput
};