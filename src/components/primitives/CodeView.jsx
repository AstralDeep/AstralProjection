// src/components/primitives/CodeView.jsx
import React from 'react';
// Using react-syntax-highlighter
import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter';
// Choose a theme (e.g., vscDarkPlus, atomDark, dracula, coy, okaidia, etc.)
import { vscDarkPlus } from 'react-syntax-highlighter/dist/esm/styles/prism';

/**
 * Renders text content with syntax highlighting.
 * Expects 'code' string via the 'content' prop.
 * Uses 'language' from config for highlighting.
 */
function CodeView({ id, config = {}, content = '', gridArea }) {
  // --- Configuration ---
  const {
    title,
    language = 'plaintext', // Default language if not provided
    height = 'auto', // Container height ('auto' or specific value like '300px')
    showLineNumbers = true,
    wrapLines = true,
    // Presentation overrides - Style the container
    // backgroundColor = undefined, // Usually let the theme handle this
    border = '1px solid var(--color-border)', // Optional container border
    borderRadius = 'var(--border-radius-md)', // Container border radius
  } = config;

  // --- Styles ---
  // Style for the main container div
  const containerStyle = {
    height: height,
    gridArea: gridArea || undefined,
    display: 'flex',
    flexDirection: 'column',
    overflow: 'hidden', // Container hides overflow
    // backgroundColor: backgroundColor, // Usually not needed if theme has one
    border: border,
    borderRadius: borderRadius,
    boxSizing: 'border-box',
  };

  // Style for the immediate child div that will scroll
  const scrollableAreaStyle = {
    flexGrow: 1,
    overflow: 'auto', // This div handles the scrolling
    // Inherit border radius if container has no border/padding, looks better
    borderRadius: !border ? borderRadius : '0',
  };

  // Style applied directly to the SyntaxHighlighter component
  const syntaxHighlighterStyle = {
    margin: 0, // Remove default margins from the highlighter component
    padding: 'var(--spacing-sm)', // Add internal padding
    height: '100%', // Allow the highlighter to fill the scrollable area
    boxSizing: 'border-box',
    // The theme (`vscDarkPlus`) will typically set background and text colors
  };

  // --- Render ---
  // Use content prop directly, ensure it's a string
  const codeToRender = String(content ?? '');

  return (
    <div id={id} style={containerStyle} className="primitive-codeview">
      {title && <h4 className="primitive-title">{title}</h4>}
      <div style={scrollableAreaStyle}>
        <SyntaxHighlighter
          language={language.toLowerCase()} // Pass language from config
          style={vscDarkPlus} // Apply the chosen theme
          showLineNumbers={showLineNumbers} // Control line numbers via config
          wrapLines={wrapLines} // Control line wrapping via config
          customStyle={syntaxHighlighterStyle} // Apply overrides/layout styles
          // Ensure the code itself uses a monospace font
          codeTagProps={{ style: { fontFamily: 'var(--font-family-monospace)' } }}
        >
          {codeToRender}
        </SyntaxHighlighter>
      </div>
    </div>
  );
}

export default React.memo(CodeView);