// src/App.jsx
import React, { useEffect, useState, useCallback } from 'react'; // Added useCallback
import { BrowserRouter as Router, Routes, Route, Navigate } from 'react-router-dom';
import { useAuthStore } from './stores/useAuthStore.jsx';
// Removed useViewStore import as setLayoutHydrated is no longer used here
import NavBar from './components/navigation/NavBar.jsx';
import WorkspaceLayout from './components/workspace/WorkspaceLayout.jsx';
import ControlPanel from './components/controls/ControlPanel.jsx';
import StatusBar from './components/status/StatusBar.jsx';
import LoginPage from './components/auth/LoginPage.jsx';
import LoadingSpinner from './components/common/LoadingSpinner.jsx';

function App() {
  // Select only necessary state/actions for App's direct logic
  const isAuthenticated = useAuthStore(state => state.isAuthenticated);
  const isAuthLoading = useAuthStore(state => state.isLoading);
  const initializeAuth = useAuthStore(state => state.initializeAuth);
  // REMOVED: const setLayoutHydrated = useViewStore(state => state.setLayoutHydrated);

  const [isControlPanelOpen, setIsControlPanelOpen] = useState(false);

  // Memoize toggle function
  const handleToggleControlPanel = useCallback(() => {
      setIsControlPanelOpen(prev => !prev);
  }, []); // No dependencies, function is stable

  // Effect 1: Initialize Auth State (runs once on mount)
  useEffect(() => {
    console.log("App Effect [Auth Init]: Running check...");
    // Only run if token exists and profile is not yet loaded in the store
    // Use getState() for one-time check inside effect if needed, or rely on selector updates
    // *** This condition might need review based on original auth logic ***
    if (useAuthStore.getState().token && !useAuthStore.getState().profile.id) {
      initializeAuth();
    } else {
      console.log("App Effect [Auth Init]: Skipped (no token or profile already loaded).");
    }
  }, [initializeAuth]); // Depend only on the stable action reference

  // REMOVED Effect 2: The hydration logic is no longer needed as layout persistence was removed

  // --- Simplified Loading Check ---
  // Only wait for the initial authentication check to complete
  if (isAuthLoading) {
    console.log("App Render: Showing Loading Spinner (Authenticating...)");
    return <LoadingSpinner message="Authenticating..." />;
  }
  console.log("App Render: Rendering main application structure based on auth state.");

  // Render based on authentication status
  return (
    <Router>
      <div className="app-container">
         {/* Render NavBar only if authenticated */}
         {isAuthenticated && (
           <NavBar onToggleControlPanel={handleToggleControlPanel} />
         )}
         <div className="main-content">
           <Routes>
             {!isAuthenticated ? (
               <>
                 {/* Auth Routes */}
                 <Route path="/login" element={<LoginPage />} />
                 {/* Redirect any other path to login if not authenticated */}
                 <Route path="*" element={<Navigate to="/login" replace />} />
               </>
             ) : (
               <>
                 {/* Authenticated Routes */}
                 {/* WorkspaceLayout now handles rendering based on rootElement */}
                 <Route path="/" element={<WorkspaceLayout />} />
                 {/* Redirect login page to workspace if already authenticated */}
                 <Route path="/login" element={<Navigate to="/" replace />} />
                 {/* Fallback route for authenticated users */}
                 <Route path="*" element={<Navigate to="/" replace />} />
               </>
             )}
           </Routes>
         </div>
         {/* Render Controls/Status only if authenticated */}
         {isAuthenticated && (
           <>
             {/* Pass memoized toggle function */}
             <ControlPanel isOpen={isControlPanelOpen} onToggle={handleToggleControlPanel} />
             <StatusBar />
           </>
         )}
      </div>
      {/* Original style tag - Check if this syntax was correct */}
       {/* <style jsx="true">{` ... `}</style> */}
       {/* If the original used styled-jsx, ensure syntax matches that */}
    </Router>
  );
}

export default App;