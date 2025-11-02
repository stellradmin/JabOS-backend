/**
 * PHASE 2 SECURITY: Comprehensive XSS Protection and Content Sanitization for Stellr
 * 
 * Advanced XSS prevention with HTML/script tag removal, content filtering,
 * and message content sanitization for dating app security.
 */

// PHASE 2 SECURITY: XSS Protection Configuration
export interface XSSProtectionConfig {
  allowBasicFormatting: boolean; // Allow basic markdown-like formatting
  stripAllHTML: boolean; // Remove all HTML tags
  allowEmoji: boolean; // Allow emoji characters
  maxContentLength: number; // Maximum content length
  blockedPatterns: RegExp[]; // Custom blocked patterns
  aggressiveMode: boolean; // More aggressive filtering
}

// PHASE 2 SECURITY: Content Sanitization Result
export interface SanitizationResult {
  sanitized: string;
  isClean: boolean;
  removedContent: string[];
  warnings: string[];
  securityThreats: string[];
  originalLength: number;
  sanitizedLength: number;
}

// PHASE 2 SECURITY: Comprehensive XSS Protection Class
export class XSSProtectionService {
  private config: XSSProtectionConfig;

  constructor(config: Partial<XSSProtectionConfig> = {}) {
    this.config = {
      allowBasicFormatting: false, // Strict for dating app
      stripAllHTML: true,
      allowEmoji: true,
      maxContentLength: 1000,
      blockedPatterns: [],
      aggressiveMode: true,
      ...config
    };
  }

  /**
   * PHASE 2 SECURITY: Comprehensive text sanitization
   */
  sanitizeText(input: string, context: 'message' | 'profile' | 'bio' | 'general' = 'general'): SanitizationResult {
    const result: SanitizationResult = {
      sanitized: '',
      isClean: true,
      removedContent: [],
      warnings: [],
      securityThreats: [],
      originalLength: input.length,
      sanitizedLength: 0
    };

    if (!input || typeof input !== 'string') {
      result.sanitized = '';
      result.sanitizedLength = 0;
      return result;
    }

    let sanitized = input;

    try {
      // Step 1: Remove/neutralize dangerous HTML tags and attributes
      const htmlResult = this.removeHTMLContent(sanitized);
      sanitized = htmlResult.cleaned;
      result.removedContent.push(...htmlResult.removed);
      result.securityThreats.push(...htmlResult.threats);

      // Step 2: Remove/neutralize script content
      const scriptResult = this.removeScriptContent(sanitized);
      sanitized = scriptResult.cleaned;
      result.removedContent.push(...scriptResult.removed);
      result.securityThreats.push(...scriptResult.threats);

      // Step 3: Remove dangerous URLs and protocols
      const urlResult = this.sanitizeURLs(sanitized);
      sanitized = urlResult.cleaned;
      result.removedContent.push(...urlResult.removed);
      result.securityThreats.push(...urlResult.threats);

      // Step 4: Context-specific sanitization
      const contextResult = this.contextSpecificSanitization(sanitized, context);
      sanitized = contextResult.cleaned;
      result.warnings.push(...contextResult.warnings);

      // Step 5: Remove dangerous Unicode and special characters
      const unicodeResult = this.sanitizeUnicode(sanitized);
      sanitized = unicodeResult.cleaned;
      result.removedContent.push(...unicodeResult.removed);

      // Step 6: Apply custom blocked patterns
      const patternResult = this.applyBlockedPatterns(sanitized);
      sanitized = patternResult.cleaned;
      result.removedContent.push(...patternResult.removed);

      // Step 7: Final cleanup and validation
      sanitized = this.finalCleanup(sanitized);

      // Step 8: Length validation
      if (sanitized.length > this.config.maxContentLength) {
        sanitized = sanitized.substring(0, this.config.maxContentLength);
        result.warnings.push(`Content truncated to ${this.config.maxContentLength} characters`);
      }

      result.sanitized = sanitized;
      result.sanitizedLength = sanitized.length;
      result.isClean = result.securityThreats.length === 0 && result.removedContent.length === 0;

    } catch (error) {
      result.sanitized = this.emergencyCleanup(input);
      result.sanitizedLength = result.sanitized.length;
      result.securityThreats.push(`Sanitization error: ${error.message}`);
      result.isClean = false;
    }

    return result;
  }

  /**
   * PHASE 2 SECURITY: Remove HTML content with comprehensive tag detection
   */
  private removeHTMLContent(input: string): { cleaned: string; removed: string[]; threats: string[] } {
    const removed: string[] = [];
    const threats: string[] = [];
    let cleaned = input;

    // Dangerous HTML tags (comprehensive list)
    const dangerousTags = [
      'script', 'iframe', 'object', 'embed', 'applet', 'form', 'input', 'button',
      'select', 'textarea', 'option', 'meta', 'link', 'style', 'title', 'head',
      'body', 'html', 'base', 'frame', 'frameset', 'noframes', 'noscript',
      'xml', 'import', 'template', 'slot', 'shadow'
    ];

    // Remove dangerous tags with content
    for (const tag of dangerousTags) {
      const tagRegex = new RegExp(`<${tag}[^>]*>.*?<\\/${tag}>`, 'gis');
      const selfClosingRegex = new RegExp(`<${tag}[^>]*\\/>`, 'gis');
      
      const tagMatches = cleaned.match(tagRegex) || [];
      const selfClosingMatches = cleaned.match(selfClosingRegex) || [];
      
      if (tagMatches.length > 0 || selfClosingMatches.length > 0) {
        threats.push(`Dangerous HTML tag detected: ${tag}`);
        removed.push(...tagMatches, ...selfClosingMatches);
      }
      
      cleaned = cleaned.replace(tagRegex, '');
      cleaned = cleaned.replace(selfClosingRegex, '');
    }

    // Remove all remaining HTML tags if configured
    if (this.config.stripAllHTML) {
      const htmlTagRegex = /<[^>]*>/g;
      const htmlMatches = cleaned.match(htmlTagRegex) || [];
      if (htmlMatches.length > 0) {
        removed.push(...htmlMatches);
        cleaned = cleaned.replace(htmlTagRegex, '');
      }
    }

    // Remove dangerous HTML attributes
    const dangerousAttributes = [
      'onload', 'onerror', 'onclick', 'onmouseover', 'onmouseout', 'onfocus', 'onblur',
      'onchange', 'onsubmit', 'onreset', 'onkeydown', 'onkeyup', 'onkeypress',
      'javascript:', 'vbscript:', 'data:', 'on\\w+='
    ];

    for (const attr of dangerousAttributes) {
      const attrRegex = new RegExp(`${attr}[^\\s>]*`, 'gi');
      const attrMatches = cleaned.match(attrRegex) || [];
      if (attrMatches.length > 0) {
        threats.push(`Dangerous HTML attribute detected: ${attr}`);
        removed.push(...attrMatches);
        cleaned = cleaned.replace(attrRegex, '');
      }
    }

    return { cleaned, removed, threats };
  }

  /**
   * PHASE 2 SECURITY: Remove script content and JavaScript
   */
  private removeScriptContent(input: string): { cleaned: string; removed: string[]; threats: string[] } {
    const removed: string[] = [];
    const threats: string[] = [];
    let cleaned = input;

    // JavaScript patterns (comprehensive)
    const jsPatterns = [
      /javascript\s*:/gi,
      /vbscript\s*:/gi,
      /data\s*:\s*[^,]*script[^,]*,/gi,
      /eval\s*\(/gi,
      /setTimeout\s*\(/gi,
      /setInterval\s*\(/gi,
      /Function\s*\(/gi,
      /constructor\s*\(/gi,
      /document\s*\.\s*write/gi,
      /document\s*\.\s*writeln/gi,
      /document\s*\.\s*cookie/gi,
      /window\s*\.\s*location/gi,
      /location\s*\.\s*href/gi,
      /XMLHttpRequest/gi,
      /fetch\s*\(/gi,
      /WebSocket/gi,
      /EventSource/gi,
      /alert\s*\(/gi,
      /confirm\s*\(/gi,
      /prompt\s*\(/gi,
    ];

    for (const pattern of jsPatterns) {
      const matches = cleaned.match(pattern) || [];
      if (matches.length > 0) {
        threats.push(`JavaScript pattern detected: ${pattern.source}`);
        removed.push(...matches);
        cleaned = cleaned.replace(pattern, '');
      }
    }

    // Remove JavaScript comments
    const commentPatterns = [
      /\/\*[\s\S]*?\*\//g,
      /\/\/.*$/gm,
      /<!--[\s\S]*?-->/g
    ];

    for (const pattern of commentPatterns) {
      const matches = cleaned.match(pattern) || [];
      if (matches.length > 0) {
        removed.push(...matches);
        cleaned = cleaned.replace(pattern, '');
      }
    }

    return { cleaned, removed, threats };
  }

  /**
   * PHASE 2 SECURITY: Sanitize URLs and dangerous protocols
   */
  private sanitizeURLs(input: string): { cleaned: string; removed: string[]; threats: string[] } {
    const removed: string[] = [];
    const threats: string[] = [];
    let cleaned = input;

    // Dangerous URL protocols
    const dangerousProtocols = [
      'javascript:', 'vbscript:', 'data:', 'file:', 'ftp:', 'jar:',
      'view-source:', 'chrome:', 'resource:', 'moz-extension:',
      'chrome-extension:', 'ms-appx:', 'x-javascript:'
    ];

    for (const protocol of dangerousProtocols) {
      const protocolRegex = new RegExp(protocol.replace(':', '\\s*:\\s*'), 'gi');
      const matches = cleaned.match(protocolRegex) || [];
      if (matches.length > 0) {
        threats.push(`Dangerous URL protocol detected: ${protocol}`);
        removed.push(...matches);
        cleaned = cleaned.replace(protocolRegex, '');
      }
    }

    // Remove suspicious URL patterns
    const suspiciousUrlPatterns = [
      /data\s*:\s*[^,]*script[^,]*,/gi,
      /data\s*:\s*[^,]*html[^,]*,/gi,
      /data\s*:\s*[^,]*svg[^,]*,/gi,
    ];

    for (const pattern of suspiciousUrlPatterns) {
      const matches = cleaned.match(pattern) || [];
      if (matches.length > 0) {
        threats.push(`Suspicious URL pattern detected`);
        removed.push(...matches);
        cleaned = cleaned.replace(pattern, '');
      }
    }

    return { cleaned, removed, threats };
  }

  /**
   * PHASE 2 SECURITY: Context-specific sanitization
   */
  private contextSpecificSanitization(input: string, context: string): { cleaned: string; warnings: string[] } {
    const warnings: string[] = [];
    let cleaned = input;

    switch (context) {
      case 'message':
        // For messages, be extra strict about links and mentions
        cleaned = this.sanitizeMessageContent(cleaned);
        if (cleaned.length !== input.length) {
          warnings.push('Message content was sanitized for safety');
        }
        break;

      case 'profile':
      case 'bio':
        // For profiles, remove potentially personal information patterns
        cleaned = this.sanitizeProfileContent(cleaned);
        if (cleaned.length !== input.length) {
          warnings.push('Profile content was sanitized');
        }
        break;

      default:
        // General sanitization
        break;
    }

    return { cleaned, warnings };
  }

  private sanitizeMessageContent(input: string): string {
    let cleaned = input;

    // Remove suspicious message patterns
    const suspiciousPatterns = [
      /(?:click|visit|go\s+to)\s+(?:https?:\/\/|www\.)/gi,
      /(?:download|install)\s+(?:from|at)\s+[^\s]+/gi,
      /(?:send|transfer)\s+(?:money|cash|bitcoin|crypto)/gi,
    ];

    for (const pattern of suspiciousPatterns) {
      cleaned = cleaned.replace(pattern, '[FILTERED]');
    }

    return cleaned;
  }

  private sanitizeProfileContent(input: string): string {
    let cleaned = input;

    // Remove potential personal information patterns
    const personalInfoPatterns = [
      /\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/g, // Phone numbers
      /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/g, // Email addresses
      /\b\d{1,5}\s+\w+\s+(?:street|st|avenue|ave|road|rd|drive|dr|lane|ln|way|blvd|boulevard)\b/gi, // Addresses
    ];

    for (const pattern of personalInfoPatterns) {
      cleaned = cleaned.replace(pattern, '[REDACTED]');
    }

    return cleaned;
  }

  /**
   * PHASE 2 SECURITY: Sanitize dangerous Unicode characters
   */
  private sanitizeUnicode(input: string): { cleaned: string; removed: string[] } {
    const removed: string[] = [];
    let cleaned = input;

    // Remove dangerous Unicode characters
    const dangerousUnicodeRanges = [
      // Control characters (except tab, newline, carriage return)
      /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/g,
      // Right-to-left override (can be used for spoofing)
      /[\u202A-\u202E]/g,
      // Zero-width characters (can hide malicious content)
      /[\u200B-\u200D\u2060\uFEFF]/g,
      // Object replacement character
      /[\uFFFC]/g,
    ];

    for (const range of dangerousUnicodeRanges) {
      const matches = cleaned.match(range) || [];
      if (matches.length > 0) {
        removed.push(...matches);
        cleaned = cleaned.replace(range, '');
      }
    }

    return { cleaned, removed };
  }

  /**
   * PHASE 2 SECURITY: Apply custom blocked patterns
   */
  private applyBlockedPatterns(input: string): { cleaned: string; removed: string[] } {
    const removed: string[] = [];
    let cleaned = input;

    for (const pattern of this.config.blockedPatterns) {
      const matches = cleaned.match(pattern) || [];
      if (matches.length > 0) {
        removed.push(...matches);
        cleaned = cleaned.replace(pattern, '');
      }
    }

    return { cleaned, removed };
  }

  /**
   * PHASE 2 SECURITY: Final cleanup
   */
  private finalCleanup(input: string): string {
    let cleaned = input;

    // Normalize whitespace
    cleaned = cleaned.replace(/\s+/g, ' ');
    cleaned = cleaned.trim();

    // Remove excessive punctuation
    cleaned = cleaned.replace(/[!?]{4,}/g, '!!!');
    cleaned = cleaned.replace(/\.{4,}/g, '...');

    // Remove null bytes and other problematic characters
    cleaned = cleaned.replace(/\0/g, '');

    return cleaned;
  }

  /**
   * PHASE 2 SECURITY: Emergency cleanup for when normal sanitization fails
   */
  private emergencyCleanup(input: string): string {
    // Last resort: only allow alphanumeric, basic punctuation, and spaces
    return input.replace(/[^a-zA-Z0-9\s.,!?-]/g, '').substring(0, 100);
  }
}

// PHASE 2 SECURITY: Convenience functions for common use cases
const defaultXSSService = new XSSProtectionService();

export function sanitizeMessage(message: string): SanitizationResult {
  return defaultXSSService.sanitizeText(message, 'message');
}

export function sanitizeProfile(content: string): SanitizationResult {
  return defaultXSSService.sanitizeText(content, 'profile');
}

export function sanitizeBio(bio: string): SanitizationResult {
  return defaultXSSService.sanitizeText(bio, 'bio');
}

export function sanitizeGeneral(content: string): SanitizationResult {
  return defaultXSSService.sanitizeText(content, 'general');
}

// PHASE 2 SECURITY: Safe text validation
export function isTextSafe(input: string, context: 'message' | 'profile' | 'bio' | 'general' = 'general'): boolean {
  const result = defaultXSSService.sanitizeText(input, context);
  return result.isClean && result.securityThreats.length === 0;
}

export { XSSProtectionService };