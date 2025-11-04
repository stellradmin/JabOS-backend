-- ==================================================
-- PHASE 2: PAYMENT INFRASTRUCTURE FOUNDATION
-- ==================================================
-- Creates comprehensive payment tracking system with full audit trail
-- Apply this migration when you have database write access

-- NOTE: The 'subscriptions' table name is already used by web app (organization subscriptions)
-- Mobile app uses 'revenuecat_subscriptions' table (see migrations 20251009024113 and 20251025000001)
-- This migration is SKIPPED to avoid conflicts - RevenueCat handles mobile subscriptions

-- 1. MOBILE USER SUBSCRIPTIONS - SKIPPED (use revenuecat_subscriptions instead)
-- The web app 'subscriptions' table has organization_id for gym subscriptions
-- The mobile app 'revenuecat_subscriptions' table has user_id for dating app subscriptions

-- 2-4. MOBILE PAYMENT TABLES - SKIPPED
-- Mobile app payment tracking is handled by:
-- - revenuecat_subscriptions table (for subscriptions)
-- - revenuecat_transactions table (for transactions)
-- - revenuecat_webhook_events table (for audit log)
-- See migrations: 20251009024113, 20251025000001

-- This entire migration is deprecated for the mobile app
-- Web app uses separate Stripe tables (see 20250101000017_create_payment_tables.sql)