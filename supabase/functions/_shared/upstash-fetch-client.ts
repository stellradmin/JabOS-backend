/**
 * Upstash REST API Client for Deno Edge Functions
 *
 * Lightweight fetch-based Redis client that eliminates SDK dependencies
 * and resolves BOOT_ERROR issues in Supabase Edge Functions.
 *
 * Uses Upstash REST API directly: https://docs.upstash.com/redis/features/restapi
 */

interface UpstashConfig {
  url: string;
  token?: string;
}

interface UpstashResponse<T = any> {
  result: T;
  error?: string;
}

export class UpstashFetchClient {
  private baseUrl: string;
  private token?: string;
  private maxRetries: number = 3;
  private retryDelay: number = 1000; // 1 second

  constructor(config: UpstashConfig) {
    // Remove trailing slash from URL
    this.baseUrl = config.url.replace(/\/$/, '');
    this.token = config.token;
  }

  /**
   * Execute Upstash REST API command with retry logic
   */
  private async execute<T = any>(
    command: string[],
    attempt: number = 1
  ): Promise<T> {
    const url = `${this.baseUrl}/${command.map(encodeURIComponent).join('/')}`;

    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
      };

      if (this.token) {
        headers['Authorization'] = `Bearer ${this.token}`;
      }

      const response = await fetch(url, {
        method: 'GET',
        headers,
      });

      if (!response.ok) {
        throw new Error(`Upstash API error: ${response.status} ${response.statusText}`);
      }

      const data: UpstashResponse<T> = await response.json();

      if (data.error) {
        throw new Error(`Upstash error: ${data.error}`);
      }

      return data.result;
    } catch (error) {
      // Retry logic
      if (attempt < this.maxRetries) {
        const delay = this.retryDelay * Math.pow(2, attempt - 1);
        await new Promise(resolve => setTimeout(resolve, delay));
        return this.execute<T>(command, attempt + 1);
      }

      throw error;
    }
  }

  /**
   * POST method for commands that send data in body
   */
  private async executePost<T = any>(
    command: string[],
    body?: any,
    attempt: number = 1
  ): Promise<T> {
    const url = `${this.baseUrl}/${command.map(encodeURIComponent).join('/')}`;

    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
      };

      if (this.token) {
        headers['Authorization'] = `Bearer ${this.token}`;
      }

      const response = await fetch(url, {
        method: 'POST',
        headers,
        body: body ? JSON.stringify(body) : undefined,
      });

      if (!response.ok) {
        throw new Error(`Upstash API error: ${response.status} ${response.statusText}`);
      }

      const data: UpstashResponse<T> = await response.json();

      if (data.error) {
        throw new Error(`Upstash error: ${data.error}`);
      }

      return data.result;
    } catch (error) {
      // Retry logic
      if (attempt < this.maxRetries) {
        const delay = this.retryDelay * Math.pow(2, attempt - 1);
        await new Promise(resolve => setTimeout(resolve, delay));
        return this.executePost<T>(command, body, attempt + 1);
      }

      throw error;
    }
  }

  /**
   * PING - Test connection
   */
  async ping(): Promise<string> {
    return await this.execute<string>(['ping']);
  }

  /**
   * GET - Retrieve value by key
   */
  async get(key: string): Promise<string | null> {
    return await this.execute<string | null>(['get', key]);
  }

  /**
   * SET - Set key to value
   */
  async set(key: string, value: string): Promise<string> {
    return await this.execute<string>(['set', key, value]);
  }

  /**
   * SETEX - Set key to value with expiration in seconds
   */
  async setex(key: string, seconds: number, value: string): Promise<string> {
    return await this.execute<string>(['setex', key, seconds.toString(), value]);
  }

  /**
   * DEL - Delete one or more keys
   */
  async del(...keys: string[]): Promise<number> {
    return await this.execute<number>(['del', ...keys]);
  }

  /**
   * EXISTS - Check if key exists
   */
  async exists(key: string): Promise<number> {
    return await this.execute<number>(['exists', key]);
  }

  /**
   * TTL - Get time to live for key in seconds
   */
  async ttl(key: string): Promise<number> {
    return await this.execute<number>(['ttl', key]);
  }

  /**
   * EXPIRE - Set expiration for key in seconds
   */
  async expire(key: string, seconds: number): Promise<number> {
    return await this.execute<number>(['expire', key, seconds.toString()]);
  }

  /**
   * INCRBY - Increment key by amount
   */
  async incrby(key: string, increment: number): Promise<number> {
    return await this.execute<number>(['incrby', key, increment.toString()]);
  }

  /**
   * MGET - Get multiple values by keys
   */
  async mget(...keys: string[]): Promise<(string | null)[]> {
    return await this.execute<(string | null)[]>(['mget', ...keys]);
  }

  /**
   * SADD - Add members to a set
   */
  async sadd(key: string, ...members: string[]): Promise<number> {
    return await this.execute<number>(['sadd', key, ...members]);
  }

  /**
   * SMEMBERS - Get all members of a set
   */
  async smembers(key: string): Promise<string[]> {
    return await this.execute<string[]>(['smembers', key]);
  }

  /**
   * KEYS - Find keys matching pattern
   * Note: Use with caution in production, can be slow on large datasets
   */
  async keys(pattern: string): Promise<string[]> {
    return await this.execute<string[]>(['keys', pattern]);
  }

  /**
   * SCAN - Iterate keys matching pattern (better than KEYS for production)
   */
  async scan(cursor: string = '0', pattern?: string, count?: number): Promise<[string, string[]]> {
    const command = ['scan', cursor];
    if (pattern) {
      command.push('match', pattern);
    }
    if (count) {
      command.push('count', count.toString());
    }
    return await this.execute<[string, string[]]>(command);
  }
}

export default UpstashFetchClient;
