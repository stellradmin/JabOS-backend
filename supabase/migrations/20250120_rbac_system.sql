-- ============================================================================
-- RBAC System Implementation
-- ============================================================================
-- Enterprise-grade Role-Based Access Control with 8-tier hierarchy
-- Implements comprehensive security with RLS policies
-- ============================================================================

-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- ROLES TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT UNIQUE NOT NULL CHECK (name IN (
        'super_admin',
        'admin',
        'moderator',
        'support',
        'premium_user',
        'verified_user',
        'basic_user',
        'suspended_user'
    )),
    level INTEGER NOT NULL CHECK (level >= 0 AND level <= 100),
    display_name TEXT NOT NULL,
    description TEXT,
    permissions JSONB NOT NULL DEFAULT '[]'::jsonb,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Create index for role lookups
CREATE INDEX idx_roles_name ON public.roles(name);
CREATE INDEX idx_roles_level ON public.roles(level);
CREATE INDEX idx_roles_active ON public.roles(is_active);

-- ============================================================================
-- USER ROLES TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.user_roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE RESTRICT,
    assigned_by UUID NOT NULL REFERENCES auth.users(id),
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ,
    reason TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ensure only one active role per user (partial unique index)
CREATE UNIQUE INDEX unique_active_role_per_user ON public.user_roles(user_id) WHERE is_active = true;

-- Create indexes for performance
CREATE INDEX idx_user_roles_user_id ON public.user_roles(user_id);
CREATE INDEX idx_user_roles_role_id ON public.user_roles(role_id);
CREATE INDEX idx_user_roles_assigned_by ON public.user_roles(assigned_by);
CREATE INDEX idx_user_roles_active ON public.user_roles(is_active);
CREATE INDEX idx_user_roles_expires ON public.user_roles(expires_at);

-- ============================================================================
-- ROLE AUDIT LOGS TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.role_audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id),
    target_user_id UUID NOT NULL REFERENCES auth.users(id),
    action TEXT NOT NULL CHECK (action IN ('assign', 'revoke', 'expire')),
    previous_role TEXT,
    new_role TEXT,
    reason TEXT NOT NULL,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Create indexes for audit log queries
CREATE INDEX idx_role_audit_user ON public.role_audit_logs(user_id);
CREATE INDEX idx_role_audit_target ON public.role_audit_logs(target_user_id);
CREATE INDEX idx_role_audit_action ON public.role_audit_logs(action);
CREATE INDEX idx_role_audit_created ON public.role_audit_logs(created_at DESC);

-- ============================================================================
-- INSERT DEFAULT ROLES
-- ============================================================================
INSERT INTO public.roles (name, level, display_name, description, permissions) VALUES
    ('super_admin', 70, 'Super Admin', 'Full system access with all permissions', 
     '["user:view", "user:edit", "user:delete", "user:suspend", "user:restore", 
       "profile:view:all", "profile:edit:all", "profile:delete", 
       "content:moderate", "content:delete", "content:restore",
       "message:view:all", "message:delete:any", "message:send:broadcast",
       "match:view:all", "match:override", "match:delete",
       "payment:view", "payment:refund", "payment:manage",
       "system:config", "system:monitor", "system:backup", "system:audit",
       "analytics:view", "analytics:export",
       "role:assign", "role:revoke", "role:create", "role:delete",
       "support:ticket:view", "support:ticket:respond", "support:ticket:close"]'::jsonb),
       
    ('admin', 60, 'Admin', 'Administrative access with most permissions',
     '["user:view", "user:edit", "user:delete", "user:suspend", "user:restore",
       "profile:view:all", "profile:edit:all", "profile:delete",
       "content:moderate", "content:delete", "content:restore",
       "message:view:all", "message:delete:any", "message:send:broadcast",
       "match:view:all", "match:override", "match:delete",
       "payment:view", "payment:refund", "payment:manage",
       "system:monitor", "system:audit",
       "analytics:view", "analytics:export",
       "role:assign", "role:revoke",
       "support:ticket:view", "support:ticket:respond", "support:ticket:close"]'::jsonb),
       
    ('moderator', 50, 'Moderator', 'Content moderation and user management',
     '["user:view", "user:suspend",
       "profile:view:all",
       "content:moderate", "content:delete", "content:restore",
       "message:view:all", "message:delete:any",
       "match:view:all",
       "analytics:view",
       "support:ticket:view", "support:ticket:respond"]'::jsonb),
       
    ('support', 40, 'Support', 'Customer support and assistance',
     '["user:view",
       "profile:view:all",
       "message:view:all",
       "match:view:all",
       "payment:view",
       "support:ticket:view", "support:ticket:respond", "support:ticket:close"]'::jsonb),
       
    ('premium_user', 30, 'Premium User', 'Paid subscription user with enhanced features',
     '[]'::jsonb),
     
    ('verified_user', 20, 'Verified User', 'Verified user with standard access',
     '[]'::jsonb),
     
    ('basic_user', 10, 'Basic User', 'Standard user with basic access',
     '[]'::jsonb),
     
    ('suspended_user', 0, 'Suspended User', 'Suspended account with no access',
     '[]'::jsonb)
ON CONFLICT (name) DO NOTHING;

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Function to get user's current role
CREATE OR REPLACE FUNCTION public.get_user_role(p_user_id UUID)
RETURNS TABLE (
    role_name TEXT,
    role_level INTEGER,
    permissions JSONB
) 
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        r.name,
        r.level,
        r.permissions
    FROM user_roles ur
    JOIN roles r ON ur.role_id = r.id
    WHERE ur.user_id = p_user_id
        AND ur.is_active = true
        AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
    LIMIT 1;
END;
$$;

-- Function to check if user has permission
CREATE OR REPLACE FUNCTION public.has_permission(
    p_user_id UUID,
    p_permission TEXT
)
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_permissions JSONB;
BEGIN
    -- Get user's permissions
    SELECT permissions INTO v_permissions
    FROM public.get_user_role(p_user_id);
    
    -- Check if permission exists in array
    RETURN v_permissions ? p_permission;
END;
$$;

-- Function to check if user has any of the specified permissions
CREATE OR REPLACE FUNCTION public.has_any_permission(
    p_user_id UUID,
    p_permissions TEXT[]
)
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_permissions JSONB;
    v_permission TEXT;
BEGIN
    -- Get user's permissions
    SELECT permissions INTO v_permissions
    FROM public.get_user_role(p_user_id);
    
    -- Check if any permission exists
    FOREACH v_permission IN ARRAY p_permissions
    LOOP
        IF v_permissions ? v_permission THEN
            RETURN true;
        END IF;
    END LOOP;
    
    RETURN false;
END;
$$;

-- Function to check role hierarchy
CREATE OR REPLACE FUNCTION public.can_manage_role(
    p_manager_id UUID,
    p_target_role TEXT
)
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_manager_level INTEGER;
    v_target_level INTEGER;
BEGIN
    -- Get manager's role level
    SELECT role_level INTO v_manager_level
    FROM public.get_user_role(p_manager_id);
    
    -- Get target role level
    SELECT level INTO v_target_level
    FROM roles
    WHERE name = p_target_role;
    
    -- Manager must have higher level than target role
    RETURN COALESCE(v_manager_level, 0) > COALESCE(v_target_level, 100);
END;
$$;

-- ============================================================================
-- ROW LEVEL SECURITY POLICIES
-- ============================================================================

-- Enable RLS on all tables
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_audit_logs ENABLE ROW LEVEL SECURITY;

-- ROLES TABLE POLICIES
-- Everyone can view active roles
CREATE POLICY "roles_select_all" ON public.roles
    FOR SELECT
    TO authenticated
    USING (is_active = true);

-- Only super admins can modify roles
CREATE POLICY "roles_insert_super_admin" ON public.roles
    FOR INSERT
    TO authenticated
    WITH CHECK (
        public.has_permission(auth.uid(), 'role:create')
    );

CREATE POLICY "roles_update_super_admin" ON public.roles
    FOR UPDATE
    TO authenticated
    USING (
        public.has_permission(auth.uid(), 'role:create')
    );

CREATE POLICY "roles_delete_super_admin" ON public.roles
    FOR DELETE
    TO authenticated
    USING (
        public.has_permission(auth.uid(), 'role:delete')
    );

-- USER ROLES TABLE POLICIES
-- Users can view their own role
CREATE POLICY "user_roles_select_own" ON public.user_roles
    FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

-- Admins can view all roles
CREATE POLICY "user_roles_select_admin" ON public.user_roles
    FOR SELECT
    TO authenticated
    USING (
        public.has_permission(auth.uid(), 'user:view')
    );

-- Role assignment requires permission and hierarchy check
CREATE POLICY "user_roles_insert_authorized" ON public.user_roles
    FOR INSERT
    TO authenticated
    WITH CHECK (
        assigned_by = auth.uid()
        AND public.has_permission(auth.uid(), 'role:assign')
        AND public.can_manage_role(auth.uid(), (
            SELECT name FROM roles WHERE id = role_id
        ))
    );

-- Role updates require permission
CREATE POLICY "user_roles_update_authorized" ON public.user_roles
    FOR UPDATE
    TO authenticated
    USING (
        public.has_permission(auth.uid(), 'role:assign')
        AND public.can_manage_role(auth.uid(), (
            SELECT name FROM roles r 
            JOIN user_roles ur ON ur.role_id = r.id 
            WHERE ur.user_id = user_roles.user_id
        ))
    );

-- ROLE AUDIT LOGS POLICIES
-- Users can view their own audit logs
CREATE POLICY "role_audit_select_own" ON public.role_audit_logs
    FOR SELECT
    TO authenticated
    USING (
        user_id = auth.uid() 
        OR target_user_id = auth.uid()
    );

-- Admins can view all audit logs
CREATE POLICY "role_audit_select_admin" ON public.role_audit_logs
    FOR SELECT
    TO authenticated
    USING (
        public.has_permission(auth.uid(), 'system:audit')
    );

-- System can insert audit logs
CREATE POLICY "role_audit_insert_system" ON public.role_audit_logs
    FOR INSERT
    TO authenticated
    WITH CHECK (
        user_id = auth.uid()
    );

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Update timestamp trigger
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply update trigger to tables
CREATE TRIGGER update_roles_updated_at
    BEFORE UPDATE ON public.roles
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_user_roles_updated_at
    BEFORE UPDATE ON public.user_roles
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at();

-- Trigger to expire roles automatically
CREATE OR REPLACE FUNCTION public.expire_user_roles()
RETURNS void AS $$
BEGIN
    -- Deactivate expired roles
    UPDATE public.user_roles
    SET is_active = false
    WHERE is_active = true
        AND expires_at IS NOT NULL
        AND expires_at < NOW();
        
    -- Log expirations
    INSERT INTO public.role_audit_logs (
        user_id,
        target_user_id,
        action,
        previous_role,
        new_role,
        reason,
        metadata
    )
    SELECT 
        'system',
        ur.user_id,
        'expire',
        r.name,
        NULL,
        'Role expired',
        jsonb_build_object(
            'expired_at', ur.expires_at,
            'role_id', ur.role_id
        )
    FROM public.user_roles ur
    JOIN public.roles r ON ur.role_id = r.id
    WHERE ur.is_active = false
        AND ur.expires_at IS NOT NULL
        AND ur.expires_at < NOW()
        AND NOT EXISTS (
            SELECT 1 FROM public.role_audit_logs ral
            WHERE ral.target_user_id = ur.user_id
                AND ral.action = 'expire'
                AND ral.created_at > ur.expires_at
        );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- GRANT PERMISSIONS
-- ============================================================================

-- Grant necessary permissions to authenticated users
GRANT SELECT ON public.roles TO authenticated;
GRANT ALL ON public.user_roles TO authenticated;
GRANT ALL ON public.role_audit_logs TO authenticated;

-- Grant execute permissions on functions
GRANT EXECUTE ON FUNCTION public.get_user_role(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_permission(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_any_permission(UUID, TEXT[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_role(UUID, TEXT) TO authenticated;

-- ============================================================================
-- COMMENTS FOR DOCUMENTATION
-- ============================================================================

COMMENT ON TABLE public.roles IS 'Defines available roles in the RBAC system';
COMMENT ON TABLE public.user_roles IS 'Maps users to their assigned roles';
COMMENT ON TABLE public.role_audit_logs IS 'Audit trail for all role changes';

COMMENT ON COLUMN public.roles.level IS 'Numeric level for role hierarchy (0-100)';
COMMENT ON COLUMN public.roles.permissions IS 'JSON array of permission strings';
COMMENT ON COLUMN public.user_roles.expires_at IS 'Optional expiration timestamp for temporary roles';
COMMENT ON COLUMN public.user_roles.is_active IS 'Whether this role assignment is currently active';

-- ============================================================================
-- END OF RBAC SYSTEM MIGRATION
-- ============================================================================