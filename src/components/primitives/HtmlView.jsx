// src/components/primitives/HtmlView.jsx
import React, { useState, useEffect, useRef, useId } from 'react';
// --- Required for Graph Rendering ---
import cytoscape from 'cytoscape';
// Example: If using cose-bilkent layout
// import coseBilkent from 'cytoscape-cose-bilkent';
// cytoscape.use(coseBilkent); // Register layout algorithm globally (run once)
// ------------------------------------

/**
 * Renders different content types based on 'viz_type' received via props.
 * Handles scalar text, generates HTML tables, and renders interactive graphs.
 * Expects the full UpdateVisualizationParams object via the 'content' prop.
 */
function HtmlView({ id, config = {}, content = {}, gridArea }) {
  // --- Configuration ---
  const {
    title,
    initialMessage = "No results yet.", // Default message text
    // Style the main container
    backgroundColor = 'var(--color-surface)', // White background usually good here
    padding = '0', // Inner content often adds its own padding
    border = '1px solid var(--color-border)',
    borderRadius = 'var(--border-radius-md)',
    height = '100%', // Default to fill available height
  } = config;

  // --- State ---
  const [vizType, setVizType] = useState('message'); // Default type
  const [vizContent, setVizContent] = useState(initialMessage); // Default content

  // --- Refs ---
  const graphContainerRef = useRef(null); // Ref for the graph container div
  const cyRef = useRef(null); // Ref to store the Cytoscape instance
  const graphContainerId = useId(); // Generate a unique ID for the graph container

  // --- Effects ---
  // Process updates received via the 'content' prop (simulating binding)
  useEffect(() => {
    // Expect 'content' prop to be the UpdateVisualizationParams object
    const newVizType = content?.viz_type;
    const newVizContent = content?.content;

    // Flag to track if an update actually occurred
    let updated = false;

    if (newVizType) {
      // Only update state if type or content actually changes
      if (newVizType !== vizType || newVizContent !== vizContent) {
         setVizType(newVizType);
         setVizContent(newVizContent ?? ''); // Handle null/undefined content
         updated = true;
      }
    } else if (content === null) { // Handle explicit clearing
        if (vizType !== 'message' || vizContent !== initialMessage) {
            setVizType('message');
            setVizContent(initialMessage);
            updated = true;
        }
    }

    // Cleanup previous Cytoscape instance if the new type is not graph
    // or if the content was explicitly cleared
    if (updated && newVizType !== 'graph' && cyRef.current) {
      console.log(`HtmlView (${id}): Destroying previous graph instance (type changed).`);
      cyRef.current.destroy();
      cyRef.current = null;
    }
  }, [content, vizType, vizContent, initialMessage, id]); // Add vizType/vizContent to deps

  // Effect for handling Cytoscape graph rendering/updates
  useEffect(() => {
    // Only run if the type is 'graph' and we have a valid container and node data
    if (vizType === 'graph' && graphContainerRef.current && Array.isArray(vizContent?.nodes)) {
      console.log(`HtmlView (${id}): Rendering/Updating graph with Cytoscape.`);

      // Destroy previous instance before creating a new one
      if (cyRef.current) {
        cyRef.current.destroy();
        console.log(`HtmlView (${id}): Destroyed existing graph instance before update.`);
        cyRef.current = null; // Ensure ref is cleared
      }

      // --- Cytoscape Initialization ---
      try {
        // Map backend data structure {nodes:[{id,..}], links:[{source, target,..}]}
        // to Cytoscape elements {data:{id,..}}, {data:{source, target,..}}
        const elements = [
          ...(vizContent.nodes || []).map(node => ({ data: { ...node, id: String(node.id) } })), // Ensure ID is string
          ...(vizContent.links || []).map(link => ({ data: { ...link, source: String(link.source), target: String(link.target) } })) // Ensure source/target are strings
        ];

        // Basic default styling (can be overridden or extended via config in future)
        const defaultCyStyle = [
            { selector: 'node', style: { 'background-color': '#666', 'label': 'data(name)', 'width': '25px', 'height': '25px', 'font-size': '10px', 'color': '#333', 'text-valign': 'bottom', 'text-halign': 'center', 'text-margin-y': '4px', 'border-width': '1px', 'border-color': '#444' } },
            { selector: 'edge', style: { 'width': 1.5, 'line-color': '#ccc', 'target-arrow-color': '#ccc', 'target-arrow-shape': 'triangle', 'curve-style': 'bezier', 'label': 'data(label)', 'font-size': '8px', 'color': '#555', 'text-rotation': 'autorotate' } },
            { selector: 'node:selected', style: { 'border-width': '3px', 'border-color': '#337ab7' } },
            { selector: 'edge:selected', style: { 'line-color': '#337ab7', 'target-arrow-color': '#337ab7', 'width': 3 } }
        ];

        // Basic default layout (can be overridden or extended via config in future)
        const defaultCyLayout = {
           name: 'cose', // Ensure 'cose-bilkent' is installed and registered if using
           // name: 'grid', // Simpler alternative, no extra dependency
           fit: true,
           padding: 30,
           animate: true,
           animationDuration: 500,
           nodeRepulsion: () => 4000, // Example: Adjust layout params
           idealEdgeLength: () => 100,
           // Add other layout options as needed
        };

        cyRef.current = cytoscape({
          container: graphContainerRef.current,
          elements: elements,
          style: defaultCyStyle, // Apply default style
          layout: defaultCyLayout, // Apply default layout
          wheelSensitivity: 0.2, // Adjust zooming speed
        });

        // Example: Add basic hover effect
        cyRef.current.on('mouseover', 'node', function(event){
            event.target.style('border-color', '#f00');
            event.target.style('border-width', '3px');
        });
        cyRef.current.on('mouseout', 'node', function(event){
            event.target.style('border-color', '#444'); // Restore default
            event.target.style('border-width', '1px'); // Restore default
        });

        console.log(`HtmlView (${id}): Cytoscape instance created with ${elements.length} elements.`);

      } catch (error) {
        console.error(`HtmlView (${id}): Error initializing Cytoscape:`, error);
        if (graphContainerRef.current) {
          graphContainerRef.current.innerHTML = `<div class='viz-error'>Error rendering graph: ${error.message}</div>`;
        }
      }
      // -----------------------------

      // Cleanup function for this effect specifically
      return () => {
        if (cyRef.current) {
          console.log(`HtmlView (${id}): Cleaning up graph instance (effect cleanup).`);
          cyRef.current.destroy();
          cyRef.current = null;
        }
      };
    }
  }, [vizType, vizContent, id]); // Re-run when type/content changes

  // --- Rendering Logic ---

  // Helper function to render table data
  const renderTable = (tableContent) => {
    if (!tableContent || !Array.isArray(tableContent.columns) || !Array.isArray(tableContent.rows)) {
      return <div className="viz-message" style={{ color: 'orange' }}>Invalid table data format received.</div>;
    }
    const { columns, rows } = tableContent;
    return (
      <div className="table-responsive-wrapper"> {/* Wrapper for horizontal scroll */}
        <table className="data-table">
          <thead>
            <tr>
              {columns.map((col, index) => <th key={`header-${index}`}>{col}</th>)}
            </tr>
          </thead>
          <tbody>
            {rows.map((row, rowIndex) => (
              <tr key={`row-${rowIndex}`}>
                {row.map((cell, cellIndex) => (
                  // Render null/undefined as empty string
                  <td key={`cell-${rowIndex}-${cellIndex}`}>{String(cell ?? '')}</td>
                ))}
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={columns.length || 1} className="table-empty-message">
                  No data available.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    );
  };

  // Main render function for the content area
  const renderContent = () => {
    switch (vizType) {
      case 'scalar':
      case 'message':
        return <div className="viz-message">{String(vizContent)}</div>;
      case 'error':
        return <div className="viz-error">{String(vizContent)}</div>;
      case 'table':
        return renderTable(vizContent);
      case 'graph':
        // Render the container div; the useEffect handles Cytoscape rendering
        return (
          <div
            key={graphContainerId} // Use stable key
            ref={graphContainerRef}
            id={`graph-container-${graphContainerId}`}
            style={{ width: '100%', height: '100%', minHeight: '300px', position: 'relative' }} // Ensure container has dimensions
          />
        );
      default:
        // Render initial/default message safely
        return <div className="viz-message">{initialMessage}</div>;
    }
  };

  // --- Styles ---
  const containerStyle = {
    height: height,
    gridArea: gridArea || undefined,
    display: 'flex',
    flexDirection: 'column',
    overflow: 'hidden', // Hide overflow on main container
    backgroundColor: backgroundColor,
    padding: padding, // Apply padding to the main container
    border: border,
    borderRadius: borderRadius,
    boxSizing: 'border-box',
  };

  // Style for the content area within the container
  const contentAreaStyle = {
      flexGrow: 1,
      overflow: 'auto', // Allow this area to scroll if needed (esp. for tables/text)
      position: 'relative', // Needed for graph absolute positioning if required by lib
  };

  // --- Component Render ---
  return (
    <div id={id} style={containerStyle} className="primitive-htmlview">
      {title && <h4 className="primitive-title">{title}</h4>}
      {/* Apply style to content area */}
      <div style={contentAreaStyle}>
          {renderContent()}
      </div>
    </div>
  );
}

export default React.memo(HtmlView);