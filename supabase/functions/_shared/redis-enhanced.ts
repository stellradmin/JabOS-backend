// Production-Ready Redis Caching System for Stellr
// Advanced caching with performance monitoring, graceful fallbacks, and intelligent invalidation

import { UpstashFetchClient } from "./upstash-fetch-client.ts";
import { getEnvStatusReport, safeGetEnv } from "./env-utils.ts";

interface CacheConfig {
  defaultTTL: number;
  maxRetries: number;
  retryDelay: number;
  enableMetrics: boolean;
  compressionThreshold: number;
}

interface CacheMetrics {
  hits: number;
  misses: number;
  errors: number;
  totalRequests: number;
  averageResponseTime: number;
  lastReset: string;
}

interface CacheOptions {
  ttl?: number;
  tags?: string[];
  compress?: boolean;
  namespace?: string;
}

class ProductionRedisCache {
  private client: UpstashFetchClient | null = null;
  private config: CacheConfig;
  private metrics: CacheMetrics;
  private isConnected: boolean = false;
  private connectionPromise: Promise<void> | null = null;
  private lastConnectionError: string | null = null;

  constructor(config: Partial<CacheConfig> = {}) {
    this.config = {
      defaultTTL: 3600, // 1 hour
      maxRetries: 3,
      retryDelay: 1000, // 1 second
      enableMetrics: true,
      compressionThreshold: 1024, // 1KB
      ...config,
    };

    this.initializeMetricsState();
    // Don't initialize in constructor - will initialize lazily on first use
    // this.initialize();
  }

  private initializeMetricsState(): void {
    this.metrics = {
      hits: 0,
      misses: 0,
      errors: 0,
      totalRequests: 0,
      averageResponseTime: 0,
      lastReset: new Date().toISOString(),
    };
  }

  private async initialize(): Promise<void> {
    if (this.connectionPromise) {
      return this.connectionPromise;
    }

    this.connectionPromise = this.connect();
    return this.connectionPromise;
  }

  private async connect(): Promise<void> {
    const redisUrl = safeGetEnv('UPSTASH_REDIS_REST_URL') || safeGetEnv('REDIS_URL');
    const redisToken = safeGetEnv('UPSTASH_REDIS_REST_TOKEN') || safeGetEnv('REDIS_TOKEN');

    if (!redisUrl) {
      const envReport = getEnvStatusReport(['UPSTASH_REDIS_REST_URL', 'REDIS_URL']);
      const reason = envReport.permissionDenied.length > 0
        ? `permission-denied:${envReport.permissionDenied.join(',')}`
        : 'missing-url';
      this.client = null;
      this.isConnected = false;
      this.lastConnectionError = reason;
      this.connectionPromise = null;
      return;
    }

    try {
      this.client = new UpstashFetchClient({
        url: redisUrl,
        token: redisToken || undefined,
      });

      // Test connection with ping
      await this.executeWithRetry(async () => {
        await this.client!.ping();
        return true;
      });

      this.isConnected = true;
      this.lastConnectionError = null;
      // Debug logging removed for security
      // DENO FIX: Comment out timer-based metrics to prevent bundling crash
      // setInterval is forbidden during module initialization in Deno Edge Functions
      // if (this.config.enableMetrics) {
      //   this.startMetricsReporting();
      // }

    } catch (error) {
      this.client = null;
      this.isConnected = false;
      this.lastConnectionError = error instanceof Error ? error.message : 'unknown-error';
    } finally {
      this.connectionPromise = null;
    }
  }

  private async executeWithRetry<T>(operation: () => Promise<T>): Promise<T | null> {
    if (!this.client) {
      return null;
    }

    let lastError: Error | null = null;
    
    for (let attempt = 1; attempt <= this.config.maxRetries; attempt++) {
      try {
        const startTime = performance.now();
        const result = await operation();
        const duration = performance.now() - startTime;
        
        if (this.config.enableMetrics) {
          this.updateMetrics('success', duration);
        }
        
        return result;
      } catch (error) {
        lastError = error as Error;
        
        if (this.config.enableMetrics) {
          this.metrics.errors++;
          this.updateMetrics('error', 0);
        }
        
        // Retry logic with exponential backoff
        if (attempt < this.config.maxRetries) {
          const delay = this.config.retryDelay * Math.pow(2, attempt - 1);
          await new Promise(resolve => setTimeout(resolve, delay));
}
      }
    }
    
return null;
  }

  private updateMetrics(type: 'success' | 'error', duration: number): void {
    this.metrics.totalRequests++;
    
    if (type === 'success' && duration > 0) {
      this.metrics.averageResponseTime = 
        (this.metrics.averageResponseTime * (this.metrics.totalRequests - 1) + duration) / 
        this.metrics.totalRequests;
    }
  }

  private generateKey(baseKey: string, options: CacheOptions = {}): string {
    const namespace = options.namespace || 'stellr';
    return `${namespace}:${baseKey}`;
  }

  private compressData(data: string): string {
    // Simple compression check - in production you might want to use actual compression
    if (data.length > this.config.compressionThreshold) {
      try {
        // For now, just mark as compressed but don't actually compress
        // In production, implement proper compression here
        return `compressed:${data}`;
      } catch (error) {
return data;
      }
    }
    return data;
  }

  private decompressData(data: string): string {
    if (data.startsWith('compressed:')) {
      return data.substring(11); // Remove 'compressed:' prefix
    }
    return data;
  }

  async get<T>(key: string, options: CacheOptions = {}): Promise<T | null> {
    await this.initialize();
    
    if (!this.isConnected) {
      return null;
    }

    const cacheKey = this.generateKey(key, options);
    
    const result = await this.executeWithRetry(async () => {
      return await this.client!.get(cacheKey);
    });
    
    if (result !== null) {
      if (this.config.enableMetrics) {
        this.metrics.hits++;
      }
      
      try {
        const decompressed = this.decompressData(result as string);
        return JSON.parse(decompressed) as T;
      } catch (error) {
await this.delete(key, options); // Remove corrupted data
        return null;
      }
    }
    
    if (this.config.enableMetrics) {
      this.metrics.misses++;
    }
    
    return null;
  }

  async set(key: string, value: any, options: CacheOptions = {}): Promise<boolean> {
    await this.initialize();
    
    if (!this.isConnected) {
      return false;
    }

    const cacheKey = this.generateKey(key, options);
    const ttl = options.ttl || this.config.defaultTTL;
    
    try {
      const serialized = JSON.stringify(value);
      const compressed = options.compress !== false ? this.compressData(serialized) : serialized;
      
      const success = await this.executeWithRetry(async () => {
        await this.client!.setex(cacheKey, ttl, compressed);
        return true;
      });
      
      if (success && options.tags && options.tags.length > 0) {
        await this.setTags(cacheKey, options.tags, ttl, options);
      }
      
      return success !== null;
    } catch (error) {
return false;
    }
  }

  private async setTags(cacheKey: string, tags: string[], ttl: number, options: CacheOptions = {}): Promise<void> {
    for (const tag of tags) {
      const tagKey = this.generateKey(`tag:${tag}`, options);
      await this.executeWithRetry(async () => {
        await this.client!.sadd(tagKey, cacheKey);
        await this.client!.expire(tagKey, ttl + 3600); // Keep tags longer than data
        return true;
      });
    }
  }

  async delete(key: string, options: CacheOptions = {}): Promise<boolean> {
    await this.initialize();
    
    if (!this.isConnected) {
      return false;
    }

    const cacheKey = this.generateKey(key, options);
    
    const result = await this.executeWithRetry(async () => {
      await this.client!.del(cacheKey);
      return true;
    });
    
    return result !== null;
  }

  async invalidateByTags(tags: string[], options: CacheOptions = {}): Promise<number> {
    await this.initialize();
    
    if (!this.isConnected) {
      return 0;
    }

    let invalidatedCount = 0;
    
    for (const tag of tags) {
      const tagKey = this.generateKey(`tag:${tag}`, options);
      
      const keys = await this.executeWithRetry(async () => {
        return await this.client!.smembers(tagKey);
      });
      
      if (keys && keys.length > 0) {
        const deleteResult = await this.executeWithRetry(async () => {
          await this.client!.del(...keys, tagKey);
          return keys.length;
        });
        
        if (deleteResult) {
          invalidatedCount += deleteResult;
          // Debug logging removed for security
}
      }
    }
    
    return invalidatedCount;
  }

  async getOrSet<T>(
    key: string,
    fetcher: () => Promise<T>,
    options: CacheOptions = {}
  ): Promise<T> {
    // Try to get from cache first
    const cached = await this.get<T>(key, options);
    
    if (cached !== null) {
      return cached;
    }
    
    // Cache miss - fetch from source
    try {
      const data = await fetcher();
      
      // Store in cache for future requests
      await this.set(key, data, options);
      
      return data;
    } catch (error) {
throw error;
    }
  }

  async multiGet<T>(keys: string[], options: CacheOptions = {}): Promise<(T | null)[]> {
    await this.initialize();
    
    if (!this.isConnected) {
      return new Array(keys.length).fill(null);
    }

    const cacheKeys = keys.map(key => this.generateKey(key, options));
    
    const results = await this.executeWithRetry(async () => {
      return await this.client!.mget(...cacheKeys);
    });
    
    if (!results) {
      return new Array(keys.length).fill(null);
    }
    
    return results.map(result => {
      if (result === null) {
        if (this.config.enableMetrics) {
          this.metrics.misses++;
        }
        return null;
      }
      
      if (this.config.enableMetrics) {
        this.metrics.hits++;
      }
      
      try {
        const decompressed = this.decompressData(result as string);
        return JSON.parse(decompressed) as T;
      } catch {
        return null;
      }
    });
  }

  async increment(key: string, amount: number = 1, options: CacheOptions = {}): Promise<number | null> {
    await this.initialize();
    
    if (!this.isConnected) {
      return null;
    }

    const cacheKey = this.generateKey(key, options);
    
    const result = await this.executeWithRetry(async () => {
      return await this.client!.incrby(cacheKey, amount);
    });
    
    // Set expiration if this is a new key
    if (result === amount && options.ttl) {
      await this.executeWithRetry(async () => {
        await this.client!.expire(cacheKey, options.ttl!);
        return true;
      });
    }
    
    return result;
  }

  async exists(key: string, options: CacheOptions = {}): Promise<boolean> {
    await this.initialize();
    
    if (!this.isConnected) {
      return false;
    }

    const cacheKey = this.generateKey(key, options);
    
    const result = await this.executeWithRetry(async () => {
      return await this.client!.exists(cacheKey);
    });
    
    return result === 1;
  }

  async ttl(key: string, options: CacheOptions = {}): Promise<number | null> {
    await this.initialize();
    
    if (!this.isConnected) {
      return null;
    }

    const cacheKey = this.generateKey(key, options);
    
    return await this.executeWithRetry(async () => {
      return await this.client!.ttl(cacheKey);
    });
  }

  getMetrics(): CacheMetrics {
    return { ...this.metrics };
  }

  getHealthStatus(): { connected: boolean; metrics: CacheMetrics; config: CacheConfig } {
    return {
      connected: this.isConnected,
      metrics: this.getMetrics(),
      config: this.config,
    };
  }

  async flushNamespace(namespace: string = 'stellr'): Promise<number> {
    await this.initialize();
    
    if (!this.isConnected) {
      return 0;
    }

    const pattern = `${namespace}:*`;
    
    // Note: KEYS command can be expensive on large datasets
    // In production, consider using SCAN instead
    const keys = await this.executeWithRetry(async () => {
      return await this.client!.keys(pattern);
    });
    
    if (keys && keys.length > 0) {
      const result = await this.executeWithRetry(async () => {
        await this.client!.del(...keys);
        return keys.length;
      });
      
      return result || 0;
    }
    
    return 0;
  }

  private startMetricsReporting(): void {
    // Report metrics every 5 minutes
    setInterval(() => {
      const metrics = this.getMetrics();
      // Debug logging removed for security - metrics collected for monitoring
    }, 5 * 60 * 1000); // 5 minutes
  }

  getDiagnostics() {
    return {
      connected: this.isConnected,
      lastConnectionError: this.lastConnectionError,
    };
  }

  resetMetrics(): void {
    this.initializeMetricsState();
  }
}

// Singleton instance
let cacheInstance: ProductionRedisCache | null = null;

export function getEnhancedCache(): ProductionRedisCache {
  if (!cacheInstance) {
    cacheInstance = new ProductionRedisCache();
  }
  return cacheInstance;
}

// Enhanced convenience functions
export async function getCachedData<T>(
  key: string,
  ttlSeconds: number,
  dataFetcher: () => Promise<T>,
  tags: string[] = []
): Promise<T> {
  const cache = getEnhancedCache();
  return await cache.getOrSet(key, dataFetcher, { ttl: ttlSeconds, tags });
}

// Cache key generators for Stellr-specific patterns
export const StellarCacheKeys = {
  user: (userId: string) => `user:${userId}`,
  userProfile: (userId: string) => `profile:${userId}`,
  userSettings: (userId: string) => `settings:${userId}`,
  
  compatibility: (user1Id: string, user2Id: string) => {
    const [id1, id2] = [user1Id, user2Id].sort();
    return `compatibility:${id1}:${id2}`;
  },
  
  potentialMatches: (userId: string, filters?: Record<string, any>) => {
    const filterKey = filters ? ':' + btoa(JSON.stringify(filters)) : '';
    return `matches:${userId}${filterKey}`;
  },
  
  conversation: (conversationId: string) => `conversation:${conversationId}`,
  conversationMessages: (conversationId: string, page: number = 1) => 
    `messages:${conversationId}:page:${page}`,
  
  userConversations: (userId: string) => `user-conversations:${userId}`,
  
  subscription: (userId: string) => `subscription:${userId}`,
  subscriptionFeatures: (userId: string) => `features:${userId}`,
  
  analytics: (metric: string, period: string) => `analytics:${metric}:${period}`,
  
  rateLimit: (identifier: string, window: string) => `ratelimit:${identifier}:${window}`,
  
  session: (sessionId: string) => `session:${sessionId}`,
  authToken: (tokenHash: string) => `auth:${tokenHash}`,
};

// Cache tags for intelligent invalidation
export const StellarCacheTags = {
  user: (userId: string) => [`user-${userId}`, 'users'],
  profile: (userId: string) => [`profile-${userId}`, 'profiles'],
  matches: (userId: string) => [`matches-${userId}`, 'matching'],
  conversation: (conversationId: string) => [`conversation-${conversationId}`, 'messaging'],
  subscription: (userId: string) => [`subscription-${userId}`, 'subscriptions'],
  compatibility: ['compatibility', 'matching'],
  analytics: ['analytics'],
  global: ['global'],
};

export { ProductionRedisCache };
