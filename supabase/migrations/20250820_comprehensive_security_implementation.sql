-- ==========================================
-- COMPREHENSIVE SECURITY MIGRATION
-- Stellr Backend Security Implementation
-- Target: Improve security score from 75/100 to 90+/100
-- ==========================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ==========================================
-- 1. RBAC SYSTEM IMPLEMENTATION
-- ==========================================

-- Create roles table
CREATE TABLE IF NOT EXISTS roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    permissions JSONB DEFAULT '[]'::jsonb,
    level INTEGER NOT NULL,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create user_roles junction table
CREATE TABLE IF NOT EXISTS user_roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role_id UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    assigned_by UUID REFERENCES auth.users(id),
    assigned_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT true,
    UNIQUE(user_id, role_id)
);

-- Create role audit logs table
CREATE TABLE IF NOT EXISTS role_audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id),
    role_id UUID NOT NULL REFERENCES roles(id),
    action TEXT NOT NULL,
    old_data JSONB,
    new_data JSONB,
    performed_by UUID REFERENCES auth.users(id),
    performed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    metadata JSONB DEFAULT '{}'::jsonb
);

-- Insert default roles (skip if they already exist from January RBAC migration)
INSERT INTO roles (name, display_name, description, level, permissions) VALUES
('super_admin', 'Super Admin', 'Super Administrator with full system access', 70, '["*"]'::jsonb),
('admin', 'Admin', 'Administrator with most system access', 60, '["USER_MANAGE", "CONTENT_MODERATE", "ANALYTICS_VIEW", "SECURITY_AUDIT"]'::jsonb),
('moderator', 'Moderator', 'Content moderator with limited admin access', 50, '["CONTENT_MODERATE", "USER_VIEW", "REPORT_HANDLE"]'::jsonb),
('support', 'Support', 'Support agent with user assistance access', 40, '["USER_VIEW", "MESSAGE_VIEW", "REPORT_VIEW"]'::jsonb),
('premium_user', 'Premium User', 'Premium user with enhanced features', 30, '["PROFILE_ENHANCED", "MESSAGE_UNLIMITED", "SWIPE_UNLIMITED"]'::jsonb),
('verified_user', 'Verified User', 'Verified user with standard features', 20, '["PROFILE_STANDARD", "MESSAGE_STANDARD", "SWIPE_STANDARD"]'::jsonb),
('basic_user', 'Basic User', 'Basic user with limited features', 10, '["PROFILE_BASIC", "MESSAGE_LIMITED", "SWIPE_LIMITED"]'::jsonb),
('suspended_user', 'Suspended User', 'Suspended user with no access', 0, '[]'::jsonb)
ON CONFLICT (name) DO NOTHING;

-- ==========================================
-- 2. RLS POLICIES IMPLEMENTATION
-- ==========================================

-- Enable RLS on all RBAC tables
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_audit_logs ENABLE ROW LEVEL SECURITY;

-- RLS Policies for roles table
CREATE POLICY "Users can view roles" ON roles FOR SELECT USING (true);
CREATE POLICY "Admins can manage roles" ON roles FOR ALL USING (
    EXISTS (
        SELECT 1 FROM user_roles ur 
        JOIN roles r ON ur.role_id = r.id 
        WHERE ur.user_id = auth.uid() 
        AND r.name IN ('super_admin', 'admin')
        AND ur.is_active = true
    )
);

-- RLS Policies for user_roles table
CREATE POLICY "Users can view their own roles" ON user_roles FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Admins can view all user roles" ON user_roles FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM user_roles ur 
        JOIN roles r ON ur.role_id = r.id 
        WHERE ur.user_id = auth.uid() 
        AND r.name IN ('super_admin', 'admin')
        AND ur.is_active = true
    )
);
CREATE POLICY "Admins can manage user roles" ON user_roles FOR ALL USING (
    EXISTS (
        SELECT 1 FROM user_roles ur 
        JOIN roles r ON ur.role_id = r.id 
        WHERE ur.user_id = auth.uid() 
        AND r.name IN ('super_admin', 'admin')
        AND ur.is_active = true
    )
);

-- RLS Policies for role_audit_logs table
CREATE POLICY "Users can view their own role audit logs" ON role_audit_logs FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Admins can view all role audit logs" ON role_audit_logs FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM user_roles ur 
        JOIN roles r ON ur.role_id = r.id 
        WHERE ur.user_id = auth.uid() 
        AND r.name IN ('super_admin', 'admin')
        AND ur.is_active = true
    )
);

-- ==========================================
-- 3. SECURITY MONITORING SYSTEM
-- ==========================================

-- Create security events table
CREATE TABLE IF NOT EXISTS security_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL,
    severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    user_id UUID REFERENCES auth.users(id),
    ip_address INET,
    user_agent TEXT,
    endpoint TEXT,
    threat_score INTEGER DEFAULT 0 CHECK (threat_score >= 0 AND threat_score <= 100),
    details JSONB DEFAULT '{}'::jsonb,
    investigation_status TEXT DEFAULT 'pending' CHECK (investigation_status IN ('pending', 'investigating', 'resolved', 'false_positive')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create security alerts table
CREATE TABLE IF NOT EXISTS security_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_type TEXT NOT NULL,
    severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    title TEXT NOT NULL,
    description TEXT,
    affected_user_id UUID REFERENCES auth.users(id),
    event_ids UUID[] DEFAULT '{}',
    status TEXT DEFAULT 'open' CHECK (status IN ('open', 'acknowledged', 'resolved', 'closed')),
    assigned_to UUID REFERENCES auth.users(id),
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Enable RLS on security tables
ALTER TABLE security_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_alerts ENABLE ROW LEVEL SECURITY;

-- RLS Policies for security tables
CREATE POLICY "Users can view their own security events" ON security_events FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Security admins can view all security events" ON security_events FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM user_roles ur 
        JOIN roles r ON ur.role_id = r.id 
        WHERE ur.user_id = auth.uid() 
        AND r.name IN ('super_admin', 'admin')
        AND ur.is_active = true
    )
);

-- ==========================================
-- 4. ENHANCED PROFILE SECURITY
-- ==========================================

-- Drop existing insecure policies
DROP POLICY IF EXISTS "Users can view all profiles" ON profiles;
DROP POLICY IF EXISTS "Public profiles are viewable by everyone" ON profiles;

-- Create secure profile policies
CREATE POLICY "Users can view their own profile" ON profiles 
    FOR SELECT USING (id = auth.uid());

CREATE POLICY "Users can view matched profiles" ON profiles 
    FOR SELECT USING (
        id IN (
            SELECT CASE 
                WHEN user1_id = auth.uid() THEN user2_id
                WHEN user2_id = auth.uid() THEN user1_id
            END
            FROM matches 
            WHERE (user1_id = auth.uid() OR user2_id = auth.uid())
            AND status = 'matched'
        )
    );

-- Create discoverable profiles policy only if is_discoverable column exists (added in August 21 migration)
DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
        AND table_name = 'profiles'
        AND column_name = 'is_discoverable'
    ) THEN
        EXECUTE 'CREATE POLICY "Users can view discoverable profiles" ON profiles
            FOR SELECT USING (
                is_discoverable = true
                AND id != auth.uid()
                AND id NOT IN (
                    SELECT blocked_user_id FROM user_blocks
                    WHERE blocking_user_id = auth.uid()
                )
                AND auth.uid() NOT IN (
                    SELECT blocked_user_id FROM user_blocks
                    WHERE blocking_user_id = id
                )
            )';
    END IF;
END $$;

-- ==========================================
-- 5. MESSAGE SECURITY ENHANCEMENT
-- ==========================================

-- Enhanced message policies
DROP POLICY IF EXISTS "Users can view messages in their conversations" ON messages;
CREATE POLICY "Users can view messages in their conversations" ON messages 
    FOR SELECT USING (
        conversation_id IN (
            SELECT id FROM conversations 
            WHERE user1_id = auth.uid() OR user2_id = auth.uid()
        )
    );

-- ==========================================
-- 6. SWIPE RATE LIMITING
-- ==========================================

-- Create function to check swipe rate limit
CREATE OR REPLACE FUNCTION check_swipe_rate_limit(user_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    recent_swipes INTEGER;
    user_role TEXT;
BEGIN
    -- Get user's highest role
    SELECT r.name INTO user_role
    FROM user_roles ur
    JOIN roles r ON ur.role_id = r.id
    WHERE ur.user_id = check_swipe_rate_limit.user_id
    AND ur.is_active = true
    ORDER BY r.level DESC
    LIMIT 1;
    
    -- Count recent swipes (last hour)
    SELECT COUNT(*) INTO recent_swipes
    FROM swipes
    WHERE swiper_id = check_swipe_rate_limit.user_id
    AND created_at > NOW() - INTERVAL '1 hour';
    
    -- Return based on role limits
    RETURN CASE 
        WHEN user_role IN ('premium_user', 'admin', 'super_admin') THEN recent_swipes < 1000
        WHEN user_role = 'verified_user' THEN recent_swipes < 100
        ELSE recent_swipes < 20
    END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ==========================================
-- 7. HELPER FUNCTIONS
-- ==========================================

-- Function to check if user has permission
CREATE OR REPLACE FUNCTION user_has_permission(user_id UUID, permission TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    has_permission BOOLEAN := false;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM user_roles ur
        JOIN roles r ON ur.role_id = r.id
        WHERE ur.user_id = user_has_permission.user_id
        AND ur.is_active = true
        AND (
            r.permissions ? permission
            OR r.permissions ? '*'
        )
    ) INTO has_permission;
    
    RETURN has_permission;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get user's role level
CREATE OR REPLACE FUNCTION get_user_role_level(user_id UUID)
RETURNS INTEGER AS $$
DECLARE
    max_level INTEGER := 0;
BEGIN
    SELECT COALESCE(MAX(r.level), 1) INTO max_level
    FROM user_roles ur
    JOIN roles r ON ur.role_id = r.id
    WHERE ur.user_id = get_user_role_level.user_id
    AND ur.is_active = true;
    
    RETURN max_level;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ==========================================
-- 8. INDEXES FOR PERFORMANCE
-- ==========================================

-- RBAC indexes
CREATE INDEX IF NOT EXISTS idx_user_roles_user_id ON user_roles(user_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_role_id ON user_roles(role_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_active ON user_roles(is_active);
CREATE INDEX IF NOT EXISTS idx_roles_hierarchy ON roles(level);

-- Security monitoring indexes
CREATE INDEX IF NOT EXISTS idx_security_events_user_id ON security_events(user_id);
CREATE INDEX IF NOT EXISTS idx_security_events_severity ON security_events(severity);
CREATE INDEX IF NOT EXISTS idx_security_events_created_at ON security_events(created_at);
CREATE INDEX IF NOT EXISTS idx_security_events_threat_score ON security_events(threat_score);

-- Profile security indexes
DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
        AND table_name = 'profiles'
        AND column_name = 'is_discoverable'
    ) THEN
        CREATE INDEX IF NOT EXISTS idx_profiles_discoverable ON profiles(is_discoverable);
    END IF;
END $$;

-- User blocks indexes (only if table exists - created in August 21 migration)
DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'user_blocks'
    ) THEN
        CREATE INDEX IF NOT EXISTS idx_user_blocks_blocking ON user_blocks(blocking_user_id);
        CREATE INDEX IF NOT EXISTS idx_user_blocks_blocked ON user_blocks(blocked_user_id);
    END IF;
END $$;

-- ==========================================
-- 9. AUDIT TRIGGERS
-- ==========================================

-- Create audit trigger function for role changes
CREATE OR REPLACE FUNCTION audit_role_changes()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO role_audit_logs (user_id, role_id, action, new_data)
        VALUES (NEW.user_id, NEW.role_id, 'INSERT', row_to_json(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO role_audit_logs (user_id, role_id, action, old_data, new_data)
        VALUES (NEW.user_id, NEW.role_id, 'UPDATE', row_to_json(OLD), row_to_json(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO role_audit_logs (user_id, role_id, action, old_data)
        VALUES (OLD.user_id, OLD.role_id, 'DELETE', row_to_json(OLD));
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger
DROP TRIGGER IF EXISTS trigger_audit_role_changes ON user_roles;
CREATE TRIGGER trigger_audit_role_changes
    AFTER INSERT OR UPDATE OR DELETE ON user_roles
    FOR EACH ROW EXECUTE FUNCTION audit_role_changes();

-- ==========================================
-- 10. VALIDATION AND SUMMARY
-- ==========================================

-- Add constraint to ensure data integrity
ALTER TABLE user_roles ADD CONSTRAINT check_expires_at_future 
    CHECK (expires_at IS NULL OR expires_at > assigned_at);

-- Summary of security implementation
DO $$
BEGIN
    RAISE NOTICE 'SECURITY MIGRATION COMPLETED SUCCESSFULLY';
    RAISE NOTICE '==========================================';
    RAISE NOTICE 'RBAC System: 8-tier role hierarchy implemented';
    RAISE NOTICE 'RLS Policies: Enhanced profile and data security';
    RAISE NOTICE 'Security Monitoring: Event logging and alerting';
    RAISE NOTICE 'Performance: Strategic indexes added';
    RAISE NOTICE 'Audit Trail: Comprehensive role change logging';
    RAISE NOTICE '==========================================';
    RAISE NOTICE 'Expected Security Score: 90+/100';
END $$;