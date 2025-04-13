// src/stores/useProjectStore.jsx
// --- Reverted to Original Logic (with loadProjects fallback) ---
import { create } from 'zustand';
import { fetchProjects, fetchProjectById } from '../services/api';
import { useAuthStore } from './useAuthStore.jsx';
import { useViewStore } from './useViewStore.jsx'; // Use current view store

// Define possible connection statuses
export const ConnectionStatus = {
  DISCONNECTED: 'disconnected',
  CONNECTING: 'connecting',
  CONNECTED: 'connected',
  RECONNECTING: 'reconnecting',
  ERROR: 'error',
};

export const useProjectStore = create((set, get) => ({
  projects: [],
  currentProject: null,
  isLoading: false,
  isLoadingDetails: false,
  error: null,
  projectConnectionStatus: ConnectionStatus.DISCONNECTED,
  projectConnectionError: null,

  // ACTION: Set connection status (Keep this helper)
  setProjectConnectionStatus: (status, error = null) => {
      if (status !== get().projectConnectionStatus || error !== get().projectConnectionError) {
          console.log(`%cuseProjectStore: Setting connection status for project ${get().currentProject?.id || 'none'} to ${status}${error ? ` (Error: ${error})` : ''}`, 'color: brown;');
          set({ projectConnectionStatus: status, projectConnectionError: error }, false, 'setProjectConnectionStatus');
      }
  },

  // ACTION: Set the INITIAL project (called by useAuthStore's login)
  setInitialProject: (project) => {
      // Original logic likely just set the project if provided
      if (project && project.id && !get().currentProject) {
           console.log(`%cuseProjectStore: Setting INITIAL project (from login/auth) to: ${project?.name} (${project?.id})`, 'color: green; font-weight: bold;');
           // Original might not have reset status here, but let's keep it for consistency on project change
            set({
                currentProject: project,
                error: null, // Clear errors
                projectConnectionStatus: ConnectionStatus.DISCONNECTED, // Reset status
                projectConnectionError: null
            }, false, 'setInitialProject_Original');
      } else {
           console.log("useProjectStore: setInitialProject skipped or project already set.");
      }
  },

  // ACTION: Load the LIST of projects (with original fallback)
  loadProjects: async () => {
    const token = useAuthStore.getState().token;
    if (!token || get().isLoading) {
         console.log("useProjectStore: loadProjects skipped (no token or already loading list).");
         return get().projects;
    };
    set({ isLoading: true, error: null });
    try {
      console.log("useProjectStore: Loading project list via loadProjects action (Original Logic)...");
      const { projects: fetchedProjects /*, current_project */ } = await fetchProjects(token); // Get list

      set({ projects: fetchedProjects || [], isLoading: false });
      console.log(`useProjectStore: Loaded ${fetchedProjects?.length ?? 0} projects into list.`);

      // --- ORIGINAL Auto-select Fallback Logic ---
      // Auto-select first project IF none is currently active after loading
      if (!get().currentProject && fetchedProjects && fetchedProjects.length > 0) {
        let projectToSelect = fetchedProjects[0]; // Simple fallback to first
        // Maybe add the 'public' check back here as a small improvement on original
        // projectToSelect = fetchedProjects.find(p => p.id === 'public') || fetchedProjects[0];
        console.warn(`%cuseProjectStore (Original Logic): No current project set after loading list, auto-selecting first: ${projectToSelect.name} (${projectToSelect.id})`, 'color: orange;');
        // Use the internal function which correctly resets UI and connection state
        get()._setCurrentProjectAndResetState(projectToSelect);
      }
      // --- END ORIGINAL Fallback ---

      return fetchedProjects || [];
    } catch (error) {
      console.error('useProjectStore: Project List Load Error -', error);
      const errorMessage = error.message || 'Failed to load project list.';
      set({ error: errorMessage, isLoading: false, projects: [] });
      if (error.status === 401) { useAuthStore.getState().logout(); }
      return [];
    }
  },

  // INTERNAL ACTION: Set current project & reset related state (Keep improved version)
  _setCurrentProjectAndResetState: (project) => {
    const currentId = get().currentProject?.id;
    const newId = project?.id;
    console.log(`%c_setCurrentProjectAndResetState: Called. Current ID: ${currentId}, Attempting to set New ID: ${newId}`, 'color: purple;');
    if (project && project.id && ((currentId !== newId) || (currentId === null && newId !== null))) {
        console.log(`%c_setCurrentProjectAndResetState: Conditions met. Updating currentProject to ${project?.name} (${newId})`, 'color: purple; font-weight: bold;');
        set({
            currentProject: project,
            error: null,
            projectConnectionStatus: ConnectionStatus.DISCONNECTED,
            projectConnectionError: null
        }, false, '_setCurrentProjectAndResetState_Update');
        console.log('%c_setCurrentProjectAndResetState: Calling resetRootElement() in useViewStore.', 'color: purple;');
        useViewStore.getState().resetRootElement(); // Use current reset function
        console.log('%c_setCurrentProjectAndResetState: State update and UI reset complete.', 'color: purple;');
    } else {
         console.log(`%c_setCurrentProjectAndResetState: Skipped or invalid project.`, 'color: purple;');
    }
  },

  // ACTION: Switch to a different project (Keep improved version)
  switchProject: async (projectId) => {
    const currentProjectId = get().currentProject?.id;
    if (!projectId || currentProjectId === projectId) {
        console.log(`useProjectStore: switchProject skipped (no ID provided or already current: ${projectId})`);
        return get().currentProject;
    }
    set({ isLoadingDetails: true, error: null });
    console.log(`%cuseProjectStore: Starting switchProject to ID: ${projectId}`, 'color: blue; font-weight: bold;');
    try {
      let project = get().projects.find(p => p.id === projectId);
      const token = useAuthStore.getState().token;
      if (!project) {
        if (!token) throw new Error("Authentication token missing...");
        console.log(`%cuseProjectStore: Project ${projectId} not cached, fetching...`, 'color: blue;');
        project = await fetchProjectById(projectId, token);
         if (project) {
             console.log(`%cuseProjectStore: Fetched project ${projectId} details.`, 'color: blue;');
             set(state => {
                 const otherProjects = state.projects.filter(p => p.id !== projectId);
                 return { projects: [...otherProjects, project] };
             }, false, 'switchProject_AddOrUpdateFetched');
         }
      } else {
          console.log(`%cuseProjectStore: Project ${projectId} found in cache.`, 'color: blue;');
      }
      if (!project) throw new Error(`Project ${projectId} not found or access denied.`);
      console.log(`%cuseProjectStore: Calling _setCurrentProjectAndResetState for ${project.name}`, 'color: blue;');
      get()._setCurrentProjectAndResetState(project);
      set({ isLoadingDetails: false });
      console.log(`%cuseProjectStore: switchProject completed successfully for ${projectId}`, 'color: green; font-weight: bold;');
      return project;
    } catch (error) {
      console.error(`%cuseProjectStore: Project Switch Error (ID: ${projectId}):`, 'color: red;', error);
      const errorMessage = error.message || 'Failed to switch project.';
      set({ error: errorMessage, isLoadingDetails: false, projectConnectionStatus: ConnectionStatus.ERROR, projectConnectionError: errorMessage });
       if (error.status === 401) { useAuthStore.getState().logout(); }
      return null;
    }
  },

  // ACTION: Reset project state (Keep improved version)
  reset: () => {
      console.log("%cuseProjectStore: Resetting project state (called on logout).", 'color: red; font-weight: bold;');
      set({
          projects: [],
          currentProject: null,
          isLoading: false,
          isLoadingDetails: false,
          error: null,
          projectConnectionStatus: ConnectionStatus.DISCONNECTED,
          projectConnectionError: null
      }, false, 'resetProjectStore');
      useViewStore.getState().resetRootElement(); // Ensure view is reset
  }
}));