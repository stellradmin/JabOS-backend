/**
 * PHASE 2 SECURITY: Secure File Handling Middleware for Stellr Edge Functions
 * 
 * Comprehensive file upload security middleware with malware scanning preparation,
 * quarantine system, and advanced threat detection capabilities.
 */

import { validateImage, ImageValidationResult } from './image-security.ts';
import { logSecurityEvent } from './enhanced-error-handler.ts';

// PHASE 2 SECURITY: File Security Configuration
export interface SecureFileConfig {
  maxFileSize: number;
  allowedMimeTypes: string[];
  quarantineEnabled: boolean;
  malwareScanningEnabled: boolean;
  autoDeleteMalicious: boolean;
  virusTotalEnabled: boolean; // For future VirusTotal integration
  metadataStripping: boolean;
  duplicateDetection: boolean;
}

// PHASE 2 SECURITY: File Upload Context
export interface FileUploadContext {
  userId: string;
  uploadType: 'profile_photo' | 'message_media' | 'verification_photo';
  clientIP?: string;
  userAgent?: string;
  requestId: string;
  sessionId?: string;
}

// PHASE 2 SECURITY: File Security Result
export interface FileSecurityResult {
  allowed: boolean;
  secure: boolean;
  fileId?: string;
  quarantined: boolean;
  threatLevel: 'none' | 'low' | 'medium' | 'high' | 'critical';
  detectedThreats: string[];
  sanitizedFile?: Blob;
  errors: string[];
  warnings: string[];
  scanResults?: {
    clamav?: { clean: boolean; signature?: string };
    virustotal?: { detected: number; total: number };
    imageValidation: ImageValidationResult;
  };
}

// PHASE 2 SECURITY: Quarantine System
class FileQuarantineSystem {
  private static quarantinedFiles = new Map<string, {
    file: Blob;
    context: FileUploadContext;
    quarantineTime: number;
    threatLevel: string;
    detectedThreats: string[];
  }>();

  static quarantineFile(
    fileId: string, 
    file: Blob, 
    context: FileUploadContext, 
    threatLevel: string, 
    threats: string[]
  ): void {
    this.quarantinedFiles.set(fileId, {
      file,
      context,
      quarantineTime: Date.now(),
      threatLevel,
      detectedThreats: threats
    });

    // Auto-cleanup after 24 hours
    setTimeout(() => {
      this.quarantinedFiles.delete(fileId);
    }, 24 * 60 * 60 * 1000);
  }

  static getQuarantinedFile(fileId: string): any {
    return this.quarantinedFiles.get(fileId);
  }

  static getQuarantineStats(): any {
    const stats = {
      totalQuarantined: this.quarantinedFiles.size,
      threatLevels: { critical: 0, high: 0, medium: 0, low: 0 },
      oldestQuarantine: 0,
      newestQuarantine: 0
    };

    let oldest = Date.now();
    let newest = 0;

    this.quarantinedFiles.forEach((entry) => {
      stats.threatLevels[entry.threatLevel as keyof typeof stats.threatLevels]++;
      oldest = Math.min(oldest, entry.quarantineTime);
      newest = Math.max(newest, entry.quarantineTime);
    });

    stats.oldestQuarantine = oldest;
    stats.newestQuarantine = newest;

    return stats;
  }
}

// PHASE 2 SECURITY: Secure File Handler Class
export class SecureFileHandler {
  private config: SecureFileConfig;

  constructor(config: Partial<SecureFileConfig> = {}) {
    this.config = {
      maxFileSize: 5 * 1024 * 1024, // 5MB
      allowedMimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
      quarantineEnabled: true,
      malwareScanningEnabled: true,
      autoDeleteMalicious: false, // Keep for investigation
      virusTotalEnabled: false, // For future implementation
      metadataStripping: true,
      duplicateDetection: true,
      ...config
    };
  }

  async processFile(
    file: File | Blob, 
    context: FileUploadContext
  ): Promise<FileSecurityResult> {
    const fileId = this.generateFileId();
    const result: FileSecurityResult = {
      allowed: false,
      secure: false,
      fileId,
      quarantined: false,
      threatLevel: 'none',
      detectedThreats: [],
      errors: [],
      warnings: [],
      scanResults: {
        imageValidation: {} as ImageValidationResult
      }
    };

    try {
      // Step 1: Basic file validation
      await this.validateBasicFile(file, result);
      if (!result.allowed) {
        return result;
      }

      // Step 2: Image security validation
      result.scanResults!.imageValidation = await validateImage(file, {
        userId: context.userId,
        uploadType: context.uploadType,
        isFirstUpload: false
      });

      if (!result.scanResults!.imageValidation.isSecure) {
        result.detectedThreats.push(...result.scanResults!.imageValidation.securityThreats || []);
        result.threatLevel = this.calculateThreatLevel(result.detectedThreats);
      }

      // Step 3: Malware scanning preparation
      if (this.config.malwareScanningEnabled) {
        await this.prepareMalwareScanning(file, result, context);
      }

      // Step 4: Metadata stripping
      if (this.config.metadataStripping) {
        result.sanitizedFile = await this.stripMetadata(file, result);
      }

      // Step 5: Duplicate detection
      if (this.config.duplicateDetection) {
        await this.checkForDuplicates(file, result, context);
      }

      // Step 6: Final security assessment
      result.secure = this.assessOverallSecurity(result);
      result.allowed = result.secure && result.threatLevel !== 'critical';

      // Step 7: Quarantine if necessary
      if (!result.secure && this.config.quarantineEnabled) {
        FileQuarantineSystem.quarantineFile(
          fileId,
          file,
          context,
          result.threatLevel,
          result.detectedThreats
        );
        result.quarantined = true;
      }

      // Step 8: Security logging
      await this.logSecurityEvents(result, context);

    } catch (error) {
      result.errors.push(`File processing failed: ${error.message}`);
      result.detectedThreats.push('Processing exception occurred');
      result.threatLevel = 'high';
      result.allowed = false;
      result.secure = false;
    }

    return result;
  }

  private async validateBasicFile(file: File | Blob, result: FileSecurityResult): Promise<void> {
    // File size check
    if (file.size > this.config.maxFileSize) {
      result.errors.push(`File size ${(file.size / 1024 / 1024).toFixed(2)}MB exceeds maximum ${(this.config.maxFileSize / 1024 / 1024).toFixed(2)}MB`);
      return;
    }

    if (file.size === 0) {
      result.errors.push('Empty file not allowed');
      return;
    }

    // MIME type check
    if (!this.config.allowedMimeTypes.includes(file.type)) {
      result.errors.push(`File type ${file.type} not allowed`);
      result.detectedThreats.push('Disallowed file type');
      return;
    }

    result.allowed = true;
  }

  private async prepareMalwareScanning(
    file: File | Blob, 
    result: FileSecurityResult, 
    context: FileUploadContext
  ): Promise<void> {
    try {
      // PHASE 2 SECURITY: Preparation for external malware scanning services
      // This sets up the infrastructure for integrating with ClamAV, VirusTotal, etc.
      
      const arrayBuffer = await file.arrayBuffer();
      const bytes = new Uint8Array(arrayBuffer);
      const fileHash = await this.calculateFileHash(bytes);
      
      // Basic signature-based detection (preparation for full scanning)
      const suspiciousSignatures = await this.checkKnownMalwareSignatures(bytes);
      if (suspiciousSignatures.length > 0) {
        result.detectedThreats.push(...suspiciousSignatures);
        result.threatLevel = 'high';
      }

      // Entropy analysis (high entropy might indicate packed/encrypted malware)
      const entropy = this.calculateEntropy(bytes);
      if (entropy > 7.5) { // High entropy threshold
        result.warnings.push('High file entropy detected - may contain compressed/encrypted data');
        result.detectedThreats.push('High entropy content');
      }

      // TODO: Implement actual ClamAV integration
      // result.scanResults!.clamav = await this.scanWithClamAV(bytes);
      
      // TODO: Implement VirusTotal integration if enabled
      // if (this.config.virusTotalEnabled) {
      //   result.scanResults!.virustotal = await this.scanWithVirusTotal(fileHash);
      // }

      // For now, mark as prepared for scanning
      result.warnings.push('File prepared for malware scanning - integrate ClamAV/VirusTotal for production');

    } catch (error) {
      result.warnings.push(`Malware scanning preparation failed: ${error.message}`);
    }
  }

  private async checkKnownMalwareSignatures(bytes: Uint8Array): Promise<string[]> {
    const threats: string[] = [];
    
    // Known malware signatures (simplified for demo)
    const malwareSignatures = [
      { name: 'EICAR Test String', pattern: new TextEncoder().encode('X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*') },
      // Add more signatures as needed
    ];

    for (const signature of malwareSignatures) {
      if (this.bytesContain(bytes, signature.pattern)) {
        threats.push(`Known malware signature: ${signature.name}`);
      }
    }

    return threats;
  }

  private bytesContain(haystack: Uint8Array, needle: Uint8Array): boolean {
    for (let i = 0; i <= haystack.length - needle.length; i++) {
      let found = true;
      for (let j = 0; j < needle.length; j++) {
        if (haystack[i + j] !== needle[j]) {
          found = false;
          break;
        }
      }
      if (found) return true;
    }
    return false;
  }

  private calculateEntropy(bytes: Uint8Array): number {
    const frequency = new Array(256).fill(0);
    
    // Count byte frequencies
    for (const byte of bytes) {
      frequency[byte]++;
    }
    
    // Calculate Shannon entropy
    let entropy = 0;
    const length = bytes.length;
    
    for (const count of frequency) {
      if (count > 0) {
        const probability = count / length;
        entropy -= probability * Math.log2(probability);
      }
    }
    
    return entropy;
  }

  private async calculateFileHash(bytes: Uint8Array): Promise<string> {
    const hashBuffer = await crypto.subtle.digest('SHA-256', bytes);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
  }

  private async stripMetadata(file: File | Blob, result: FileSecurityResult): Promise<Blob> {
    try {
      // For now, return the original file
      // TODO: Implement actual metadata stripping for JPEG/PNG files
      result.warnings.push('Metadata stripping prepared - implement exif-js or similar for production');
      return file;
    } catch (error) {
      result.warnings.push(`Metadata stripping failed: ${error.message}`);
      return file;
    }
  }

  private async checkForDuplicates(
    file: File | Blob, 
    result: FileSecurityResult, 
    context: FileUploadContext
  ): Promise<void> {
    try {
      const arrayBuffer = await file.arrayBuffer();
      const bytes = new Uint8Array(arrayBuffer);
      const hash = await this.calculateFileHash(bytes);
      
      // TODO: Check against database of known file hashes
      // For now, just log the hash for future duplicate detection
      result.warnings.push(`File hash calculated: ${hash.substring(0, 16)}... (implement duplicate DB check)`);
    } catch (error) {
      result.warnings.push(`Duplicate detection failed: ${error.message}`);
    }
  }

  private calculateThreatLevel(threats: string[]): 'none' | 'low' | 'medium' | 'high' | 'critical' {
    if (threats.length === 0) return 'none';
    
    const criticalThreats = threats.filter(t => 
      t.includes('malware') || t.includes('executable') || t.includes('virus')
    );
    if (criticalThreats.length > 0) return 'critical';
    
    const highThreats = threats.filter(t => 
      t.includes('suspicious') || t.includes('dangerous') || t.includes('spoofing')
    );
    if (highThreats.length > 0) return 'high';
    
    const mediumThreats = threats.filter(t => 
      t.includes('entropy') || t.includes('metadata') || t.includes('structure')
    );
    if (mediumThreats.length > 0) return 'medium';
    
    return 'low';
  }

  private assessOverallSecurity(result: FileSecurityResult): boolean {
    return result.threatLevel === 'none' || result.threatLevel === 'low';
  }

  private async logSecurityEvents(result: FileSecurityResult, context: FileUploadContext): Promise<void> {
    if (result.detectedThreats.length > 0) {
      await logSecurityEvent('file_security_threat', {
        fileId: result.fileId,
        userId: context.userId,
        uploadType: context.uploadType,
        threatLevel: result.threatLevel,
        detectedThreats: result.detectedThreats,
        quarantined: result.quarantined,
        allowed: result.allowed,
        clientIP: context.clientIP,
        userAgent: context.userAgent
      });
    }
  }

  private generateFileId(): string {
    return `file_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
  }
}

// PHASE 2 SECURITY: Convenience Functions
export async function processSecureFile(
  file: File | Blob, 
  context: FileUploadContext,
  config?: Partial<SecureFileConfig>
): Promise<FileSecurityResult> {
  const handler = new SecureFileHandler(config);
  return await handler.processFile(file, context);
}

export function getQuarantineStats(): any {
  return FileQuarantineSystem.getQuarantineStats();
}

export { FileQuarantineSystem };