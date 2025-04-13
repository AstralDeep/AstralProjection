// src/components/DynamicRenderer.jsx
import React, { useCallback } from 'react';
import { produce } from 'immer'; // For safe state updates
import { useViewStore } from '../stores/useViewStore.jsx'; // To access view state and setState
// *** IMPORT useToolSchemaStore ***
import { useToolSchemaStore } from '../stores/useToolSchemaStore.jsx'; // To get action schemas
import { idGenerator } from '../utils/idGenerator'; // For unique message keys

// Primitive Components
import StackLayout from './primitives/StackLayout.jsx';
import TextView from './primitives/TextView.jsx';
import LogView from './primitives/LogView.jsx';
import InputField from './primitives/InputField.jsx';
import Button from './primitives/Button.jsx';
import ChatViewBasic from './primitives/ChatViewBasic.jsx';
import McpStructuredLogView from './primitives/McpStructuredLogView.jsx';
import StreamingTextView from './primitives/StreamingTextView.jsx';

// Map backend type strings to frontend component implementations
const primitiveMap = { StackLayout, TextView, LogView, InputField, Button, ChatViewBasic, McpStructuredLogView, StreamingTextView };

// Fallback component for rendering unknown primitive types
const UnknownPrimitive = ({ id, type, gridArea }) => (
  <div style={{
      border: '2px dashed red',
      backgroundColor: 'rgba(255, 0, 0, 0.05)',
      padding: '10px',
      margin: '5px',
      gridArea: gridArea || undefined,
      color: 'red',
      fontSize: '0.9em',
      fontFamily: 'monospace'
  }}>
    <strong>Unknown Primitive Type:</strong> "{type}"<br />
    <strong>ID:</strong> {id}
  </div>
);


// --- Helper Functions ---
// Helper function to find primitive by ID
const findPrimitiveById = (node, targetId) => {
  if (!node || !targetId) return null;
  if (node.id === targetId) return node;
  if (node.children && Array.isArray(node.children)) {
    for (const child of node.children) {
      const found = findPrimitiveById(child, targetId);
      if (found) return found;
    }
  }
  return null;
};

// Helper function to find primitive by updateBinding
const findPrimitiveByBinding = (node, targetBinding) => {
  if (!node || !targetBinding) return null;
  if (node.updateBinding === targetBinding) return node;
  if (node.children && Array.isArray(node.children)) {
    for (const child of node.children) {
      const found = findPrimitiveByBinding(child, targetBinding);
      if (found) return found;
    }
  }
  return null;
};
// --- End Helper Functions ---


function DynamicRenderer({ primitive, sendAction }) {
  // --- Hooks ---
  const getRootElement = useViewStore((state) => state.getRootElement);
  const setViewStoreState = useViewStore((state) => state.setState);
  // No need to get getSchema here, we'll use getState inside useCallback

  // --- Callbacks ---

  const handleValueChange = useCallback((changedElementId, newValue) => {
    setViewStoreState(produce((draft) => {
      if (!draft.rootElement) return;
      const elementToUpdate = findPrimitiveById(draft.rootElement, changedElementId);
      if (elementToUpdate) {
        console.log(`%c[DEBUG] handleValueChange: Updating element "${changedElementId}" in DRAFT state to:`, 'color: green;', JSON.stringify(newValue));
        elementToUpdate.content = newValue;
      } else {
         console.warn(`handleValueChange: Could not find element ${changedElementId} in state tree to update content.`);
      }
    }), false, `handleValueChange_${changedElementId}`);
  }, [setViewStoreState]);


  const handleAction = useCallback((triggeredActionId, sourceElementId) => {
      console.log(`DynamicRenderer: handleAction triggered by "${sourceElementId}" for actionId="${triggeredActionId}"`);

      if (!sendAction) {
         console.warn(`DynamicRenderer: sendAction function not provided for element ${sourceElementId}. Cannot send message.`);
         return;
      }

      // Get current state
      console.log(`%c[DEBUG] handleAction: Reading rootElement state from store...`, 'color: blue;');
      const rootElement = getRootElement();
      if (!rootElement) {
           console.error("DynamicRenderer handleAction: Cannot find rootElement state!");
           return;
      }
      console.log(`%c[DEBUG] handleAction: rootElement state read successfully.`, 'color: blue;');

      const triggeringPrimitive = findPrimitiveById(rootElement, sourceElementId);
      if (!triggeringPrimitive) {
          console.error(`DynamicRenderer handleAction: Could not find triggering primitive with ID: ${sourceElementId}`);
          return;
      }

      // --- Read Values Needed for Backend Payload ---
      let valuesForBackend = {};
      const valueSourceElementIds = triggeringPrimitive?.config?.valueSourceElementIds || [];
      console.log(`%c[DEBUG] handleAction: Reading values from valueSourceElementIds:`, 'color: blue;', valueSourceElementIds);

      valueSourceElementIds.forEach(id => {
          const sourcePrimitive = findPrimitiveById(rootElement, id);
          const contentRead = sourcePrimitive?.content;
          console.log(`%c[DEBUG] handleAction: Trying to read value source. Found primitive for ID '${id}':`, 'color: blue;', sourcePrimitive ? 'Yes' : 'No');
          if (sourcePrimitive) {
              console.log(`%c[DEBUG] handleAction: Content read from "${id}":`, 'color: blue;', JSON.stringify(contentRead));
          }
          valuesForBackend[id] = contentRead ?? '';
      });

      // Determine the primary input value (assuming first source ID)
      const primaryInputValueForBackend = valuesForBackend[valueSourceElementIds[0]] ?? '';
      console.log(`%c[DEBUG] handleAction: Value assigned to primaryInputValueForBackend (before frontend actions):`, 'color: blue; font-weight: bold;', JSON.stringify(primaryInputValueForBackend));


      // --- START MODIFIED INPUT REQUIREMENT CHECK ---

      // 1. Determine if the current action requires input
      //    Access the schema store state directly inside the callback
      const toolSchemaStoreState = useToolSchemaStore.getState();
      const actionSchema = toolSchemaStoreState.toolSchemas?.[triggeredActionId]; // Get schema for this action

      // Helper function to check if input is required based on schema
      // TODO: Implement more robust schema checking (e.g., check schema.inputSchema.required array or properties)
      const doesActionRequireInput = (schema) => {
          // Example logic: Check if the schema exists and has properties defined in inputSchema
          // A simple check: does inputSchema.properties exist and have any keys?
          const inputProperties = schema?.inputSchema?.properties;
          const hasInputProperties = inputProperties && Object.keys(inputProperties).length > 0;

          // You might need more specific checks, e.g., if a 'query' or 'uri' property exists.
          // For now, let's use the example logic + check for properties as a basic indicator.
          if (triggeredActionId === 'trigger_resource_update') { // Known action requiring input
              return true;
          }
          // If other actions require input, add checks here or rely on schema properties check
          if (hasInputProperties) {
              console.log(`[DEBUG] Action ${triggeredActionId} schema has input properties, assuming input might be required.`);
              // This is a basic assumption, refine based on actual schema structure (e.g., 'required' field)
              // return true; // Uncomment this line for a more general check based on properties existing
          }

          return false; // Default: assume no input required if not explicitly known or schema has no input props
      };

      const requiresInput = doesActionRequireInput(actionSchema);
      console.log(`%c[DEBUG] handleAction: Action "${triggeredActionId}" requires input (based on current logic): ${requiresInput}`, 'color: brown;');

      // 2. Perform the conditional check
      let shouldSendAction = true; // Default to sending
      const primaryValueTrimmed = String(primaryInputValueForBackend).trim();

      if (requiresInput && primaryValueTrimmed === '') {
          // ONLY skip if input IS required AND it IS empty
          console.log(`%c[DEBUG] handleAction: Action "${triggeredActionId}" requires input, but value is empty. Skipping backend action.`, 'color: red; font-weight: bold;');
          shouldSendAction = false;
      } else {
          // Proceed if input is not required, OR if it is required and provided
           console.log(`%c[DEBUG] handleAction: Conditions met to send action "${triggeredActionId}". RequiresInput: ${requiresInput}, ValueProvidedOrNotRequired: ${primaryValueTrimmed !== '' || !requiresInput}`, 'color: green;');
      }

      // --- END MODIFIED INPUT REQUIREMENT CHECK ---


      // --- Process Frontend Actions (if any) ---
      // (Keeping existing frontend action logic - clearElement, echoToView)
      // Note: Frontend actions run regardless of whether backend action is skipped
      const frontendActions = triggeringPrimitive?.config?.frontendActions;
      // let skipBackendAction = false; // This flag is now effectively replaced by !shouldSendAction
      if (Array.isArray(frontendActions) && frontendActions.length > 0) {
          console.log(`DynamicRenderer: Processing ${frontendActions.length} configured frontend actions for ${sourceElementId}`);
          setViewStoreState(produce((draft) => {
             if (!draft.rootElement) return;
              for (const action of frontendActions) {
                   // ... (keep existing switch statement for clearElement, echoToView) ...
                   // --- Start of existing switch ---
                   switch (action.type) {
                      case 'clearElement': {
                          const targetId = action.targetElementId;
                          if (!targetId) {
                              console.warn("Frontend Action 'clearElement': Missing targetElementId", action);
                              continue;
                          }
                          const elementToClear = findPrimitiveById(draft.rootElement, targetId);
                          if (elementToClear) {
                              elementToClear.content = '';
                              console.log(`Frontend Action 'clearElement': Cleared ${targetId}`);
                          } else {
                              console.warn(`Frontend Action 'clearElement': Target ${targetId} not found.`);
                          }
                          break;
                      }
                      case 'echoToView': {
                          const sourceId = action.sourceElementId;
                          const targetBinding = action.targetBinding;
                          const role = action.role || 'user';
                          if (!sourceId || !targetBinding) {
                              console.warn("Frontend Action 'echoToView': Missing sourceElementId or targetBinding", action);
                              continue;
                          }
                          const textToEcho = valuesForBackend[sourceId];
                          // *** IMPORTANT: Check if echo should skip backend send ***
                          // If echo source is empty, it might imply the primary action should also be skipped
                          // We set shouldSendAction = false here if echo source is empty AND the action required input
                          if (textToEcho === undefined || textToEcho === null || String(textToEcho).trim() === '') {
                              console.log(`Frontend Action 'echoToView': Source ${sourceId} is empty, skipping echo.`);
                              if(requiresInput) {
                                  // If input was required, and the value echoed (which is the primary value) is empty,
                                  // ensure we don't send the backend action later.
                                  console.log(`Frontend Action 'echoToView': Also preventing backend action send because required input is empty.`);
                                  shouldSendAction = false;
                              }
                              continue; // Skip the echo itself
                          }
                          const targetView = findPrimitiveByBinding(draft.rootElement, targetBinding);
                          if (targetView) {
                              const message = {
                                  role: role,
                                  text: String(textToEcho),
                                  uniqueId: idGenerator.generateKey(`msg-${targetView.id}-${role}-`)
                              };
                              if (!Array.isArray(targetView.content)) {
                                  console.warn(`Frontend Action 'echoToView': Target view ${targetBinding} content was not an array. Initializing.`);
                                  targetView.content = [];
                              }
                              targetView.content.push(message);
                              console.log(`Frontend Action 'echoToView': Echoed from ${sourceId} to ${targetBinding}`);
                          } else {
                              console.warn(`Frontend Action 'echoToView': Target view ${targetBinding} not found.`);
                          }
                          break;
                      }
                      default:
                          console.warn(`DynamicRenderer: Unknown frontendAction type: ${action.type}`);
                  }
                   // --- End of existing switch ---
              }
          }), false, `handleAction_FrontendActions_${triggeredActionId}`);
      }
      // --- END Process Frontend Actions ---


      // --- Conditionally Send Backend Action ---
      if (shouldSendAction) {
          // Prepare Payload
          let finalActionPayload = {};
          let primaryInputKey = 'query'; // Default key

          // Attempt to find the primary input key from the schema
          if (actionSchema?.inputSchema?.properties) {
              const schemaKeys = Object.keys(actionSchema.inputSchema.properties);
              if (schemaKeys.length > 0) {
                  primaryInputKey = schemaKeys[0];
                  console.log(`DynamicRenderer: Determined primary input key from schema for "${triggeredActionId}": "${primaryInputKey}"`);
              }
          }

          // Specific override for trigger_resource_update
          if (triggeredActionId === 'trigger_resource_update') {
              primaryInputKey = 'uri';
              console.log(`DynamicRenderer: Overriding input key to "${primaryInputKey}" for action "${triggeredActionId}"`);
          }

          // Assign the value using the determined key *if input was required*.
          // For actions not requiring input, send empty args or adjust as needed.
          // Current logic sends the primaryInputValue even if empty/not required.
          // Consider sending {} if !requiresInput, depending on backend needs.
          if (requiresInput) {
             finalActionPayload[primaryInputKey] = primaryInputValueForBackend;
          } else {
             // How to handle actions that don't require input?
             // Option 1: Send empty arguments object
             // finalActionPayload = {};
             // Option 2: Send the primary key with empty value (current behavior implicitly)
             finalActionPayload[primaryInputKey] = primaryInputValueForBackend; // Keep this for now, might need adjustment
             console.log(`DynamicRenderer: Action "${triggeredActionId}" does not require input, sending potentially empty/default payload.`);
          }

          console.log(`DynamicRenderer: Constructed finalActionPayload for "${triggeredActionId}":`, finalActionPayload);

          // Construct the final message
          const message = {
            type: 'ui_action',
            payload: {
              actionId: triggeredActionId,
              sourceElementId: sourceElementId,
              arguments: finalActionPayload
            }
          };
          console.log("DynamicRenderer: Constructing and sending final message:", message);
          sendAction(message); // Send the message via the passed prop

      } else {
          // Log why it was skipped (already logged inside the conditional check)
          // console.log(`DynamicRenderer: Backend action for "${triggeredActionId}" was skipped.`);
      }
      // --- END Send Backend Action ---

  }, [sendAction, getRootElement, setViewStoreState]); // Added setViewStoreState dependency


  // --- Validate Primitive ---
  const { id, type, config = {}, children, content, actionId, gridArea } = primitive;
  if (!type || !id) {
    console.error("DynamicRenderer: Invalid primitive data received (missing type or id):", primitive);
    return <div style={{color: 'red', border: '1px solid red', padding: '5px'}}>Error: Invalid primitive data (missing type or id)</div>;
  }
  const PrimitiveComponent = primitiveMap[type] || UnknownPrimitive;

   // --- Prepare Props ---
  const commonProps = {
      id, config, content, gridArea,
      ...( (type === 'InputField' || type === 'Button') ? { actionId, onAction: handleAction } : {} ),
      ...( (type === 'InputField') ? { onValueChange: handleValueChange } : {} ),
      ...( (type === 'StackLayout') ? { children, sendAction } : {} ),
  };
  if (PrimitiveComponent === UnknownPrimitive) {
      commonProps.type = type;
  }

  // Render the mapped primitive component with its props
  return <PrimitiveComponent {...commonProps} />;
}

export default React.memo(DynamicRenderer);
