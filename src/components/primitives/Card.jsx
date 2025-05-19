// src/components/primitives/Card.jsx
import React from 'react';
import DynamicRenderer from '../DynamicRenderer.jsx'; // Assuming path from StackLayout

function Card({ id, config = {}, children: childElements, gridArea, sendAction }) {
  const {
    // Presentation properties
    padding = 'var(--spacing-md, 1em)',
    margin,
    border = '1px solid var(--color-border, #ccc)',
    borderRadius = 'var(--border-radius-md, 4px)',
    backgroundColor = 'var(--color-background-card, white)',
    boxShadow = 'var(--shadow-sm, 0 1px 3px rgba(0,0,0,0.1))',
    // Layout/Sizing
    width,
    height,
    // Allow merging arbitrary styles from config
    style: configStyle = {},
  } = config;

  const finalStyle = {
    padding: padding,
    margin: margin || undefined,
    border: border,
    borderRadius: borderRadius,
    backgroundColor: backgroundColor,
    boxShadow: boxShadow,
    width: width || undefined,
    height: height || undefined,
    gridArea: gridArea || undefined,
    boxSizing: 'border-box',
    overflow: 'hidden', // Often good for cards to contain their content
    ...configStyle,
  };

  // If childElements are passed (as they are to StackLayout from DynamicRenderer)
  // then Card is responsible for rendering them using DynamicRenderer.
  // The 'children' prop is an array of primitive configurations.
  const hasChildrenToRender = childElements && Array.isArray(childElements) && childElements.length > 0;

  return (
    <div id={id} style={finalStyle} className="primitive-card">
      {hasChildrenToRender && childElements.map(childPrimitive => (
        <DynamicRenderer
          key={childPrimitive.id}
          primitive={childPrimitive}
          sendAction={sendAction} // Pass down the original sendAction
        />
      ))}
    </div>
  );
}

export default React.memo(Card);