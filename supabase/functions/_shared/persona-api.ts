/**
 * Persona API Helper
 *
 * Server-side integration with Persona's REST API for identity verification.
 * Handles inquiry creation, status checks, and webhook verification.
 *
 * @see https://docs.withpersona.com/reference
 */

// Persona API configuration
const PERSONA_API_KEY = Deno.env.get('PERSONA_API_KEY') || '';
const PERSONA_WEBHOOK_SECRET = Deno.env.get('PERSONA_WEBHOOK_SECRET') || '';
const PERSONA_ENVIRONMENT = Deno.env.get('PERSONA_ENVIRONMENT') || 'sandbox';
const PERSONA_TEMPLATE_ID = Deno.env.get('PERSONA_TEMPLATE_ID') || '';

// API Base URL
const getPersonaApiUrl = (): string => {
  return PERSONA_ENVIRONMENT === 'production'
    ? 'https://withpersona.com/api/v1'
    : 'https://withpersona.com/api/v1'; // Same endpoint, behavior controlled by API key
};

/**
 * Persona Inquiry interface
 */
export interface PersonaInquiry {
  id: string;
  type: string;
  attributes: {
    status: string;
    'reference-id': string;
    'session-token': string;
    'created-at': string;
    'completed-at': string | null;
    'failed-at': string | null;
    'declined-at': string | null;
    'approved-at': string | null;
    fields: Record<string, any>;
  };
}

/**
 * Inquiry creation parameters
 */
export interface CreateInquiryParams {
  referenceId: string;
  templateId?: string;
  fields?: Record<string, any>;
}

/**
 * Create a new Persona inquiry
 */
export async function createInquiry(params: CreateInquiryParams): Promise<PersonaInquiry | null> {
  try {
    const url = `${getPersonaApiUrl()}/inquiries`;

    const payload = {
      data: {
        type: 'inquiry',
        attributes: {
          'inquiry-template-id': params.templateId || PERSONA_TEMPLATE_ID,
          'reference-id': params.referenceId,
          fields: params.fields || {}
        }
      }
    };

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${PERSONA_API_KEY}`,
        'Content-Type': 'application/json',
        'Persona-Version': '2023-01-05'
      },
      body: JSON.stringify(payload)
    });

    if (!response.ok) {
      const error = await response.text();
      console.error('[Persona API] Create inquiry failed:', error);
      return null;
    }

    const data = await response.json();
    return data.data as PersonaInquiry;
  } catch (error) {
    console.error('[Persona API] Error creating inquiry:', error);
    return null;
  }
}

/**
 * Retrieve an existing inquiry by ID
 */
export async function getInquiry(inquiryId: string): Promise<PersonaInquiry | null> {
  try {
    const url = `${getPersonaApiUrl()}/inquiries/${inquiryId}`;

    const response = await fetch(url, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${PERSONA_API_KEY}`,
        'Persona-Version': '2023-01-05'
      }
    });

    if (!response.ok) {
      const error = await response.text();
      console.error('[Persona API] Get inquiry failed:', error);
      return null;
    }

    const data = await response.json();
    return data.data as PersonaInquiry;
  } catch (error) {
    console.error('[Persona API] Error fetching inquiry:', error);
    return null;
  }
}

/**
 * Resume an existing inquiry (get new session token)
 */
export async function resumeInquiry(inquiryId: string): Promise<{ sessionToken: string } | null> {
  try {
    const url = `${getPersonaApiUrl()}/inquiries/${inquiryId}/resume`;

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${PERSONA_API_KEY}`,
        'Content-Type': 'application/json',
        'Persona-Version': '2023-01-05'
      }
    });

    if (!response.ok) {
      const error = await response.text();
      console.error('[Persona API] Resume inquiry failed:', error);
      return null;
    }

    const data = await response.json();
    return {
      sessionToken: data.data.attributes['session-token']
    };
  } catch (error) {
    console.error('[Persona API] Error resuming inquiry:', error);
    return null;
  }
}

/**
 * Verify webhook signature
 *
 * @see https://docs.withpersona.com/reference/webhooks#webhook-signatures
 */
export function verifyWebhookSignature(
  payload: string,
  signature: string,
  timestamp: string
): boolean {
  try {
    // Persona uses HMAC SHA256 for webhook signatures
    const signedPayload = `${timestamp}.${payload}`;

    const encoder = new TextEncoder();
    const keyData = encoder.encode(PERSONA_WEBHOOK_SECRET);
    const messageData = encoder.encode(signedPayload);

    // Verify using Web Crypto API
    return crypto.subtle.importKey(
      'raw',
      keyData,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['verify']
    ).then(key => {
      const signatureData = hexToBytes(signature);
      return crypto.subtle.verify(
        'HMAC',
        key,
        signatureData,
        messageData
      );
    }).then(isValid => isValid).catch(() => false);
  } catch (error) {
    console.error('[Persona API] Error verifying webhook signature:', error);
    return false;
  }
}

/**
 * Helper function to convert hex string to bytes
 */
function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
  }
  return bytes;
}

/**
 * Parse webhook event
 */
export interface WebhookEvent {
  type: string;
  id: string;
  attributes: {
    name: string;
    payload: {
      data: {
        id: string;
        type: string;
        attributes: Record<string, any>;
      };
    };
  };
}

export function parseWebhookEvent(payload: any): WebhookEvent | null {
  try {
    if (!payload || !payload.data) {
      return null;
    }

    return payload.data as WebhookEvent;
  } catch (error) {
    console.error('[Persona API] Error parsing webhook event:', error);
    return null;
  }
}

/**
 * Map Persona inquiry status to our verification status
 */
export function mapInquiryStatus(personaStatus: string): string {
  const statusMap: Record<string, string> = {
    'created': 'in_progress',
    'pending': 'in_progress',
    'completed': 'pending',
    'approved': 'approved',
    'declined': 'declined',
    'failed': 'failed',
    'expired': 'failed',
    'needs_review': 'pending'
  };

  return statusMap[personaStatus.toLowerCase()] || 'pending';
}

/**
 * Extract liveness score from inquiry data
 */
export function extractLivenessScore(inquiry: PersonaInquiry): number | null {
  try {
    // Liveness score is typically in the verifications or checks
    // This depends on your Persona template configuration
    const checks = inquiry.attributes.fields?.checks;
    if (checks && Array.isArray(checks)) {
      const livenessCheck = checks.find((check: any) =>
        check.name?.includes('selfie') || check.name?.includes('liveness')
      );

      if (livenessCheck?.score) {
        return parseFloat(livenessCheck.score);
      }
    }

    return null;
  } catch (error) {
    console.error('[Persona API] Error extracting liveness score:', error);
    return null;
  }
}

/**
 * Validate Persona configuration
 */
export function isPersonaConfigured(): boolean {
  return !!(PERSONA_API_KEY && PERSONA_TEMPLATE_ID && PERSONA_WEBHOOK_SECRET);
}

/**
 * Get Persona configuration status
 */
export function getConfigurationStatus(): {
  configured: boolean;
  environment: string;
  issues: string[];
} {
  const issues: string[] = [];

  if (!PERSONA_API_KEY) issues.push('PERSONA_API_KEY not set');
  if (!PERSONA_TEMPLATE_ID) issues.push('PERSONA_TEMPLATE_ID not set');
  if (!PERSONA_WEBHOOK_SECRET) issues.push('PERSONA_WEBHOOK_SECRET not set');

  return {
    configured: issues.length === 0,
    environment: PERSONA_ENVIRONMENT,
    issues
  };
}
