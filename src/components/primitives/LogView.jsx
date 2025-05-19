// src/components/primitives/LogView.jsx
import React, { useState, useEffect, useRef, useCallback } from 'react'; // Added useCallback

function LogView({ id, config = {}, content, gridArea }) {
  const {
    title,
    autoScroll: initialAutoScroll = true, // Renamed to avoid conflict with internal state
    lineFormat = 'string',
    maxLines,
    height = '200px',
    backgroundColor = undefined,
    border = undefined,
    padding = undefined,
    borderRadius = undefined,
  } = config;

  const [logs, setLogs] = useState([]);
  const scrollRef = useRef(null);

  // --- ENHANCEMENT: State for Sticky Scroll ---
  const [userHasScrolledUp, setUserHasScrolledUp] = useState(false);
  // Keep a ref for the autoScroll prop to avoid re-triggering scroll handler effect if only autoScroll prop changes
  const autoScrollEnabledRef = useRef(initialAutoScroll);

  useEffect(() => {
    autoScrollEnabledRef.current = initialAutoScroll;
  }, [initialAutoScroll]);


  useEffect(() => {
    let newLogs = Array.isArray(content) ? content : [];
    if (maxLines > 0 && newLogs.length > maxLines) {
      newLogs = newLogs.slice(-maxLines);
    }
    setLogs(newLogs);
  }, [content, maxLines]);

  // --- ENHANCEMENT: Modified Auto-Scroll Logic for Sticky Scroll ---
  useEffect(() => {
    const scrollElement = scrollRef.current;
    if (scrollElement) {
      // Only auto-scroll if the feature is enabled AND the user hasn't scrolled up
      if (autoScrollEnabledRef.current && !userHasScrolledUp) {
        scrollElement.scrollTo({ top: scrollElement.scrollHeight, behavior: 'smooth' });
      }
    }
  }, [logs, userHasScrolledUp]); // Auto-scroll depends on logs and userHasScrolledUp state

  // --- ENHANCEMENT: Scroll Handler for Sticky Scroll ---
  const handleScroll = useCallback(() => {
    const scrollElement = scrollRef.current;
    if (scrollElement) {
      const threshold = 20; // Pixels from bottom to consider "at bottom"
      const atBottom = scrollElement.scrollHeight - scrollElement.scrollTop - scrollElement.clientHeight <= threshold;

      if (atBottom) {
        if (userHasScrolledUp) { // Only update state if it changed
          setUserHasScrolledUp(false);
        }
      } else {
        if (!userHasScrolledUp) { // Only update state if it changed
          setUserHasScrolledUp(true);
        }
      }
    }
  }, [userHasScrolledUp]); // Dependency: userHasScrolledUp to avoid stale closure

  // Attach/detach scroll listener
  useEffect(() => {
    const scrollElement = scrollRef.current;
    if (scrollElement && autoScrollEnabledRef.current) { // Only add listener if autoScroll is a feature
      scrollElement.addEventListener('scroll', handleScroll);
      return () => {
        scrollElement.removeEventListener('scroll', handleScroll);
      };
    }
  }, [handleScroll]); // Re-attach if handleScroll changes (due to its own deps)


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
    return <pre key={key} className="log-entry">{text}</pre>;
  };

  const containerStyle = {
    height: height,
    gridArea: gridArea || undefined,
    display: 'flex',
    flexDirection: 'column',
    overflow: 'hidden',
    backgroundColor: backgroundColor,
    padding: padding,
    border: border,
    borderRadius: borderRadius,
  };

  const logAreaStyle = {
    flexGrow: 1,
    overflowY: 'auto',
  };

  const titleStyle = {
    margin: '0 0 var(--spacing-sm) 0',
    paddingBottom: 'var(--spacing-sm)',
    borderBottom: '1px solid var(--color-border)',
    fontSize: '1em',
    fontWeight: '600',
    flexShrink: 0,
    paddingLeft: 'var(--spacing-sm)',
    paddingRight: 'var(--spacing-sm)',
  };

  return (
    <div id={id} style={containerStyle} className="primitive-logview">
      {title && <h4 style={titleStyle}>{title}</h4>}
      <div
        ref={scrollRef}
        style={logAreaStyle}
        // --- ENHANCEMENT: ARIA Attributes for Accessibility ---
        role="log" // Semantically identifies the region as a log.
        aria-live={autoScrollEnabledRef.current && !userHasScrolledUp ? "polite" : "off"} // Announce new logs if auto-scrolling, "off" if user scrolled up.
        aria-atomic="false" // Announce only new additions, not the entire log.
      >
        {logs.length > 0 ? (
          logs.map(formatLogEntry)
        ) : (
          <div className="log-empty">No log entries.</div>
        )}
      </div>
    </div>
  );
}

export default React.memo(LogView);