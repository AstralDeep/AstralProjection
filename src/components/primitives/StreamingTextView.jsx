// src/components/primitives/StreamingTextView.jsx
import React, { useState, useEffect, useRef } from 'react';

function StreamingTextView({ id, config = {}, content, gridArea }) {
  const {
    title,
    // Presentation from config or CSS defaults
    fontSize = '0.9em', // Default size for streaming/logs
    fontWeight = 'normal',
    textAlign = 'left',
    color = undefined, // Default to inherit
    whiteSpace = 'pre-wrap',
    // Layout/Structure from config
    autoScroll = true,
    height = '200px', // Default height
    // Base presentation via CSS, overrides from config
    backgroundColor = undefined,
    border = undefined,
    borderRadius = undefined,
    padding = undefined,
    margin = undefined,
  } = config;

  const [accumulatedText, setAccumulatedText] = useState('');
  const scrollContainerRef = useRef(null);

  useEffect(() => {
    if (content !== null && content !== undefined && typeof content === 'string') {
      setAccumulatedText(prevText => prevText + content);
    }
  }, [content]);

  useEffect(() => {
    if (autoScroll && scrollContainerRef.current) {
      requestAnimationFrame(() => {
         if (scrollContainerRef.current) {
             scrollContainerRef.current.scrollTop = scrollContainerRef.current.scrollHeight;
         }
      });
    }
  }, [accumulatedText, autoScroll]);

  // Container styles (layout + config overrides)
  const containerStyle = {
    display: 'flex',
    flexDirection: 'column',
    height: height,
    gridArea: gridArea || undefined,
    boxSizing: 'border-box',
    overflow: 'hidden', // Hide overflow on container
    // Presentation overrides from config
    backgroundColor: backgroundColor,
    border: border,
    borderRadius: borderRadius,
    padding: padding,
    margin: margin,
    // Default presentation comes from CSS class primitive-streamingtextview-container
  };

  // Text area styles (layout + config overrides)
  const textStyle = {
    flexGrow: 1,
    overflowY: 'auto', // Scroll only the text area
    fontSize: fontSize, // From config or default
    fontWeight: fontWeight, // From config or default
    textAlign: textAlign, // From config or default
    color: color, // From config or default
    whiteSpace: whiteSpace, // From config or default
    wordBreak: 'break-word', // Good default
    fontFamily: 'var(--font-family-monospace)', // Default to monospace
    // Padding/Margin applied to container
  };

  return (
    // Apply base class for default styles
    <div
        id={id}
        style={containerStyle}
        className="primitive-streamingtextview-container"
    >
      {title && typeof title === 'string' && (
          <h4 className="primitive-title">{title}</h4>
      )}
      {/* Apply text area class */}
      <div
        ref={scrollContainerRef}
        style={textStyle}
        className="primitive-streamingtextview"
      >
        {accumulatedText || <>&nbsp;</>} {/* Render non-breaking space if empty to maintain height */}
      </div>
    </div>
  );
}

export default React.memo(StreamingTextView);