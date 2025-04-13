// src/components/primitives/StackLayout.jsx
import React from 'react';
import DynamicRenderer from '../DynamicRenderer.jsx'; // Adjust path if necessary

function StackLayout({ id, config = {}, children: childElements, gridArea, sendAction }) {
  const {
    // Layout properties controlled by config
    direction = 'vertical',
    gap = 'var(--spacing-sm)', // Use CSS var default
    padding = '0px',
    alignItems = 'stretch',
    justifyContent = 'flex-start',
    wrap = 'nowrap',
    // Presentation properties controlled by config or CSS class
    border,
    backgroundColor,
    borderRadius,
    // Allow merging arbitrary styles from config
    style: configStyle = {},
    // Layout/Sizing
    width,
    height,
    margin,
  } = config;

  // Base style object (Layout focused)
  const baseStyle = {
    display: 'flex',
    flexDirection: direction === 'horizontal' ? 'row' : 'column',
    flexWrap: wrap,
    gap: gap,
    padding: padding,
    alignItems: alignItems,
    justifyContent: justifyContent,
    // Layout/Sizing from config
    gridArea: gridArea || undefined,
    width: width || undefined,
    height: height || undefined,
    margin: margin || undefined,
    // Presentation from config (overrides CSS class)
    border: typeof border === 'string' ? border : (border ? '1px solid var(--color-border)' : undefined),
    backgroundColor: backgroundColor || undefined,
    borderRadius: borderRadius || undefined,
    boxSizing: 'border-box',
  };

  // Combine baseStyle with styles from config.style
  const finalStyle = {
    ...baseStyle,
    ...configStyle, // config.style overrides baseStyle properties
  };

  return (
    // Apply base class and combined style
    <div id={id} style={finalStyle} className="primitive-stacklayout">
      {childElements && childElements.length > 0 && (
        childElements.map(childPrimitive => (
          <DynamicRenderer
            key={childPrimitive.id}
            primitive={childPrimitive}
            sendAction={sendAction} // Pass down sendAction
          />
        ))
      )}
    </div>
  );
}
export default React.memo(StackLayout);