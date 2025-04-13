// src/stores/useAuthStore.jsx
import { create } from 'zustand';
import { loginUser /* fetchUserProfile - no longer needed for init */ } from '../services/api'; // Original didn't use fetchUserProfile here
import { useProjectStore } from './useProjectStore.jsx';
import { useViewStore } from './useViewStore.jsx'; // Original used 'resetViews'

const initialProfile = {
  id: null,
  username: null,
  globalRole: null,
  preferenceId: 'default',
  profileTags: [],
};

export const useAuthStore = create((set, get) => ({
  profile: initialProfile,
  token: localStorage.getItem('access_token') || null,
  isAuthenticated: !!localStorage.getItem('access_token'), // Based on token presence initially
  isLoading: false, // Original started false
  error: null,

  // Original Initialization: Trust token, load cached profile, skip API call.
  initializeAuth: () => {
    const token = get().token;
    const cachedProfile = localStorage.getItem('userProfile');
    let profileToSet = initialProfile;
    let authStatus = false;

    console.log("useAuthStore: Running initializeAuth check (Original Logic)...");

    if (token) {
      console.log("useAuthStore: Token found in storage.");
      if (cachedProfile) {
        try {
          profileToSet = JSON.parse(cachedProfile);
          authStatus = true; // Assume token is valid if cached profile exists
          console.log(`useAuthStore: Loaded cached profile for ${profileToSet.username}. Assuming authenticated.`);
        } catch (e) {
          console.warn(`useAuthStore: Failed to parse cached profile, clearing cache.(${e})`);
          localStorage.removeItem('userProfile');
          localStorage.removeItem('access_token');
           profileToSet = initialProfile;
           authStatus = false;
        }
      } else {
           // Token exists but no cached profile. Still assume authenticated FOR NOW.
           authStatus = true;
           profileToSet = { // Basic placeholder
               id: 'unknown', username: 'User (from token)', globalRole: 'user'
           };
           console.warn("useAuthStore: Token found but no cached profile. Assuming authenticated tentatively.");
      }

      // Update state based on cached info check
      set({
          profile: profileToSet,
          isAuthenticated: authStatus,
          isLoading: false,
          error: null,
          token: authStatus ? token : null
      }, false, 'initializeAuth_Original'); // Use distinct action name

      // Trigger project loading ONLY if authenticated AND no project is currently set
      // This relied on the fallback in loadProjects
      if (authStatus && !useProjectStore.getState().currentProject) {
          console.log("useAuthStore (Init - Original): Triggering project list load as no initial project is set.");
          useProjectStore.getState().loadProjects();
      }

    } else {
        // No token found
        console.log("useAuthStore: No token found. Setting logged out state.");
        set({ profile: initialProfile, token: null, isAuthenticated: false, isLoading: false, error: null }, false, 'initializeAuth_Original_NoToken');
    }
  },

  // Original Login: Fetch token, profile, and INITIAL PROJECT from backend
  login: async (username, password) => {
    set({ isLoading: true, error: null });
    try {
      // Assumes loginUser returns { access_token, user, current_project }
      const { access_token, user, current_project } = await loginUser(username, password);

      localStorage.setItem('access_token', access_token);
      localStorage.setItem('userProfile', JSON.stringify(user));

      set({
        profile: user,
        token: access_token,
        isAuthenticated: true,
        isLoading: false,
        error: null,
      }, false, 'login_Original_Success');

      // Set the initial project obtained from login response
      useProjectStore.getState().setInitialProject(current_project); // This part was likely correct

      // If login didn't return a project, load the list as fallback
      // This part relied on the fallback in loadProjects
      if (!current_project) {
           console.warn("Login response did not include current_project. Loading project list.");
           useProjectStore.getState().loadProjects();
      }

      console.log(`useAuthStore: Login successful for ${username}`);
      return true;
    } catch (error) {
      console.error('useAuthStore: Login Error -', error);
      const errorMessage = error.message || 'Login failed. Please check credentials.';
      localStorage.removeItem('access_token');
      localStorage.removeItem('userProfile');
      set({ error: errorMessage, isLoading: false, isAuthenticated: false, token: null, profile: initialProfile }, false, 'login_Original_Error');
      return false;
    }
  },

  // Original Logout: Clear everything
  logout: () => {
    console.log('useAuthStore: Logging out user:', get().profile.username);
    const wasAuthenticated = get().isAuthenticated;

    localStorage.removeItem('access_token');
    localStorage.removeItem('userProfile');

    set({
      profile: initialProfile,
      token: null,
      isAuthenticated: false,
      error: null,
      isLoading: false,
    }, false, 'logout_Original');

    if (wasAuthenticated) {
        console.log("useAuthStore: Resetting project and view stores due to logout.");
        useProjectStore.getState().reset();
        // Assuming original view store reset function was named resetViews
        // If it was resetRootElement originally, use that.
        useViewStore.getState().resetRootElement(); // Use current name from cite: 23
    }
  },
}));

// Original code likely didn't auto-call initializeAuth here either.