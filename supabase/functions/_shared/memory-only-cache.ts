// Memory-only cache system for testing

class SimpleMemoryCache {
  private cache = new Map<string, { value: any; expires: number }>();

  set(key: string, value: any, ttlSeconds: number): boolean {
    const expires = Date.now() + (ttlSeconds * 1000);
    this.cache.set(key, { value, expires });
    return true;
  }

  get(key: string): any | null {
    const item = this.cache.get(key);

    if (!item) {
      return null;
    }

    if (Date.now() > item.expires) {
      this.cache.delete(key);
      return null;
    }

    return item.value;
  }

  delete(key: string): boolean {
    return this.cache.delete(key);
  }

  clear(): void {
    this.cache.clear();
  }
}

let cacheInstance: SimpleMemoryCache | null = null;

export function getMemoryOnlyCache(): SimpleMemoryCache {
  if (!cacheInstance) {
    cacheInstance = new SimpleMemoryCache();
  }
  return cacheInstance;
}
