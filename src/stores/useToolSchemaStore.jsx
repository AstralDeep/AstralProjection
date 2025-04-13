// src/stores/useToolSchemaStore.jsx
import { create } from 'zustand';

export const useToolSchemaStore = create((set) => ({
  toolSchemas: {}, // Stores: { [actionId]: { name, description, inputSchema, outputSchema }, ... }
  isLoading: false, // Optional: track loading state if needed
  error: null,     // Optional: track errors if needed

  /**
   * Action to set the tool schemas received from the backend.
   * @param {object} schemas - The 'tools' object from the tool_schemas message payload.
   */
  setToolSchemas: (schemas) => {
    console.log("useToolSchemaStore: Setting tool schemas received from backend.");
    if (typeof schemas === 'object' && schemas !== null) {
      set({ toolSchemas: schemas, isLoading: false, error: null }, false, 'setToolSchemas');
    } else {
      console.error("useToolSchemaStore: Invalid schemas object received.", schemas);
      set({ toolSchemas: {}, error: "Invalid schema format received.", isLoading: false }, false, 'setToolSchemas_error');
    }
  },

  /**
   * Action to clear the tool schemas, e.g., on disconnect or project change.
   */
  clearToolSchemas: () => {
    console.log("useToolSchemaStore: Clearing tool schemas.");
    set({ toolSchemas: {}, isLoading: false, error: null }, false, 'clearToolSchemas');
  },

  // --- Selectors ---
  /**
   * Selector to get all stored tool schemas.
   * @returns {object} The toolSchemas object.
   */
  getAllSchemas: () => useToolSchemaStore.getState().toolSchemas,

  /**
   * Selector to get the schema for a specific tool/action ID.
   * @param {string} actionId - The ID of the tool/action.
   * @returns {object|null} The schema object for the tool or null if not found.
   */
  getSchemaByActionId: (actionId) => {
    const schemas = useToolSchemaStore.getState().toolSchemas;
    return schemas[actionId] || null;
  },

  /**
   * Selector to get the input schema for a specific tool/action ID.
   * @param {string} actionId - The ID of the tool/action.
   * @returns {object|null} The inputSchema object or null if not found.
   */
  getInputSchemaByActionId: (actionId) => {
    const toolSchema = useToolSchemaStore.getState().getSchemaByActionId(actionId);
    return toolSchema?.inputSchema || null;
  }
}));