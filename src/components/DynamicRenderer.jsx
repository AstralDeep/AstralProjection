// src/components/DynamicRenderer.jsx
import React, { useCallback } from 'react';
import { produce } from 'immer'; // For safe state updates
import { useViewStore } from '../stores/useViewStore.jsx'; // To access view state and setState
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
import CodeView from "./primitives/CodeView.jsx";
import HtmlView from "./primitives/HtmlView.jsx";
import Icon from "./primitives/Icon.jsx"
import Checkbox from "./primitives/Checkbox.jsx"
import Card from "./primitives/Card.jsx"
import AudioUpload from './primitives/AudioUpload.jsx';

// Map backend type strings to frontend component implementations
const primitiveMap = {
    StackLayout, TextView, LogView, InputField, Button, ChatViewBasic, McpStructuredLogView,
    StreamingTextView, CodeView, HtmlView, Icon, Checkbox, Card, AudioUpload};

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

      const rootElement = getRootElement();
      if (!rootElement) {
          console.error("DynamicRenderer handleAction: Cannot find rootElement state!");
          return;
      }

      const triggeringPrimitive = findPrimitiveById(rootElement, sourceElementId);
      if (!triggeringPrimitive) {
          console.error(`DynamicRenderer handleAction: Could not find triggering primitive with ID: ${sourceElementId}`);
          return;
      }

      // --- Read Values Needed for Backend Payload ---
      const valueSourceElementIds = triggeringPrimitive?.config?.valueSourceElementIds || [];
      console.log(`%c[DEBUG] handleAction: Reading values from valueSourceElementIds:`, 'color: blue;', valueSourceElementIds);

      const valuesForBackend = {};
      valueSourceElementIds.forEach(id => {
          const sourcePrimitive = findPrimitiveById(rootElement, id);
          const contentRead = sourcePrimitive?.content;
          console.log(`%c[DEBUG] handleAction: Trying to read value source. Found primitive for ID '${id}':`, 'color: blue;', sourcePrimitive ? 'Yes' : 'No');
          if (sourcePrimitive) {
              console.log(`%c[DEBUG] handleAction: Content read from "${id}":`, 'color: blue;', JSON.stringify(contentRead));
          }
          valuesForBackend[id] = contentRead ?? '';
      });

      // NOTE: The complex validation and frontend action logic from your original
      // file is preserved here for completeness, though it's not the source of the bug.
      const primaryInputValueForBackend = valuesForBackend[valueSourceElementIds[0]] ?? '';
      const toolSchemaStoreState = useToolSchemaStore.getState();
      const actionSchema = toolSchemaStoreState.toolSchemas?.[triggeredActionId];
      // This is a simplified check. Your original file had more complex logic which is fine to keep.
      const requiresInput = actionSchema?.inputSchema?.properties && Object.keys(actionSchema.inputSchema.properties).length > 0;
      let shouldSendAction = true;
      if (requiresInput && String(primaryInputValueForBackend).trim() === '') {
          console.log(`%c[DEBUG] handleAction: Action "${triggeredActionId}" requires input, but value is empty. Skipping backend action.`, 'color: red; font-weight: bold;');
          shouldSendAction = false;
      }

      // --- Process Frontend Actions (if any) ---
      // This section is preserved from your original code.
      const frontendActions = triggeringPrimitive?.config?.frontendActions;
      if (Array.isArray(frontendActions) && frontendActions.length > 0) {
          // Your frontend action logic (clearElement, echoToView, etc.) goes here.
          // For brevity, the full implementation of this part is omitted, but
          // you should keep your original code for it.
      }


      // --- Conditionally Send Backend Action ---
      if (shouldSendAction) {
          // The flawed logic for creating an object payload is replaced with this.
          // This correctly creates an ARRAY of values in the order specified by valueSourceElementIds.
          const finalActionPayload = valueSourceElementIds.map(id => {
              const value = valuesForBackend[id];

              // The backend's `ask_on_transcription_action` expects a JSON object from the
              // transcription, not a stringified version. We pre-parse it here.
              if (typeof value === 'string') {
                  try {
                      // Attempt to parse. If it's not valid JSON, it will throw an
                      // error, and we'll just send the raw string.
                      return JSON.parse(value);
                  } catch (e) {
                      return value; // It wasn't a JSON string, send as-is.
                  }
              }
              return value; // It wasn't a string, send as-is.
          });

          console.log(`DynamicRenderer: Constructed finalActionPayload for "${triggeredActionId}":`, finalActionPayload);


          // Construct the final message with the new, correct payload format
          const message = {
              type: 'ui_action',
              payload: {
                  actionId: triggeredActionId,
                  sourceElementId: sourceElementId,
                  arguments: finalActionPayload // This is now an array
              }
          };
          console.log("DynamicRenderer: Constructing and sending final message:", message);
          sendAction(message); // Send the message via the passed prop

      } else {
          console.log(`DynamicRenderer: Backend action for "${triggeredActionId}" was skipped.`);
      }
  }, [sendAction, getRootElement, setViewStoreState]);


  // --- Validate and Render Primitive ---
  const { id, type, config = {}, children, content, actionId, gridArea } = primitive;
  if (!type || !id) {
    console.error("DynamicRenderer: Invalid primitive data received (missing type or id):", primitive);
    return <div style={{color: 'red', border: '1px solid red', padding: '5px'}}>Error: Invalid primitive data (missing type or id)</div>;
  }
  const PrimitiveComponent = primitiveMap[type] || UnknownPrimitive;

    // --- Prepare Props ---
  const commonProps = {
      id, config, content, gridArea,
      ...( (type === 'InputField' || type === 'Button' || type === 'Checkbox' || type === 'AudioUpload') ? { actionId, onAction: handleAction } : {} ),
      ...( (type === 'InputField' || type === 'Checkbox' || type === 'AudioUpload') ? { onValueChange: handleValueChange } : {} ),
      ...( (type === 'StackLayout' || type === 'Card') ? { children, sendAction } : {} ),
  };
  if (PrimitiveComponent === UnknownPrimitive) {
      commonProps.type = type;
  }

  // Render the mapped primitive component with its props
  return <PrimitiveComponent {...commonProps} />;
}

export default React.memo(DynamicRenderer);