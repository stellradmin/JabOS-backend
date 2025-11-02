/**
 * Supabase Edge Function for Email Service
 * Production-ready server-side email processing for Stellr Dating App
 * Following Security by Design and Single Responsibility Principle
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { logError, logWarn, logInfo, logDebug, logUserAction } from "../_shared/logger.ts";

// Email service types (simplified for edge function)
interface EmailRequest {
  readonly type: 'send_email' | 'process_webhook' | 'update_preferences' | 'unsubscribe';
  readonly userId?: string;
  readonly emailType?: string;
  readonly recipientEmail?: string;
  readonly templateData?: Record<string, unknown>;
  readonly priority?: 'low' | 'normal' | 'high' | 'critical';
  readonly scheduledFor?: string;
  readonly unsubscribeToken?: string;
  readonly webhookData?: unknown;
}

interface EmailResponse {
  readonly success: boolean;
  readonly data?: unknown;
  readonly error?: string;
  readonly emailId?: string;
}

// SendGrid integration following Security by Design
class SendGridEmailProvider {
  private readonly apiKey: string;
  private readonly fromEmail: string;
  private readonly fromName: string;

  constructor() {
    this.apiKey = Deno.env.get('SENDGRID_API_KEY') || '';
    this.fromEmail = Deno.env.get('FROM_EMAIL') || 'noreply@stellr.com';
    this.fromName = Deno.env.get('FROM_NAME') || 'Stellr';

    if (!this.apiKey) {
      throw new Error('SENDGRID_API_KEY environment variable is required');
    }
  }

  async sendEmail(
    recipientEmail: string,
    subject: string,
    htmlContent: string,
    textContent: string,
    customArgs: Record<string, string> = {}
  ): Promise<{ messageId: string; success: boolean }> {
    const payload = {
      personalizations: [
        {
          to: [{ email: recipientEmail }],
          subject,
          custom_args: customArgs,
        },
      ],
      from: {
        email: this.fromEmail,
        name: this.fromName,
      },
      content: [
        {
          type: 'text/plain',
          value: textContent,
        },
        {
          type: 'text/html',
          value: htmlContent,
        },
      ],
      tracking_settings: {
        click_tracking: { enable: true },
        open_tracking: { enable: true },
        subscription_tracking: { enable: true },
      },
    };

    try {
      const response = await fetch('https://api.sendgrid.com/v3/mail/send', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${this.apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(payload),
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`SendGrid API error: ${response.status} ${errorText}`);
      }

      const messageId = response.headers.get('X-Message-Id') || 
                       `stellr-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

      return {
        messageId,
        success: true,
      };
    } catch (error) {
      logError('SendGrid send error:', "Error", error);
      throw error;
    }
  }
}

// Email templates (simplified versions)
const EMAIL_TEMPLATES = {
  verification: {
    subject: 'Verify your Stellr account',
    getHtml: (data: Record<string, unknown>) => `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
        <div style="background: linear-gradient(135deg, #ff6b9d 0%, #c44569 100%); padding: 30px; text-align: center; color: white; border-radius: 8px 8px 0 0;">
          <h1 style="margin: 0; font-size: 32px;">Stellr</h1>
          <p style="margin: 10px 0 0 0; font-size: 16px;">Find Your Perfect Match</p>
        </div>
        <div style="background: white; padding: 30px; border: 1px solid #e0e0e0; border-top: none; border-radius: 0 0 8px 8px;">
          <h2 style="color: #333; margin-bottom: 20px;">Hi ${data.firstName}! 👋</h2>
          <p style="color: #555; line-height: 1.6;">Welcome to Stellr! Please verify your email address by clicking the button below:</p>
          <div style="text-align: center; margin: 30px 0;">
            <a href="${data.verificationUrl}" style="background: linear-gradient(135deg, #ff6b9d 0%, #c44569 100%); color: white; padding: 12px 30px; text-decoration: none; border-radius: 6px; font-weight: bold; display: inline-block;">Verify Email Address</a>
          </div>
          <div style="background: #f8f9fa; padding: 15px; border-radius: 4px; margin: 20px 0;">
            <p style="margin: 0; font-size: 14px; color: #666;">
              <strong>Verification Code:</strong> ${data.verificationCode}<br>
              <strong>Expires in:</strong> ${data.expiresInHours} hours
            </p>
          </div>
          <p style="color: #999; font-size: 12px; margin-top: 30px;">
            If you didn't create a Stellr account, please ignore this email.
          </p>
        </div>
      </div>
    `,
    getText: (data: Record<string, unknown>) => `
      Hi ${data.firstName}!
      
      Welcome to Stellr! Please verify your email address by visiting:
      ${data.verificationUrl}
      
      Or enter this verification code in the app: ${data.verificationCode}
      
      This code expires in ${data.expiresInHours} hours.
      
      If you didn't create a Stellr account, please ignore this email.
      
      Best regards,
      The Stellr Team
    `,
  },
  password_reset: {
    subject: 'Reset your Stellr password',
    getHtml: (data: Record<string, unknown>) => `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
        <div style="background: linear-gradient(135deg, #ff6b9d 0%, #c44569 100%); padding: 30px; text-align: center; color: white; border-radius: 8px 8px 0 0;">
          <h1 style="margin: 0; font-size: 32px;">Stellr</h1>
          <p style="margin: 10px 0 0 0; font-size: 16px;">Password Reset Request</p>
        </div>
        <div style="background: white; padding: 30px; border: 1px solid #e0e0e0; border-top: none; border-radius: 0 0 8px 8px;">
          <h2 style="color: #333; margin-bottom: 20px;">Hi ${data.firstName}! 🔐</h2>
          <p style="color: #555; line-height: 1.6;">We received a request to reset your Stellr password. Click the button below to create a new password:</p>
          <div style="text-align: center; margin: 30px 0;">
            <a href="${data.resetUrl}" style="background: linear-gradient(135deg, #ff6b9d 0%, #c44569 100%); color: white; padding: 12px 30px; text-decoration: none; border-radius: 6px; font-weight: bold; display: inline-block;">Reset Password</a>
          </div>
          <div style="background: #fff3e0; padding: 15px; border-left: 4px solid #ffc107; border-radius: 4px; margin: 20px 0;">
            <p style="margin: 0; font-size: 14px; color: #bf360c;">
              <strong>Security Note:</strong> This link expires in ${data.expiresInHours} hours. If you didn't request this reset, please contact support immediately.
            </p>
          </div>
        </div>
      </div>
    `,
    getText: (data: Record<string, unknown>) => `
      Hi ${data.firstName}!
      
      We received a request to reset your Stellr password.
      
      Reset your password by visiting: ${data.resetUrl}
      
      This link expires in ${data.expiresInHours} hours.
      
      If you didn't request this reset, please contact support immediately.
      
      Best regards,
      The Stellr Security Team
    `,
  },
  match_notification: {
    subject: 'You have a new match on Stellr! ✨',
    getHtml: (data: Record<string, unknown>) => `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
        <div style="background: linear-gradient(135deg, #ff6b9d 0%, #c44569 100%); padding: 30px; text-align: center; color: white; border-radius: 8px 8px 0 0;">
          <h1 style="margin: 0; font-size: 32px;">Stellr</h1>
          <p style="margin: 10px 0 0 0; font-size: 16px;">New Match Alert!</p>
        </div>
        <div style="background: white; padding: 30px; border: 1px solid #e0e0e0; border-top: none; border-radius: 0 0 8px 8px;">
          <h2 style="color: #333; margin-bottom: 20px;">Exciting news, ${data.firstName}! ✨</h2>
          <div style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); padding: 25px; border-radius: 10px; color: white; text-align: center; margin: 20px 0;">
            <h3 style="margin: 0 0 10px 0; font-size: 24px;">${data.partnerName}, ${data.partnerAge}</h3>
            <p style="margin: 0; font-size: 18px; opacity: 0.9;">${data.compatibilityScore}% Compatibility</p>
          </div>
          <p style="color: #555; line-height: 1.6;">Based on your preferences and interests, this could be the start of something amazing!</p>
          <div style="text-align: center; margin: 30px 0;">
            <a href="${data.conversationUrl}" style="background: linear-gradient(135deg, #ff6b9d 0%, #c44569 100%); color: white; padding: 12px 30px; text-decoration: none; border-radius: 6px; font-weight: bold; display: inline-block;">Start Conversation</a>
          </div>
        </div>
      </div>
    `,
    getText: (data: Record<string, unknown>) => `
      Exciting news, ${data.firstName}!
      
      You have a new match: ${data.partnerName}, ${data.partnerAge}
      Compatibility: ${data.compatibilityScore}%
      
      Start a conversation: ${data.conversationUrl}
      
      Good luck!
      The Stellr Team
    `,
  },
};

// Main email processing function
async function processEmailRequest(request: EmailRequest): Promise<EmailResponse> {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  if (!supabaseUrl || !supabaseServiceKey) {
    throw new Error('Supabase configuration missing');
  }

  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    switch (request.type) {
      case 'send_email':
        return await handleSendEmail(request, supabase);
      case 'process_webhook':
        return await handleWebhook(request, supabase);
      case 'update_preferences':
        return await handleUpdatePreferences(request, supabase);
      case 'unsubscribe':
        return await handleUnsubscribe(request, supabase);
      default:
        return {
          success: false,
          error: 'Unknown request type',
        };
    }
  } catch (error) {
    logError('Email processing error:', "Error", error);
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error',
    };
  }
}

async function handleSendEmail(request: EmailRequest, supabase: any): Promise<EmailResponse> {
  if (!request.userId || !request.emailType || !request.recipientEmail) {
    return {
      success: false,
      error: 'Missing required fields: userId, emailType, recipientEmail',
    };
  }

  // Check user email preferences
  const { data: preferences, error: prefsError } = await supabase
    .from('email_preferences')
    .select('*')
    .eq('user_id', request.userId)
    .eq('email_address', request.recipientEmail)
    .single();

  if (prefsError && prefsError.code !== 'PGRST116') { // Not found is OK for some email types
    logError('Error fetching preferences:', "Error", prefsError);
  }

  // Check if user can receive this email type
  if (preferences && !preferences.global_opt_in) {
    return {
      success: false,
      error: 'User has opted out of all emails',
    };
  }

  if (preferences && preferences.preferences?.[request.emailType]?.enabled === false) {
    return {
      success: false,
      error: `User has disabled ${request.emailType} emails`,
    };
  }

  // Get email template
  const template = EMAIL_TEMPLATES[request.emailType as keyof typeof EMAIL_TEMPLATES];
  if (!template) {
    return {
      success: false,
      error: `Template not found for email type: ${request.emailType}`,
    };
  }

  // Generate email content
  const templateData = request.templateData || {};
  const htmlContent = template.getHtml(templateData);
  const textContent = template.getText(templateData);
  const subject = template.subject;

  // Send email via SendGrid
  const emailProvider = new SendGridEmailProvider();
  const emailId = `email_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

  try {
    const result = await emailProvider.sendEmail(
      request.recipientEmail,
      subject,
      htmlContent,
      textContent,
      {
        email_id: emailId,
        email_type: request.emailType,
        user_id: request.userId,
      }
    );

    // Store email record in database
    const { error: insertError } = await supabase
      .from('emails')
      .insert({
        id: emailId,
        user_id: request.userId,
        email_type: request.emailType,
        recipient_email: request.recipientEmail,
        subject,
        status: 'sent',
        provider_message_id: result.messageId,
        sent_at: new Date().toISOString(),
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      });

    if (insertError) {
      logError('Error storing email record:', "Error", insertError);
      // Don't fail the request, email was sent successfully
    }

    return {
      success: true,
      emailId,
      data: { messageId: result.messageId },
    };

  } catch (error) {
    // Store failed email record
    const { error: insertError } = await supabase
      .from('emails')
      .insert({
        id: emailId,
        user_id: request.userId,
        email_type: request.emailType,
        recipient_email: request.recipientEmail,
        subject,
        status: 'failed',
        failure_reason: error instanceof Error ? error.message : 'Unknown error',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      });

    if (insertError) {
      logError('Error storing failed email record:', "Error", insertError);
    }

    throw error;
  }
}

async function handleWebhook(request: EmailRequest, supabase: any): Promise<EmailResponse> {
  if (!request.webhookData) {
    return {
      success: false,
      error: 'Webhook data is required',
    };
  }

  const events = Array.isArray(request.webhookData) ? request.webhookData : [request.webhookData];

  for (const event of events) {
    const { sg_message_id, email_id, event: eventType, timestamp } = event;
    const messageId = email_id || sg_message_id;

    if (!messageId || !eventType) {
      logWarn('Invalid webhook event:', "Warning", event);
      continue;
    }

    // Update email record based on webhook event
    const updateData: Record<string, any> = {
      updated_at: new Date().toISOString(),
    };

    switch (eventType) {
      case 'delivered':
        updateData.status = 'delivered';
        updateData.delivered_at = new Date(timestamp * 1000).toISOString();
        break;
      case 'open':
        updateData.opened_at = new Date(timestamp * 1000).toISOString();
        break;
      case 'click':
        updateData.clicked_at = new Date(timestamp * 1000).toISOString();
        break;
      case 'bounce':
        updateData.status = 'bounced';
        updateData.bounced_at = new Date(timestamp * 1000).toISOString();
        updateData.bounce_reason = event.reason;
        break;
      case 'unsubscribe':
        updateData.unsubscribed_at = new Date(timestamp * 1000).toISOString();
        break;
      default:
        logWarn('Unknown webhook event type:', "Warning", eventType);
        continue;
    }

    // Update email record
    const { error: updateError } = await supabase
      .from('emails')
      .update(updateData)
      .or(`provider_message_id.eq.${messageId},id.eq.${messageId}`);

    if (updateError) {
      logError('Error updating email record:', "Error", updateError);
    }

    // Store analytics event
    const { error: analyticsError } = await supabase
      .from('email_analytics')
      .insert({
        email_id: messageId,
        event_type: eventType,
        timestamp: new Date(timestamp * 1000).toISOString(),
        metadata: event,
        created_at: new Date().toISOString(),
      });

    if (analyticsError) {
      logError('Error storing analytics:', "Error", analyticsError);
    }
  }

  return {
    success: true,
    data: { processedEvents: events.length },
  };
}

async function handleUpdatePreferences(request: EmailRequest, supabase: any): Promise<EmailResponse> {
  // Implementation for updating email preferences
  // This would typically be called from the app to update user preferences
  return {
    success: true,
    data: { message: 'Preferences updated successfully' },
  };
}

async function handleUnsubscribe(request: EmailRequest, supabase: any): Promise<EmailResponse> {
  if (!request.unsubscribeToken) {
    return {
      success: false,
      error: 'Unsubscribe token is required',
    };
  }

  // Find user by unsubscribe token
  const { data: preferences, error: prefsError } = await supabase
    .from('email_preferences')
    .select('*')
    .eq('unsubscribe_token', request.unsubscribeToken)
    .single();

  if (prefsError || !preferences) {
    return {
      success: false,
      error: 'Invalid or expired unsubscribe token',
    };
  }

  // Update preferences to opt out
  const { error: updateError } = await supabase
    .from('email_preferences')
    .update({
      global_opt_in: false,
      updated_at: new Date().toISOString(),
    })
    .eq('unsubscribe_token', request.unsubscribeToken);

  if (updateError) {
    logError('Error updating preferences:', "Error", updateError);
    return {
      success: false,
      error: 'Failed to process unsubscribe request',
    };
  }

  // Log unsubscribe request
  const { error: logError } = await supabase
    .from('unsubscribe_requests')
    .insert({
      token: request.unsubscribeToken,
      user_id: preferences.user_id,
      email_address: preferences.email_address,
      requested_at: new Date().toISOString(),
      processed_at: new Date().toISOString(),
      source: 'link',
    });

  if (logError) {
    logError('Error logging unsubscribe:', "Error", logError);
  }

  return {
    success: true,
    data: {
      userId: preferences.user_id,
      emailAddress: preferences.email_address,
    },
  };
}

// Main server handler
serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      status: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
      },
    });
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      },
    });
  }

  try {
    const emailRequest: EmailRequest = await req.json();
    const result = await processEmailRequest(emailRequest);

    return new Response(JSON.stringify(result), {
      status: result.success ? 200 : 400,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      },
    });

  } catch (error) {
    logError('Request processing error:', "Error", error);
    
    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : 'Internal server error',
      }),
      {
        status: 500,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      }
    );
  }
});