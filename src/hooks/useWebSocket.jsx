// src/hooks/useWebSocket.jsx
import { useEffect, useRef, useCallback } from 'react';
import { useAuthStore } from '../stores/useAuthStore.jsx';
import { useViewStore } from '../stores/useViewStore.jsx';
import { useNotificationStore } from '../stores/useNotificationStore.jsx'; // Needed
import { useProjectStore, ConnectionStatus } from '../stores/useProjectStore.jsx';
import { useToolSchemaStore } from '../stores/useToolSchemaStore.jsx';

// Helper function to format MCP notification messages for display
const formatMcpNotification = (payload) => {
  if (!payload || !payload.notification_type) {
    return "Received an unknown MCP notification.";
  }
  // Customize messages based on notification type
  switch (payload.notification_type) {
    case 'ResourceListChanged':
      return "Resource list has been updated.";
    case 'PromptListChanged':
      return "Prompt list has been updated.";
    case 'ResourceUpdated':
      // You could potentially use payload.details here if it contains info like a URI/name
      return "A resource has been updated.";
    case 'ToolListChanged': // Example if this type were used
      return "Tool list has changed.";
    default:
      return `Received notification: ${payload.notification_type}`;
  }
};

// Define message handlers, accepting notify/notifyError actions as arguments
const createMessageHandlers = (notify, notifyError) => ({
    'initial_ui_state': (payload) => {
        console.log("WS Handler: initial_ui_state received");
        useViewStore.getState().resetRootElement();
        useToolSchemaStore.getState().clearToolSchemas();
        useViewStore.getState().handleInitialState(payload);
    },
    'tool_schemas': (payload) => {
        console.log("WS Handler: tool_schemas received", payload);
        if (payload?.tools && typeof payload.tools === 'object') {
            useToolSchemaStore.getState().setToolSchemas(payload.tools);
        } else {
            console.error("Invalid tool_schemas payload:", payload);
            notifyError("Received invalid tool schema data from server."); // Use arg
            useToolSchemaStore.getState().clearToolSchemas();
        }
    },
    'primitive_content_update': (payload) => {
         console.log("WS Handler: primitive_content_update", payload);
         if ((payload?.targetId || payload?.targetBinding) && payload.content !== undefined) {
             requestAnimationFrame(() => {
                useViewStore.getState().handlePrimitiveUpdate(payload);
             });
         } else {
              console.error("Invalid primitive_content_update payload:", payload);
              notifyError("Received invalid content update from server."); // Use arg
         }
    },
    'mcp_progress': (payload) => {
        console.log("WS Handler: mcp_progress received", payload);
        const progressText = payload?.text;
        // Dynamically get current project ID for binding
        const currentProjId = useProjectStore.getState().currentProject?.id;
        if (!currentProjId) {
            console.warn("Cannot handle mcp_progress: No current project ID found.");
            return;
        }
        const targetBinding = `mcp_stream:${currentProjId}:progress_updates`; // Construct dynamic binding

        if (progressText !== undefined && progressText !== null) {
            const updateData = {
                targetBinding: targetBinding, // Use dynamic binding
                content: String(progressText),
                updateType: 'replace'
            };
            requestAnimationFrame(() => {
                useViewStore.getState().handlePrimitiveUpdate(updateData);
            });
        } else {
            console.warn("Received mcp_progress message without valid 'text' field in payload:", payload);
        }
    },
    // *** ADDED MCP_NOTIFICATION HANDLER ***
    'mcp_notification': (payload) => {
        console.log("WS Handler: mcp_notification received", payload);
        const notificationMessage = formatMcpNotification(payload);
        notify(notificationMessage); // Use the passed-in notify action

        // Optional: Add logic here to trigger data re-fetching based on payload.notification_type
        // e.g., if (payload.notification_type === 'ResourceListChanged') { useProjectStore.getState().fetchResources?.(); }
    },
    // *** END ADDED HANDLER ***
     'auth_required': (payload) => {
         console.warn("WS Handler: Received auth_required. Logging out.");
         notifyError(payload?.message || 'Authentication required. Please log in again.'); // Use arg
         useToolSchemaStore.getState().clearToolSchemas();
         setTimeout(() => useAuthStore.getState().logout(), 0);
     },
     'auth_failure': (payload) => {
         console.error("WS Handler: Received auth_failure.", payload);
         notifyError(payload?.message || 'Authentication failed via WebSocket.'); // Use arg
         useToolSchemaStore.getState().clearToolSchemas();
         // Consider triggering logout here too? Maybe not automatically.
     },
     'error': (payload) => {
         console.error("WS Handler: Received error message:", payload);
         notifyError(payload?.message || 'Received error from server.'); // Use arg
     },
     'notification': (payload) => { // Keep generic notification handler
         console.log("WS Handler: Received generic notification:", payload);
         notify(payload?.message || 'Received notification from server.'); // Use arg
     },
     'pong': () => {}, // Ignore pong messages
     'connect_ack': () => { console.log("WS Handler: Received connection acknowledgement."); }, // Handle ack if needed
});


export function useWebSocket() { // streamId prop might be less relevant now with dynamic fetching
  // --- Refs ---
  const socketRef = useRef(null);
  const reconnectTimerRef = useRef(null);
  const reconnectAttemptsRef = useRef(0);
  const pingIntervalRef = useRef(null);

  // --- Store State/Actions (use stable references where possible) ---
  const token = useAuthStore((state) => state.token);
  const logout = useAuthStore((state) => state.logout); // Get logout action
  const notify = useNotificationStore((state) => state.notify); // Get notify action
  const notifyError = useNotificationStore((state) => state.notifyError); // Get notifyError action
  const setProjectConnectionStatus = useProjectStore((state) => state.setProjectConnectionStatus);
  const clearToolSchemas = useToolSchemaStore((state) => state.clearToolSchemas);
  // Select project ID for useEffect dependency, logic inside callbacks will use getState
  const currentProjectId = useProjectStore((state) => state.currentProject?.id);

  // --- Constants ---
  const MAX_RECONNECT_ATTEMPTS = 5;
  const INITIAL_RECONNECT_DELAY = 1000;
  const PING_INTERVAL = 30000;

  // --- Memoized Message Handlers ---
  // Create handlers once, passing the stable notify/notifyError actions
  const messageHandlers = useRef(createMessageHandlers(notify, notifyError));

  // --- Stable WebSocket Event Handlers wrapped in useCallback ---
  const handleOpen = useCallback(() => {
      // Get current project ID dynamically inside the handler
      const dynamicProjectId = useProjectStore.getState().currentProject?.id;
      const dynamicMcpStreamId = dynamicProjectId ? `mcp:${dynamicProjectId}` : null;
      console.log(`WebSocket: Connected to ${dynamicMcpStreamId || 'stream'}`);

      const capabilitiesPayload = {
          supported_primitives: [
            "AudioUpload",
            "Button",
            "Card",
            "ChatViewBasic",
            "Checkbox",
            "CodeView",
            "HtmlView",
            "Icon",
            "InputField",
            "LogView",
            "McpStructuredLogView",
            "StackLayout",
            "StreamingTextView",
            "TextView"
          ]
      };
      const registrationMessage = { type: "register_capabilities", payload: capabilitiesPayload };

      try {
          if (socketRef.current && socketRef.current.readyState === WebSocket.OPEN) {
             socketRef.current.send(JSON.stringify(registrationMessage));
             console.log("[WebSocket] Sent register_capabilities message:", registrationMessage);
          } else { console.warn("[WebSocket] Could not send capabilities: Socket not open or ref missing."); }
      } catch (error) { console.error("[WebSocket] Failed to send register_capabilities message:", error); }

      setProjectConnectionStatus(ConnectionStatus.CONNECTED);
      reconnectAttemptsRef.current = 0;
      if (pingIntervalRef.current) clearInterval(pingIntervalRef.current);
      pingIntervalRef.current = setInterval(() => {
          if (socketRef.current && socketRef.current.readyState === WebSocket.OPEN) {
               try { socketRef.current.send(JSON.stringify({ type: 'ping', timestamp: Date.now() })); }
               catch (e) { console.warn("WS Ping Error:", e); }
          }
      }, PING_INTERVAL);
  // Depend only on stable store actions/setters passed in or defined outside
  }, [setProjectConnectionStatus]);

  const handleMessage = useCallback((event) => {
      let message;
      try {
          message = JSON.parse(event.data);
          const handler = messageHandlers.current[message.type];
          if (handler) {
              // Pass payload if it exists, otherwise the whole message
              handler(message.payload !== undefined ? message.payload : message);
          } else {
              console.warn(`No handler found for WebSocket message type: ${message.type}`);
              // Keep debug log for unhandled messages
              console.log(`[DEBUG] Received unhandled message payload for type ${message.type}:`, message.payload !== undefined ? message.payload : message);
          }
      } catch (e) {
          console.error('Failed to parse WebSocket message or apply handler:', e, event.data);
           notifyError('Received invalid message from server.'); // Use notifyError from closure
      }
  // Depends only on notifyError which is obtained from the store (stable reference expected)
  }, [notifyError]);

  // --- Forward declaration needed for scheduleReconnect ---
  const internalConnect = useRef(); // Keep using ref for connect logic

  const scheduleReconnect = useCallback(() => {
      // Get dynamic project ID for logging
      const dynamicProjectId = useProjectStore.getState().currentProject?.id;
      const dynamicMcpStreamId = dynamicProjectId ? `mcp:${dynamicProjectId}` : null;

      if (reconnectAttemptsRef.current >= MAX_RECONNECT_ATTEMPTS) {
           console.error(`WebSocket: Max reconnect attempts reached for ${dynamicMcpStreamId || 'stream'}.`);
           setProjectConnectionStatus(ConnectionStatus.ERROR, 'Connection failed after multiple attempts.');
           notifyError(`Connection failed for ${dynamicMcpStreamId || 'stream'}. Please check logs or refresh.`);
           reconnectAttemptsRef.current = 0;
           clearToolSchemas();
           return;
       }
      reconnectAttemptsRef.current++;
      const delay = Math.min(INITIAL_RECONNECT_DELAY * Math.pow(2, reconnectAttemptsRef.current -1), 30000) + Math.random() * 1000;
      console.log(`WebSocket: Scheduling reconnect attempt ${reconnectAttemptsRef.current} in ${Math.round(delay)}ms for ${dynamicMcpStreamId || 'stream'}`);
      setProjectConnectionStatus(ConnectionStatus.RECONNECTING);

      if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current);
      reconnectTimerRef.current = setTimeout(() => {
          // Check current state again before attempting connect
          const latestProjectId = useProjectStore.getState().currentProject?.id;
          const latestMcpStreamId = latestProjectId ? `mcp:${latestProjectId}` : null;
          const latestToken = useAuthStore.getState().token;
          const latestStatus = useProjectStore.getState().projectConnectionStatus;

          if (latestMcpStreamId && latestToken && internalConnect.current && latestStatus !== ConnectionStatus.CONNECTED && latestStatus !== ConnectionStatus.CONNECTING) {
              console.log(`WebSocket: Executing reconnect attempt ${reconnectAttemptsRef.current} for ${latestMcpStreamId}`);
              internalConnect.current(); // internalConnect should handle using latest state
          } else {
               console.warn(`WebSocket: Reconnect skipped. Conditions not met (mcpStreamId:${!!latestMcpStreamId}, token:${!!latestToken}, connectFn:${!!internalConnect.current}, status:${latestStatus})`);
          }
      }, delay);
  // Depend on stable actions + external stable refs if any
  }, [notifyError, setProjectConnectionStatus, clearToolSchemas]); // Add token/projectId if logic fundamentally changes based on them, but getState is preferred inside

  const handleClose = useCallback((event) => {
      // Get dynamic project ID for logging
      const dynamicProjectId = useProjectStore.getState().currentProject?.id;
      const dynamicMcpStreamId = dynamicProjectId ? `mcp:${dynamicProjectId}` : null;
      console.log(`WebSocket: Closed connection to ${dynamicMcpStreamId || 'stream'}. Code: ${event.code}, Reason: ${event.reason}`);
      const statusBeforeClose = useProjectStore.getState().projectConnectionStatus;
      socketRef.current = null; // Clear socket ref

      let newStatus = ConnectionStatus.DISCONNECTED;
      let errorMsg = null;

      // Clear timers
      if (pingIntervalRef.current) clearInterval(pingIntervalRef.current);
      pingIntervalRef.current = null;
       if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current);
       reconnectTimerRef.current = null;

      // Handle close codes
      if (event.code === 4000 || event.code === 4003 || event.code === 1008) { // Auth errors
           console.warn("WebSocket: Auth error (Close Code), logging out.");
           errorMsg = 'Authentication failed via WebSocket.';
           newStatus = ConnectionStatus.ERROR;
           notifyError(errorMsg);
           clearToolSchemas();
           setTimeout(logout, 0); // Call stable logout action
      } else if (event.code !== 1000 && event.code !== 1001 && event.code !== 1005 && statusBeforeClose !== ConnectionStatus.ERROR && statusBeforeClose !== ConnectionStatus.DISCONNECTED) {
          // Unexpected close, try to reconnect
          console.log(`WebSocket: Connection closed unexpectedly (${event.code}). Attempting reconnect for ${dynamicMcpStreamId || 'stream'}...`);
          scheduleReconnect();
          return; // scheduleReconnect handles status setting
      } else if (statusBeforeClose !== ConnectionStatus.ERROR && statusBeforeClose !== ConnectionStatus.DISCONNECTED) {
           // Normal closure or intentional disconnect
           console.log(`WebSocket: Connection closed normally or intentionally (${event.code}). Status before: ${statusBeforeClose}`);
           newStatus = ConnectionStatus.DISCONNECTED;
           reconnectAttemptsRef.current = 0; // Reset attempts
           clearToolSchemas();
      } else {
           console.log(`WebSocket: Close event (${event.code}) occurred but status already ${statusBeforeClose}. No status change necessary.`);
           return; // Don't reset status if already disconnected/error
      }

      // Set final status if not handled by reconnect/logout
      setProjectConnectionStatus(newStatus, errorMsg);

  // Ensure all dependencies used directly are listed (stable actions are fine)
  }, [notifyError, setProjectConnectionStatus, clearToolSchemas, scheduleReconnect, logout]);

  // --- Internal Connection Logic (using useRef to hold the function) ---
  internalConnect.current = useCallback(() => {
      const dynamicProjectId = useProjectStore.getState().currentProject?.id;
      const dynamicMcpStreamId = dynamicProjectId ? `mcp:${dynamicProjectId}` : null;
      const dynamicToken = useAuthStore.getState().token; // Get current token

      if (!dynamicMcpStreamId || !dynamicToken) {
           console.warn(`internalConnect skipped: dynamicMcpStreamId (${dynamicMcpStreamId}) or dynamicToken missing.`);
           const currentStatus = useProjectStore.getState().projectConnectionStatus;
           if (currentStatus !== ConnectionStatus.DISCONNECTED) {
               setProjectConnectionStatus(ConnectionStatus.DISCONNECTED, "Missing project or token");
           }
           clearToolSchemas();
           return;
       }

       const currentStatus = useProjectStore.getState().projectConnectionStatus;
       if (currentStatus === ConnectionStatus.CONNECTING || currentStatus === ConnectionStatus.CONNECTED) {
           console.log(`internalConnect skipped: Store status already ${currentStatus} for ${dynamicMcpStreamId}`);
           return;
       }
       // Check socket state more carefully
       if (socketRef.current && (socketRef.current.readyState === WebSocket.OPEN || socketRef.current.readyState === WebSocket.CONNECTING)) {
           console.warn(`internalConnect skipped: WebSocket already ${socketRef.current.readyState === WebSocket.OPEN ? 'OPEN' : 'CONNECTING'} for ${dynamicMcpStreamId} (Store status was ${currentStatus})`);
           // Sync store status with socket reality if needed
           setProjectConnectionStatus(socketRef.current.readyState === WebSocket.OPEN ? ConnectionStatus.CONNECTED : ConnectionStatus.CONNECTING);
           return;
       }

       setProjectConnectionStatus(ConnectionStatus.CONNECTING);
       console.log(`WebSocket internalConnect: Attempting connection to ${dynamicMcpStreamId}...`);

       const wsProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
       const backendHost = window.location.hostname;
       const backendPort = 8000; // Make configurable if necessary
       const url = `${wsProtocol}//${backendHost}:${backendPort}/api/ws/stream/${dynamicMcpStreamId}?token=${encodeURIComponent(dynamicToken)}`;

       try {
           // Clean up previous socket ref just in case
           if (socketRef.current) {
               socketRef.current.onopen = null;
               socketRef.current.onmessage = null;
               socketRef.current.onerror = null;
               socketRef.current.onclose = null;
               if (socketRef.current.readyState !== WebSocket.CLOSED) {
                   socketRef.current.close(1001, "Starting new connection");
               }
           }

           const socket = new WebSocket(url);
           socketRef.current = socket; // Assign new socket to ref

           // Attach stable handlers
           socket.onopen = handleOpen;
           socket.onmessage = handleMessage;
           socket.onerror = (event) => {
               console.error(`WebSocket: Error on ${dynamicMcpStreamId}:`, event);
               // Note: handleClose will likely be called after onerror
           };
           socket.onclose = handleClose;

       } catch (err) {
            console.error(`WebSocket: Failed to create connection to ${dynamicMcpStreamId}:`, err);
            setProjectConnectionStatus(ConnectionStatus.ERROR, 'Failed to initialize WebSocket connection.');
            socketRef.current = null;
            clearToolSchemas();
       }
  // Depend only on stable handlers/actions
  }, [handleOpen, handleMessage, handleClose, setProjectConnectionStatus, clearToolSchemas]);

  // --- Public Actions (stable references) ---
  const connect = useCallback(() => {
      const dynamicProjectId = useProjectStore.getState().currentProject?.id;
      const dynamicMcpStreamId = dynamicProjectId ? `mcp:${dynamicProjectId}` : null;
      console.log(`WebSocket: Manual connect requested for ${dynamicMcpStreamId || 'current project'}`);
      reconnectAttemptsRef.current = 0;
      if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current);
      if (internalConnect.current) {
         internalConnect.current();
      } else {
          console.error("WebSocket: internalConnect function not available for manual connect.");
          // Set error status directly if connect function isn't ready
          setProjectConnectionStatus(ConnectionStatus.ERROR, "Connect function not initialized");
      }
  // Depend only on stable actions if possible
  }, [setProjectConnectionStatus]);

  const disconnect = useCallback(() => {
      const dynamicProjectId = useProjectStore.getState().currentProject?.id;
      const dynamicMcpStreamId = dynamicProjectId ? `mcp:${dynamicProjectId}` : null;
      console.log(`WebSocket: Manual disconnect requested for ${dynamicMcpStreamId || 'current project'}`);
      // Clear timers
      if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current);
      if (pingIntervalRef.current) clearInterval(pingIntervalRef.current);
      reconnectTimerRef.current = null; pingIntervalRef.current = null; reconnectAttemptsRef.current = 0;

      // Close socket and detach handlers
      if (socketRef.current) {
          socketRef.current.onopen = null;
          socketRef.current.onmessage = null;
          socketRef.current.onerror = null;
          socketRef.current.onclose = null; // Prevent handleClose trigger
          if (socketRef.current.readyState === WebSocket.OPEN || socketRef.current.readyState === WebSocket.CONNECTING) {
              console.log(`WebSocket: Closing connection manually via disconnect action`);
              socketRef.current.close(1000, 'User disconnected'); // Normal closure
          }
          socketRef.current = null; // Clear ref immediately
      }
      clearToolSchemas();
      setProjectConnectionStatus(ConnectionStatus.DISCONNECTED, 'Manual disconnect');
  // Depend only on stable actions
  }, [setProjectConnectionStatus, clearToolSchemas]);

  const sendJson = useCallback((data) => {
      const currentStatus = useProjectStore.getState().projectConnectionStatus;
      if (socketRef.current && socketRef.current.readyState === WebSocket.OPEN && currentStatus === ConnectionStatus.CONNECTED) {
         try {
           const jsonData = JSON.stringify(data);
           socketRef.current.send(jsonData);
           return true;
         } catch (e) {
            console.error('WebSocket: Failed to stringify or send JSON data:', e, data);
            notifyError('Failed to send message.');
            return false;
         }
      } else {
         const dynamicProjectId = useProjectStore.getState().currentProject?.id;
         const dynamicMcpStreamId = dynamicProjectId ? `mcp:${dynamicProjectId}` : null;
         console.warn(`WebSocket: Cannot send message, connection not open for ${dynamicMcpStreamId || 'current project'}. Status: ${currentStatus}, ReadyState: ${socketRef.current?.readyState}`);
         notifyError('Cannot send message: Connection not open.');
         return false;
      }
  // Depend only on stable notifyError action
  }, [notifyError]);

  // --- Effect for Connection Management ---
  useEffect(() => {
      // Get the stable connect function reference
      const connectFn = internalConnect.current;

      // Read current state inside effect
      const currentProjId = useProjectStore.getState().currentProject?.id;
      const currentToken = useAuthStore.getState().token;
      const currentMcpStreamId = currentProjId ? `mcp:${currentProjId}` : null;

      console.log(`WebSocket Effect Check: ProjectID=${currentProjId}, Token=${!!currentToken}`);

      if (currentMcpStreamId && currentToken && connectFn) {
          console.log(`WebSocket Effect: Target stream ${currentMcpStreamId} and token exist. Ensuring connection.`);
          reconnectAttemptsRef.current = 0; // Reset attempts on valid check
          const currentStatus = useProjectStore.getState().projectConnectionStatus;
          // Only attempt connect if disconnected or errored
          if (currentStatus === ConnectionStatus.DISCONNECTED || currentStatus === ConnectionStatus.ERROR) {
               console.log(`WebSocket Effect: Status is ${currentStatus}, attempting connection.`);
               connectFn();
          } else {
               console.log(`WebSocket Effect: Connection skipped, status already ${currentStatus}`);
          }
      } else {
          // If no stream or token, ensure disconnection
          console.log(`WebSocket Effect: Target stream (${currentMcpStreamId}) or token missing. Ensuring disconnection.`);
          // Call the stable disconnect reference
          disconnect();
      }

      // Cleanup function: Always called when dependencies change or component unmounts
      return () => {
          console.log(`WebSocket Effect Cleanup: Triggered due to change in dependencies or unmount.`);
          // Call the stable disconnect reference to ensure cleanup
          disconnect();
      };
  // Depend on the project ID and token values from the store selectors
  // Also depend on the stable disconnect callback reference
  }, [currentProjectId, token, disconnect]);

  // Return stable actions
  return { sendJson, connect, disconnect };
}