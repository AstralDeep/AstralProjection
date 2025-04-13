// src/components/workspace/WorkspaceLayout.jsx
import React, { useCallback } from 'react';
import { useViewStore } from '../../stores/useViewStore.jsx';
// Import store and status enum
import { useProjectStore, ConnectionStatus } from '../../stores/useProjectStore.jsx';
// Hook still needed for sendJson action
import { useWebSocket } from '../../hooks/useWebSocket.jsx';
import DynamicRenderer from '../DynamicRenderer.jsx';
import LoadingSpinner from '../common/LoadingSpinner.jsx';

function WorkspaceLayoutInternal() {
  const rootElement = useViewStore((state) => state.getRootElement());
  const currentProject = useProjectStore((state) => state.currentProject);
  // --- Read status from the store ---
  const wsStatus = useProjectStore((state) => state.projectConnectionStatus);
  const wsError = useProjectStore((state) => state.projectConnectionError); // Optional

  // Derive streamId for the hook
  const streamId = currentProject ? `project:${currentProject.id}` : null;
  // Get sendJson action from the hook
  const { sendJson } = useWebSocket(streamId);

  const sendAction = useCallback((message) => {
      // Check store status
      if (wsStatus !== ConnectionStatus.CONNECTED) {
          console.warn("WorkspaceLayout: Cannot send action, WebSocket not connected.", `Status: ${wsStatus}`, message);
          // Optionally notify user
          // useNotificationStore.getState().notifyError("Cannot perform action: Not connected.");
          return;
      }
       if (!sendJson) {
           console.error("WorkspaceLayout: sendJson function is not available.", message);
           return;
       }
      // Ensure the message has the correct basic structure before sending
      if (message && message.type === 'ui_action' && message.payload) {
          console.log("WorkspaceLayout: Sending UI Action Message:", message);
          sendJson(message); // Pass the received message object directly
      } else {
          console.error("WorkspaceLayout: Invalid message structure received by sendAction:", message);
      }
  }, [sendJson, wsStatus]); // Depend on sendJson and store status

  // --- Render Logic using store status ---
  const renderContent = () => {
      if (!currentProject) {
          return <div className="workspace-message">Select a project to begin.</div>; // Simpler message
      }
      // Show loading spinner only when actively connecting/reconnecting
      if (wsStatus === ConnectionStatus.CONNECTING || wsStatus === ConnectionStatus.RECONNECTING) {
           return <LoadingSpinner message={`Connecting to ${currentProject.name}...`} />;
      }
       // Show disconnected/error message
      if (wsStatus !== ConnectionStatus.CONNECTED) {
           const errorText = wsStatus === ConnectionStatus.ERROR ? (wsError || 'Connection error.') : 'Attempting to reconnect...';
           return <div className="workspace-message">Disconnected. {errorText}</div>;
      }
      // Connected, but waiting for UI definition
      if (!rootElement) {
          return <LoadingSpinner message="Waiting for UI definition from server..." />;
      }

      // We have the root element, render it
      return (
          <DynamicRenderer
              primitive={rootElement}
              sendAction={sendAction} // Pass the sendAction function
          />
      );
  };

  return (
    <div className="workspace-layout" style={{ height: '100%', overflow: 'auto', padding: '10px' /* Example padding */ }}>
      {renderContent()}
      <style jsx="true">{`
          .workspace-message {
              display: flex;
              align-items: center;
              justify-content: center;
              height: 100%;
              color: var(--color-text-secondary);
              font-style: italic;
              padding: 20px;
              text-align: center;
          }
          .workspace-layout {
              position: relative; /* Needed for potential absolute positioning of children or overlays */
              /* background-color: #f0f2f5; Optional background */
          }
      `}</style>
    </div>
  );
}

const WorkspaceLayout = React.memo(WorkspaceLayoutInternal);

export default WorkspaceLayout;