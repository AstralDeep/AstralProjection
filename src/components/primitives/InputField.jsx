// src/components/primitives/InputField.jsx
import React, { useState, useEffect, useCallback } from 'react';

function InputField({ id, config = {}, onAction, gridArea, content, onValueChange }) {
  const {
    label,
    placeholder = '',
    multiline = false,
    rows = 3,
    initialValue = '',
    inputType = 'text',
    disabled = false,
    enterKeyAction = {},
    // Presentation styles (padding, border, background) should come from CSS class
    // Layout/Sizing styles from config
    margin,
    width,
  } = config;

  const {
      isEnabled: enterEnabled = false,
      actionId: enterActionId,
      targetElementId: enterTargetId
  } = enterKeyAction;

  const [value, setValue] = useState(
    content !== null && content !== undefined ? String(content) : initialValue
  );

  // Effect to update internal state if the 'content' prop changes externally
 useEffect(() => {
  const externalContentStr = content !== null && content !== undefined ? String(content) : '';
  setValue(currentInternalValue => {
    if (externalContentStr !== currentInternalValue) {
      return externalContentStr;
    }
    return currentInternalValue;
  });
}, [content]); // Only depends on the external prop 'content'


  // Handle changes to the input field
  const handleChange = useCallback((event) => {
    const newValue = event.target.value;
    setValue(newValue);
    if (onValueChange) {
      onValueChange(id, newValue);
    }
  }, [id, onValueChange]);


  // Handle key down events, specifically for Enter key based on config
  const handleKeyDown = useCallback((event) => {
    // Check for Enter key, single-line input, AND if the enterKeyAction is configured and enabled
    if (event.key === 'Enter' && !multiline && enterEnabled && enterActionId && enterTargetId) {
        event.preventDefault();
        console.log(`InputField ${id}: Enter key configured. Triggering action ('${enterActionId}') for target element '${enterTargetId}'`);

        if (onAction) {
            // Call onAction with the configured actionId and targetElementId from enterKeyAction
            onAction(enterActionId, enterTargetId);
        }
        // NOTE: Clearing the input field after Enter is handled by the BACKEND sending a
        // primitive_content_update message after successfully processing the action.
    }

  }, [multiline, enterEnabled, enterActionId, enterTargetId, onAction, id]);


  // Determine the component type (input or textarea)
  const InputComponent = multiline ? 'textarea' : 'input';
  const finalInputType = multiline ? undefined : inputType;

  // Styles for the container (layout)
   const containerStyle = {
      display: 'flex',
      flexDirection: 'column',
      gap: 'var(--spacing-xs)', // Use CSS var
      gridArea: gridArea || undefined,
      width: width || '100%', // Default or from config
      margin: margin || undefined, // Margin from config
      boxSizing: 'border-box',
  };

  // Props for the input/textarea element itself
  const inputProps = {
      id: `input-${id}`,
      className: "form-control", // Apply the generic form control class from index.css
      // Inline style removed - presentation handled by .form-control
      type: finalInputType,
      value: value,
      placeholder: placeholder,
      onChange: handleChange,
      onKeyDown: handleKeyDown,
      disabled: disabled,
      'aria-label': label || placeholder,
      ...(multiline && { rows: rows }) // Add rows only for textarea
  };

  // Render the component
  return (
    <div id={id} style={containerStyle} className="primitive-inputfield">
      {label && <label htmlFor={`input-${id}`}>{label}</label>}
      <InputComponent {...inputProps} />
    </div>
  );
}

export default React.memo(InputField);