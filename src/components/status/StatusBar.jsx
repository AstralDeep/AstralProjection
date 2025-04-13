// src/components/status/StatusBar.jsx
import React from 'react';
import { useProjectStore, ConnectionStatus } from '../../stores/useProjectStore.jsx';
import { useNotificationStore } from '../../stores/useNotificationStore.jsx';

function StatusBar() {
  // --- Read connection status directly from the store ---
  const wsStatus = useProjectStore((state) => state.projectConnectionStatus);
  const wsError = useProjectStore((state) => state.projectConnectionError); // Optional: display error

  const notifications = useNotificationStore((state) => state.notifications);

  const formatTime = (timestamp) => {
    return new Date(timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  };

  // Determine status text and title more precisely
  let statusText = wsStatus;
  let statusTitle = wsStatus;
  if (wsStatus === ConnectionStatus.ERROR && wsError) {
      statusTitle = `Error: ${wsError}`;
  } else if (wsStatus === ConnectionStatus.DISCONNECTED && wsError === 'Manual disconnect') {
      statusTitle = 'Disconnected by user';
  }


  return (
    <div className="status-bar">
      <div className="status-left">
        {/* Connection Indicator - uses store status */}
        <div
           className={`connection-indicator ${wsStatus.toLowerCase()}`} // Use status string for class
           title={statusTitle} // Show detailed title on hover
        >
          <span className="indicator-dot"></span>
          <span className="indicator-text">{statusText}</span> {/* Show status string */}
        </div>
      </div>

      {/* Notifications Area */}
      <div className="status-center">
        <div className="status-messages">
          {notifications.map(message => (
            <div
              key={message.id}
              className={`status-message message-${message.type}`}
              title={message.message} // Show full message on hover
            >
              <span className="message-time">{formatTime(message.timestamp)}</span>
              <span className="message-content">{message.message}</span>
            </div>
          ))}
          {notifications.length === 0 && <span className="no-messages"></span>}
        </div>
      </div>

      {/* Stats Area */}
      <div className="status-right">
        <div className="status-stats">
           {/* Add stats if needed */}
        </div>
      </div>
        {/* Keep existing styles, including connection indicator styles */}
        <style jsx="true">{`
           .status-bar { /* ... */ }
           .status-left, .status-right { /* ... */ }
           .status-center { /* ... */ }
           .status-messages { /* ... */ }
           .status-message { /* ... */ }
           /* Connection indicator styles (ensure classes match ConnectionStatus values) */
           .connection-indicator { display: flex; align-items: center; gap: 5px; padding: 2px 6px; border-radius: 10px; font-size: 11px; text-transform: capitalize; }
           .connection-indicator .indicator-dot { width: 7px; height: 7px; border-radius: 50%; }
           .connection-indicator.connected .indicator-dot { background-color: var(--color-success); }
           .connection-indicator.disconnected .indicator-dot { background-color: var(--color-danger); }
           .connection-indicator.reconnecting .indicator-dot { background-color: var(--color-warning); animation: pulse 1.5s infinite; }
           .connection-indicator.connecting .indicator-dot { background-color: var(--color-info); animation: pulse 1.5s infinite; }
           .connection-indicator.error .indicator-dot { background-color: var(--color-danger); }
           .connection-indicator.connected { background-color: rgba(40, 167, 69, 0.1); color: #1b642c; }
           .connection-indicator.disconnected { background-color: rgba(220, 53, 69, 0.1); color: #7e242e; }
           .connection-indicator.reconnecting { background-color: rgba(255, 193, 7, 0.1); color: #8b6d1a; }
           .connection-indicator.connecting { background-color: rgba(23, 162, 184, 0.1); color: #1b6474; }
           .connection-indicator.error { background-color: rgba(220, 53, 69, 0.1); color: #7e242e; font-weight: bold; }
           /* ... other styles ... */
           @keyframes pulse {
              0% { opacity: 0.6; } 50% { opacity: 1; } 100% { opacity: 0.6; }
           }
       `}</style>
    </div>
  );
}

export default StatusBar;