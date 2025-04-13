// src/components/primitives/LogView.jsx
import React, { useState, useEffect, useRef } from 'react';

function LogView({ id, config = {}, content, gridArea }) {
  const {
    title,
    autoScroll = true,
    lineFormat = 'string',
    maxLines,
    // Layout/dimension config
    height = '200px',
    // Presentation config (use CSS class primitive-logview defaults)
    backgroundColor = undefined, // Use CSS default
    border = undefined, // Use CSS default
    padding = undefined, // Use CSS default
    borderRadius = undefined, // Use CSS default
  } = config;

  const [logs, setLogs] = useState([]);
  const scrollRef = useRef(null);

  useEffect(() => {
    let newLogs = Array.isArray(content) ? content : [];
    if (maxLines > 0 && newLogs.length > maxLines) {
      newLogs = newLogs.slice(-maxLines);
    }
    setLogs(newLogs);
  }, [content, maxLines]);

  useEffect(() => {
    if (autoScroll && scrollRef.current) {
      scrollRef.current.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' });
    }
  }, [logs, autoScroll]);

  const formatLogEntry = (entry, index) => {
    let text;
    if (lineFormat === 'json') {
      try {
        text = typeof entry === 'object' && entry !== null ? JSON.stringify(entry, null, 2) : String(entry);
      } catch (e) {
        console.warn(`Response (${e}) body is not JSON fallback to string`);
        text = String(entry);
      }
    } else {
      text = String(entry);
    }
    const key = (typeof entry === 'object' && entry?.id) ? entry.id : `${id}-log-${index}`;
    // Apply .log-entry class for styling from index.css
    return <pre key={key} className="log-entry">{text}</pre>;
  };

  // Container styles (layout + config overrides)
  const containerStyle = {
    height: height,
    gridArea: gridArea || undefined,
    display: 'flex',
    flexDirection: 'column',
    overflow: 'hidden', // Keep overflow control
    // Apply overrides from config if provided
    backgroundColor: backgroundColor,
    padding: padding,
    border: border,
    borderRadius: borderRadius,
    // Default presentation comes from CSS class
  };

  // Scrollable area styles (layout)
  const logAreaStyle = {
      flexGrow: 1,
      overflowY: 'auto',
      // Font family, size, line height moved to CSS class primitive-logview
  };

  // Title styles
   const titleStyle = {
       margin: '0 0 var(--spacing-sm) 0', // Use CSS var
       paddingBottom: 'var(--spacing-sm)', // Use CSS var
       borderBottom: '1px solid var(--color-border)',
       fontSize: '1em',
       fontWeight: '600',
       flexShrink: 0,
       // Add padding to align with container padding defined in CSS
       paddingLeft: 'var(--spacing-sm)',
       paddingRight: 'var(--spacing-sm)',
   };

  return (
    // Apply base class for default styles
    <div id={id} style={containerStyle} className="primitive-logview">
      {title && <h4 style={titleStyle}>{title}</h4>}
      {/* Inner div for scrolling doesn't need extra class if styled via parent */}
      <div ref={scrollRef} style={logAreaStyle}>
        {logs.length > 0 ? (
          logs.map(formatLogEntry)
        ) : (
          // Apply .log-empty class for styling
          <div className="log-empty">No log entries.</div>
        )}
      </div>
    </div>
  );
}
export default React.memo(LogView);