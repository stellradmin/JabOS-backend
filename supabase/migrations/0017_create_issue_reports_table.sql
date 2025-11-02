-- Create issue_reports table
CREATE TABLE IF NOT EXISTS issue_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    issue_description TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'resolved', 'closed')),
    admin_notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_issue_reports_user_id ON issue_reports(user_id);
CREATE INDEX IF NOT EXISTS idx_issue_reports_status ON issue_reports(status);
CREATE INDEX IF NOT EXISTS idx_issue_reports_created_at ON issue_reports(created_at);

-- Enable RLS (Row Level Security)
ALTER TABLE issue_reports ENABLE ROW LEVEL SECURITY;

-- Create policies
-- Users can only see their own reports
CREATE POLICY "Users can view their own issue reports" ON issue_reports
    FOR SELECT USING (auth.uid() = user_id);

-- Users can only insert their own reports
CREATE POLICY "Users can insert their own issue reports" ON issue_reports
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Users cannot update or delete their reports (admin only)
-- Admin policies would be added separately with appropriate roles

-- Create trigger to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_issue_reports_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_issue_reports_updated_at
    BEFORE UPDATE ON issue_reports
    FOR EACH ROW
    EXECUTE FUNCTION update_issue_reports_updated_at();
