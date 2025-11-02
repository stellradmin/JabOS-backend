/**
 * PHASE 3 SECURITY: API Versioning Strategy & Middleware
 * 
 * Comprehensive API versioning system with deprecation handling
 * Supports multiple version formats and backward compatibility
 */

import { getCorsHeaders } from './cors.ts';
import { getResponseSecurityHeaders } from './security-validation.ts';

/**
 * Supported API versions
 */
export const API_VERSIONS = {
  V1: 'v1',
  V2: 'v2', // Future version
} as const;

/**
 * Version information interface
 */
export interface ApiVersionInfo {
  version: string;
  status: 'current' | 'deprecated' | 'sunset';
  deprecationDate?: string;
  sunsetDate?: string;
  supportedUntil?: string;
  migrationGuide?: string;
  breaking_changes?: string[];
}

/**
 * API version registry with metadata
 */
export const VERSION_REGISTRY: Record<string, ApiVersionInfo> = {
  [API_VERSIONS.V1]: {
    version: 'v1',
    status: 'current',
    supportedUntil: '2026-01-01',
    migrationGuide: '/docs/api/v1-to-v2-migration',
  },
  [API_VERSIONS.V2]: {
    version: 'v2',
    status: 'current', // Will be future version
    breaking_changes: [
      'Response format changes for user profiles',
      'New authentication flow requirements',
      'Updated rate limiting structure'
    ]
  }
};

/**
 * Version compatibility matrix
 */
export const VERSION_COMPATIBILITY = {
  [API_VERSIONS.V1]: {
    supports: ['basic_auth', 'legacy_responses', 'old_error_format'],
    requires: ['user_agent_header'],
  },
  [API_VERSIONS.V2]: {
    supports: ['enhanced_auth', 'structured_responses', 'detailed_errors'],
    requires: ['api_key_header', 'content_type_json'],
  },
};

/**
 * Request version context
 */
export interface VersionContext {
  requestedVersion: string;
  resolvedVersion: string;
  isSupported: boolean;
  isDeprecated: boolean;
  deprecationWarnings: string[];
  compatibilityMode: string[];
}

/**
 * Extract API version from request
 */
export function extractApiVersion(request: Request): string {
  const url = new URL(request.url);
  
  // Method 1: URL path version (preferred)
  // Example: /v1/users, /v2/matches
  const pathMatch = url.pathname.match(/^\/?(v\d+)\//);
  if (pathMatch) {
    return pathMatch[1];
  }

  // Method 2: Accept header version
  // Example: Accept: application/vnd.stellr.v1+json
  const acceptHeader = request.headers.get('accept');
  if (acceptHeader) {
    const acceptMatch = acceptHeader.match(/application\/vnd\.stellr\.(v\d+)\+json/);
    if (acceptMatch) {
      return acceptMatch[1];
    }
  }

  // Method 3: Custom version header
  // Example: X-API-Version: v1
  const versionHeader = request.headers.get('x-api-version') || 
                        request.headers.get('api-version');
  if (versionHeader) {
    return versionHeader.toLowerCase().startsWith('v') ? 
           versionHeader.toLowerCase() : 
           `v${versionHeader}`;
  }

  // Method 4: Query parameter (fallback)
  // Example: ?version=v1
  const versionParam = url.searchParams.get('version') || 
                       url.searchParams.get('v');
  if (versionParam) {
    return versionParam.toLowerCase().startsWith('v') ? 
           versionParam.toLowerCase() : 
           `v${versionParam}`;
  }

  // Default to latest stable version
  return API_VERSIONS.V1;
}

/**
 * Validate and resolve API version
 */
export function resolveApiVersion(requestedVersion: string): VersionContext {
  const normalizedVersion = requestedVersion.toLowerCase();
  const versionInfo = VERSION_REGISTRY[normalizedVersion];
  
  const context: VersionContext = {
    requestedVersion,
    resolvedVersion: normalizedVersion,
    isSupported: false,
    isDeprecated: false,
    deprecationWarnings: [],
    compatibilityMode: [],
  };

  if (!versionInfo) {
    // Try to find a compatible version
    const availableVersions = Object.keys(VERSION_REGISTRY);
    const latestVersion = availableVersions[availableVersions.length - 1];
    
    context.resolvedVersion = latestVersion;
    context.compatibilityMode = ['unsupported_version_fallback'];
    context.deprecationWarnings.push(
      `API version '${requestedVersion}' is not supported. Falling back to '${latestVersion}'.`
    );
  } else {
    context.isSupported = true;
    
    // Check deprecation status
    if (versionInfo.status === 'deprecated') {
      context.isDeprecated = true;
      context.deprecationWarnings.push(
        `API version '${normalizedVersion}' is deprecated.`
      );
      
      if (versionInfo.deprecationDate) {
        context.deprecationWarnings.push(
          `Deprecated since: ${versionInfo.deprecationDate}`
        );
      }
      
      if (versionInfo.sunsetDate) {
        context.deprecationWarnings.push(
          `Will be sunset on: ${versionInfo.sunsetDate}`
        );
      }
      
      if (versionInfo.migrationGuide) {
        context.deprecationWarnings.push(
          `Migration guide: ${versionInfo.migrationGuide}`
        );
      }
    }
    
    if (versionInfo.status === 'sunset') {
      context.isSupported = false;
      context.deprecationWarnings.push(
        `API version '${normalizedVersion}' has been sunset and is no longer supported.`
      );
    }
  }

  return context;
}

/**
 * Apply version-specific transformations to request data
 */
export function transformRequestData(data: any, version: string): any {
  switch (version) {
    case API_VERSIONS.V1:
      return transformV1Request(data);
      
    case API_VERSIONS.V2:
      return transformV2Request(data);
      
    default:
      return data;
  }
}

/**
 * Apply version-specific transformations to response data
 */
export function transformResponseData(data: any, version: string): any {
  switch (version) {
    case API_VERSIONS.V1:
      return transformV1Response(data);
      
    case API_VERSIONS.V2:
      return transformV2Response(data);
      
    default:
      return data;
  }
}

/**
 * V1 request transformation
 */
function transformV1Request(data: any): any {
  // Handle legacy field names, data structures
  if (data && typeof data === 'object') {
    const transformed = { ...data };
    
    // Example: Convert new field names to legacy ones
    if ('displayName' in transformed) {
      transformed.display_name = transformed.displayName;
      delete transformed.displayName;
    }
    
    // Example: Handle legacy boolean representations
    if ('isActive' in transformed) {
      transformed.is_active = transformed.isActive ? 1 : 0;
      delete transformed.isActive;
    }
    
    return transformed;
  }
  
  return data;
}

/**
 * V2 request transformation
 */
function transformV2Request(data: any): any {
  // V2 uses modern field names and structures
  return data;
}

/**
 * V1 response transformation
 */
function transformV1Response(data: any): any {
  if (data && typeof data === 'object') {
    const transformed = { ...data };
    
    // Convert snake_case to camelCase for V1 compatibility
    Object.keys(transformed).forEach(key => {
      if (key.includes('_')) {
        const camelKey = key.replace(/_([a-z])/g, (_, letter) => letter.toUpperCase());
        transformed[camelKey] = transformed[key];
        delete transformed[key];
      }
    });
    
    // Legacy error format
    if ('error' in transformed && typeof transformed.error === 'object') {
      transformed.error_message = transformed.error.message || transformed.error;
      transformed.error_code = transformed.error.code || 'UNKNOWN_ERROR';
    }
    
    return transformed;
  }
  
  return data;
}

/**
 * V2 response transformation
 */
function transformV2Response(data: any): any {
  if (data && typeof data === 'object') {
    const transformed = { ...data };
    
    // Enhanced error structure for V2
    if ('error' in transformed && typeof transformed.error === 'string') {
      transformed.error = {
        message: transformed.error,
        code: 'GENERAL_ERROR',
        timestamp: new Date().toISOString(),
        version: 'v2'
      };
    }
    
    // Add metadata for V2 responses
    if (!('meta' in transformed)) {
      transformed.meta = {
        version: 'v2',
        timestamp: new Date().toISOString(),
        requestId: crypto.randomUUID(),
      };
    }
    
    return transformed;
  }
  
  return data;
}

/**
 * Create version-aware response headers
 */
export function createVersionHeaders(context: VersionContext): Record<string, string> {
  const headers: Record<string, string> = {
    'X-API-Version': context.resolvedVersion,
    'X-API-Version-Requested': context.requestedVersion,
  };

  if (context.isDeprecated) {
    headers['X-API-Deprecated'] = 'true';
    headers['Sunset'] = VERSION_REGISTRY[context.resolvedVersion]?.sunsetDate || '';
  }

  if (context.deprecationWarnings.length > 0) {
    headers['X-API-Deprecation-Warning'] = context.deprecationWarnings.join('; ');
  }

  if (context.compatibilityMode.length > 0) {
    headers['X-API-Compatibility-Mode'] = context.compatibilityMode.join(',');
  }

  // Link to documentation
  headers['Link'] = `</docs/api/${context.resolvedVersion}>; rel="documentation"`;

  return headers;
}

/**
 * Create version-incompatible error response
 */
export function createVersionErrorResponse(
  context: VersionContext, 
  statusCode: number = 400
): Response {
  const corsHeaders = getCorsHeaders();
  const securityHeaders = getResponseSecurityHeaders('application/json', false);
  const versionHeaders = createVersionHeaders(context);

  const errorData = {
    error: 'API Version Error',
    message: context.deprecationWarnings.join(' '),
    requestedVersion: context.requestedVersion,
    supportedVersions: Object.keys(VERSION_REGISTRY),
    timestamp: new Date().toISOString(),
  };

  // Apply version-specific response format
  const transformedData = transformResponseData(errorData, context.resolvedVersion);

  return new Response(
    JSON.stringify(transformedData),
    {
      status: statusCode,
      headers: {
        ...corsHeaders,
        ...securityHeaders,
        ...versionHeaders,
        'Content-Type': 'application/json',
      },
    }
  );
}

/**
 * Main API versioning middleware
 */
export async function applyApiVersioning(
  request: Request,
  handler: (request: Request, context: VersionContext) => Promise<Response>
): Promise<Response> {
  try {
    // Extract and resolve API version
    const requestedVersion = extractApiVersion(request);
    const versionContext = resolveApiVersion(requestedVersion);

    // Reject sunset versions
    if (VERSION_REGISTRY[versionContext.resolvedVersion]?.status === 'sunset') {
      return createVersionErrorResponse(versionContext, 410); // Gone
    }

    // Execute the handler with version context
    const response = await handler(request, versionContext);

    // Add version headers to response
    const versionHeaders = createVersionHeaders(versionContext);
    Object.entries(versionHeaders).forEach(([key, value]) => {
      response.headers.set(key, value);
    });

    return response;
  } catch (error) {
    // Fallback error handling
    const corsHeaders = getCorsHeaders();
    const securityHeaders = getResponseSecurityHeaders('application/json', false);

    return new Response(
      JSON.stringify({
        error: 'API Versioning Error',
        message: 'Failed to process API version',
        timestamp: new Date().toISOString(),
      }),
      {
        status: 500,
        headers: {
          ...corsHeaders,
          ...securityHeaders,
          'Content-Type': 'application/json',
        },
      }
    );
  }
}

/**
 * Utility function to check if version supports feature
 */
export function supportsFeature(version: string, feature: string): boolean {
  const compatibility = VERSION_COMPATIBILITY[version];
  return compatibility?.supports.includes(feature) || false;
}

/**
 * Utility function to check if version requires feature
 */
export function requiresFeature(version: string, feature: string): boolean {
  const compatibility = VERSION_COMPATIBILITY[version];
  return compatibility?.requires.includes(feature) || false;
}

/**
 * Get all supported versions
 */
export function getSupportedVersions(): string[] {
  return Object.keys(VERSION_REGISTRY).filter(
    version => VERSION_REGISTRY[version].status !== 'sunset'
  );
}

/**
 * Get version status
 */
export function getVersionStatus(version: string): string {
  return VERSION_REGISTRY[version]?.status || 'unknown';
}

export { API_VERSIONS, VERSION_REGISTRY, VersionContext };