# JabOS Backend

Database infrastructure and migrations for JabOS platform.

## 📁 Structure

```
backend/
└── supabase/
    ├── config.toml              # Supabase configuration
    ├── migrations/              # Database migrations (18 files)
    │   ├── 20250101000000_create_organizations.sql
    │   ├── 20250101000001_create_users.sql
    │   ├── ...
    │   └── 20250101000018_add_user_settings.sql
    └── seed.sql                 # Development seed data
```

## 🗄️ Database Schema

### Organizations & Users
- `organizations` - Gym/facility accounts
- `users` - All platform users (owners, coaches, members)
- `member_profiles` - Extended member information

### Classes & Scheduling
- `classes` - Class templates
- `class_instances` - Scheduled class sessions
- `bookings` - Class reservations
- `attendance` - Check-in records

### Training & Sparring
- `timer_presets` - Round timer configurations
- `workout_logs` - Training session tracking
- `sparring_matches` - Sparring partnerships and requests

### Business Operations
- `membership_plans` - Subscription tiers
- `member_subscriptions` - Active memberships
- `messages` - Internal messaging
- `announcements` - Gym-wide announcements
- `gym_metrics` - Analytics data

### Payment Integration
- `stripe_customers` - Stripe customer records
- `subscriptions` - Stripe subscription data
- `invoices` - Payment invoices

## 🔐 Security

All tables include:
- **Row Level Security (RLS)** policies
- **Multi-tenant isolation** via `organization_id`
- **Soft deletes** where appropriate
- **Timestamps** (created_at, updated_at)

## 🚀 Local Development

### Setup Local Database

```bash
# Install Supabase CLI
npm install -g supabase

# Start local Supabase
npx supabase start

# Migrations will run automatically
```

### Reset Database

```bash
# Reset and reapply all migrations
npx supabase db reset
```

### Load Seed Data

⚠️ **Development only! This deletes all data!**

```bash
# After starting local Supabase
psql -h localhost -p 54322 -U postgres -f supabase/seed.sql
```

## ☁️ Cloud Deployment

### Link to Cloud Project

```bash
# Replace with your project ref
npx supabase link --project-ref your-project-ref
```

### Push Migrations

```bash
# Push all migrations to cloud
npx supabase db push
```

### Verify Migrations

```bash
# List applied migrations
npx supabase migration list

# Check migration status
npx supabase db remote commit
```

## 📝 Creating New Migrations

```bash
# Create new migration file
npx supabase migration new your_migration_name

# Edit the generated file in migrations/
# Then test locally:
npx supabase db reset
```

## 🛠️ Database Tools

### Access Database Directly

**Local:**
```bash
psql -h localhost -p 54322 -U postgres
```

**Cloud:**
```bash
# Get connection string from Supabase dashboard
psql postgresql://postgres:[password]@[host]:5432/postgres
```

### Run SQL Queries

```bash
# Execute SQL file
psql -h localhost -p 54322 -U postgres -f your-query.sql

# Interactive mode
npx supabase db shell
```

## 📊 Database Statistics

```sql
-- Check table sizes
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- Check row counts
SELECT
    schemaname,
    tablename,
    n_live_tup as row_count
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC;
```

## 🔍 Troubleshooting

### Migration Fails

```bash
# Check current migration status
npx supabase migration list

# Repair migration history
npx supabase migration repair --status reverted <version>

# Force reapply
npx supabase db reset
```

### RLS Policy Issues

```bash
# Test RLS policy
SELECT * FROM your_table; -- Should fail without auth

# Check if RLS is enabled
SELECT tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'public';
```

### Connection Issues

```bash
# Check if local Supabase is running
npx supabase status

# Restart local Supabase
npx supabase stop
npx supabase start
```

## 📖 Resources

- [Supabase Docs](https://supabase.com/docs)
- [PostgreSQL Docs](https://www.postgresql.org/docs/)
- [RLS Guide](https://supabase.com/docs/guides/auth/row-level-security)

---

See [../DEPLOYMENT.md](../DEPLOYMENT.md) for production deployment instructions.
