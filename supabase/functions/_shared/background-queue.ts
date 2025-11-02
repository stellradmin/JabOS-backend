/**
 * Background Processing Queue System for Stellr
 * 
 * Features:
 * - Priority-based job processing
 * - Retry logic with exponential backoff
 * - Job persistence and recovery
 * - Rate limiting and concurrency control
 * - Progress tracking and notifications
 * - Dead letter queue for failed jobs
 * - Performance monitoring and metrics
 * 
 * Use Cases:
 * - Compatibility calculations (expensive)
 * - Match recommendation generation
 * - User data synchronization
 * - Analytics and metrics processing
 * - Image processing and optimization
 * - Push notification sending
 */

import { getAdvancedCache } from './advanced-cache-system.ts';
import { getConnectionPool } from './connection-pool.ts';

export interface Job {
  id: string;
  type: string;
  priority: 'low' | 'medium' | 'high' | 'critical';
  payload: any;
  userId?: string;
  attempts: number;
  maxAttempts: number;
  createdAt: number;
  scheduledAt: number;
  startedAt?: number;
  completedAt?: number;
  failedAt?: number;
  error?: string;
  progress?: number;
  status: 'pending' | 'running' | 'completed' | 'failed' | 'retrying';
  metadata?: Record<string, any>;
}

export interface JobHandler {
  (job: Job): Promise<any>;
}

export interface QueueConfig {
  maxConcurrency: number;
  defaultMaxAttempts: number;
  defaultRetryDelay: number;
  retryBackoffMultiplier: number;
  jobTimeoutMs: number;
  cleanupIntervalMs: number;
  enablePersistence: boolean;
  enableMetrics: boolean;
}

export interface QueueMetrics {
  totalJobs: number;
  pendingJobs: number;
  runningJobs: number;
  completedJobs: number;
  failedJobs: number;
  averageProcessingTime: number;
  throughputPerSecond: number;
  errorRate: number;
  queueLatency: number;
}

class JobQueue {
  private jobs: Map<string, Job> = new Map();
  private handlers: Map<string, JobHandler> = new Map();
  private runningJobs: Set<string> = new Set();
  private retryQueue: Job[] = [];
  private deadLetterQueue: Job[] = [];
  private config: QueueConfig;
  private metrics: QueueMetrics;
  private processingInterval: number | null = null;
  private cleanupInterval: number | null = null;
  private cache = getAdvancedCache();
  private db = getConnectionPool();

  constructor(config: Partial<QueueConfig> = {}) {
    this.config = {
      maxConcurrency: 10,
      defaultMaxAttempts: 3,
      defaultRetryDelay: 1000,
      retryBackoffMultiplier: 2,
      jobTimeoutMs: 300000, // 5 minutes
      cleanupIntervalMs: 60000, // 1 minute
      enablePersistence: true,
      enableMetrics: true,
      ...config
    };

    this.metrics = {
      totalJobs: 0,
      pendingJobs: 0,
      runningJobs: 0,
      completedJobs: 0,
      failedJobs: 0,
      averageProcessingTime: 0,
      throughputPerSecond: 0,
      errorRate: 0,
      queueLatency: 0
    };

    // Defer initialization to prevent BOOT_ERROR in Edge Functions
    // this.initialize();
  }

  private async initialize(): Promise<void> {
    if (this.config.enablePersistence) {
      await this.loadPersistedJobs();
    }

    this.startProcessing();
    this.startCleanup();
    this.startMetricsCollection();

    // Debug logging removed for security
}

  /**
   * Register a job handler for a specific job type
   */
  registerHandler(jobType: string, handler: JobHandler): void {
    this.handlers.set(jobType, handler);
    // Debug logging removed for security
}

  /**
   * Add a job to the queue
   */
  async addJob(
    type: string,
    payload: any,
    options: {
      priority?: Job['priority'];
      userId?: string;
      delay?: number;
      maxAttempts?: number;
      metadata?: Record<string, any>;
    } = {}
  ): Promise<string> {
    const timestamp = Date.now();
    const randomStr = Math.random().toString(36).substr(2, 9);
    const jobId = 'job_' + timestamp + '_' + randomStr;
    const now = Date.now();

    const job: Job = {
      id: jobId,
      type,
      priority: options.priority || 'medium',
      payload,
      userId: options.userId,
      attempts: 0,
      maxAttempts: options.maxAttempts || this.config.defaultMaxAttempts,
      createdAt: now,
      scheduledAt: now + (options.delay || 0),
      status: 'pending',
      metadata: options.metadata
    };

    this.jobs.set(jobId, job);
    this.metrics.totalJobs++;
    this.metrics.pendingJobs++;

    if (this.config.enablePersistence) {
      await this.persistJob(job);
    }

    // Debug logging removed for security
return jobId;
  }

  /**
   * Get job status and progress
   */
  getJob(jobId: string): Job | null {
    return this.jobs.get(jobId) || null;
  }

  /**
   * Cancel a pending job
   */
  async cancelJob(jobId: string): Promise<boolean> {
    const job = this.jobs.get(jobId);
    
    if (!job) {
      return false;
    }

    if (job.status === 'running') {
return false;
    }

    if (job.status === 'pending' || job.status === 'retrying') {
      job.status = 'failed';
      job.error = 'Job cancelled by user';
      job.failedAt = Date.now();

      this.metrics.pendingJobs--;
      this.metrics.failedJobs++;

      if (this.config.enablePersistence) {
        await this.persistJob(job);
      }

      // Debug logging removed for security
return true;
    }

    return false;
  }

  /**
   * Get queue metrics
   */
  getMetrics(): QueueMetrics {
    // Update real-time metrics
    this.metrics.pendingJobs = Array.from(this.jobs.values())
      .filter(job => job.status === 'pending' || job.status === 'retrying').length;
    
    this.metrics.runningJobs = this.runningJobs.size;

    return { ...this.metrics };
  }

  /**
   * Start processing jobs
   */
  private startProcessing(): void {
    this.processingInterval = setInterval(async () => {
      await this.processJobs();
    }, 1000); // Check every second
  }

  /**
   * Process available jobs
   */
  private async processJobs(): Promise<void> {
    if (this.runningJobs.size >= this.config.maxConcurrency) {
      return; // At capacity
    }

    // Get available jobs sorted by priority and creation time
    const availableJobs = Array.from(this.jobs.values())
      .filter(job => 
        (job.status === 'pending' || job.status === 'retrying') &&
        job.scheduledAt <= Date.now() &&
        !this.runningJobs.has(job.id)
      )
      .sort((a, b) => {
        // Priority order: critical > high > medium > low
        const priorityOrder = { critical: 4, high: 3, medium: 2, low: 1 };
        const priorityDiff = priorityOrder[b.priority] - priorityOrder[a.priority];
        
        if (priorityDiff !== 0) return priorityDiff;
        
        // Then by creation time (oldest first)
        return a.createdAt - b.createdAt;
      });

    const slotsAvailable = this.config.maxConcurrency - this.runningJobs.size;
    const jobsToProcess = availableJobs.slice(0, slotsAvailable);

    // Process jobs concurrently
    await Promise.all(
      jobsToProcess.map(job => this.processJob(job))
    );
  }

  /**
   * Process a single job
   */
  private async processJob(job: Job): Promise<void> {
    const handler = this.handlers.get(job.type);
    
    if (!handler) {
      await this.failJob(job, 'No handler registered for job type: ' + job.type);
      return;
    }

    this.runningJobs.add(job.id);
    job.status = 'running';
    job.startedAt = Date.now();
    job.attempts++;

    this.metrics.pendingJobs--;
    this.metrics.runningJobs++;

    // Debug logging removed for security

    if (this.config.enablePersistence) {
      await this.persistJob(job);
    }

    try {
      // Set up timeout
      const timeoutPromise = new Promise((_, reject) => {
        setTimeout(() => reject(new Error('Job timeout')), this.config.jobTimeoutMs);
      });

      // Execute job with timeout
      const result = await Promise.race([
        handler(job),
        timeoutPromise
      ]);

      await this.completeJob(job, result);

    } catch (error) {
if (job.attempts < job.maxAttempts) {
        await this.retryJob(job, error.message);
      } else {
        await this.failJob(job, error.message);
      }
    } finally {
      this.runningJobs.delete(job.id);
      this.metrics.runningJobs--;
    }
  }

  /**
   * Complete a job successfully
   */
  private async completeJob(job: Job, result: any): Promise<void> {
    job.status = 'completed';
    job.completedAt = Date.now();
    job.progress = 100;

    this.metrics.completedJobs++;

    // Update average processing time
    if (job.startedAt) {
      const processingTime = job.completedAt - job.startedAt;
      this.metrics.averageProcessingTime = 
        (this.metrics.averageProcessingTime * (this.metrics.completedJobs - 1) + processingTime) / 
        this.metrics.completedJobs;
    }

    if (this.config.enablePersistence) {
      await this.persistJob(job);
    }

    // Debug logging removed for security
// Notify user if applicable
    if (job.userId) {
      await this.notifyJobCompletion(job, result);
    }
  }

  /**
   * Retry a failed job
   */
  private async retryJob(job: Job, error: string): Promise<void> {
    job.status = 'retrying';
    job.error = error;
    
    // Calculate retry delay with exponential backoff
    const retryDelay = this.config.defaultRetryDelay * 
      Math.pow(this.config.retryBackoffMultiplier, job.attempts - 1);
    
    job.scheduledAt = Date.now() + retryDelay;

    this.metrics.pendingJobs++;

    if (this.config.enablePersistence) {
      await this.persistJob(job);
    }

    // Debug logging removed for security
  }

  /**
   * Fail a job permanently
   */
  private async failJob(job: Job, error: string): Promise<void> {
    job.status = 'failed';
    job.error = error;
    job.failedAt = Date.now();

    this.metrics.failedJobs++;
    this.deadLetterQueue.push(job);

    // Update error rate
    this.metrics.errorRate = this.metrics.failedJobs / this.metrics.totalJobs;

    if (this.config.enablePersistence) {
      await this.persistJob(job);
    }

    // Debug logging removed for security
// Notify user if applicable
    if (job.userId) {
      await this.notifyJobFailure(job, error);
    }
  }

  /**
   * Persist job to database
   */
  private async persistJob(job: Job): Promise<void> {
    try {
      await this.db.executeQuery(
        (client) => client
          .from('background_jobs')
          .upsert({
            id: job.id,
            type: job.type,
            priority: job.priority,
            payload: job.payload,
            user_id: job.userId,
            attempts: job.attempts,
            max_attempts: job.maxAttempts,
            status: job.status,
            created_at: new Date(job.createdAt).toISOString(),
            scheduled_at: new Date(job.scheduledAt).toISOString(),
            started_at: job.startedAt ? new Date(job.startedAt).toISOString() : null,
            completed_at: job.completedAt ? new Date(job.completedAt).toISOString() : null,
            failed_at: job.failedAt ? new Date(job.failedAt).toISOString() : null,
            error: job.error,
            progress: job.progress,
            metadata: job.metadata
          }),
        { cache: false }
      );
    } catch (error) {
}
  }

  /**
   * Load persisted jobs from database
   */
  private async loadPersistedJobs(): Promise<void> {
    try {
      const result = await this.db.executeQuery(
        (client) => client
          .from('background_jobs')
          .select('*')
          .in('status', ['pending', 'running', 'retrying'])
          .order('created_at', { ascending: true }),
        { cache: false }
      );

      if (result.data) {
        for (const jobData of result.data) {
          const job: Job = {
            id: jobData.id,
            type: jobData.type,
            priority: jobData.priority,
            payload: jobData.payload,
            userId: jobData.user_id,
            attempts: jobData.attempts,
            maxAttempts: jobData.max_attempts,
            createdAt: new Date(jobData.created_at).getTime(),
            scheduledAt: new Date(jobData.scheduled_at).getTime(),
            startedAt: jobData.started_at ? new Date(jobData.started_at).getTime() : undefined,
            completedAt: jobData.completed_at ? new Date(jobData.completed_at).getTime() : undefined,
            failedAt: jobData.failed_at ? new Date(jobData.failed_at).getTime() : undefined,
            error: jobData.error,
            progress: jobData.progress,
            status: jobData.status === 'running' ? 'pending' : jobData.status, // Reset running jobs to pending
            metadata: jobData.metadata
          };

          this.jobs.set(job.id, job);
        }

        // Debug logging removed for security
}
    } catch (error) {
}
  }

  /**
   * Notify user of job completion
   */
  private async notifyJobCompletion(job: Job, result: any): Promise<void> {
    // Implementation would send push notification or update user state
    // Debug logging removed for security
}

  /**
   * Notify user of job failure
   */
  private async notifyJobFailure(job: Job, error: string): Promise<void> {
    // Implementation would send error notification
    // Debug logging removed for security
}

  /**
   * Start cleanup routine
   */
  private startCleanup(): void {
    this.cleanupInterval = setInterval(async () => {
      await this.cleanup();
    }, this.config.cleanupIntervalMs);
  }

  /**
   * Clean up old completed/failed jobs
   */
  private async cleanup(): Promise<void> {
    const cutoffTime = Date.now() - (24 * 60 * 60 * 1000); // 24 hours ago
    
    const jobsToRemove = Array.from(this.jobs.values())
      .filter(job => 
        (job.status === 'completed' || job.status === 'failed') &&
        (job.completedAt || job.failedAt || 0) < cutoffTime
      );

    for (const job of jobsToRemove) {
      this.jobs.delete(job.id);
    }

    if (jobsToRemove.length > 0) {
      // Debug logging removed for security
}

    // Limit dead letter queue size
    if (this.deadLetterQueue.length > 1000) {
      this.deadLetterQueue = this.deadLetterQueue.slice(-500);
    }
  }

  /**
   * Start metrics collection
   */
  private startMetricsCollection(): void {
    if (!this.config.enableMetrics) return;

    setInterval(() => {
      const metrics = this.getMetrics();
      // Debug logging removed for security
    }, 60000); // Log every minute
  }

  /**
   * Shutdown the queue
   */
  async shutdown(): Promise<void> {
    // Debug logging removed for security
if (this.processingInterval) {
      clearInterval(this.processingInterval);
    }

    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
    }

    // Wait for running jobs to complete (with timeout)
    const shutdownTimeout = 30000; // 30 seconds
    const startTime = Date.now();

    while (this.runningJobs.size > 0 && (Date.now() - startTime) < shutdownTimeout) {
      await new Promise(resolve => setTimeout(resolve, 1000));
    }

    if (this.runningJobs.size > 0) {
}

    // Debug logging removed for security
}
}

// Singleton instance
let queueInstance: JobQueue | null = null;

export function getBackgroundQueue(): JobQueue {
  if (!queueInstance) {
    queueInstance = new JobQueue();
  }
  return queueInstance;
}

// Pre-defined job handlers for Stellr
export const StellarJobHandlers = {
  // Compatibility calculation job
  async calculateCompatibility(job: Job): Promise<any> {
    const { user1Id, user2Id } = job.payload;
    
    // Update progress
    job.progress = 10;
    
    try {
      // Simulate expensive compatibility calculation
      const pool = getConnectionPool();
      
      // Get user profiles
      job.progress = 30;
      const [user1Result, user2Result] = await Promise.all([
        pool.executeQuery(client => client.from('profiles').select('*').eq('id', user1Id).single()),
        pool.executeQuery(client => client.from('profiles').select('*').eq('id', user2Id).single())
      ]);

      if (user1Result.error || user2Result.error) {
        throw new Error('Failed to fetch user profiles');
      }

      job.progress = 60;
      
      // Calculate compatibility (simplified)
      const compatibility = {
        astrologicalScore: Math.floor(Math.random() * 100),
        questionnaireScore: Math.floor(Math.random() * 100),
        overallScore: Math.floor(Math.random() * 100),
        isRecommended: Math.random() > 0.5
      };

      job.progress = 80;

      // Store result in cache
      const cache = getAdvancedCache();
      const sortedIds = [user1Id, user2Id].sort().join(':');
      const cacheKey = 'compatibility:' + sortedIds;
      await cache.set(
        cacheKey,
        compatibility,
        'compatibility'
      );

      job.progress = 100;

      return compatibility;
      
    } catch (error) {
throw error;
    }
  },

  // Match recommendation generation
  async generateMatchRecommendations(job: Job): Promise<any> {
    const { userId, limit = 50 } = job.payload;
    
    job.progress = 10;
    
    try {
      const pool = getConnectionPool();
      
      // Get potential matches using optimized function
      job.progress = 50;
      const result = await pool.executeQuery(
        client => client.rpc('get_potential_matches_optimized', {
          viewer_id: userId,
          limit_count: limit
        }),
        { cache: true, cacheTTL: 1800000 } // 30 minute cache
      );

      job.progress = 80;

      if (result.error) {
        throw new Error('Failed to generate match recommendations');
      }

      // Cache the recommendations
      const cache = getAdvancedCache();
      const cacheKey2 = 'match_recommendations:' + userId;
      await cache.set(
        cacheKey2,
        result.data,
        'potential_matches'
      );

      job.progress = 100;

      return { matchCount: result.data?.length || 0, userId };
      
    } catch (error) {
throw error;
    }
  },

  // User data synchronization
  async syncUserData(job: Job): Promise<any> {
    const { userId } = job.payload;
    
    job.progress = 10;
    
    try {
      // Sync profile data, preferences, and location
      const cache = getAdvancedCache();
      
      // Invalidate cached user data
      job.progress = 30;
      await cache.invalidateUserData(userId);
      
      // Refresh materialized views
      job.progress = 60;
      const pool = getConnectionPool();
      await pool.executeQuery(
        client => client.rpc('refresh_user_matching_summary')
      );

      job.progress = 100;

      return { userId, syncedAt: new Date().toISOString() };
      
    } catch (error) {
throw error;
    }
  }
};

// Register default handlers
export function initializeDefaultHandlers(): void {
  const queue = getBackgroundQueue();
  
  queue.registerHandler('calculate_compatibility', StellarJobHandlers.calculateCompatibility);
  queue.registerHandler('generate_match_recommendations', StellarJobHandlers.generateMatchRecommendations);
  queue.registerHandler('sync_user_data', StellarJobHandlers.syncUserData);
  
  // Debug logging removed for security
}

export { JobQueue };
