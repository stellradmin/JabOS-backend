/**
 * COMPREHENSIVE ZOD VALIDATION SCHEMAS for Stellr API
 * 
 * This file contains all Zod validation schemas for API requests and responses,
 * providing type-safe validation across the entire application.
 * 
 * Features:
 * - Complete request/response validation
 * - Custom error messages
 * - Transform functions for data normalization
 * - Cross-field validation rules
 * - Performance-optimized schemas with lazy loading
 */

import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

// ============================================================================
// COMMON VALIDATION HELPERS
// ============================================================================

/**
 * UUID validation with custom error message
 */
export const UUIDSchema = z.string().uuid({
  message: 'Must be a valid UUID format'
});

/**
 * Email validation with comprehensive regex
 */
export const EmailSchema = z.string()
  .email({ message: 'Must be a valid email address' })
  .min(5, 'Email must be at least 5 characters')
  .max(254, 'Email must not exceed 254 characters')
  .toLowerCase()
  .trim();

/**
 * Date validation for birth dates with age restrictions
 */
export const BirthDateSchema = z.string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Date must be in YYYY-MM-DD format')
  .refine(
    (date) => {
      const birthDate = new Date(date);
      const now = new Date();
      const age = now.getFullYear() - birthDate.getFullYear();
      const monthDiff = now.getMonth() - birthDate.getMonth();
      const dayDiff = now.getDate() - birthDate.getDate();
      
      const actualAge = monthDiff < 0 || (monthDiff === 0 && dayDiff < 0) ? age - 1 : age;
      
      return actualAge >= 18 && actualAge <= 120;
    },
    { message: 'User must be between 18 and 120 years old' }
  );

/**
 * Time validation for birth times (HH:MM format)
 */
export const TimeSchema = z.string()
  .regex(/^([0-1]?[0-9]|2[0-3]):[0-5][0-9]$/, 'Time must be in HH:MM format');

/**
 * Location validation with basic format checking
 */
export const LocationSchema = z.string()
  .min(2, 'Location must be at least 2 characters')
  .max(100, 'Location must not exceed 100 characters')
  .trim();

/**
 * Latitude validation
 */
export const LatitudeSchema = z.number()
  .min(-90, 'Latitude must be between -90 and 90')
  .max(90, 'Latitude must be between -90 and 90');

/**
 * Longitude validation
 */
export const LongitudeSchema = z.number()
  .min(-180, 'Longitude must be between -180 and 180')
  .max(180, 'Longitude must be between -180 and 180');

/**
 * Text input with XSS prevention
 */
const createTextSchema = (minLength: number, maxLength: number, fieldName: string) => 
  z.string()
    .min(minLength, `${fieldName} must be at least ${minLength} characters`)
    .max(maxLength, `${fieldName} must not exceed ${maxLength} characters`)
    .trim()
    // Remove HTML tags and potential XSS
    .transform(val => val.replace(/<[^>]*>/g, ''))
    .refine(
      val => !/<script|javascript:|data:|vbscript:/i.test(val),
      { message: `${fieldName} contains forbidden content` }
    );

// ============================================================================
// AUTHENTICATION SCHEMAS
// ============================================================================

/**
 * User registration request schema
 */
export const UserRegistrationSchema = z.object({
  email: EmailSchema,
  password: z.string()
    .min(8, 'Password must be at least 8 characters')
    .max(128, 'Password must not exceed 128 characters')
    .regex(/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)/, 'Password must contain at least one lowercase letter, one uppercase letter, and one number'),
  displayName: createTextSchema(2, 50, 'Display name'),
  dateOfBirth: BirthDateSchema,
  acceptTerms: z.boolean().refine(val => val === true, {
    message: 'You must accept the terms and conditions'
  }),
  marketingConsent: z.boolean().default(false),
}).strict();

/**
 * User login request schema
 */
export const UserLoginSchema = z.object({
  email: EmailSchema,
  password: z.string().min(1, 'Password is required'),
}).strict();

/**
 * Password reset request schema
 */
export const PasswordResetRequestSchema = z.object({
  email: EmailSchema,
}).strict();

/**
 * Password reset confirmation schema
 */
export const PasswordResetConfirmSchema = z.object({
  token: z.string().min(1, 'Reset token is required'),
  newPassword: z.string()
    .min(8, 'Password must be at least 8 characters')
    .max(128, 'Password must not exceed 128 characters')
    .regex(/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)/, 'Password must contain at least one lowercase letter, one uppercase letter, and one number'),
}).strict();

// ============================================================================
// PROFILE SCHEMAS
// ============================================================================

/**
 * Zodiac sign validation
 */
export const ZodiacSignSchema = z.enum([
  'aries', 'taurus', 'gemini', 'cancer', 'leo', 'virgo',
  'libra', 'scorpio', 'sagittarius', 'capricorn', 'aquarius', 'pisces'
], { 
  errorMap: () => ({ message: 'Must be a valid zodiac sign' })
});

/**
 * Gender validation
 */
export const GenderSchema = z.enum(['man', 'woman', 'non-binary', 'other'], {
  errorMap: () => ({ message: 'Must select a valid gender option' })
});

/**
 * Looking for validation
 */
export const LookingForSchema = z.enum(['men', 'women', 'everyone', 'non-binary'], {
  errorMap: () => ({ message: 'Must select a valid preference' })
});

/**
 * Education level validation
 */
export const EducationLevelSchema = z.enum([
  'high-school', 'some-college', 'bachelors', 'masters', 'doctorate', 'trade-school', 'other'
], {
  errorMap: () => ({ message: 'Must select a valid education level' })
});

/**
 * Height validation (in centimeters)
 */
export const HeightSchema = z.number()
  .min(100, 'Height must be at least 100 cm')
  .max(250, 'Height must not exceed 250 cm')
  .int('Height must be a whole number');

/**
 * Interests array validation
 */
export const InterestsSchema = z.array(
  createTextSchema(1, 50, 'Interest')
).min(1, 'Must have at least one interest')
  .max(20, 'Cannot have more than 20 interests')
  .refine(
    (interests) => new Set(interests).size === interests.length,
    { message: 'Interests must be unique' }
  );

/**
 * Complete profile update schema
 */
export const ProfileUpdateSchema = z.object({
  displayName: createTextSchema(2, 50, 'Display name').optional(),
  bio: createTextSchema(0, 500, 'Bio').optional(),
  birthDate: BirthDateSchema.optional(),
  birthTime: TimeSchema.optional(),
  birthLocation: LocationSchema.optional(),
  gender: GenderSchema.optional(),
  lookingFor: LookingForSchema.optional(),
  height: HeightSchema.optional(),
  education: EducationLevelSchema.optional(),
  occupation: createTextSchema(0, 100, 'Occupation').optional(),
  interests: InterestsSchema.optional(),
  zodiacSign: ZodiacSignSchema.optional(),
  // Location data
  latitude: LatitudeSchema.optional(),
  longitude: LongitudeSchema.optional(),
  locationName: LocationSchema.optional(),
  // Preferences
  ageMin: z.number().min(18).max(80).int().optional(),
  ageMax: z.number().min(18).max(100).int().optional(),
  maxDistance: z.number().min(1).max(1000).int().optional(),
}).refine(
  (data) => {
    if (data.ageMin && data.ageMax) {
      return data.ageMin <= data.ageMax;
    }
    return true;
  },
  {
    message: 'Minimum age cannot be greater than maximum age',
    path: ['ageMin']
  }
).strict();

// ============================================================================
// MATCHING SCHEMAS
// ============================================================================

/**
 * Get potential matches query parameters
 */
export const GetMatchesQuerySchema = z.object({
  page: z.string().optional().default('1').transform(val => {
    const parsed = parseInt(val, 10);
    if (isNaN(parsed) || parsed < 1) return 1;
    return Math.min(parsed, 100); // Max 100 pages
  }),
  pageSize: z.string().optional().default('20').transform(val => {
    const parsed = parseInt(val, 10);
    if (isNaN(parsed) || parsed < 1) return 20;
    return Math.min(parsed, 50); // Max 50 items per page
  }),
  cursor: z.string().optional(),
  zodiacSign: ZodiacSignSchema.optional(),
  minAge: z.string().optional().transform(val => {
    if (!val) return undefined;
    const parsed = parseInt(val, 10);
    if (isNaN(parsed) || parsed < 18 || parsed > 100) return undefined;
    return parsed;
  }),
  maxAge: z.string().optional().transform(val => {
    if (!val) return undefined;
    const parsed = parseInt(val, 10);
    if (isNaN(parsed) || parsed < 18 || parsed > 100) return undefined;
    return parsed;
  }),
  maxDistanceKm: z.string().optional().transform(val => {
    if (!val) return undefined;
    const parsed = parseInt(val, 10);
    if (isNaN(parsed) || parsed < 1 || parsed > 500) return undefined;
    return parsed;
  }),
  refresh: z.string().optional().transform(val => val === 'true'),
}).refine(
  (data) => {
    if (data.minAge && data.maxAge && data.minAge > data.maxAge) {
      throw new Error('Minimum age cannot be greater than maximum age');
    }
    return true;
  }
);

/**
 * Swipe action schema
 */
export const SwipeActionSchema = z.object({
  targetUserId: UUIDSchema,
  action: z.enum(['like', 'dislike', 'super_like'], {
    errorMap: () => ({ message: 'Action must be like, dislike, or super_like' })
  }),
  latitude: LatitudeSchema.optional(),
  longitude: LongitudeSchema.optional(),
}).strict();

/**
 * Match request schema
 */
export const MatchRequestSchema = z.object({
  targetUserId: UUIDSchema,
  message: createTextSchema(0, 500, 'Match message').optional(),
}).strict();

// ============================================================================
// COMPATIBILITY SCHEMAS
// ============================================================================

/**
 * Compatibility calculation request
 */
export const CompatibilityRequestSchema = z.object({
  userId1: UUIDSchema,
  userId2: UUIDSchema,
  includeDetails: z.boolean().default(false),
}).refine(
  (data) => data.userId1 !== data.userId2,
  { message: 'Cannot calculate compatibility with yourself' }
).strict();

/**
 * Natal chart calculation request
 */
export const NatalChartRequestSchema = z.object({
  birthDate: BirthDateSchema,
  birthTime: TimeSchema,
  birthLocation: LocationSchema,
  latitude: LatitudeSchema,
  longitude: LongitudeSchema,
}).strict();

// ============================================================================
// MESSAGING SCHEMAS
// ============================================================================

/**
 * Send message schema
 */
export const SendMessageSchema = z.object({
  conversationId: UUIDSchema,
  content: createTextSchema(1, 5000, 'Message content'),
  mediaUrl: z.string().url('Must be a valid URL').optional(),
  mediaType: z.enum(['image', 'video', 'audio', 'gif'], {
    errorMap: () => ({ message: 'Media type must be image, video, audio, or gif' })
  }).optional(),
}).refine(
  (data) => {
    // If mediaUrl is provided, mediaType must also be provided
    if (data.mediaUrl && !data.mediaType) {
      return false;
    }
    return true;
  },
  {
    message: 'Media type is required when media URL is provided',
    path: ['mediaType']
  }
).strict();

/**
 * Get messages query parameters
 */
export const GetMessagesQuerySchema = z.object({
  conversationId: UUIDSchema,
  limit: z.string().optional().default('50').transform(val => {
    const parsed = parseInt(val, 10);
    if (isNaN(parsed) || parsed < 1) return 50;
    return Math.min(parsed, 100); // Max 100 messages at once
  }),
  before: z.string().optional(), // Cursor for pagination
  after: z.string().optional(), // Cursor for pagination
}).strict();

// ============================================================================
// DATE PROPOSAL SCHEMAS
// ============================================================================

/**
 * Date proposal creation schema
 */
export const CreateDateProposalSchema = z.object({
  conversationId: UUIDSchema,
  title: createTextSchema(3, 100, 'Date title'),
  description: createTextSchema(10, 1000, 'Date description'),
  proposedDate: z.string()
    .datetime({ message: 'Must be a valid ISO datetime' })
    .refine(
      (date) => new Date(date) > new Date(),
      { message: 'Proposed date must be in the future' }
    ),
  location: LocationSchema,
  latitude: LatitudeSchema.optional(),
  longitude: LongitudeSchema.optional(),
  estimatedCost: z.number().min(0, 'Cost cannot be negative').optional(),
  category: z.enum([
    'dinner', 'drinks', 'coffee', 'outdoor', 'cultural', 'entertainment', 'sports', 'other'
  ]).optional(),
}).strict();

/**
 * Date proposal response schema
 */
export const DateProposalResponseSchema = z.object({
  proposalId: UUIDSchema,
  response: z.enum(['accept', 'decline', 'counter'], {
    errorMap: () => ({ message: 'Response must be accept, decline, or counter' })
  }),
  counterProposal: z.object({
    proposedDate: z.string().datetime().optional(),
    location: LocationSchema.optional(),
    message: createTextSchema(0, 500, 'Counter proposal message').optional(),
  }).optional(),
}).refine(
  (data) => {
    // If response is counter, counterProposal must be provided
    if (data.response === 'counter' && !data.counterProposal) {
      return false;
    }
    return true;
  },
  {
    message: 'Counter proposal details are required when countering',
    path: ['counterProposal']
  }
).strict();

// ============================================================================
// SETTINGS SCHEMAS
// ============================================================================

/**
 * User settings update schema
 */
export const UserSettingsSchema = z.object({
  // Privacy settings
  profileVisibility: z.enum(['public', 'discoverable', 'private']).optional(),
  showDistance: z.boolean().optional(),
  showLastActive: z.boolean().optional(),
  showReadReceipts: z.boolean().optional(),
  
  // Notification preferences
  pushNotifications: z.boolean().optional(),
  emailNotifications: z.boolean().optional(),
  marketingEmails: z.boolean().optional(),
  matchNotifications: z.boolean().optional(),
  messageNotifications: z.boolean().optional(),
  
  // Discovery preferences
  discoverable: z.boolean().optional(),
  ageRange: z.object({
    min: z.number().min(18).max(80).int(),
    max: z.number().min(18).max(100).int(),
  }).refine(
    (data) => data.min <= data.max,
    { message: 'Minimum age cannot be greater than maximum age' }
  ).optional(),
  maxDistance: z.number().min(1).max(1000).int().optional(),
  
  // Content preferences
  explicitContent: z.boolean().optional(),
  autoPlayVideos: z.boolean().optional(),
}).strict();

// ============================================================================
// PAYMENT SCHEMAS
// ============================================================================

/**
 * Create checkout session schema
 */
export const CreateCheckoutSessionSchema = z.object({
  priceId: z.string().min(1, 'Price ID is required'),
  successUrl: z.string().url('Must be a valid URL'),
  cancelUrl: z.string().url('Must be a valid URL'),
  metadata: z.record(z.string()).optional(),
}).strict();

/**
 * Subscription management schema
 */
export const SubscriptionUpdateSchema = z.object({
  action: z.enum(['cancel', 'reactivate', 'change_plan'], {
    errorMap: () => ({ message: 'Action must be cancel, reactivate, or change_plan' })
  }),
  newPriceId: z.string().optional(),
}).refine(
  (data) => {
    // If action is change_plan, newPriceId must be provided
    if (data.action === 'change_plan' && !data.newPriceId) {
      return false;
    }
    return true;
  },
  {
    message: 'New price ID is required when changing plans',
    path: ['newPriceId']
  }
).strict();

// ============================================================================
// REPORTING SCHEMAS
// ============================================================================

/**
 * Report issue schema
 */
export const ReportIssueSchema = z.object({
  reportedUserId: UUIDSchema.optional(),
  conversationId: UUIDSchema.optional(),
  messageId: UUIDSchema.optional(),
  category: z.enum([
    'harassment', 'spam', 'inappropriate_content', 'fake_profile', 
    'scam', 'violence', 'hate_speech', 'underage', 'other'
  ], {
    errorMap: () => ({ message: 'Must select a valid report category' })
  }),
  description: createTextSchema(10, 2000, 'Report description'),
  evidence: z.array(
    z.object({
      type: z.enum(['screenshot', 'message', 'profile', 'other']),
      url: z.string().url('Must be a valid URL').optional(),
      description: createTextSchema(0, 500, 'Evidence description').optional(),
    })
  ).max(10, 'Cannot submit more than 10 pieces of evidence').optional(),
}).refine(
  (data) => {
    // At least one of reportedUserId, conversationId, or messageId must be provided
    return !!(data.reportedUserId || data.conversationId || data.messageId);
  },
  {
    message: 'Must specify what you are reporting (user, conversation, or message)',
    path: ['reportedUserId']
  }
).strict();

// ============================================================================
// RESPONSE SCHEMAS
// ============================================================================

/**
 * Standard API response wrapper
 */
export const ApiResponseSchema = <T extends z.ZodTypeAny>(dataSchema: T) =>
  z.object({
    success: z.boolean(),
    data: dataSchema.optional(),
    error: z.object({
      code: z.string(),
      message: z.string(),
      details: z.record(z.unknown()).optional(),
    }).optional(),
    metadata: z.object({
      timestamp: z.string().datetime(),
      requestId: z.string(),
      processingTime: z.number().optional(),
      rateLimit: z.object({
        remaining: z.number(),
        resetTime: z.number(),
        category: z.string(),
      }).optional(),
    }),
  }).strict();

/**
 * Paginated response wrapper
 */
export const PaginatedResponseSchema = <T extends z.ZodTypeAny>(itemSchema: T) =>
  z.object({
    success: z.boolean(),
    data: z.array(itemSchema),
    pagination: z.object({
      hasMore: z.boolean(),
      nextCursor: z.string().optional(),
      prevCursor: z.string().optional(),
      totalCount: z.number().optional(),
      pageSize: z.number(),
      currentPage: z.number().optional(),
    }),
    metadata: z.object({
      timestamp: z.string().datetime(),
      requestId: z.string(),
      processingTime: z.number().optional(),
      fromCache: z.boolean().optional(),
    }),
  }).strict();

// ============================================================================
// EXPORT VALIDATION HELPER FUNCTIONS
// ============================================================================

/**
 * Validate and parse request data with comprehensive error handling
 */
export function validateRequest<T>(
  schema: z.ZodSchema<T>,
  data: unknown,
  context?: string
): { success: true; data: T } | { success: false; errors: string[]; details: z.ZodError } {
  try {
    const result = schema.parse(data);
    return { success: true, data: result };
  } catch (error) {
    if (error instanceof z.ZodError) {
      const errors = error.errors.map(err => {
        const path = err.path.length > 0 ? ` at ${err.path.join('.')}` : '';
        return `${err.message}${path}`;
      });
      
      return {
        success: false,
        errors,
        details: error,
      };
    }
    
    return {
      success: false,
      errors: [`Validation failed${context ? ` for ${context}` : ''}: ${error.message}`],
      details: error as z.ZodError,
    };
  }
}

/**
 * Create a validation middleware for Edge Functions
 */
export function createValidationMiddleware<T>(
  schema: z.ZodSchema<T>,
  options: {
    source?: 'body' | 'query' | 'params';
    context?: string;
    onError?: (errors: string[], details: z.ZodError) => Response;
  } = {}
) {
  const { source = 'body', context, onError } = options;
  
  return async (request: Request): Promise<
    { success: true; data: T; request: Request } | 
    { success: false; response: Response }
  > => {
    try {
      let rawData: unknown;
      
      switch (source) {
        case 'body':
          rawData = await request.json();
          break;
        case 'query':
          const url = new URL(request.url);
          rawData = Object.fromEntries(url.searchParams.entries());
          break;
        case 'params':
          // This would need to be implemented based on routing system
          rawData = {};
          break;
      }
      
      const validation = validateRequest(schema, rawData, context);
      
      if (validation.success) {
        return { success: true, data: validation.data, request };
      }
      
      // Handle validation errors
      if (onError) {
        return { success: false, response: onError(validation.errors, validation.details) };
      }
      
      // Default error response
      const errorResponse = new Response(
        JSON.stringify({
          success: false,
          error: {
            code: 'VALIDATION_ERROR',
            message: 'Request validation failed',
            details: {
              errors: validation.errors,
              fields: validation.details.errors.map(err => ({
                field: err.path.join('.'),
                message: err.message,
                received: err.received,
              })),
            },
          },
          metadata: {
            timestamp: new Date().toISOString(),
            requestId: `val_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
          },
        }),
        {
          status: 400,
          headers: {
            'Content-Type': 'application/json',
            'Cache-Control': 'no-store',
          },
        }
      );
      
      return { success: false, response: errorResponse };
      
    } catch (error) {
      const errorResponse = new Response(
        JSON.stringify({
          success: false,
          error: {
            code: 'REQUEST_PARSING_ERROR',
            message: 'Failed to parse request data',
            details: { error: error.message },
          },
          metadata: {
            timestamp: new Date().toISOString(),
            requestId: `parse_err_${Date.now()}`,
          },
        }),
        {
          status: 400,
          headers: {
            'Content-Type': 'application/json',
            'Cache-Control': 'no-store',
          },
        }
      );
      
      return { success: false, response: errorResponse };
    }
  };
}

/**
 * Schema registry for runtime schema loading and caching
 */
export const SchemaRegistry = {
  // Authentication schemas
  userRegistration: UserRegistrationSchema,
  userLogin: UserLoginSchema,
  passwordResetRequest: PasswordResetRequestSchema,
  passwordResetConfirm: PasswordResetConfirmSchema,
  
  // Profile schemas
  profileUpdate: ProfileUpdateSchema,
  
  // Matching schemas
  getMatchesQuery: GetMatchesQuerySchema,
  swipeAction: SwipeActionSchema,
  matchRequest: MatchRequestSchema,
  
  // Compatibility schemas
  compatibilityRequest: CompatibilityRequestSchema,
  natalChartRequest: NatalChartRequestSchema,
  
  // Messaging schemas
  sendMessage: SendMessageSchema,
  getMessagesQuery: GetMessagesQuerySchema,
  
  // Date proposal schemas
  createDateProposal: CreateDateProposalSchema,
  dateProposalResponse: DateProposalResponseSchema,
  
  // Settings schemas
  userSettings: UserSettingsSchema,
  
  // Payment schemas
  createCheckoutSession: CreateCheckoutSessionSchema,
  subscriptionUpdate: SubscriptionUpdateSchema,
  
  // Reporting schemas
  reportIssue: ReportIssueSchema,
} as const;

export type SchemaKey = keyof typeof SchemaRegistry;

/**
 * Get schema by key with type safety
 */
export function getSchema<K extends SchemaKey>(key: K): typeof SchemaRegistry[K] {
  return SchemaRegistry[key];
}

export default SchemaRegistry;