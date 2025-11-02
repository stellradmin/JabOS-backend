/**
 * SECURE TOKEN MANAGER V2 - Production-Ready JWT Implementation
 * 
 * Implements proper AES-256-GCM encryption, secure key management,
 * and comprehensive token security for Stellr authentication.
 * 
 * SECURITY FIXES:
 * - Replaces weak base64 encoding with AES-256-GCM encryption
 * - Implements secure key derivation from environment variables
 * - Adds proper HMAC signature verification
 * - Implements secure random IV generation
 * - Adds comprehensive audit logging
 */

import { createHash, randomBytes } from 'https://deno.land/std@0.208.0/node/crypto.ts';

// Token Security Configuration
export interface TokenSecurityConfig {
  encryptionEnabled: boolean;
  encryptionKey?: string; // From environment
  signingKey?: string; // From environment
  tokenExpiration: number;
  refreshTokenExpiration: number;
  maxTokensPerUser: number;
  ipValidationEnabled: boolean;
  deviceTrackingEnabled: boolean;
  auditLoggingEnabled: boolean;
}

// Token Metadata
export interface TokenMetadata {
  tokenId: string;
  userId: string;
  deviceFingerprint?: string;
  ipAddress?: string;
  userAgent?: string;
  issuedAt: number;
  expiresAt: number;
  lastUsed: number;
  isRevoked: boolean;
  permissions?: string[];
}

// Token Validation Result
export interface TokenValidationResult {
  valid: boolean;
  expired: boolean;
  revoked: boolean;
  metadata?: TokenMetadata;
  errors: string[];
  userId?: string;
  tokenId?: string;
}

// Secure Token Payload
interface SecureTokenPayload {
  userId: string;
  tokenId: string;
  deviceFingerprint?: string;
  ipAddress?: string;
  issuedAt: number;
  expiresAt: number;
  permissions?: string[];
  sessionData?: Record<string, any>;
}

// Audit Log Entry
interface AuditLogEntry {
  timestamp: number;
  action: string;
  userId?: string;
  tokenId?: string;
  ipAddress?: string;
  result: 'success' | 'failure';
  details?: string;
}

export class SecureTokenManagerV2 {
  private config: TokenSecurityConfig;
  private activeTokens = new Map<string, TokenMetadata>();
  private revokedTokens = new Set<string>();
  private auditLog: AuditLogEntry[] = [];
  private encryptionKey?: CryptoKey;
  private signingKey?: CryptoKey;

  constructor(config: Partial<TokenSecurityConfig> = {}) {
    this.config = {
      encryptionEnabled: true,
      tokenExpiration: 15 * 60 * 1000, // 15 minutes
      refreshTokenExpiration: 7 * 24 * 60 * 60 * 1000, // 7 days
      maxTokensPerUser: 5,
      ipValidationEnabled: true,
      deviceTrackingEnabled: true,
      auditLoggingEnabled: true,
      ...config
    };

    // Initialize encryption keys
    this.initializeKeys();
  }

  /**
   * Initialize encryption and signing keys from environment
   */
  private async initializeKeys(): Promise<void> {
    const encryptionKeyString = this.config.encryptionKey || Deno.env.get('JWT_ENCRYPTION_KEY');
    const signingKeyString = this.config.signingKey || Deno.env.get('JWT_SIGNING_KEY');

    if (!encryptionKeyString || !signingKeyString) {
      throw new Error('JWT_ENCRYPTION_KEY and JWT_SIGNING_KEY must be set in environment');
    }

    // Derive encryption key using PBKDF2
    const encKeyMaterial = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(encryptionKeyString),
      'PBKDF2',
      false,
      ['deriveKey']
    );

    this.encryptionKey = await crypto.subtle.deriveKey(
      {
        name: 'PBKDF2',
        salt: new TextEncoder().encode('stellr-jwt-encryption-v2'),
        iterations: 100000,
        hash: 'SHA-256'
      },
      encKeyMaterial,
      { name: 'AES-GCM', length: 256 },
      false,
      ['encrypt', 'decrypt']
    );

    // Derive signing key
    const signKeyMaterial = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(signingKeyString),
      'PBKDF2',
      false,
      ['deriveKey']
    );

    this.signingKey = await crypto.subtle.deriveKey(
      {
        name: 'PBKDF2',
        salt: new TextEncoder().encode('stellr-jwt-signing-v2'),
        iterations: 100000,
        hash: 'SHA-256'
      },
      signKeyMaterial,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign', 'verify']
    );
  }

  /**
   * Generate secure token with AES-256-GCM encryption
   */
  async generateSecureToken(
    userId: string,
    context: {
      ipAddress?: string;
      userAgent?: string;
      deviceFingerprint?: string;
      permissions?: string[];
      sessionData?: Record<string, any>;
    } = {}
  ): Promise<{ token: string; refreshToken: string; metadata: TokenMetadata }> {
    const tokenId = this.generateSecureTokenId();
    const now = Date.now();
    const expiresAt = now + this.config.tokenExpiration;

    // Create token payload
    const payload: SecureTokenPayload = {
      userId,
      tokenId,
      deviceFingerprint: context.deviceFingerprint,
      ipAddress: context.ipAddress,
      issuedAt: now,
      expiresAt,
      permissions: context.permissions || [],
      sessionData: context.sessionData
    };

    // Encrypt token
    const token = await this.encryptAndSignToken(payload);

    // Generate refresh token
    const refreshToken = await this.generateRefreshToken(userId, tokenId);

    // Create metadata
    const metadata: TokenMetadata = {
      tokenId,
      userId,
      deviceFingerprint: context.deviceFingerprint,
      ipAddress: context.ipAddress,
      userAgent: context.userAgent,
      issuedAt: now,
      expiresAt,
      lastUsed: now,
      isRevoked: false,
      permissions: context.permissions
    };

    // Store token metadata
    this.activeTokens.set(tokenId, metadata);

    // Enforce token limit
    await this.enforceTokenLimit(userId);

    // Audit log
    this.logAudit({
      timestamp: now,
      action: 'token_generated',
      userId,
      tokenId,
      ipAddress: context.ipAddress,
      result: 'success'
    });

    return { token, refreshToken, metadata };
  }

  /**
   * Encrypt and sign token using AES-256-GCM
   */
  private async encryptAndSignToken(payload: SecureTokenPayload): Promise<string> {
    if (!this.encryptionKey || !this.signingKey) {
      throw new Error('Encryption keys not initialized');
    }

    // Generate random IV
    const iv = crypto.getRandomValues(new Uint8Array(12));

    // Encrypt payload
    const payloadBytes = new TextEncoder().encode(JSON.stringify(payload));
    const encryptedData = await crypto.subtle.encrypt(
      {
        name: 'AES-GCM',
        iv: iv
      },
      this.encryptionKey,
      payloadBytes
    );

    // Combine IV and encrypted data
    const combined = new Uint8Array(iv.length + encryptedData.byteLength);
    combined.set(iv, 0);
    combined.set(new Uint8Array(encryptedData), iv.length);

    // Sign the combined data
    const signature = await crypto.subtle.sign(
      'HMAC',
      this.signingKey,
      combined
    );

    // Encode as base64url
    const tokenData = {
      data: this.base64UrlEncode(combined),
      sig: this.base64UrlEncode(new Uint8Array(signature))
    };

    return `STV2.${this.base64UrlEncode(new TextEncoder().encode(JSON.stringify(tokenData)))}`;
  }

  /**
   * Validate token with comprehensive security checks
   */
  async validateToken(
    token: string,
    context: {
      ipAddress?: string;
      userAgent?: string;
      deviceFingerprint?: string;
    } = {}
  ): Promise<TokenValidationResult> {
    const result: TokenValidationResult = {
      valid: false,
      expired: false,
      revoked: false,
      errors: []
    };

    try {
      // Check token format
      if (!token.startsWith('STV2.')) {
        result.errors.push('Invalid token format');
        return result;
      }

      // Decrypt and verify token
      const payload = await this.decryptAndVerifyToken(token);
      if (!payload) {
        result.errors.push('Token decryption or verification failed');
        return result;
      }

      result.tokenId = payload.tokenId;
      result.userId = payload.userId;

      // Check if revoked
      if (this.revokedTokens.has(payload.tokenId)) {
        result.revoked = true;
        result.errors.push('Token has been revoked');
        return result;
      }

      // Check expiration
      const now = Date.now();
      if (payload.expiresAt < now) {
        result.expired = true;
        result.errors.push('Token has expired');
        return result;
      }

      // Get metadata
      const metadata = this.activeTokens.get(payload.tokenId);
      if (!metadata) {
        result.errors.push('Token metadata not found');
        return result;
      }

      result.metadata = metadata;

      // Security validations
      if (this.config.ipValidationEnabled && payload.ipAddress && context.ipAddress) {
        if (payload.ipAddress !== context.ipAddress) {
          result.errors.push('IP address mismatch');
        }
      }

      if (this.config.deviceTrackingEnabled && payload.deviceFingerprint && context.deviceFingerprint) {
        if (payload.deviceFingerprint !== context.deviceFingerprint) {
          result.errors.push('Device fingerprint mismatch');
        }
      }

      // Update last used
      metadata.lastUsed = now;
      this.activeTokens.set(payload.tokenId, metadata);

      result.valid = result.errors.length === 0;

      // Audit log
      this.logAudit({
        timestamp: now,
        action: 'token_validated',
        userId: payload.userId,
        tokenId: payload.tokenId,
        ipAddress: context.ipAddress,
        result: result.valid ? 'success' : 'failure',
        details: result.errors.join(', ')
      });

    } catch (error) {
      result.errors.push(`Validation error: ${error.message}`);
    }

    return result;
  }

  /**
   * Decrypt and verify token
   */
  private async decryptAndVerifyToken(token: string): Promise<SecureTokenPayload | null> {
    if (!this.encryptionKey || !this.signingKey) {
      throw new Error('Encryption keys not initialized');
    }

    try {
      // Extract token data
      const tokenPart = token.substring(5); // Remove 'STV2.'
      const tokenDataJson = new TextDecoder().decode(this.base64UrlDecode(tokenPart));
      const tokenData = JSON.parse(tokenDataJson);

      // Verify signature
      const data = this.base64UrlDecode(tokenData.data);
      const signature = this.base64UrlDecode(tokenData.sig);

      const isValid = await crypto.subtle.verify(
        'HMAC',
        this.signingKey,
        signature,
        data
      );

      if (!isValid) {
        return null;
      }

      // Extract IV and encrypted data
      const iv = data.slice(0, 12);
      const encryptedData = data.slice(12);

      // Decrypt
      const decrypted = await crypto.subtle.decrypt(
        {
          name: 'AES-GCM',
          iv: iv
        },
        this.encryptionKey,
        encryptedData
      );

      const payload = JSON.parse(new TextDecoder().decode(decrypted));
      return payload as SecureTokenPayload;

    } catch (error) {
      console.error('Token decryption error:', error);
      return null;
    }
  }

  /**
   * Generate secure refresh token
   */
  private async generateRefreshToken(userId: string, tokenId: string): Promise<string> {
    const refreshPayload = {
      userId,
      tokenId,
      type: 'refresh',
      issuedAt: Date.now(),
      expiresAt: Date.now() + this.config.refreshTokenExpiration,
      nonce: crypto.getRandomValues(new Uint8Array(16))
    };

    // Sign refresh token
    const data = new TextEncoder().encode(JSON.stringify(refreshPayload));
    const signature = await crypto.subtle.sign(
      'HMAC',
      this.signingKey!,
      data
    );

    return `STR2.${this.base64UrlEncode(data)}.${this.base64UrlEncode(new Uint8Array(signature))}`;
  }

  /**
   * Revoke token
   */
  async revokeToken(tokenId: string, reason: string = 'Manual revocation'): Promise<boolean> {
    const metadata = this.activeTokens.get(tokenId);
    if (!metadata) {
      return false;
    }

    // Mark as revoked
    metadata.isRevoked = true;
    this.revokedTokens.add(tokenId);
    this.activeTokens.delete(tokenId);

    // Audit log
    this.logAudit({
      timestamp: Date.now(),
      action: 'token_revoked',
      userId: metadata.userId,
      tokenId,
      result: 'success',
      details: reason
    });

    return true;
  }

  /**
   * Revoke all tokens for a user
   */
  async revokeAllUserTokens(userId: string, reason: string = 'Security revocation'): Promise<number> {
    let revokedCount = 0;

    for (const [tokenId, metadata] of this.activeTokens.entries()) {
      if (metadata.userId === userId) {
        await this.revokeToken(tokenId, reason);
        revokedCount++;
      }
    }

    return revokedCount;
  }

  /**
   * Enforce token limit per user
   */
  private async enforceTokenLimit(userId: string): Promise<void> {
    const userTokens = Array.from(this.activeTokens.values())
      .filter(token => token.userId === userId)
      .sort((a, b) => a.lastUsed - b.lastUsed);

    while (userTokens.length > this.config.maxTokensPerUser) {
      const oldestToken = userTokens.shift();
      if (oldestToken) {
        await this.revokeToken(oldestToken.tokenId, 'Token limit exceeded');
      }
    }
  }

  /**
   * Generate cryptographically secure token ID
   */
  private generateSecureTokenId(): string {
    const timestamp = Date.now().toString(36);
    const randomPart = this.base64UrlEncode(crypto.getRandomValues(new Uint8Array(16)));
    return `tok_${timestamp}_${randomPart}`;
  }

  /**
   * Base64URL encode
   */
  private base64UrlEncode(data: Uint8Array): string {
    const base64 = btoa(String.fromCharCode(...data));
    return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
  }

  /**
   * Base64URL decode
   */
  private base64UrlDecode(str: string): Uint8Array {
    const base64 = str.replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64 + '=='.substring(0, (4 - base64.length % 4) % 4);
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }

  /**
   * Log audit entry
   */
  private logAudit(entry: AuditLogEntry): void {
    if (this.config.auditLoggingEnabled) {
      this.auditLog.push(entry);
      
      // In production, send to logging service
      console.log('[TOKEN AUDIT]', JSON.stringify(entry));

      // Rotate audit log if too large
      if (this.auditLog.length > 10000) {
        this.auditLog = this.auditLog.slice(-5000);
      }
    }
  }

  /**
   * Get token statistics
   */
  getTokenStatistics(): {
    activeTokens: number;
    revokedTokens: number;
    tokensByUser: Record<string, number>;
    recentAuditEntries: AuditLogEntry[];
  } {
    const tokensByUser: Record<string, number> = {};

    for (const metadata of this.activeTokens.values()) {
      tokensByUser[metadata.userId] = (tokensByUser[metadata.userId] || 0) + 1;
    }

    return {
      activeTokens: this.activeTokens.size,
      revokedTokens: this.revokedTokens.size,
      tokensByUser,
      recentAuditEntries: this.auditLog.slice(-100)
    };
  }
}

// Export singleton instance
let tokenManager: SecureTokenManagerV2;

export function getTokenManager(config?: Partial<TokenSecurityConfig>): SecureTokenManagerV2 {
  if (!tokenManager) {
    tokenManager = new SecureTokenManagerV2(config);
  }
  return tokenManager;
}

// Convenience functions
export async function generateSecureToken(
  userId: string,
  context?: {
    ipAddress?: string;
    userAgent?: string;
    deviceFingerprint?: string;
    permissions?: string[];
  }
): Promise<{ token: string; refreshToken: string; metadata: TokenMetadata }> {
  return await getTokenManager().generateSecureToken(userId, context);
}

export async function validateSecureToken(
  token: string,
  context?: {
    ipAddress?: string;
    userAgent?: string;
    deviceFingerprint?: string;
  }
): Promise<TokenValidationResult> {
  return await getTokenManager().validateToken(token, context);
}

export async function revokeSecureToken(tokenId: string, reason?: string): Promise<boolean> {
  return await getTokenManager().revokeToken(tokenId, reason);
}