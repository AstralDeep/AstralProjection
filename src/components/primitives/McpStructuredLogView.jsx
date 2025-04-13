// Corrected for no-prototype-builtins: src/components/primitives/McpStructuredLogView.jsx
import React, { useEffect, useMemo, useRef } from 'react';

function McpStructuredLogView({ id, config = {}, content, gridArea }) {
  const { title, autoScroll = true, height = '200px', /* ... other config ... */ } = config;
  const scrollRef = useRef(null);

  const entries = useMemo(() => (Array.isArray(content) ? content : []), [content]);

  useEffect(() => {
    if (autoScroll && scrollRef.current) {
      scrollRef.current.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' });
    }
  }, [entries, autoScroll]);

  const renderEntry = (entry, index) => {
    let textToDisplay = '[Invalid Log Entry Format]';
    let level = 'info';
    let key = `${id}-log-${index}`;

    if (typeof entry === 'string') {
        textToDisplay = entry;
        key = `${id}-log-str-${index}`;
    } else if (typeof entry === 'object' && entry !== null) {
        if (index === 0) {
            console.debug(`McpStructuredLogView (${id}): Received entry object structure:`, entry);
        }

        // --- CORRECTED hasOwnProperty checks ---
        if (Object.prototype.hasOwnProperty.call(entry, 'data') && typeof entry.data === 'string') {
            textToDisplay = entry.data;
        } else if (Object.prototype.hasOwnProperty.call(entry, 'message') && typeof entry.message === 'string') {
            textToDisplay = entry.message;
        } else if (Object.prototype.hasOwnProperty.call(entry, 'text') && typeof entry.text === 'string') {
            textToDisplay = entry.text;
        } else {
            console.warn(`McpStructuredLogView (${id}): Cannot find standard text field in object. Stringifying.`, entry);
            try { textToDisplay = JSON.stringify(entry); } catch { /* Keep default */ }
        }
        // --- END CORRECTION ---

        level = entry?.level?.toLowerCase() ?? level;
        key = entry?.id || key;
    } else {
        textToDisplay = String(entry ?? '');
    }

    let className = `log-entry log-level-${level}`;

    return <pre key={key} className={className} style={{ margin: '2px 0', padding: '2px 4px', whiteSpace: 'pre-wrap', wordBreak: 'break-all' }}>{textToDisplay}</pre>;
  };

  const containerStyle = {
      height: height,
      display: 'flex',
      flexDirection: 'column',
      overflow: 'hidden',
      boxSizing: 'border-box',
      border: config.border || '1px solid var(--color-border, #ccc)',
      padding: config.padding || '8px',
      backgroundColor: config.backgroundColor || '#f8f9fa',
      borderRadius: config.borderRadius || 'var(--border-radius-sm, 4px)',
      gridArea: gridArea || undefined,
   };
  const logAreaStyle = { flexGrow: 1, overflowY: 'auto', fontFamily: 'monospace', fontSize: '0.85em', lineHeight: '1.4' };

  return (
    <div id={id} style={containerStyle} className="primitive-mcpstructuredlogview">
      {title && <h4 className="primitive-title">{title}</h4>}
      <div ref={scrollRef} style={logAreaStyle}>
        {entries.length > 0 ? (
          entries.map(renderEntry)
        ) : (
          <div className="log-empty" style={{ color: '#aaa', fontStyle: 'italic', padding: '10px 0' }}>No log entries.</div>
        )}
      </div>
    </div>
  );
}
export default React.memo(McpStructuredLogView);