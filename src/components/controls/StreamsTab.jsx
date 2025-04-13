// src/components/controls/StreamsTab.jsx
import React from 'react';
// Import store and status enum
import { useProjectStore, ConnectionStatus } from '../../stores/useProjectStore.jsx';
// useWebSocket hook is still needed for connect/disconnect actions
import { useWebSocket } from '../../hooks/useWebSocket.jsx';

function StreamsTab() {
  const currentProject = useProjectStore((state) => state.currentProject);
  // --- Read connection status and error from the store ---
  const status = useProjectStore((state) => state.projectConnectionStatus);
  const error = useProjectStore((state) => state.projectConnectionError); // Get error message

  // Derive streamId for the hook, but status comes from store
  const streamId = currentProject ? `project:${currentProject.id}` : null;
  // Get connect/disconnect actions from the hook
  const { connect, disconnect } = useWebSocket(streamId);

  return (
    <div className="streams-tab">
      <h4>Project Connection</h4>
      {currentProject ? (
        <div className="connection-info">
          <p><strong>Project:</strong> {currentProject.name} ({currentProject.id})</p>
          <p><strong>Stream ID:</strong> {streamId}</p>
          <p><strong>Status:</strong> <span className={`status-${status}`}>{status}</span></p>
          {/* Display error message from store */}
          {status === ConnectionStatus.ERROR && error && (
              <p className="error-message"><strong>Error:</strong> {error}</p>
          )}
          <div className="connection-actions">
             {/* Enable connect button if disconnected or in error state */}
             {(status === ConnectionStatus.DISCONNECTED || status === ConnectionStatus.ERROR) && (
                 <button onClick={connect} disabled={status === ConnectionStatus.CONNECTING}>
                     Connect
                 </button>
             )}
             {/* Enable disconnect button if connected or connecting */}
              {(status === ConnectionStatus.CONNECTED || status === ConnectionStatus.CONNECTING || status === ConnectionStatus.RECONNECTING) && (
                  <button onClick={disconnect}>
                      Disconnect
                  </button>
              )}
          </div>
        </div>
      ) : (
        <p>No project selected. Select a project in the NavBar to connect.</p>
      )}
        <style jsx="true">{`
            .streams-tab h4 { margin-bottom: 15px; }
            .connection-info { font-size: 0.9rem; line-height: 1.6; }
            .connection-info p strong { margin-right: 5px; }
            /* Use status string for class */
            span[class*="status-"] { text-transform: capitalize; font-weight: bold; }
            .status-connected { color: var(--color-success); }
            .status-disconnected { color: var(--color-secondary); } /* Adjusted color */
            .status-connecting, .status-reconnecting { color: var(--color-info); } /* Adjusted color */
            .status-error { color: var(--color-danger); }
            .error-message { color: var(--color-danger); font-size: 0.85rem; margin-top: 5px; border: 1px solid var(--color-danger); background-color: rgba(220, 53, 69, 0.05); padding: 4px 8px; border-radius: 3px; }
            .connection-actions { margin-top: 15px; }
            .connection-actions button { margin-right: 10px; padding: 5px 10px; font-size: 0.8rem; cursor: pointer; }
            .connection-actions button:disabled { opacity: 0.5; cursor: not-allowed; }
        `}</style>
    </div>
  );
}

export default StreamsTab;