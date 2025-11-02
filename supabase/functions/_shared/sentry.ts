// Production-Ready Sentry Error Tracking for Stellr Edge Functions
// Comprehensive error monitoring, performance tracking, and debugging

interface SentryConfig {
  dsn: string;
  environment: string;
  release?: string;
  serverName?: string;
  tracesSampleRate?: number;
}

interface SentryEvent {
  event_id: string;
  timestamp: string;
  level: 'debug' | 'info' | 'warning' | 'error' | 'fatal';
  logger?: string;
  platform: string;
  sdk: {
    name: string;
    version: string;
  };
  server_name?: string;
  release?: string;
  environment?: string;
  message?: {
    message: string;
    params?: any[];
  };
  exception?: {
    values: Array<{
      type: string;
      value: string;
      stacktrace?: {
        frames: Array<{
          filename: string;
          function: string;
          lineno: number;
          colno?: number;
        }>;
      };
    }>;
  };
  request?: {
    url: string;
    method: string;
    headers?: Record<string, string>;
    query_string?: string;
    data?: any;
  };
  user?: {
    id?: string;
    email?: string;
    username?: string;
  };
  tags?: Record<string, string>;
  extra?: Record<string, any>;
  breadcrumbs?: Array<{
    timestamp: string;
    message: string;
    category: string;
    level: string;
    data?: Record<string, any>;
  }>;
}

class SentryClient {
  private config: SentryConfig;
  private breadcrumbs: Array<any> = [];

  constructor(config: SentryConfig) {
    this.config = config;
  }

  private generateEventId(): string {
    return crypto.randomUUID().replace(/-/g, '');
  }

  private parseStackTrace(error: Error): Array<any> {
    if (!error.stack) return [];

    return error.stack
      .split('\n')
      .slice(1) // Remove the error message line
      .map(line => {
        const match = line.match(/\s+at\s+(.+?)\s+\((.+?):(\d+):(\d+)\)/);
        if (match) {
          return {
            function: match[1] || '<anonymous>',
            filename: match[2] || '<unknown>',
            lineno: parseInt(match[3]) || 0,
            colno: parseInt(match[4]) || 0,
          };
        }
        return {
          function: '<anonymous>',
          filename: line.trim(),
          lineno: 0,
        };
      })
      .filter(frame => frame.filename !== '<unknown>');
  }

  addBreadcrumb(breadcrumb: {
    message: string;
    category: string;
    level?: string;
    data?: Record<string, any>;
  }): void {
    this.breadcrumbs.push({
      timestamp: new Date().toISOString(),
      level: breadcrumb.level || 'info',
      ...breadcrumb,
    });

    // Keep only last 100 breadcrumbs
    if (this.breadcrumbs.length > 100) {
      this.breadcrumbs.shift();
    }
  }

  captureException(
    error: Error,
    context?: {
      user?: { id?: string; email?: string; username?: string };
      tags?: Record<string, string>;
      extra?: Record<string, any>;
      level?: 'error' | 'fatal';
      request?: Request;
    }
  ): string {
    const eventId = this.generateEventId();

    const event: SentryEvent = {
      event_id: eventId,
      timestamp: new Date().toISOString(),
      level: context?.level || 'error',
      platform: 'javascript',
      sdk: {
        name: 'stellr-edge-functions',
        version: '1.0.0',
      },
      server_name: 'supabase-edge-function',
      release: this.config.release,
      environment: this.config.environment,
      exception: {
        values: [
          {
            type: error.name || 'Error',
            value: error.message || 'Unknown error',
            stacktrace: {
              frames: this.parseStackTrace(error),
            },
          },
        ],
      },
      user: context?.user,
      tags: {
        function_name: Deno.env.get('FUNCTION_NAME') || 'unknown',
        ...context?.tags,
      },
      extra: {
        error_details: {
          name: error.name,
          message: error.message,
          stack: error.stack,
        },
        ...context?.extra,
      },
      breadcrumbs: [...this.breadcrumbs],
    };

    // Add request context if available
    if (context?.request) {
      const url = new URL(context.request.url);
      event.request = {
        url: context.request.url,
        method: context.request.method,
        headers: Object.fromEntries(context.request.headers.entries()),
        query_string: url.search,
      };
    }

    this.sendEvent(event);
    return eventId;
  }

  captureMessage(
    message: string,
    level: 'debug' | 'info' | 'warning' | 'error' = 'info',
    context?: {
      user?: { id?: string; email?: string; username?: string };
      tags?: Record<string, string>;
      extra?: Record<string, any>;
    }
  ): string {
    const eventId = this.generateEventId();

    const event: SentryEvent = {
      event_id: eventId,
      timestamp: new Date().toISOString(),
      level,
      platform: 'javascript',
      sdk: {
        name: 'stellr-edge-functions',
        version: '1.0.0',
      },
      server_name: 'supabase-edge-function',
      release: this.config.release,
      environment: this.config.environment,
      message: {
        message,
      },
      user: context?.user,
      tags: {
        function_name: Deno.env.get('FUNCTION_NAME') || 'unknown',
        ...context?.tags,
      },
      extra: context?.extra,
      breadcrumbs: [...this.breadcrumbs],
    };

    this.sendEvent(event);
    return eventId;
  }

  private async sendEvent(event: SentryEvent): Promise<void> {
    try {
      const response = await fetch(`https://sentry.io/api/0/projects/${this.extractProjectId()}/store/`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Sentry-Auth': this.buildAuthHeader(),
        },
        body: JSON.stringify(event),
      });

      if (!response.ok) {
}
    } catch (error) {
}
  }

  private extractProjectId(): string {
    // Extract project ID from DSN: https://key@sentry.io/project-id
    const match = this.config.dsn.match(/sentry\.io\/(\d+)$/);
    return match ? match[1] : '';
  }

  private buildAuthHeader(): string {
    // Extract key from DSN: https://key@sentry.io/project-id
    const match = this.config.dsn.match(/https:\/\/([^@]+)@/);
    const key = match ? match[1] : '';
    
    return [
      `Sentry sentry_version=7`,
      `sentry_client=stellr-edge-functions/1.0.0`,
      `sentry_timestamp=${Math.floor(Date.now() / 1000)}`,
      `sentry_key=${key}`,
    ].join(', ');
  }
}

// Singleton Sentry client
let sentryClient: SentryClient | null = null;

export function initSentry(): SentryClient | null {
  const dsn = Deno.env.get('SENTRY_DSN');
  
  if (!dsn) {
return null;
  }

  if (!sentryClient) {
    sentryClient = new SentryClient({
      dsn,
      environment: Deno.env.get('SENTRY_ENVIRONMENT') || 'development',
      release: Deno.env.get('BUILD_VERSION') || '1.0.0',
      serverName: 'stellr-edge-functions',
      tracesSampleRate: 1.0,
    });
  }

  return sentryClient;
}

export function getSentry(): SentryClient | null {
  return sentryClient || initSentry();
}

// Convenience functions
export function captureException(
  error: Error,
  context?: {
    user?: { id?: string; email?: string; username?: string };
    tags?: Record<string, string>;
    extra?: Record<string, any>;
    level?: 'error' | 'fatal';
    request?: Request;
  }
): string | null {
  const sentry = getSentry();
  if (!sentry) return null;
  
  return sentry.captureException(error, context);
}

export function captureMessage(
  message: string,
  level: 'debug' | 'info' | 'warning' | 'error' = 'info',
  context?: {
    user?: { id?: string; email?: string; username?: string };
    tags?: Record<string, string>;
    extra?: Record<string, any>;
  }
): string | null {
  const sentry = getSentry();
  if (!sentry) return null;
  
  return sentry.captureMessage(message, level, context);
}

export function addBreadcrumb(breadcrumb: {
  message: string;
  category: string;
  level?: string;
  data?: Record<string, any>;
}): void {
  const sentry = getSentry();
  if (sentry) {
    sentry.addBreadcrumb(breadcrumb);
  }
}

// Performance monitoring
export function startTransaction(name: string, op: string): PerformanceTransaction {
  return new PerformanceTransaction(name, op);
}

class PerformanceTransaction {
  private name: string;
  private op: string;
  private startTime: number;
  private spans: Array<{ name: string; op: string; startTime: number; endTime?: number }> = [];

  constructor(name: string, op: string) {
    this.name = name;
    this.op = op;
    this.startTime = performance.now();
  }

  startSpan(name: string, op: string): PerformanceSpan {
    const span = new PerformanceSpan(name, op);
    this.spans.push(span.getDetails());
    return span;
  }

  finish(): void {
    const duration = performance.now() - this.startTime;
    
    captureMessage(`Transaction ${this.name} completed`, 'info', {
      tags: {
        transaction_name: this.name,
        transaction_op: this.op,
      },
      extra: {
        duration_ms: duration,
        spans: this.spans.filter(span => span.endTime),
      },
    });
  }
}

class PerformanceSpan {
  private name: string;
  private op: string;
  private startTime: number;
  private endTime?: number;

  constructor(name: string, op: string) {
    this.name = name;
    this.op = op;
    this.startTime = performance.now();
  }

  finish(): void {
    this.endTime = performance.now();
  }

  getDetails() {
    return {
      name: this.name,
      op: this.op,
      startTime: this.startTime,
      endTime: this.endTime,
    };
  }
}

// Error wrapper for Edge Functions
export function withSentryErrorHandling<T extends (...args: any[]) => any>(
  handler: T,
  functionName: string
): T {
  return ((...args: any[]) => {
    try {
      addBreadcrumb({
        message: `Function ${functionName} started`,
        category: 'function',
        level: 'info',
      });

      const result = handler(...args);

      // Handle async functions
      if (result instanceof Promise) {
        return result.catch((error: Error) => {
          captureException(error, {
            tags: {
              function_name: functionName,
              error_boundary: 'async_handler',
            },
            extra: {
              function_args: args,
            },
          });
          throw error;
        });
      }

      return result;
    } catch (error) {
      captureException(error as Error, {
        tags: {
          function_name: functionName,
          error_boundary: 'sync_handler',
        },
        extra: {
          function_args: args,
        },
      });
      throw error;
    }
  }) as T;
}