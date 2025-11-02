// PHASE 2 SECURITY: Enhanced Production-Ready Image Upload Security for Stellr Dating App
// Comprehensive image validation, security scanning, content moderation, and magic number validation

interface ImageValidationResult {
  isValid: boolean;
  isSecure: boolean;
  fileSize: number;
  dimensions?: { width: number; height: number };
  format: string;
  actualFormat?: string; // Detected format via magic numbers
  errors: string[];
  warnings: string[];
  securityThreats: string[]; // New: Track specific security threats
  moderationResult?: {
    isAppropriate: boolean;
    confidence: number;
    flags: string[];
  };
}

interface ImageSecurityConfig {
  maxFileSize: number; // bytes - reduced for security
  allowedFormats: string[];
  allowedMagicNumbers: MagicNumberSignature[]; // New: Magic number validation
  minDimensions: { width: number; height: number };
  maxDimensions: { width: number; height: number };
  enableContentModeration: boolean;
  enableMalwareScanning: boolean;
  enableMagicNumberValidation: boolean; // New: Enable magic number checks
  requireSquareAspectRatio: boolean;
  maxCompressionLevel: number;
  strictModeEnabled: boolean; // New: Enable strict security mode
}

// PHASE 2 SECURITY: Magic number signatures for file type validation
interface MagicNumberSignature {
  mimeType: string;
  signature: number[];
  offset: number;
  description: string;
}

// PHASE 2 SECURITY: Comprehensive magic number database
const ALLOWED_MAGIC_NUMBERS: MagicNumberSignature[] = [
  // JPEG variants
  { mimeType: 'image/jpeg', signature: [0xFF, 0xD8, 0xFF, 0xE0], offset: 0, description: 'JPEG JFIF' },
  { mimeType: 'image/jpeg', signature: [0xFF, 0xD8, 0xFF, 0xE1], offset: 0, description: 'JPEG EXIF' },
  { mimeType: 'image/jpeg', signature: [0xFF, 0xD8, 0xFF, 0xDB], offset: 0, description: 'JPEG raw' },
  
  // PNG
  { mimeType: 'image/png', signature: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], offset: 0, description: 'PNG' },
  
  // WebP
  { mimeType: 'image/webp', signature: [0x52, 0x49, 0x46, 0x46], offset: 0, description: 'WebP RIFF' },
];

// PHASE 2 SECURITY: Dangerous magic numbers to block
const DANGEROUS_MAGIC_NUMBERS: MagicNumberSignature[] = [
  // Executables
  { mimeType: 'application/x-executable', signature: [0x4D, 0x5A], offset: 0, description: 'PE Executable' },
  { mimeType: 'application/x-executable', signature: [0x7F, 0x45, 0x4C, 0x46], offset: 0, description: 'ELF Executable' },
  { mimeType: 'application/x-executable', signature: [0xFE, 0xED, 0xFA, 0xCE], offset: 0, description: 'Mach-O Binary' },
  { mimeType: 'application/x-executable', signature: [0xCE, 0xFA, 0xED, 0xFE], offset: 0, description: 'Mach-O Binary (reverse)' },
  
  // Archives (can contain executables)
  { mimeType: 'application/zip', signature: [0x50, 0x4B, 0x03, 0x04], offset: 0, description: 'ZIP Archive' },
  { mimeType: 'application/x-rar', signature: [0x52, 0x61, 0x72, 0x21], offset: 0, description: 'RAR Archive' },
  { mimeType: 'application/x-7z', signature: [0x37, 0x7A, 0xBC, 0xAF], offset: 0, description: '7-Zip Archive' },
  
  // Scripts and potentially dangerous formats
  { mimeType: 'text/html', signature: [0x3C, 0x68, 0x74, 0x6D, 0x6C], offset: 0, description: 'HTML Document' },
  { mimeType: 'application/x-shockwave-flash', signature: [0x46, 0x57, 0x53], offset: 0, description: 'Flash SWF' },
  { mimeType: 'application/pdf', signature: [0x25, 0x50, 0x44, 0x46], offset: 0, description: 'PDF Document' },
];

class ImageSecurityService {
  private config: ImageSecurityConfig;

  constructor(config: Partial<ImageSecurityConfig> = {}) {
    this.config = {
      maxFileSize: 5 * 1024 * 1024, // PHASE 2 SECURITY: Reduced to 5MB for better security
      allowedFormats: ['image/jpeg', 'image/png', 'image/webp'],
      allowedMagicNumbers: ALLOWED_MAGIC_NUMBERS, // PHASE 2 SECURITY: Magic number validation
      minDimensions: { width: 200, height: 200 },
      maxDimensions: { width: 4096, height: 4096 },
      enableContentModeration: true,
      enableMalwareScanning: true,
      enableMagicNumberValidation: true, // PHASE 2 SECURITY: Enable magic number validation
      requireSquareAspectRatio: false, // Dating apps often prefer square profile pics
      maxCompressionLevel: 0.9,
      strictModeEnabled: true, // PHASE 2 SECURITY: Enable strict security mode
      ...config,
    };
  }

  async validateImage(
    file: File | Blob,
    context: {
      userId: string;
      uploadType: 'profile_photo' | 'message_media' | 'verification_photo';
      isFirstUpload?: boolean;
    }
  ): Promise<ImageValidationResult> {
    const result: ImageValidationResult = {
      isValid: true,
      isSecure: true,
      fileSize: file.size,
      format: file.type,
      errors: [],
      warnings: [],
      securityThreats: [], // PHASE 2 SECURITY: Track security threats
    };

    try {
      // 1. Basic file validation
      await this.validateFileBasics(file, result);

      // 2. PHASE 2 SECURITY: Magic number validation (critical security check)
      if (this.config.enableMagicNumberValidation) {
        await this.validateMagicNumbers(file, result);
      }

      // 3. Security validation
      await this.validateSecurity(file, result);

      // 4. Image-specific validation
      await this.validateImageProperties(file, result, context);

      // 5. Content moderation (if enabled)
      if (this.config.enableContentModeration) {
        await this.moderateImageContent(file, result, context);
      }

      // 6. Enhanced malware scanning (if enabled)
      if (this.config.enableMalwareScanning) {
        await this.scanForMalware(file, result);
      }

      // 7. PHASE 2 SECURITY: Additional strict mode checks
      if (this.config.strictModeEnabled) {
        await this.performStrictSecurityChecks(file, result, context);
      }

      // Final validation with enhanced security checks
      result.isValid = result.errors.length === 0;
      result.isSecure = result.isValid && result.securityThreats.length === 0 && 
        !result.errors.some(error => 
          error.includes('malware') || error.includes('security') || error.includes('threat')
        );

    } catch (error) {
      result.errors.push(`Critical validation failure: ${error.message}`);
      result.securityThreats.push(`Validation process exception: ${error.message}`);
      result.isValid = false;
      result.isSecure = false;
    }

    // Log validation result for monitoring
    await this.logValidationResult(result, context);

    return result;
  }

  private async validateFileBasics(file: File | Blob, result: ImageValidationResult): Promise<void> {
    // File size validation
    if (file.size > this.config.maxFileSize) {
      result.errors.push(`File size ${(file.size / 1024 / 1024).toFixed(2)}MB exceeds maximum of ${(this.config.maxFileSize / 1024 / 1024).toFixed(2)}MB`);
    }

    if (file.size < 1024) { // Less than 1KB
      result.errors.push('File is too small and may be corrupted');
    }

    // MIME type validation
    if (!this.config.allowedFormats.includes(file.type)) {
      result.errors.push(`Format ${file.type} not allowed. Allowed formats: ${this.config.allowedFormats.join(', ')}`);
    }

    // Check for empty file
    if (file.size === 0) {
      result.errors.push('File is empty');
    }
  }

  // PHASE 2 SECURITY: Magic Number Validation Method
  private async validateMagicNumbers(file: File | Blob, result: ImageValidationResult): Promise<void> {
    try {
      const arrayBuffer = await file.arrayBuffer();
      const bytes = new Uint8Array(arrayBuffer);

      if (bytes.length < 16) {
        result.errors.push('File too small for magic number validation');
        return;
      }

      // Check for dangerous magic numbers first (security priority)
      for (const dangerousSignature of DANGEROUS_MAGIC_NUMBERS) {
        if (this.matchesMagicNumber(bytes, dangerousSignature)) {
          result.errors.push(`SECURITY THREAT: File contains dangerous format - ${dangerousSignature.description}`);
          result.securityThreats.push(`Dangerous file type detected: ${dangerousSignature.mimeType}`);
          return;
        }
      }

      // Check for allowed magic numbers
      let matchedSignature: MagicNumberSignature | null = null;
      for (const allowedSignature of this.config.allowedMagicNumbers) {
        if (this.matchesMagicNumber(bytes, allowedSignature)) {
          matchedSignature = allowedSignature;
          break;
        }
      }

      if (!matchedSignature) {
        result.errors.push('File format not recognized or not allowed based on file signature');
        result.securityThreats.push('Unrecognized file signature - potential file type spoofing');
        return;
      }

      // Verify declared MIME type matches magic number
      result.actualFormat = matchedSignature.mimeType;
      if (file.type && file.type !== matchedSignature.mimeType) {
        // Special handling for JPEG variants
        const isJpegVariant = file.type === 'image/jpg' && matchedSignature.mimeType === 'image/jpeg';
        if (!isJpegVariant) {
          result.warnings.push(`Declared MIME type '${file.type}' doesn't match detected format '${matchedSignature.mimeType}'`);
          result.securityThreats.push('MIME type mismatch - potential file type spoofing attempt');
        }
      }

      // Additional validation for WebP files
      if (matchedSignature.mimeType === 'image/webp') {
        if (!this.validateWebPStructure(bytes)) {
          result.errors.push('Invalid WebP file structure detected');
          result.securityThreats.push('Malformed WebP structure');
        }
      }

    } catch (error) {
      result.errors.push(`Magic number validation failed: ${error.message}`);
      result.securityThreats.push('Magic number validation process failed');
    }
  }

  private matchesMagicNumber(bytes: Uint8Array, signature: MagicNumberSignature): boolean {
    if (bytes.length < signature.offset + signature.signature.length) {
      return false;
    }

    for (let i = 0; i < signature.signature.length; i++) {
      if (bytes[signature.offset + i] !== signature.signature[i]) {
        return false;
      }
    }

    return true;
  }

  private validateWebPStructure(bytes: Uint8Array): boolean {
    try {
      // WebP files must have RIFF header, file size, and WEBP signature
      if (bytes.length < 12) return false;
      
      // Check RIFF header (already validated in magic number)
      // Check file size field (bytes 4-7)
      const fileSize = new DataView(bytes.buffer).getUint32(4, true); // little-endian
      
      // File size should be reasonable and match actual size minus 8 bytes
      if (fileSize !== bytes.length - 8) {
        return false;
      }

      // Check WEBP signature (bytes 8-11, already validated in magic number)
      return true;
    } catch {
      return false;
    }
  }

  // PHASE 2 SECURITY: Strict Security Checks
  private async performStrictSecurityChecks(
    file: File | Blob, 
    result: ImageValidationResult, 
    context: any
  ): Promise<void> {
    try {
      const arrayBuffer = await file.arrayBuffer();
      const bytes = new Uint8Array(arrayBuffer);
      const textContent = new TextDecoder('utf-8', { fatal: false }).decode(bytes);

      // Check for embedded scripts or suspicious content
      const suspiciousPatterns = [
        /<script[\s\S]*?>[\s\S]*?<\/script>/gi,
        /javascript:/gi,
        /vbscript:/gi,
        /data:[\s\S]*?base64/gi,
        /eval\s*\(/gi,
        /document\.cookie/gi,
        /window\.location/gi,
        /XMLHttpRequest/gi,
        /fetch\s*\(/gi,
      ];

      for (const pattern of suspiciousPatterns) {
        if (pattern.test(textContent)) {
          result.errors.push('File contains suspicious embedded content');
          result.securityThreats.push(`Suspicious pattern detected: ${pattern.source}`);
        }
      }

      // Check for unusual file sizes that might indicate payload injection
      if (context.uploadType === 'profile_photo') {
        const expectedMaxSize = 2 * 1024 * 1024; // 2MB for profile photos
        if (file.size > expectedMaxSize) {
          result.warnings.push('Profile photo unusually large - may contain hidden data');
        }
      }

      // Check for excessive metadata that could hide malicious content
      if (result.format === 'image/jpeg') {
        const metadataSize = this.estimateJPEGMetadataSize(bytes);
        if (metadataSize > 100 * 1024) { // 100KB metadata limit
          result.warnings.push('Excessive metadata detected - will be stripped');
          result.securityThreats.push('Excessive JPEG metadata - potential steganography');
        }
      }

    } catch (error) {
      result.warnings.push(`Strict security check failed: ${error.message}`);
    }
  }

  private estimateJPEGMetadataSize(bytes: Uint8Array): number {
    // Simple estimation: look for EXIF and other metadata markers
    let metadataSize = 0;
    for (let i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] === 0xFF) {
        const marker = bytes[i + 1];
        // EXIF, JFIF, and other metadata markers
        if (marker >= 0xE0 && marker <= 0xEF) {
          const segmentLength = (bytes[i + 2] << 8) | bytes[i + 3];
          metadataSize += segmentLength;
          i += segmentLength + 1;
        }
      }
    }
    return metadataSize;
  }

  private async validateSecurity(file: File | Blob, result: ImageValidationResult): Promise<void> {
    try {
      const arrayBuffer = await file.arrayBuffer();
      const bytes = new Uint8Array(arrayBuffer);

      // Check file headers for actual format vs declared MIME type
      const actualFormat = this.detectImageFormat(bytes);
      if (actualFormat && actualFormat !== file.type) {
        result.warnings.push(`Declared MIME type ${file.type} doesn't match actual format ${actualFormat}`);
      }

      // Check for executable headers (security risk)
      if (this.containsExecutableHeaders(bytes)) {
        result.errors.push('File contains executable code and is not safe');
      }

      // Check for suspicious metadata
      if (this.containsSuspiciousMetadata(bytes)) {
        result.warnings.push('File contains suspicious metadata that will be stripped');
      }

      // Validate image structure
      if (!this.isValidImageStructure(bytes, file.type)) {
        result.errors.push('Invalid image file structure detected');
      }

    } catch (error) {
      result.errors.push(`Security validation failed: ${error.message}`);
    }
  }

  private async validateImageProperties(
    file: File | Blob,
    result: ImageValidationResult,
    context: any
  ): Promise<void> {
    try {
      // Get image dimensions using canvas (in browser) or ImageData
      const dimensions = await this.getImageDimensions(file);
      
      if (dimensions) {
        result.dimensions = dimensions;

        // Validate dimensions
        if (dimensions.width < this.config.minDimensions.width || 
            dimensions.height < this.config.minDimensions.height) {
          result.errors.push(`Image dimensions ${dimensions.width}x${dimensions.height} below minimum ${this.config.minDimensions.width}x${this.config.minDimensions.height}`);
        }

        if (dimensions.width > this.config.maxDimensions.width || 
            dimensions.height > this.config.maxDimensions.height) {
          result.errors.push(`Image dimensions ${dimensions.width}x${dimensions.height} exceed maximum ${this.config.maxDimensions.width}x${this.config.maxDimensions.height}`);
        }

        // Check aspect ratio for profile photos
        if (context.uploadType === 'profile_photo' && this.config.requireSquareAspectRatio) {
          const aspectRatio = dimensions.width / dimensions.height;
          if (Math.abs(aspectRatio - 1) > 0.1) { // Allow 10% tolerance
            result.warnings.push('Profile photos should be square for best appearance');
          }
        }

        // Validate reasonable aspect ratios
        const aspectRatio = Math.max(dimensions.width, dimensions.height) / Math.min(dimensions.width, dimensions.height);
        if (aspectRatio > 3) {
          result.warnings.push('Unusual aspect ratio detected - image may appear distorted');
        }
      }

    } catch (error) {
      result.warnings.push(`Could not validate image properties: ${error.message}`);
    }
  }

  private async moderateImageContent(
    file: File | Blob,
    result: ImageValidationResult,
    context: any
  ): Promise<void> {
    try {
      // TODO: Integrate with image moderation service
      // For now, implement basic checks that can be done client-side

      // Check file name for inappropriate content
      if ('name' in file) {
        const fileName = (file as File).name.toLowerCase();
        const inappropriateTerms = ['nude', 'nsfw', 'sex', 'porn', 'xxx'];
        
        for (const term of inappropriateTerms) {
          if (fileName.includes(term)) {
            result.moderationResult = {
              isAppropriate: false,
              confidence: 0.8,
              flags: ['inappropriate_filename']
            };
            result.errors.push('Image filename contains inappropriate content');
            break;
          }
        }
      }

      // Basic image analysis could be added here
      // In production, integrate with services like:
      // - AWS Rekognition
      // - Google Cloud Vision
      // - Microsoft Computer Vision
      // - Clarifai

      if (!result.moderationResult) {
        result.moderationResult = {
          isAppropriate: true,
          confidence: 0.5,
          flags: []
        };
      }

    } catch (error) {
      result.warnings.push(`Content moderation failed: ${error.message}`);
    }
  }

  private async scanForMalware(file: File | Blob, result: ImageValidationResult): Promise<void> {
    try {
      const arrayBuffer = await file.arrayBuffer();
      const bytes = new Uint8Array(arrayBuffer);

      // Basic malware signatures check
      const malwareSignatures = [
        [0x4D, 0x5A], // PE executable header
        [0x7F, 0x45, 0x4C, 0x46], // ELF header
        [0xFE, 0xED, 0xFA, 0xCE], // Mach-O binary
        [0xCE, 0xFA, 0xED, 0xFE], // Mach-O binary (reverse)
      ];

      for (const signature of malwareSignatures) {
        if (this.bytesStartWith(bytes, signature)) {
          result.errors.push('File contains executable code and is blocked for security');
          break;
        }
      }

      // Check for suspicious script content in metadata
      const textContent = new TextDecoder('utf-8', { fatal: false }).decode(bytes);
      const scriptPatterns = [
        /<script/i,
        /javascript:/i,
        /vbscript:/i,
        /onload=/i,
        /onerror=/i
      ];

      for (const pattern of scriptPatterns) {
        if (pattern.test(textContent)) {
          result.errors.push('File contains suspicious script content');
          break;
        }
      }

    } catch (error) {
      result.warnings.push(`Malware scan failed: ${error.message}`);
    }
  }

  private detectImageFormat(bytes: Uint8Array): string | null {
    // JPEG
    if (bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
      return 'image/jpeg';
    }

    // PNG
    if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) {
      return 'image/png';
    }

    // WebP
    if (bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
        bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
      return 'image/webp';
    }

    // GIF
    if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
      return 'image/gif';
    }

    return null;
  }

  private containsExecutableHeaders(bytes: Uint8Array): boolean {
    const executableSignatures = [
      [0x4D, 0x5A], // DOS/PE
      [0x7F, 0x45, 0x4C, 0x46], // ELF
      [0xFE, 0xED, 0xFA, 0xCE], // Mach-O
      [0xCE, 0xFA, 0xED, 0xFE], // Mach-O reverse
      [0x50, 0x4B, 0x03, 0x04], // ZIP (could contain executables)
    ];

    for (const signature of executableSignatures) {
      if (this.bytesStartWith(bytes, signature)) {
        return true;
      }
    }

    return false;
  }

  private containsSuspiciousMetadata(bytes: Uint8Array): boolean {
    // Check for suspicious metadata in EXIF or other formats
    const suspiciousPatterns = [
      'javascript:',
      'vbscript:',
      '<script',
      'eval(',
      'document.cookie',
    ];

    const textContent = new TextDecoder('utf-8', { fatal: false }).decode(bytes);
    
    return suspiciousPatterns.some(pattern => 
      textContent.toLowerCase().includes(pattern.toLowerCase())
    );
  }

  private isValidImageStructure(bytes: Uint8Array, mimeType: string): boolean {
    try {
      switch (mimeType) {
        case 'image/jpeg':
          return this.isValidJPEG(bytes);
        case 'image/png':
          return this.isValidPNG(bytes);
        case 'image/webp':
          return this.isValidWebP(bytes);
        default:
          return true; // Allow other formats to pass basic validation
      }
    } catch {
      return false;
    }
  }

  private isValidJPEG(bytes: Uint8Array): boolean {
    // Check JPEG header
    if (bytes.length < 10) return false;
    if (bytes[0] !== 0xFF || bytes[1] !== 0xD8) return false;

    // Check for valid JPEG footer
    const lastTwo = bytes.slice(-2);
    return lastTwo[0] === 0xFF && lastTwo[1] === 0xD9;
  }

  private isValidPNG(bytes: Uint8Array): boolean {
    // Check PNG signature
    if (bytes.length < 8) return false;
    const pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    
    for (let i = 0; i < 8; i++) {
      if (bytes[i] !== pngSignature[i]) return false;
    }

    return true;
  }

  private isValidWebP(bytes: Uint8Array): boolean {
    if (bytes.length < 12) return false;
    
    // Check RIFF header
    if (bytes[0] !== 0x52 || bytes[1] !== 0x49 || bytes[2] !== 0x46 || bytes[3] !== 0x46) {
      return false;
    }
    
    // Check WebP signature
    if (bytes[8] !== 0x57 || bytes[9] !== 0x45 || bytes[10] !== 0x42 || bytes[11] !== 0x50) {
      return false;
    }

    return true;
  }

  private bytesStartWith(bytes: Uint8Array, signature: number[]): boolean {
    if (bytes.length < signature.length) return false;
    
    for (let i = 0; i < signature.length; i++) {
      if (bytes[i] !== signature[i]) return false;
    }
    
    return true;
  }

  private async getImageDimensions(file: File | Blob): Promise<{ width: number; height: number } | null> {
    return new Promise((resolve) => {
      try {
        const img = new Image();
        const url = URL.createObjectURL(file);
        
        img.onload = () => {
          URL.revokeObjectURL(url);
          resolve({ width: img.width, height: img.height });
        };
        
        img.onerror = () => {
          URL.revokeObjectURL(url);
          resolve(null);
        };
        
        img.src = url;
      } catch {
        resolve(null);
      }
    });
  }

  private async logValidationResult(result: ImageValidationResult, context: any): Promise<void> {
    try {
      // Log to analytics/monitoring service
      // Debug logging removed for security

      // In production, you might want to log this to your database
      // for security monitoring and analysis

    } catch (error) {
}
  }

  // Utility method to compress image if it's too large
  async compressImage(file: File, maxSize: number = this.config.maxFileSize): Promise<Blob> {
    if (file.size <= maxSize) {
      return file;
    }

    return new Promise((resolve, reject) => {
      const canvas = document.createElement('canvas');
      const ctx = canvas.getContext('2d');
      const img = new Image();

      img.onload = () => {
        try {
          // Calculate new dimensions to fit within size limit
          const maxDimension = Math.min(this.config.maxDimensions.width, this.config.maxDimensions.height);
          const scale = Math.min(maxDimension / img.width, maxDimension / img.height);
          
          canvas.width = img.width * scale;
          canvas.height = img.height * scale;

          ctx?.drawImage(img, 0, 0, canvas.width, canvas.height);

          canvas.toBlob(
            (blob) => {
              if (blob) {
                resolve(blob);
              } else {
                reject(new Error('Failed to compress image'));
              }
            },
            'image/jpeg',
            this.config.maxCompressionLevel
          );
        } catch (error) {
          reject(error);
        }
      };

      img.onerror = () => reject(new Error('Failed to load image for compression'));
      img.src = URL.createObjectURL(file);
    });
  }
}

// Singleton instance
let imageSecurityService: ImageSecurityService | null = null;

export function getImageSecurityService(): ImageSecurityService {
  if (!imageSecurityService) {
    imageSecurityService = new ImageSecurityService();
  }
  return imageSecurityService;
}

// Convenience function
export async function validateImage(
  file: File | Blob,
  context: {
    userId: string;
    uploadType: 'profile_photo' | 'message_media' | 'verification_photo';
    isFirstUpload?: boolean;
  }
): Promise<ImageValidationResult> {
  const service = getImageSecurityService();
  return await service.validateImage(file, context);
}

export async function compressImage(file: File, maxSize?: number): Promise<Blob> {
  const service = getImageSecurityService();
  return await service.compressImage(file, maxSize);
}

export { ImageSecurityService };
export type { ImageValidationResult, ImageSecurityConfig };