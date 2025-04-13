// src/components/navigation/NavBar.jsx
import React, { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { useAuthStore } from '../../stores/useAuthStore.jsx'; //
// Import store and status enum
import { useProjectStore, ConnectionStatus } from '../../stores/useProjectStore.jsx'; //

function NavBar({ onToggleControlPanel }) { //
  // --- Auth Store selectors ---
  const profile = useAuthStore(state => state.profile); //
  const logout = useAuthStore(state => state.logout); //

  // --- Project Store selectors ---
  const projects = useProjectStore(state => state.projects); //
  const currentProjectId = useProjectStore(state => state.currentProject?.id); //
  const currentProjectName = useProjectStore(state => state.currentProject?.name); //
  const isLoadingProjects = useProjectStore(state => state.isLoading); //
  const switchProject = useProjectStore(state => state.switchProject); //
  const loadProjects = useProjectStore(state => state.loadProjects); //
  // --- Read connection status from the store ---
  const wsStatus = useProjectStore(state => state.projectConnectionStatus); //
  const wsError = useProjectStore(state => state.projectConnectionError); //

  // --- Local UI State ---
  const [isUserMenuOpen, setIsUserMenuOpen] = useState(false); //
  const [isProjectMenuOpen, setIsProjectMenuOpen] = useState(false); //

  // --- Handlers ---
  const handleToggleProjectMenu = () => { //
      const open = !isProjectMenuOpen;
      setIsProjectMenuOpen(open);
      // If opening the menu and the project list is empty and not already loading, trigger load
      if (open && projects.length === 0 && !isLoadingProjects) {
          console.log("NavBar: Opening project menu, loading project list..."); //
          loadProjects(); //
      }
  };

  const handleProjectSelect = (project) => { //
    setIsProjectMenuOpen(false); // Close menu on selection
    if (project.id !== currentProjectId) { // Only switch if different project selected
      switchProject(project.id); //
    }
  };

  const toggleUserMenu = () => setIsUserMenuOpen(prev => !prev); //

  // Close menus when clicking outside
  useEffect(() => { //
    const handleClickOutside = (event) => {
      // Close user menu if click is outside its container
      if (!event.target.closest('.user-menu-container')) setIsUserMenuOpen(false); //
      // Close project menu if click is outside its container
      if (!event.target.closest('.project-selector-container')) setIsProjectMenuOpen(false); //
    };
    document.addEventListener('mousedown', handleClickOutside); //
    // Cleanup listener on component unmount
    return () => document.removeEventListener('mousedown', handleClickOutside); //
  }, []); // Empty dependency array ensures this runs only once on mount

  // --- Determine status text/title for display ---
   let statusText = wsStatus; //
   let statusTitle = wsStatus; //
   if (wsStatus === ConnectionStatus.ERROR && wsError) { //
       statusTitle = `Error: ${wsError}`; //
   } else if (wsStatus === ConnectionStatus.DISCONNECTED && wsError === 'Manual disconnect') { //
       statusTitle = 'Disconnected by user'; //
   }

  // *** === ADDED CONSOLE LOG FOR DEBUGGING === ***
  console.log("NavBar Render: projects state from store:", projects);
  console.log("NavBar Render: projects.length:", projects?.length);
  // *** ======================================= ***

  return (
    <nav className="nav-bar"> {/* */}
      <div className="nav-logo"> {/* */}
        <Link to="/" className="logo-link"> {/* */}
          <span className="logo-text">AI Interface</span> {/* */}
        </Link>
      </div>

      {/* Project Selector */}
      <div className="nav-center"> {/* */}
        <div className="project-selector-container"> {/* */}
          <button
            className="project-menu-button" //
            onClick={handleToggleProjectMenu} //
            disabled={isLoadingProjects || !profile?.id} // Disable if loading or not logged in
            title={currentProjectName || 'Select Project'} //
          >
            {isLoadingProjects ? ( //
              <span className="loading-indicator">Loading...</span> //
            ) : (
              <>
                <span className="project-name"> {/* */}
                  {currentProjectName ?? 'Select Project'} {/* Display current name or placeholder */}
                </span>
                <span className="dropdown-icon">▼</span> {/* */}
              </>
            )}
          </button>

          {/* Dropdown Menu - Renders only if isProjectMenuOpen is true */}
          {isProjectMenuOpen && ( //
            <div className="dropdown-menu" id="project-dropdown"> {/* */}
               <strong>Available Projects ({projects?.length ?? 0})</strong> {/* Display count safely */}
               <div style={{ marginTop: '10px', maxHeight: '300px', overflowY: 'auto' }}> {/* Scrollable area */}
                 {/* Map over the projects array from the store */}
                 {Array.isArray(projects) && projects.length > 0 ? ( //
                   projects.map(project => ( //
                     <div
                       key={project.id} // React key
                       onClick={() => handleProjectSelect(project)} // Click handler
                       // Apply 'active' class if this project is the current one
                       className={`dropdown-item project-item ${currentProjectId === project.id ? 'active' : ''}`} //
                     >
                       <div>{project.name}</div> {/* Project name */}
                       {/* Display description if available */}
                       {project.description && <small>{project.description}</small>} {/* */}
                     </div>
                   ))
                 ) : (
                   // Display message if no projects or still loading
                   <div className="dropdown-item">{isLoadingProjects ? 'Loading...' : 'No projects found.'}</div> //
                 )}
               </div>
               {/* Refresh button */}
               <button className="dropdown-item refresh-button" onClick={loadProjects} disabled={isLoadingProjects}> {/* */}
                   {isLoadingProjects ? 'Refreshing...' : 'Refresh Projects'} {/* */}
               </button>
            </div>
          )}
        </div>
      </div>

      {/* Nav Controls */}
      <div className="nav-controls"> {/* */}
        {/* Control Panel Toggle Button */}
        <button className="control-panel-toggle btn-reset" onClick={onToggleControlPanel} title="Toggle Control Panel">⚙️</button> {/* */}
        {/* Connection Status Indicator - Reads from store */}

        {/* User Menu */}
        <div className="user-menu-container"> {/* */}
           {/* User Menu Button */}
           <button className="user-menu-button btn-reset" onClick={toggleUserMenu}> {/* */}
              {/* Display first initial of username */}
              <span className="user-initial">{profile?.username ? profile.username.charAt(0).toUpperCase() : '?'}</span> {/* */}
           </button>
           {/* User Dropdown Menu - Renders only if isUserMenuOpen is true */}
           {isUserMenuOpen && ( //
             <div className="user-menu dropdown-menu right-aligned show"> {/* */}
               {/* User Info Section */}
               <div className="user-info"> {/* */}
                 <span className="username">{profile?.username}</span> {/* */}
                 <span className="role">{profile?.globalRole}</span> {/* */}
               </div>
               <div className="dropdown-divider"></div> {/* */}
               {/* Logout Button */}
               <button className="menu-item logout-button dropdown-item" onClick={() => { logout(); setIsUserMenuOpen(false); }}> {/* */}
                 Log Out
               </button>
             </div>
           )}
        </div>
      </div>
       {/* Embedded Styles - Keep existing styles from original file */}
       <style jsx="true">{`
            /* --- Styles copied from original src/components/navigation/NavBar.jsx --- */
            .nav-bar { display: flex; align-items: center; justify-content: space-between; height: var(--nav-height); padding: 0 var(--spacing-md); background-color: var(--color-surface); box-shadow: var(--shadow-small); z-index: var(--z-navbar); position: relative; }
            .nav-logo { font-size: var(--font-size-xlarge); font-weight: bold; color: var(--color-primary); }
            .logo-link { display: flex; align-items: center; gap: var(--spacing-sm); color: inherit; text-decoration: none; }
            .logo-text { background: linear-gradient(45deg, var(--color-primary), var(--color-primary-dark)); -webkit-background-clip: text; -webkit-text-fill-color: transparent; font-weight: 700; }
            .nav-center { flex: 1; display: flex; justify-content: center; padding: 0 var(--spacing-md); position: relative; }
            .project-selector-container { position: relative; z-index: calc(var(--z-navbar) + 1); }
            .project-menu-button { display: flex; align-items: center; gap: var(--spacing-sm); padding: 0.5rem 1rem; background-color: var(--color-surface); border: 1px solid var(--color-border); border-radius: var(--border-radius-md); cursor: pointer; transition: all var(--transition-fast); }
            .project-menu-button:hover:not(:disabled) { background-color: var(--color-primary-light); }
            .project-menu-button:disabled { opacity: 0.6; cursor: not-allowed; }
            .project-name { font-weight: 500; max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .dropdown-icon { font-size: 10px; color: var(--color-text-secondary); margin-left: 4px; }
            /* Project dropdown specific styles */
            #project-dropdown { position: absolute; top: 100%; left: 0; margin-top: 8px; width: 300px; max-height: 400px; overflow-y: auto; background-color: var(--color-surface); border-radius: var(--border-radius-md); box-shadow: var(--shadow-medium); z-index: var(--z-dropdown); padding: 1rem; border: 1px solid var(--color-border); /* Added border for visibility */ }
            #project-dropdown strong { display: block; margin-bottom: 10px; font-size: 0.9rem; color: var(--color-text-secondary); }
            .project-item { cursor: pointer; padding: 8px 12px; border-radius: var(--border-radius-sm); margin-bottom: 4px; }
            .project-item:hover { background-color: var(--color-primary-light); }
            .project-item.active { background-color: var(--color-primary); color: white; font-weight: bold; }
            .project-item.active small { color: #eee; }
            .project-item small { display: block; font-size: 0.8rem; color: var(--color-text-secondary); margin-top: 2px; }
            .refresh-button { margin-top: 10px; border-top: 1px solid var(--color-border); padding-top: 10px !important; width: 100%; text-align: center; color: var(--color-primary); }
            .refresh-button:disabled { color: var(--color-text-secondary); cursor: not-allowed; }
            .loading-indicator { font-style: italic; color: var(--color-text-secondary); font-size: 0.9em; }
            /* Nav Controls */
            .nav-controls { display: flex; align-items: center; gap: var(--spacing-md); }
            .control-panel-toggle { width: 36px; height: 36px; border-radius: 50%; display: flex; align-items: center; justify-content: center; background-color: var(--color-light); box-shadow: var(--shadow-small); transition: transform var(--transition-fast); }
            .control-panel-toggle:hover { transform: rotate(30deg); box-shadow: var(--shadow-medium); }
            /* Connection status styles (ensure classes match ConnectionStatus values) */
            .connection-status { display: flex; align-items: center; gap: var(--spacing-xs); font-size: var(--font-size-small); padding: 4px 8px; border-radius: var(--border-radius-md); text-transform: capitalize; }
            .connection-status .status-indicator { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
            .connection-status.connected .status-indicator { background-color: var(--color-success); box-shadow: 0 0 0 2px rgba(40, 167, 69, 0.2); }
            .connection-status.disconnected .status-indicator { background-color: var(--color-danger); box-shadow: 0 0 0 2px rgba(220, 53, 69, 0.2); }
            .connection-status.reconnecting .status-indicator { background-color: var(--color-warning); box-shadow: 0 0 0 2px rgba(255, 193, 7, 0.2); animation: pulse 1.5s infinite; }
            .connection-status.connecting .status-indicator { background-color: var(--color-info); box-shadow: 0 0 0 2px rgba(23, 162, 184, 0.2); animation: pulse 1.5s infinite; }
            .connection-status.error .status-indicator { background-color: var(--color-danger); box-shadow: 0 0 0 2px rgba(220, 53, 69, 0.2); }
            .connection-status.connected { background-color: rgba(40, 167, 69, 0.1); color: #1b642c; }
            .connection-status.disconnected { background-color: rgba(220, 53, 69, 0.1); color: #7e242e; }
            .connection-status.reconnecting { background-color: rgba(255, 193, 7, 0.1); color: #8b6d1a; }
            .connection-status.connecting { background-color: rgba(23, 162, 184, 0.1); color: #1b6474; }
            .connection-status.error { background-color: rgba(220, 53, 69, 0.1); color: #7e242e; font-weight: bold; }
            /* User Menu */
            .user-menu-container { position: relative; }
            .user-menu-button { width: 36px; height: 36px; border-radius: 50%; background-color: var(--color-primary); color: white; display: flex; align-items: center; justify-content: center; font-weight: bold; box-shadow: var(--shadow-small); transition: transform var(--transition-fast); cursor: pointer; }
            .user-menu-button:hover { transform: scale(1.05); }
            .user-initial { font-size: 1rem; line-height: 1; }
            .user-menu { position: absolute; top: calc(100% + 8px); right: 0; background-color: var(--color-surface); border-radius: var(--border-radius-md); box-shadow: var(--shadow-medium); min-width: 220px; z-index: var(--z-dropdown); overflow: hidden; animation: fadeIn 0.2s ease-out; border: 1px solid var(--color-border); /* Added border */ }
            .user-info { padding: var(--spacing-md); border-bottom: 1px solid var(--color-border); }
            .username { font-weight: bold; display: block; }
            .role { color: var(--color-text-secondary); font-size: var(--font-size-small); }
            .menu-item { display: block; padding: var(--spacing-sm) var(--spacing-md); /* Adjusted padding */ width: 100%; text-align: left; transition: background-color var(--transition-fast); border: none; background: none; font-size: 0.9rem; /* Adjusted size */ cursor: pointer; }
            .menu-item:hover { background-color: rgba(0, 0, 0, 0.05); }
            .logout-button { color: var(--color-danger); }
            .btn-reset { background: none; border: none; padding: 0; margin: 0; font: inherit; color: inherit; cursor: pointer; outline: inherit; }
            /* Animations */
            @keyframes pulse { 0% { opacity: 0.6; } 50% { opacity: 1; } 100% { opacity: 0.6; } }
            @keyframes fadeIn { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }
       `}</style>
    </nav>
  );
}

export default NavBar; //