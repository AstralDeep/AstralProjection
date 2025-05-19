// src/components/controls/ControlPanel.jsx (Modified)
import React, { useState } from 'react';
import StreamsTab from './StreamsTab.jsx'; // Keep StreamsTab for Connection info

// Receive isOpen and onToggle props from App
function ControlPanel({ isOpen, onToggle }) {
  // Default to 'streams' tab since 'views' is removed
  const [activeTab, setActiveTab] = useState('streams');

  return (
    // Use CSS classes to control visibility based on isOpen prop
    <div className={`control-panel ${!isOpen ? 'collapsed' : ''}`}>
      <div className="panel-header">
        <h3>Control Panel</h3>
        {/* Use the onToggle prop passed from App */}
        <button 
          className="collapse-button btn-reset" 
          onClick={onToggle}
          aria-label="Close control panel" // Added for accessibility
        >
          <strong>X</strong>
        </button>
      </div>

      {/* Only render content if the panel is open */}
      {isOpen && (
        <>
          {/* Tabs Section - Only show if more than one tab exists in the future */}
          {/* For now, only 'streams' exists, so we can simplify or hide */}
          <div className="panel-tabs">
            {/* <button
              className={`tab-button ${activeTab === 'views' ? 'active' : ''}`}
              onClick={() => setActiveTab('views')}
            >
              Views
            </button> */}
            <button
              className={`tab-button ${activeTab === 'streams' ? 'active' : ''}`}
              // onClick={() => setActiveTab('streams')} // No need to click if it's the only one
              // Disable click or style differently if only one tab
              style={{ flexGrow: 1, cursor: 'default' }} // Make it take full width and not look clickable
            >
              Connection {/* Renamed from Streams */}
            </button>
             {/* Add other tabs if needed */}
          </div>

          {/* Content Section */}
          <div className="panel-content">
            {/* Removed: {activeTab === 'views' && <ViewsTab />} */}
            {/* Always show StreamsTab content when panel is open and streams tab is active (which is always now) */}
            {activeTab === 'streams' && <StreamsTab />}
            {/* Render other tab content */}
          </div>
        </>
      )}
      {/* Keep original styles */}
      <style jsx="true">{`
            .control-panel {
                position: fixed; right: 0; top: var(--nav-height); bottom: var(--status-height);
                width: var(--control-panel-width); background-color: var(--color-surface);
                box-shadow: var(--shadow-medium); z-index: var(--z-control-panel);
                display: flex; flex-direction: column; transition: transform 0.3s ease;
                border-left: 1px solid var(--color-border); transform: translateX(0);
            }
            .control-panel.collapsed {
                transform: translateX(100%);
            }
            .panel-header { height: 45px; display: flex; align-items: center; justify-content: space-between; padding: 0 10px 0 15px; border-bottom: 1px solid var(--color-border); background: #f8f9fa; }
            .panel-header h3 { margin: 0; font-size: 1rem; }
            .collapse-button { width: 24px; height: 24px; display: flex; align-items: center; justify-content: center; font-size: 1rem; }
            .panel-tabs { display: flex; border-bottom: 1px solid var(--color-border); }
            .tab-button { flex: 1; padding: 8px 10px; text-align: center; font-weight: 500; border: none; background: none; cursor: pointer; color: var(--color-text-secondary); border-bottom: 2px solid transparent; font-size: 0.9rem; }
            .tab-button.active { color: var(--color-primary); border-bottom-color: var(--color-primary); }
            .panel-content { flex: 1; overflow-y: auto; padding: 15px; }
             .btn-reset { background: none; border: none; padding: 0; font: inherit; color: inherit; cursor: pointer; outline: inherit; }
        `}</style>
    </div>
  );
}

export default ControlPanel;