// src/stores/useViewStore.jsx
import { create } from 'zustand';
import { produce } from 'immer'; // Import Immer for safe state mutation

export const useViewStore = create((set, get) => ({
  rootElement: null, // Holds the entire UI tree structure from the backend

  // *** ADD THIS LINE to expose the raw setState function ***
  // This allows components/callbacks to update the state using Immer's produce
  setState: set,
  // **********************************************************
  /**
   * Action to replace the entire UI tree, typically called on initial load.
   * @param {object} payload - The payload containing the new rootElement.
   */
  handleInitialState: (payload) => {
    console.log("useViewStore: Setting initial UI state");
    if (payload?.rootElement) {
      // Use the exposed setState or the 'set' function directly
      get().setState({ rootElement: payload.rootElement }, false, 'handleInitialState');
    } else {
      console.error("handleInitialState: Invalid payload received, clearing UI state.", payload);
      get().setState({ rootElement: null }, false, 'handleInitialState_error'); // Clear if payload is invalid
    }
  },

  /**
   * Action to update a specific primitive's content within the tree,
   * usually triggered by a 'primitive_content_update' message from the backend.
   * @param {object} updateData - Object containing targetId/targetBinding, content, updateType, etc.
   */
  handlePrimitiveUpdate: (updateData) => {

    // Use the exposed setState with Immer's produce for safe nested updates
    get().setState(produce((draft) => {
      const { targetId, targetBinding, content, updateType = 'replace', sectionId } = updateData;
      if (!draft.rootElement) {
         console.warn("handlePrimitiveUpdate: No rootElement to update.");
         return; // Exit Immer producer if no root element exists
      }
      if (!targetId && !targetBinding) {
          console.error("handlePrimitiveUpdate: Missing targetId or targetBinding.", updateData);
          return; // Exit Immer producer if target is missing
      }

      console.log(`handlePrimitiveUpdate: Searching for ${targetId ? `ID "${targetId}"` : `Binding "${targetBinding}"`} to ${updateType} content.`);

      let updated = false;

      // Recursive function to find and update the target primitive(s)
      const findAndUpdate = (node) => {
        // Optimization: If we found by ID, stop searching deeper in other branches
        if (updated && targetId) return true;

        let nodeMatches = false;
        if (targetId && node.id === targetId) {
          nodeMatches = true;
        } else if (targetBinding && node.updateBinding === targetBinding) {
          // Note: targetBinding might match multiple elements
          nodeMatches = true;
        }

        if (nodeMatches) {
          console.log(`Found match for ${node.id}. Updating content.`);
          // TODO: Implement section-specific updates if needed based on sectionId
          if (sectionId) {
              console.warn(`handlePrimitiveUpdate: sectionId "${sectionId}" received but not yet fully implemented for targeted content updates.`);
              // Placeholder: Update main content for now
          }

          // Apply update based on updateType
          if (updateType === 'append') {
              // <<< START MODIFICATION >>>
              // Check if the target element is meant for streaming text
              // Assuming the node object has a 'type' property
              const isTextStreamTarget = node.type === 'StreamingTextView'; // Check the type

              if (isTextStreamTarget) {
                  // Ensure existing content is treated as a string (even if null/undefined initially)
                  const existingContent = String(node.content || ''); // Ensure string
                  // Ensure incoming content is a string
                  const incomingChunk = String(content); // Ensure string
                  // Concatenate strings
                  node.content = existingContent + incomingChunk; // String concatenation
                  console.debug(`[handlePrimitiveUpdate] Appended string chunk to ${node.id}. New length: ${node.content.length}`);
              } else {
                  // --- Existing logic for appending to arrays (e.g., for logs) ---
                  if (Array.isArray(node.content)) {
                      node.content.push(content); // Append to existing array
                  } else if (node.content === null || node.content === undefined) {
                      node.content = [content]; // Start a new array
                  } else {
                      // Convert existing non-array content to an array and append
                      node.content = [node.content, content]; // Convert to array and append
                      console.warn(`handlePrimitiveUpdate: Appending to non-array content for ${node.id}. Content converted to array.`);
                  }
                  // --- End of existing array logic ---
              }
               // <<< END MODIFICATION >>>
          } else { // Default to 'replace'
            node.content = content; // Replace existing content
          }

          updated = true; // Mark that at least one update occurred
          if (targetId) return true; // Stop searching this branch if unique ID found
          return false; // Continue search if using targetBinding (might match others)
        }

        // Recursively search children if this node doesn't match
        if (node.children) {
          for (const child of node.children) {
            if (findAndUpdate(child)) {
                // If the recursive call returns true (meaning ID match found deeper), propagate upwards
                if (targetId) return true; //
            }
          }
        }
        // Target not found in this node or its children
        return false;
      };

      // Start the search from the root
      findAndUpdate(draft.rootElement); //

      // Log if no matching element was found
      if (!updated) {
          console.warn(`handlePrimitiveUpdate: No element found matching ${targetId ? `ID "${targetId}"` : `Binding "${targetBinding}"`}`);
      }
    }), false, 'handlePrimitiveUpdate'); // Add action name for debugging

  }, // End handlePrimitiveUpdate


  /**
   * Action to reset the UI state, clearing the root element.
   */
  resetRootElement: () => {
    console.log("useViewStore: Resetting rootElement.");
    // Use the exposed setState or the 'set' function directly
    get().setState({ rootElement: null }, false, 'resetRootElement');
  },

  // --- Selectors ---
  /**
   * Selector to get the current root element of the UI tree.
   * @returns {object|null} The root element object or null.
   */
  getRootElement: () => get().rootElement,

}));