// src/components/primitives/TextView.jsx
import React from 'react';

function TextView({ id, config = {}, content, gridArea }) {
  const {
    initialText = '',
    // Presentation styles controlled by config (as TextView is highly configurable)
    fontSize = 'inherit',
    fontWeight = 'normal',
    textAlign = 'left',
    color,
    padding = '0',
    margin = '0',
    backgroundColor,
    borderRadius,
    whiteSpace: configWhiteSpace = 'pre-wrap', // Default from component
    // Layout styles
    width,
    height,
    // Debugging option
    debugJsonIndent = 2,
  } = config;

  let textToDisplay;
  let isJson = false;

  if (content !== null && content !== undefined) {
    if (typeof content === 'object') {
      isJson = true;
      try {
        textToDisplay = JSON.stringify(content, null, debugJsonIndent);
      } catch (e) {
        textToDisplay = '[Error stringifying object]';
        console.error(`TextView (${id}): Error stringifying content object:`, e, content);
      }
    } else {
      textToDisplay = String(content);
    }
  } else {
    textToDisplay = initialText;
  }

  // Determine the final whiteSpace style based on content type and config
  const finalWhiteSpace = isJson ? 'pre-wrap' : configWhiteSpace;

  // Construct the style object inline FROM CONFIG
  // TextView is intended to be styled primarily via config props
  const style = {
    gridArea: gridArea || undefined,
    width: width || undefined,
    height: height || undefined,
    fontSize: fontSize,
    fontWeight: fontWeight,
    textAlign: textAlign,
    color: color || undefined, // Use undefined to allow CSS inheritance
    padding: padding,
    margin: margin,
    backgroundColor: backgroundColor || undefined, // Use undefined for transparency
    borderRadius: borderRadius || undefined,
    whiteSpace: finalWhiteSpace,
    wordBreak: 'break-word', // Good default
    boxSizing: 'border-box',
    fontFamily: isJson ? 'var(--font-family-monospace)' : 'inherit', // Use CSS var
  };

  // Render as 'pre' if it was JSON, otherwise 'div'
  // Apply base primitive class
  const Tag = isJson ? 'pre' : 'div';

  return (
    <Tag id={id} style={style} className="primitive-textview">
      {textToDisplay}
    </Tag>
  );
}

export default React.memo(TextView);