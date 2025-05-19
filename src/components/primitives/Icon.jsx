// src/components/primitives/Icon.jsx
import React from 'react';

function Icon({ id, config = {}, gridArea }) {
  const {
    // Icon source/name (you'll need a system to map this to actual SVGs)
    iconName, // e.g., 'user', 'settings', 'close'
    // Presentation properties
    size = 'var(--icon-size-md, 1.5em)', // Default size with CSS var fallback
    color = 'currentColor', // Inherits text color by default
    title, // For accessibility
    // Allow merging arbitrary styles from config
    style: configStyle = {},
    // Layout/Sizing (less common for icons directly, but possible)
    width,
    height,
    margin,
  } = config;

  // Placeholder for actual SVG content -
  // In a real app, you'd have an SVG sprite, a library, or dynamic imports
  const getSvgPath = (name) => {
    switch (name) {
      case 'close':
        return <path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" />;
      case 'user':
        return <path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z" />;
      default:
        return <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" strokeWidth="2" />; // Default placeholder
    }
  };

  const finalStyle = {
    display: 'inline-flex', // Icons are typically inline
    alignItems: 'center',
    justifyContent: 'center',
    width: width || size,
    height: height || size,
    color: color,
    gridArea: gridArea || undefined,
    margin: margin || undefined,
    boxSizing: 'border-box',
    ...configStyle,
  };

  return (
    <svg
      id={id}
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24" // Common viewBox, adjust if needed
      style={finalStyle}
      className="primitive-icon"
      aria-hidden={title ? undefined : 'true'} // Hide from screen readers if no title
      focusable="false" // Prevent from being focusable by default
    >
      {title && <title>{title}</title>}
      {getSvgPath(iconName)}
    </svg>
  );
}

export default React.memo(Icon);