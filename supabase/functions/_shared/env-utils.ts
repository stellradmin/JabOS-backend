/**
 * Shared helpers for accessing environment variables inside Edge Functions.
 * Provides a safe wrapper around Deno.env to avoid crashes when env access
 * is not permitted (for example during local tests without --allow-env).
 */

type EnvCacheEntry = {
  value?: string;
  reason: 'value' | 'missing' | 'permission-denied' | 'error';
  errorMessage?: string;
};

const envCache = new Map<string, EnvCacheEntry>();

function cacheResult(key: string, entry: EnvCacheEntry) {
  envCache.set(key, entry);
}

export function safeGetEnv(key: string): string | undefined {
  const cached = envCache.get(key);
  if (cached) {
    return cached.value;
  }

  try {
    const value = Deno.env.get(key);
    if (value === undefined || value === null) {
      cacheResult(key, { reason: 'missing' });
      return undefined;
    }

    cacheResult(key, { reason: 'value', value });
    return value;
  } catch (error) {
    if (error instanceof Deno.errors.PermissionDenied) {
      cacheResult(key, { reason: 'permission-denied' });
      return undefined;
    }

    cacheResult(key, { reason: 'error', errorMessage: error instanceof Error ? error.message : String(error) });
    return undefined;
  }
}

export interface EnvStatusReport {
  missing: string[];
  permissionDenied: string[];
  errors: Array<{ key: string; message: string }>;
}

export function getEnvStatusReport(keys: string[]): EnvStatusReport {
  const report: EnvStatusReport = {
    missing: [],
    permissionDenied: [],
    errors: []
  };

  for (const key of keys) {
    const entry = envCache.get(key) ?? (safeGetEnv(key), envCache.get(key));

    if (!entry) {
      report.missing.push(key);
      continue;
    }

    switch (entry.reason) {
      case 'value':
        break;
      case 'missing':
        report.missing.push(key);
        break;
      case 'permission-denied':
        report.permissionDenied.push(key);
        break;
      case 'error':
        report.errors.push({ key, message: entry.errorMessage ?? 'Unknown error' });
        break;
    }
  }

  return report;
}

export function clearEnvCacheForTesting(): void {
  envCache.clear();
}
