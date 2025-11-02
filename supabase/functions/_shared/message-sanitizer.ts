/**
 * Message Sanitizer - Comprehensive XSS Protection for Stellr Messaging
 * 
 * Implements defense-in-depth sanitization with:
 * - HTML entity encoding
 * - Script injection prevention
 * - URL validation
 * - Content Security Policy enforcement
 * - Rich text preservation (safe subset)
 */

// DOMPurify for Deno
import DOMPurify from 'https://esm.sh/isomorphic-dompurify@2.11.0';

// Comprehensive XSS patterns
const DANGEROUS_PATTERNS = [
  // JavaScript execution
  /javascript:/gi,
  /on\w+\s*=/gi,         // Event handlers
  /vbscript:/gi,
  /data:text\/html/gi,
  /data:application\/javascript/gi,
  
  // Dangerous protocols
  /file:/gi,
  /jar:/gi,
  /resource:/gi,
  
  // CSS injection
  /expression\s*\(/gi,
  /@import/gi,
  /behavior:/gi,
  /-moz-binding:/gi,
  
  // SVG/XML injection
  /<svg[^>]*>/gi,
  /<xml[^>]*>/gi,
  
  // Form injection
  /<form[^>]*>/gi,
  /<input[^>]*>/gi,
  
  // Meta refresh
  /<meta[^>]*>/gi,
  
  // Base tag hijacking
  /<base[^>]*>/gi,
  
  // Object/embed/applet
  /<object[^>]*>/gi,
  /<embed[^>]*>/gi,
  /<applet[^>]*>/gi,
  
  // Frame injection
  /<iframe[^>]*>/gi,
  /<frameset[^>]*>/gi,
  /<frame[^>]*>/gi,
  
  // Link injection patterns
  /<link[^>]*>/gi,
  
  // Unicode direction override
  /[\u202A-\u202E\u2066-\u2069]/g,
  
  // Zero-width characters used for fingerprinting
  /[\u200B-\u200F\u202A-\u202E\u2060-\u206F]/g,
];

// Spam/phishing patterns
const SPAM_PATTERNS = [
  // Excessive repetition
  /(.)\1{10,}/gi,
  
  // Common spam phrases
  /click\s+here\s+now/gi,
  /limited\s+time\s+offer/gi,
  /act\s+now/gi,
  /100%\s+free/gi,
  /no\s+credit\s+card/gi,
  
  // Suspicious URLs
  /bit\.ly|tinyurl|goo\.gl|short\.link/gi,
  
  // Phone number patterns (basic)
  /\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b/g,
  
  // Email harvesting
  /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g,
  
  // Cryptocurrency scams
  /bitcoin|btc|ethereum|eth|wallet\s+address/gi,
];

// Safe HTML elements for rich text
const ALLOWED_TAGS = [
  'p', 'br', 'strong', 'em', 'u', 's', 
  'blockquote', 'code', 'pre',
  'ul', 'ol', 'li',
  'a', // With URL validation
];

// Safe attributes
const ALLOWED_ATTRIBUTES = {
  'a': ['href', 'title'],
  'blockquote': ['cite'],
};

// URL validation
const SAFE_URL_PROTOCOLS = ['http:', 'https:', 'mailto:'];

export interface SanitizationResult {
  sanitized: string;
  original: string;
  hasChanges: boolean;
  threats: string[];
  isSpam: boolean;
  metadata: {
    originalLength: number;
    sanitizedLength: number;
    removedElements: string[];
    suspiciousPatterns: string[];
  };
}

export interface SanitizationOptions {
  allowRichText?: boolean;
  allowLinks?: boolean;
  allowImages?: boolean;
  maxLength?: number;
  stripInvisibleChars?: boolean;
  checkSpam?: boolean;
  preserveNewlines?: boolean;
}

export class MessageSanitizer {
  private purifier: typeof DOMPurify;
  
  constructor() {
    this.purifier = DOMPurify;
    this.configurePurifier();
  }

  /**
   * Configure DOMPurify with secure defaults
   */
  private configurePurifier(): void {
    // Add hooks for additional security
    this.purifier.addHook('uponSanitizeElement', (node, data) => {
      // Log removed elements for audit
      if (data.tagName) {
        console.warn(`[XSS] Removed dangerous element: ${data.tagName}`);
      }
    });

    this.purifier.addHook('uponSanitizeAttribute', (node, data) => {
      // Additional attribute validation
      if (data.attrName === 'href') {
        const value = data.attrValue;
        if (!this.isValidUrl(value)) {
          data.keepAttr = false;
          console.warn(`[XSS] Removed dangerous URL: ${value}`);
        }
      }
    });
  }

  /**
   * Main sanitization method
   */
  sanitize(content: string, options: SanitizationOptions = {}): SanitizationResult {
    const {
      allowRichText = false,
      allowLinks = true,
      allowImages = false,
      maxLength = 2000,
      stripInvisibleChars = true,
      checkSpam = true,
      preserveNewlines = true,
    } = options;

    const result: SanitizationResult = {
      sanitized: content,
      original: content,
      hasChanges: false,
      threats: [],
      isSpam: false,
      metadata: {
        originalLength: content.length,
        sanitizedLength: 0,
        removedElements: [],
        suspiciousPatterns: [],
      },
    };

    // Step 1: Length validation
    if (content.length > maxLength) {
      result.sanitized = content.substring(0, maxLength);
      result.hasChanges = true;
      result.threats.push('Content exceeded maximum length');
    }

    // Step 2: Strip invisible/zero-width characters
    if (stripInvisibleChars) {
      const beforeStrip = result.sanitized;
      result.sanitized = result.sanitized.replace(/[\u200B-\u200F\u202A-\u202E\u2060-\u206F]/g, '');
      if (beforeStrip !== result.sanitized) {
        result.hasChanges = true;
        result.threats.push('Invisible characters detected and removed');
      }
    }

    // Step 3: Check for dangerous patterns
    for (const pattern of DANGEROUS_PATTERNS) {
      if (pattern.test(result.sanitized)) {
        result.threats.push(`Dangerous pattern detected: ${pattern.source}`);
        result.metadata.suspiciousPatterns.push(pattern.source);
        result.sanitized = result.sanitized.replace(pattern, '');
        result.hasChanges = true;
      }
    }

    // Step 4: Check for spam patterns
    if (checkSpam) {
      let spamScore = 0;
      for (const pattern of SPAM_PATTERNS) {
        if (pattern.test(result.sanitized)) {
          spamScore++;
          result.metadata.suspiciousPatterns.push(`Spam: ${pattern.source}`);
        }
      }
      result.isSpam = spamScore >= 3;
    }

    // Step 5: HTML sanitization
    if (allowRichText) {
      // Configure DOMPurify for rich text
      const purifyConfig = {
        ALLOWED_TAGS: allowImages ? [...ALLOWED_TAGS, 'img'] : ALLOWED_TAGS,
        ALLOWED_ATTR: allowImages 
          ? { ...ALLOWED_ATTRIBUTES, img: ['src', 'alt', 'width', 'height'] }
          : ALLOWED_ATTRIBUTES,
        ALLOW_DATA_ATTR: false,
        ALLOW_UNKNOWN_PROTOCOLS: false,
        SAFE_FOR_TEMPLATES: true,
        WHOLE_DOCUMENT: false,
        RETURN_DOM: false,
        RETURN_DOM_FRAGMENT: false,
        FORCE_BODY: true,
        SANITIZE_DOM: true,
        KEEP_CONTENT: true,
        IN_PLACE: false,
      };

      const beforePurify = result.sanitized;
      result.sanitized = this.purifier.sanitize(result.sanitized, purifyConfig);
      
      if (beforePurify !== result.sanitized) {
        result.hasChanges = true;
        result.threats.push('HTML content sanitized');
      }
    } else {
      // Plain text - escape all HTML
      const beforeEscape = result.sanitized;
      result.sanitized = this.escapeHtml(result.sanitized);
      
      if (beforeEscape !== result.sanitized) {
        result.hasChanges = true;
        result.threats.push('HTML entities encoded');
      }
    }

    // Step 6: URL validation in plain text
    if (!allowRichText && allowLinks) {
      result.sanitized = this.sanitizeUrls(result.sanitized);
    }

    // Step 7: Preserve newlines if requested
    if (preserveNewlines && !allowRichText) {
      result.sanitized = result.sanitized.replace(/\n/g, '<br>');
    }

    // Step 8: Final validation
    result.sanitized = result.sanitized.trim();
    result.metadata.sanitizedLength = result.sanitized.length;

    // Step 9: Content Security Policy headers recommendation
    if (result.threats.length > 0) {
      result.metadata.suspiciousPatterns.push(
        'Recommend CSP: default-src \'self\'; script-src \'none\'; style-src \'self\' \'unsafe-inline\';'
      );
    }

    return result;
  }

  /**
   * Escape HTML entities
   */
  private escapeHtml(text: string): string {
    const escapeMap: Record<string, string> = {
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;',
      '/': '&#x2F;',
      '`': '&#x60;',
      '=': '&#x3D;',
    };

    return text.replace(/[&<>"'`=\/]/g, (char) => escapeMap[char]);
  }

  /**
   * Validate and sanitize URLs
   */
  private isValidUrl(url: string): boolean {
    try {
      const parsed = new URL(url);
      
      // Check protocol
      if (!SAFE_URL_PROTOCOLS.includes(parsed.protocol)) {
        return false;
      }

      // Check for suspicious patterns
      if (/[<>\"\'`]/.test(url)) {
        return false;
      }

      // Check for IP addresses (often used in phishing)
      if (/^https?:\/\/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/.test(url)) {
        return false;
      }

      // Check for homograph attacks
      if (/[а-яА-Я]/.test(parsed.hostname)) { // Cyrillic
        return false;
      }

      return true;
    } catch {
      return false;
    }
  }

  /**
   * Sanitize URLs in plain text
   */
  private sanitizeUrls(text: string): string {
    // Simple URL regex for plain text
    const urlRegex = /(https?:\/\/[^\s<]+)/g;
    
    return text.replace(urlRegex, (url) => {
      if (this.isValidUrl(url)) {
        return url;
      }
      return '[removed-unsafe-url]';
    });
  }

  /**
   * Validate message before storage
   */
  validateMessage(content: string, options: SanitizationOptions = {}): {
    isValid: boolean;
    errors: string[];
    sanitized: string;
  } {
    const result = this.sanitize(content, options);

    const errors: string[] = [];

    // Check if content is empty after sanitization
    if (!result.sanitized || result.sanitized.length === 0) {
      errors.push('Message is empty after sanitization');
    }

    // Check if marked as spam
    if (result.isSpam) {
      errors.push('Message appears to be spam');
    }

    // Check threat level
    if (result.threats.length > 5) {
      errors.push('Message contains too many security threats');
    }

    // Check minimum length
    if (result.sanitized.length < 1) {
      errors.push('Message is too short');
    }

    return {
      isValid: errors.length === 0,
      errors,
      sanitized: result.sanitized,
    };
  }

  /**
   * Batch sanitize multiple messages
   */
  sanitizeBatch(
    messages: Array<{ id: string; content: string }>,
    options: SanitizationOptions = {}
  ): Map<string, SanitizationResult> {
    const results = new Map<string, SanitizationResult>();

    for (const message of messages) {
      results.set(message.id, this.sanitize(message.content, options));
    }

    return results;
  }
}

// Export singleton instance
export const messageSanitizer = new MessageSanitizer();

// Convenience function
export function sanitizeMessage(
  content: string,
  options?: SanitizationOptions
): SanitizationResult {
  return messageSanitizer.sanitize(content, options);
}

// Validation function
export function validateMessageContent(
  content: string,
  options?: SanitizationOptions
): { isValid: boolean; errors: string[]; sanitized: string } {
  return messageSanitizer.validateMessage(content, options);
}