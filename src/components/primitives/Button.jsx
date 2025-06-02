// src/components/primitives/Button.jsx
import React from 'react';

function Button({ id, config = {}, actionId, onAction, gridArea }) {
  const {
    label = 'Submit',
    variant = 'default', // Maps to btn-primary, btn-success etc.
    disabled = false,
    title,
    // Presentation styles (like padding, color, etc.) should come from CSS classes
    // Keep layout/sizing styles from config
    margin = "8px 0 0 0",
    width,
    // height // Height usually determined by padding + content
  } = config;


  const handleClick = (event) => {
    event.preventDefault();
    if (onAction && actionId && !disabled) {
       console.log(`Button ${id}: Triggering action "${actionId}"`);
       onAction(actionId, id);
    }
  };

  // Map variant string to appropriate CSS classes
  const getVariantClass = () => {
      switch(variant) {
          case 'primary': return 'btn-primary';
          case 'success': return 'btn-success';
          case 'danger': return 'btn-danger';
          case 'secondary': return 'btn-secondary';
          default: return ''; // Uses default .btn styles
      }
  }

  // Apply layout styles inline from config
  const style = {
      gridArea: gridArea || undefined,
      margin: margin || undefined,
      width: width || undefined,
      // Avoid setting presentation styles like padding, background, color here
  };

  return (
    <button
      type="button"
      id={id}
      onClick={handleClick}
      disabled={disabled}
      // Apply base class, variant class, and primitive-specific class
      className={`btn ${getVariantClass()} primitive-button`}
      style={style}
      title={title || label}
      aria-label={label}
    >
      {label}
    </button>
  );
}
export default React.memo(Button);