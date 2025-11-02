/**
 * STELLR REAL-TIME MATCH EVENTS
 * 
 * Provides real-time notifications for match-related events via Server-Sent Events (SSE)
 * Enables live match invitations, responses, and notifications
 * 
 * Features:
 * - Server-Sent Events (SSE) for real-time updates
 * - Match invitation notifications
 * - Match response notifications  
 * - Connection management and heartbeat
 * - User-specific event streams
 * - Security and authentication validation
 */

import { serve } from 'std/http/server.ts';
import { createClient } from '@supabase/supabase-js';
import { corsHeaders } from '../_shared/cors.ts';
import { applyRateLimit, RateLimitCategory } from '../_shared/rate-limit-enhancements.ts';
import { structuredLogger } from '../_shared/structured-logging.ts';

// =====================================================================================
// REAL-TIME EVENT TYPES AND INTERFACES
// =====================================================================================

interface MatchEvent {
  id: string;
  type: 'match_request' | 'match_response' | 'new_match' | 'match_expired' | 'heartbeat';
  data: Record<string, any>;
  timestamp: string;
  userId: string;
}

interface ConnectionManager {
  connections: Map<string, {
    controller: ReadableStreamController<Uint8Array>;
    userId: string;
    lastSeen: number;
    subscriptions: Set<string>;
  }>;
  
  addConnection(connectionId: string, controller: ReadableStreamController<Uint8Array>, userId: string): void;
  removeConnection(connectionId: string): void;
  sendToUser(userId: string, event: MatchEvent): void;
  sendToConnection(connectionId: string, event: MatchEvent): void;
  cleanup(): void;
  getConnectionCount(): number;
  getUserConnections(userId: string): string[];
}

// =====================================================================================
// CONNECTION MANAGER IMPLEMENTATION
// =====================================================================================

class SSEConnectionManager implements ConnectionManager {
  connections = new Map<string, {
    controller: ReadableStreamController<Uint8Array>;
    userId: string;
    lastSeen: number;
    subscriptions: Set<string>;
  }>();

  private cleanupInterval: number;

  constructor() {
    // Cleanup stale connections every 30 seconds
    this.cleanupInterval = setInterval(() => this.cleanup(), 30000);
  }

  addConnection(connectionId: string, controller: ReadableStreamController<Uint8Array>, userId: string): void {
    this.connections.set(connectionId, {
      controller,
      userId,
      lastSeen: Date.now(),
      subscriptions: new Set(['matches', 'requests'])
    });

    // Send initial connection confirmation
    this.sendToConnection(connectionId, {
      id: crypto.randomUUID(),
      type: 'heartbeat',
      data: { 
        message: 'Connected to real-time match events',
        connectionId,
        serverTime: new Date().toISOString()
      },
      timestamp: new Date().toISOString(),
      userId
    });
  }

  removeConnection(connectionId: string): void {
    const connection = this.connections.get(connectionId);
    if (connection) {
      try {
        connection.controller.close();
      } catch (error) {
        console.warn(`Error closing connection ${connectionId}:`, error);
      }
      this.connections.delete(connectionId);
    }
  }

  sendToUser(userId: string, event: MatchEvent): void {
    const userConnections = Array.from(this.connections.entries())
      .filter(([_, conn]) => conn.userId === userId);

    for (const [connectionId, _] of userConnections) {
      this.sendToConnection(connectionId, event);
    }
  }

  sendToConnection(connectionId: string, event: MatchEvent): void {
    const connection = this.connections.get(connectionId);
    if (!connection) return;

    try {
      const eventData = `data: ${JSON.stringify(event)}\n\n`;
      const encoder = new TextEncoder();
      connection.controller.enqueue(encoder.encode(eventData));
      connection.lastSeen = Date.now();
    } catch (error) {
      console.warn(`Failed to send event to connection ${connectionId}:`, error);
      this.removeConnection(connectionId);
    }
  }

  cleanup(): void {
    const now = Date.now();
    const staleTimeout = 5 * 60 * 1000; // 5 minutes

    for (const [connectionId, connection] of this.connections.entries()) {
      if (now - connection.lastSeen > staleTimeout) {
        console.log(`Removing stale connection: ${connectionId}`);
        this.removeConnection(connectionId);
      }
    }
  }

  getConnectionCount(): number {
    return this.connections.size;
  }

  getUserConnections(userId: string): string[] {
    return Array.from(this.connections.entries())
      .filter(([_, conn]) => conn.userId === userId)
      .map(([connectionId, _]) => connectionId);
  }

  destroy(): void {
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
    }
    
    // Close all connections
    for (const connectionId of this.connections.keys()) {
      this.removeConnection(connectionId);
    }
  }
}

// Global connection manager instance
const connectionManager = new SSEConnectionManager();

// =====================================================================================
// DATABASE EVENT LISTENERS
// =====================================================================================

/**
 * Set up database listeners for real-time events
 */
async function setupDatabaseListeners(supabaseClient: any) {
  // Listen for new match requests
  const matchRequestsChannel = supabaseClient
    .channel('match_requests_realtime')
    .on(
      'postgres_changes',
      {
        event: 'INSERT',
        schema: 'public',
        table: 'match_requests'
      },
      async (payload: any) => {
        const matchRequest = payload.new;
        
        // Get user profile information
        const { data: requesterProfile } = await supabaseClient
          .from('profiles')
          .select('display_name, avatar_url')
          .eq('id', matchRequest.requester_id)
          .single();

        // Send notification to the matched user
        const event: MatchEvent = {
          id: crypto.randomUUID(),
          type: 'match_request',
          data: {
            match_request_id: matchRequest.id,
            requester_id: matchRequest.requester_id,
            requester_name: requesterProfile?.display_name || 'Someone',
            requester_avatar: requesterProfile?.avatar_url,
            compatibility_score: matchRequest.compatibility_score,
            message: `${requesterProfile?.display_name || 'Someone'} sent you a match request!`
          },
          timestamp: new Date().toISOString(),
          userId: matchRequest.matched_user_id
        };

        connectionManager.sendToUser(matchRequest.matched_user_id, event);
      }
    );

  // Listen for match request status updates
  const matchRequestUpdatesChannel = supabaseClient
    .channel('match_request_updates')
    .on(
      'postgres_changes',
      {
        event: 'UPDATE',
        schema: 'public',
        table: 'match_requests'
      },
      async (payload: any) => {
        const updated = payload.new;
        const old = payload.old;
        
        // Only send notification if status changed
        if (updated.status !== old.status && updated.status !== 'pending') {
          const { data: responderProfile } = await supabaseClient
            .from('profiles')
            .select('display_name, avatar_url')
            .eq('id', updated.matched_user_id)
            .single();

          const event: MatchEvent = {
            id: crypto.randomUUID(),
            type: 'match_response',
            data: {
              match_request_id: updated.id,
              response: updated.status,
              responder_name: responderProfile?.display_name || 'Someone',
              responder_avatar: responderProfile?.avatar_url,
              message: `${responderProfile?.display_name || 'Someone'} ${
                updated.status === 'confirmed' ? 'accepted' : 'declined'
              } your match request!`,
              response_message: updated.response_message
            },
            timestamp: new Date().toISOString(),
            userId: updated.requester_id
          };

          connectionManager.sendToUser(updated.requester_id, event);
        }
      }
    );

  // Listen for new matches (mutual likes)
  const matchesChannel = supabaseClient
    .channel('new_matches')
    .on(
      'postgres_changes',
      {
        event: 'INSERT',
        schema: 'public',
        table: 'matches'
      },
      async (payload: any) => {
        const match = payload.new;
        
        // Get both user profiles
        const { data: profiles } = await supabaseClient
          .from('profiles')
          .select('id, display_name, avatar_url')
          .in('id', [match.user1_id, match.user2_id]);

        const user1Profile = profiles?.find((p: any) => p.id === match.user1_id);
        const user2Profile = profiles?.find((p: any) => p.id === match.user2_id);

        // Send notification to both users
        const events: MatchEvent[] = [
          {
            id: crypto.randomUUID(),
            type: 'new_match',
            data: {
              match_id: match.id,
              other_user_id: match.user2_id,
              other_user_name: user2Profile?.display_name || 'Someone',
              other_user_avatar: user2Profile?.avatar_url,
              compatibility_score: match.compatibility_score,
              conversation_id: match.conversation_id,
              message: `🎉 You matched with ${user2Profile?.display_name || 'someone'}!`
            },
            timestamp: new Date().toISOString(),
            userId: match.user1_id
          },
          {
            id: crypto.randomUUID(),
            type: 'new_match',
            data: {
              match_id: match.id,
              other_user_id: match.user1_id,
              other_user_name: user1Profile?.display_name || 'Someone',
              other_user_avatar: user1Profile?.avatar_url,
              compatibility_score: match.compatibility_score,
              conversation_id: match.conversation_id,
              message: `🎉 You matched with ${user1Profile?.display_name || 'someone'}!`
            },
            timestamp: new Date().toISOString(),
            userId: match.user2_id
          }
        ];

        for (const event of events) {
          connectionManager.sendToUser(event.userId, event);
        }
      }
    );

  // Subscribe to all channels
  await Promise.all([
    matchRequestsChannel.subscribe(),
    matchRequestUpdatesChannel.subscribe(),
    matchesChannel.subscribe()
  ]);

  return {
    matchRequestsChannel,
    matchRequestUpdatesChannel,
    matchesChannel
  };
}

// =====================================================================================
// MAIN HANDLER FUNCTION
// =====================================================================================

serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  
  // Initialize logger
  const logger = structuredLogger.createLogger({
    service: 'real-time-match-events',
    requestId,
    operation: 'sse_connection'
  });

  try {
    // Handle CORS preflight
    if (req.method === 'OPTIONS') {
      return new Response('ok', { headers: corsHeaders });
    }

    // Only allow GET method for SSE
    if (req.method !== 'GET') {
      return new Response(
        JSON.stringify({ error: 'Method not allowed. Use GET for SSE connection.' }),
        {
          status: 405,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Rate limiting for SSE connections
    const rateLimitResult = await applyRateLimit(
      req, 
      '/real-time-match-events',
      undefined, 
      RateLimitCategory.REALTIME
    );
    
    if (rateLimitResult.blocked) {
      logger.warn('SSE connection blocked by rate limiting');
      return rateLimitResult.response;
    }

    // Authentication validation
    const userAuthHeader = req.headers.get('Authorization');
    if (!userAuthHeader) {
      logger.warn('Missing authorization header for SSE connection');
      return new Response(
        JSON.stringify({ error: 'Authorization required for real-time events' }), 
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

    if (!supabaseUrl || !supabaseAnonKey) {
      logger.error('Missing Supabase configuration for SSE');
      return new Response(
        JSON.stringify({ error: 'Server configuration error' }),
        {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    const supabaseClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: userAuthHeader } }
    });

    // Validate user authentication
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();

    if (userError || !user) {
      logger.warn('User authentication failed for SSE', { error: userError?.message });
      return new Response(
        JSON.stringify({ error: 'Authentication failed' }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    logger.info('SSE connection requested', { userId: user.id });

    // Set up database listeners (only once globally)
    if (connectionManager.getConnectionCount() === 0) {
      await setupDatabaseListeners(supabaseClient);
      logger.info('Database listeners initialized');
    }

    // =====================================================================================
    // CREATE SSE STREAM
    // =====================================================================================

    const connectionId = crypto.randomUUID();
    
    const stream = new ReadableStream({
      start(controller) {
        connectionManager.addConnection(connectionId, controller, user.id);
        
        logger.info('SSE connection established', {
          connectionId,
          userId: user.id,
          totalConnections: connectionManager.getConnectionCount()
        });

        // Send heartbeat every 30 seconds to keep connection alive
        const heartbeatInterval = setInterval(() => {
          const heartbeatEvent: MatchEvent = {
            id: crypto.randomUUID(),
            type: 'heartbeat',
            data: {
              serverTime: new Date().toISOString(),
              connectionCount: connectionManager.getConnectionCount()
            },
            timestamp: new Date().toISOString(),
            userId: user.id
          };
          
          connectionManager.sendToConnection(connectionId, heartbeatEvent);
        }, 30000);

        // Cleanup on connection close
        controller.closed.then(() => {
          clearInterval(heartbeatInterval);
          connectionManager.removeConnection(connectionId);
          
          logger.info('SSE connection closed', {
            connectionId,
            userId: user.id,
            totalConnections: connectionManager.getConnectionCount()
          });
        });
      },

      cancel() {
        connectionManager.removeConnection(connectionId);
      }
    });

    // Return SSE response
    return new Response(stream, {
      headers: {
        ...corsHeaders,
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no' // Disable Nginx buffering
      }
    });

  } catch (error) {
    logger.error('SSE connection setup failed', {
      error: error instanceof Error ? error.message : 'Unknown error',
      stack: error instanceof Error ? error.stack : undefined,
      requestId
    });

    return new Response(
      JSON.stringify({
        error: 'Failed to establish real-time connection',
        requestId
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});

// =====================================================================================
// GRACEFUL SHUTDOWN HANDLING
// =====================================================================================

// Handle process termination gracefully
globalThis.addEventListener('unload', () => {
  connectionManager.destroy();
});

export { serve };
