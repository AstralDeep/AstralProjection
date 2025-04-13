// src/services/api.js

const BASE_URL = '/api'; // Your API base path

/**
 * Handles the response from fetch requests, parsing JSON and throwing errors for non-OK statuses.
 * Includes specific handling for 401 Unauthorized errors.
 * @param {Response} response - The response object from fetch.
 * @returns {Promise<object|null>} - The parsed JSON data or null for empty responses.
 * @throws {Error} - Throws an error with details if the response status is not OK.
 */
async function handleResponse(response) {
    if (!response.ok) {
        let errorData = { detail: `HTTP error! Status: ${response.status}` }; // Default error
        try {
            errorData = await response.json();
        } catch (e) {
            console.error(`Response (${e}) body is not JSON`)
            // Ignore if response body is not JSON
        }

        // Create an error object
        const error = new Error(errorData.detail || `HTTP error! Status: ${response.status}`);
        error.status = response.status;

        // Log the error
        console.error(`API Error (${response.url}): ${error.status} - ${error.message}`, errorData);

        // Specific handling for 401 Unauthorized
        if (error.status === 401) {
            // Optionally add logic here to trigger logout if needed globally,
            // though stores also handle this based on the thrown error.
             console.warn("API request failed with 401 Unauthorized.");
             error.message = "Authentication failed or token expired. Please log in again."; // Standardize message
        }

        throw error;
    }
    // Handle cases where the response might be empty (e.g., 204 No Content)
    if (response.status === 204) {
        return null;
    }
    // Otherwise, parse the JSON body
    return response.json();
}

/**
 * Authenticates the user.
 * Assumes backend returns { access_token: string, user: object, current_project: object | null }.
 * @param {string} username - The user's username.
 * @param {string} password - The user's password.
 * @returns {Promise<{access_token: string, user: object, current_project: object | null}>}
 */
export async function loginUser(username, password) {
    console.log(`API: Attempting login for ${username}`);
    const response = await fetch(`${BASE_URL}/auth/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify({ username, password }),
    });
    return handleResponse(response);
}

/**
 * Fetches session data including user profile and initial project for the authenticated user.
 * Uses /api/users/me as a placeholder endpoint. Adjust if your backend differs.
 * Assumes endpoint returns { user: object, current_project: object | null } on success.
 * @param {string} token - The user's access token.
 * @returns {Promise<{user: object, current_project: object | null}>} - User and initial project data.
 */
export async function fetchUserProfile(token) {
    console.log("API: Fetching user profile + initial session data (via /api/users/me placeholder)");
    if (!token) throw new Error("Authentication required (fetchUserProfile/session)");

    // --- IMPORTANT ---
    // Replace '/api/users/me' with your actual backend endpoint for validating
    // a token and getting session info (profile + current project).
    const sessionEndpoint = `${BASE_URL}/users/me`;
    // --- --- --- ---

    const response = await fetch(sessionEndpoint, {
        headers: { 'Authorization': `Bearer ${token}`, 'Accept': 'application/json' },
        credentials: 'include'
    });

    try {
        // Assuming the endpoint returns the profile directly or nested like { user: ..., current_project: ...}
        const data = await handleResponse(response);

        // Adapt parsing based on your actual API response structure:
        let userProfile = null;
        let currentProject = null;

        if (data) {
             // Example: If API returns profile directly and project is nested or separate
             userProfile = data.user || data; // Assume 'user' field or data itself is the profile
             currentProject = data.current_project || null; // Look for 'current_project'
        }

        if (!userProfile) {
            // If handleResponse didn't throw but data is bad, treat as error
             throw new Error("User profile data not found in session response.");
        }

        return { user: userProfile, current_project: currentProject };

    } catch (error) {
        if (error.status === 404) {
             console.warn(`API: Session endpoint (${sessionEndpoint}) not found (404). Cannot fetch initial profile/project.`);
             // Cannot reliably authenticate without a valid session/profile endpoint.
             // Throw an auth error to trigger logout.
             throw new Error("Authentication failed: Session validation endpoint not found.");
        }
        // Re-throw other errors (like 401, 500, network errors)
        throw error;
    }
}


/**
 * Fetches the list of projects accessible to the user.
 * Assumes backend returns { projects: Array, current_project: object|null }.
 * @param {string} token - The user's access token.
 * @param {number} [skip=0] - Number of projects to skip.
 * @param {number} [limit=100] - Maximum number of projects to return.
 * @returns {Promise<{projects: Array, current_project: object|null}>}
 */
export async function fetchProjects(token, skip = 0, limit = 100) {
    console.log(`API: Fetching projects (skip: ${skip}, limit: ${limit})`);
    if (!token) throw new Error("Authentication required (fetchProjects)");
    const response = await fetch(`${BASE_URL}/projects/?skip=${skip}&limit=${limit}`, {
        headers: { 'Authorization': `Bearer ${token}`, 'Accept': 'application/json' },
        credentials: 'include'
    });
    return handleResponse(response);
}

/**
 * Fetches details for a specific project by its ID.
 * Assumes backend returns the project object.
 * @param {string} projectId - The ID of the project to fetch.
 * @param {string} token - The user's access token.
 * @returns {Promise<object>} - The project details object.
 */
export async function fetchProjectById(projectId, token) {
    console.log(`API: Fetching project by ID: ${projectId}`);
    if (!token) throw new Error("Authentication required (fetchProjectById)");
    const response = await fetch(`${BASE_URL}/projects/${projectId}`, {
        headers: { 'Authorization': `Bearer ${token}`, 'Accept': 'application/json' },
        credentials: 'include'
    });
    return handleResponse(response);
}


/**
 * Updates the favorite status of a project.
 * Assumes backend uses POST on `/api/projects/{projectId}/favorite`.
 * @param {string} projectId - The ID of the project.
 * @param {boolean} isFavorite - The desired favorite status.
 * @param {string} token - The user's access token.
 * @returns {Promise<object|null>} - The response from the server.
 */
export async function updateFavoriteStatus(projectId, isFavorite, token) {
    console.log(`API: Setting favorite status for project ${projectId} to ${isFavorite}`);
    if (!token) throw new Error("Authentication required (updateFavoriteStatus)");
    const response = await fetch(`${BASE_URL}/projects/${projectId}/favorite`, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${token}`,
            'Content-Type': 'application/json',
            'Accept': 'application/json'
        },
        body: JSON.stringify({ favorite: isFavorite }),
        credentials: 'include'
    });
    return handleResponse(response);
}