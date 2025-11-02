/**
 * RevenueCat REST API Helper Functions
 *
 * Provides functions to interact with RevenueCat's REST API v1
 * Documentation: https://docs.revenuecat.com/reference/basic
 */

const REVENUECAT_API_BASE = 'https://api.revenuecat.com/v1';

interface RevenueCatSubscriber {
  request_date: string;
  request_date_ms: number;
  subscriber: {
    original_app_user_id: string;
    original_application_version: string | null;
    first_seen: string;
    last_seen: string;
    management_url: string | null;
    non_subscriptions: Record<string, any>;
    subscriptions: Record<string, RevenueCatSubscription>;
    entitlements: Record<string, RevenueCatEntitlement>;
  };
}

interface RevenueCatSubscription {
  auto_resume_date: string | null;
  billing_issues_detected_at: string | null;
  expires_date: string;
  grace_period_expires_date: string | null;
  is_sandbox: boolean;
  original_purchase_date: string;
  ownership_type: string;
  period_type: string;
  purchase_date: string;
  refunded_at: string | null;
  store: string;
  store_transaction_id: string;
  unsubscribe_detected_at: string | null;
}

interface RevenueCatEntitlement {
  expires_date: string | null;
  grace_period_expires_date: string | null;
  product_identifier: string;
  purchase_date: string;
}

/**
 * Get subscriber info from RevenueCat API
 *
 * @param appUserId - The app user ID (should match Supabase auth_user_id)
 * @param apiKey - RevenueCat secret API key
 * @returns Subscriber data or null if not found
 */
export async function getRevenueCatSubscriber(
  appUserId: string,
  apiKey: string
): Promise<RevenueCatSubscriber | null> {
  try {
    const response = await fetch(`${REVENUECAT_API_BASE}/subscribers/${appUserId}`, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
        'X-Platform': 'server',
      },
    });

    if (response.status === 404) {
      // Subscriber not found in RevenueCat
      return null;
    }

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`RevenueCat API error: ${response.status} - ${errorText}`);
    }

    const data: RevenueCatSubscriber = await response.json();
    return data;
  } catch (error) {
    console.error('Failed to fetch RevenueCat subscriber:', error);
    throw error;
  }
}

/**
 * Check if subscriber has an active entitlement
 *
 * @param subscriberData - RevenueCat subscriber data
 * @param entitlementId - The entitlement ID to check (e.g., 'premium')
 * @returns True if entitlement is active
 */
export function hasActiveEntitlement(
  subscriberData: RevenueCatSubscriber,
  entitlementId: string
): boolean {
  const entitlement = subscriberData.subscriber.entitlements[entitlementId];

  if (!entitlement) {
    return false;
  }

  // Check if entitlement has expired
  if (entitlement.expires_date) {
    const expiresAt = new Date(entitlement.expires_date);
    const now = new Date();

    if (expiresAt < now) {
      // Check grace period
      if (entitlement.grace_period_expires_date) {
        const gracePeriodExpires = new Date(entitlement.grace_period_expires_date);
        return gracePeriodExpires > now;
      }
      return false;
    }
  }

  return true;
}

/**
 * Get active subscriptions for a subscriber
 *
 * @param subscriberData - RevenueCat subscriber data
 * @returns Array of active subscription identifiers
 */
export function getActiveSubscriptions(
  subscriberData: RevenueCatSubscriber
): string[] {
  const activeSubscriptions: string[] = [];
  const now = new Date();

  for (const [productId, subscription] of Object.entries(subscriberData.subscriber.subscriptions)) {
    const expiresAt = new Date(subscription.expires_date);

    // Check if subscription is active (not expired or in grace period)
    const isActive = expiresAt > now ||
      (subscription.grace_period_expires_date && new Date(subscription.grace_period_expires_date) > now);

    if (isActive) {
      activeSubscriptions.push(productId);
    }
  }

  return activeSubscriptions;
}

/**
 * Sync RevenueCat subscriber data to local database
 *
 * This is the recommended approach when receiving webhook events:
 * 1. Receive webhook
 * 2. Respond 200 immediately
 * 3. Fetch latest data from RevenueCat API
 * 4. Update local database
 *
 * @param supabase - Supabase client
 * @param appUserId - The app user ID
 * @param apiKey - RevenueCat secret API key
 */
export async function syncRevenueCatSubscriber(
  supabase: any,
  appUserId: string,
  apiKey: string
): Promise<void> {
  try {
    // Fetch latest data from RevenueCat
    const subscriberData = await getRevenueCatSubscriber(appUserId, apiKey);

    if (!subscriberData) {
      console.log(`No RevenueCat data found for user: ${appUserId}`);
      return;
    }

    // Find user in database
    const { data: userData } = await supabase
      .from('users')
      .select('id')
      .eq('auth_user_id', appUserId)
      .single();

    if (!userData) {
      console.error(`User not found in database: ${appUserId}`);
      return;
    }

    const userId = userData.id;

    // Sync subscriptions
    for (const [productId, subscription] of Object.entries(subscriberData.subscriber.subscriptions)) {
      const expiresAt = new Date(subscription.expires_date);
      const now = new Date();

      // Determine status
      let status = 'active';
      if (subscription.billing_issues_detected_at) {
        status = 'billing_retry';
      } else if (subscription.unsubscribe_detected_at) {
        status = 'canceled';
      } else if (expiresAt < now) {
        status = 'expired';
      }

      await supabase
        .from('revenuecat_subscriptions')
        .upsert({
          user_id: userId,
          revenuecat_subscriber_id: subscriberData.subscriber.original_app_user_id,
          revenuecat_original_app_user_id: subscriberData.subscriber.original_app_user_id,
          product_id: productId,
          entitlement_id: 'premium', // Default, should be mapped from product
          store: subscription.store,
          status: status,
          period_type: subscription.period_type,
          purchase_date: subscription.purchase_date,
          original_purchase_date: subscription.original_purchase_date,
          expires_date: subscription.expires_date,
          billing_issue_detected_at: subscription.billing_issues_detected_at,
          grace_period_expires_date: subscription.grace_period_expires_date,
          unsubscribe_detected_at: subscription.unsubscribe_detected_at,
          will_renew: !subscription.unsubscribe_detected_at,
          auto_resume_date: subscription.auto_resume_date,
          store_transaction_id: subscription.store_transaction_id,
          is_sandbox: subscription.is_sandbox
        }, {
          onConflict: 'user_id,revenuecat_subscriber_id'
        });
    }

    // Sync entitlements
    for (const [entitlementId, entitlement] of Object.entries(subscriberData.subscriber.entitlements)) {
      const isActive = hasActiveEntitlement(subscriberData, entitlementId);

      await supabase
        .from('revenuecat_entitlements')
        .upsert({
          user_id: userId,
          entitlement_id: entitlementId,
          product_id: entitlement.product_identifier,
          is_active: isActive,
          purchase_date: entitlement.purchase_date,
          expires_date: entitlement.expires_date
        }, {
          onConflict: 'user_id,entitlement_id'
        });
    }

    // PHASE 5 ENHANCEMENT: Sync subscription status to profiles table for invite system
    const hasPremiumEntitlement = hasActiveEntitlement(subscriberData, 'premium');
    const subscriptionStatus = hasPremiumEntitlement ? 'premium' : 'free';
    const inviteLimit = hasPremiumEntitlement ? 20 : 5;

    // Get profile by auth_user_id
    const { data: profileData } = await supabase
      .from('profiles')
      .select('id')
      .eq('id', appUserId)
      .single();

    if (profileData) {
      // Update profiles table with subscription status and reset invites
      await supabase
        .from('profiles')
        .update({
          subscription_status: subscriptionStatus,
          revenue_cat_user_id: appUserId,
          daily_invites_remaining: inviteLimit, // Reset to new limit when subscription changes
          updated_at: new Date().toISOString()
        })
        .eq('id', appUserId);

      console.log(`Synced subscription status to profiles: ${appUserId} -> ${subscriptionStatus}`);
    } else {
      console.warn(`Profile not found for app_user_id: ${appUserId}`);
    }

    console.log(`Successfully synced RevenueCat data for user: ${appUserId}`);
  } catch (error) {
    console.error('Failed to sync RevenueCat subscriber:', error);
    throw error;
  }
}
