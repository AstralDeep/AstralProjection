// src/components/primitives/Checkbox.jsx
import React, { useState, useEffect, useCallback } from 'react';

function Checkbox({ id, config = {}, content, actionId, onAction, onValueChange, gridArea }) {
  const {
    label = '',
    initialChecked = false, // Changed from 'checked' to avoid conflict with HTML attribute
    disabled = false,
    // Config for action
    actionId: configActionId, // Action to trigger (can also come from direct prop)
    // Styling from config
    style: configStyle = {},
    labelStyle: configLabelStyle = {},
    checkboxStyle: configCheckboxStyle = {},
    margin,
  } = config;

  // The `content` prop from DynamicRenderer can be used to control the checked state externally
  // If `content` is explicitly passed and is a boolean, it overrides internal state.
  const isControlled = typeof content === 'boolean';
  const [internalChecked, setInternalChecked] = useState(initialChecked);

  const currentChecked = isControlled ? content : internalChecked;

  // Update internal state if initialChecked prop changes (and not controlled)
  useEffect(() => {
    if (!isControlled) {
      setInternalChecked(Boolean(initialChecked));
    }
  }, [initialChecked, isControlled]);

  // Update internal state if content prop changes (and not controlled by content directly yet)
  // This allows the store to update the checkbox's initial displayed state via `content`
  useEffect(() => {
    if (typeof content === 'boolean' && !isControlled) {
        // This logic might be tricky. If `content` is meant to *set* the initial state
        // and then the component becomes uncontrolled, this is one way.
        // If `content` *always* means control, then `isControlled` check above handles it.
        setInternalChecked(content);
    } else if (typeof content === 'undefined' && !isControlled) {
        // If content becomes undefined, fall back to initialChecked config
        setInternalChecked(Boolean(initialChecked));
    }
  }, [content, initialChecked, isControlled]);


  const handleChange = useCallback((event) => {
    if (disabled) return;

    const newCheckedState = event.target.checked;

    if (!isControlled) {
      setInternalChecked(newCheckedState);
    }

    // Notify DynamicRenderer/ViewStore about the value change (updates `content` field)
    if (onValueChange) {
      onValueChange(id, newCheckedState);
    }

    // Trigger an action if configured
    const finalActionId = configActionId || actionId; // Prefer config.actionId
    if (finalActionId && onAction) {
      // `onAction` is `handleAction` from DynamicRenderer
      // It expects (triggeredActionId, sourceElementId)
      onAction(finalActionId, id);
    }
  }, [disabled, isControlled, onValueChange, id, configActionId, actionId, onAction]);

  const finalContainerStyle = {
    display: 'flex',
    alignItems: 'center',
    gap: 'var(--spacing-xs, 0.5em)',
    margin: margin || undefined,
    gridArea: gridArea || undefined,
    cursor: disabled ? 'not-allowed' : 'pointer',
    opacity: disabled ? 0.6 : 1,
    ...configStyle,
  };

  const finalCheckboxStyle = {
    accentColor: 'var(--color-primary)', // Easy way to theme the checkbox color
    margin: 0, // Reset default margin
    width: 'var(--checkbox-size, 1em)',
    height: 'var(--checkbox-size, 1em)',
    ...configCheckboxStyle,
  };

  const finalLabelStyle = {
    userSelect: 'none', // Prevent text selection on click
    ...configLabelStyle,
  };

  return (
    <label id={`${id}-label`} style={finalContainerStyle} className="primitive-checkbox-container">
      <input
        type="checkbox"
        id={id}
        checked={currentChecked}
        disabled={disabled}
        onChange={handleChange}
        style={finalCheckboxStyle}
        className="primitive-checkbox-input"
      />
      {label && <span style={finalLabelStyle} className="primitive-checkbox-label">{label}</span>}
    </label>
  );
}

export default React.memo(Checkbox);