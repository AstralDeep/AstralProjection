// src/components/primitives/Button.jsx
import React from 'react';

function Button({ id, config = {}, actionId, onAction, gridArea, getComponentData }) {
  const {
    label = 'Submit',
    variant = 'default',
    disabled = false,
    title,
    margin = "8px 0 0 0",
    width,
    clientAction, // New: Destructure clientAction from config
  } = config;

  const handleDownload = () => {
    if (!clientAction || clientAction.type !== 'downloadData') return;

    const { dataSourceElementId, defaultFilename } = clientAction;
    if (!dataSourceElementId) {
      console.error(`Button ${id}: downloadData action is missing dataSourceElementId.`);
      return;
    }
    if (!getComponentData) {
      console.error(`Button ${id}: getComponentData function not provided.`);
      return;
    }

    const sourceDataString = getComponentData(dataSourceElementId);
    if (!sourceDataString) {
      console.error(`Button ${id}: Could not find data for element with ID: ${dataSourceElementId}`);
      return;
    }

    try {
      // --- START: MODIFIED LOGIC ---
      let payload;
      if (typeof sourceDataString === 'string') {
        payload = JSON.parse(sourceDataString);
      } else if (typeof sourceDataString === 'object' && sourceDataString !== null) {
        payload = sourceDataString;
      } else {
        console.error(`Button ${id}: Data from ${dataSourceElementId} is not a valid JSON string or object.`);
        return;
      }
      
      console.log(payload);

      // 1. Access the 'full_response' object we created on the backend.
      const structuredData = JSON.parse(payload[0].text.raw_embedding_vector);
      
      if (!structuredData) {
        console.error(`Button ${id}: 'raw_embedding_vector' object not found in the payload. The backend response structure might have changed.`, payload);
        return;
      }

      if (structuredData === undefined) {
        console.error(`Button ${id}: 'raw_embedding_vector' not found in the structured data from ${dataSourceElementId}.`, structuredData);
        return;
      }

      // 3. Get the suggested filename from the data, or use the default.
      const now = new Date();
      const year = now.getFullYear();
      const month = String(now.getMonth() + 1).padStart(2, '0'); // Months are zero-based
      const day = String(now.getDate()).padStart(2, '0');
      const hours = String(now.getHours()).padStart(2, '0');
      const minutes = String(now.getMinutes()).padStart(2, '0');
      const seconds = String(now.getSeconds()).padStart(2, '0');

      const filename = `${year}-${month}-${day}_${hours}-${minutes}-${seconds}_embeddings.json`;

      // 4. Create and trigger the download link.
      const blob = new Blob([JSON.stringify(structuredData, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      
    } catch (error) {
      console.error(`Button ${id}: Failed to process or download data.`, error);
      console.error(`Button ${id}: Received data string was:`, sourceDataString);
    }
  };

  const handleClick = (event) => {
    event.preventDefault();
    if (disabled) return;

    if (clientAction) {
      switch (clientAction.type) {
        case 'downloadData':
          handleDownload();
          break;
        default:
          console.warn(`Button ${id}: Unknown clientAction type "${clientAction.type}"`);
      }
    } else if (onAction && actionId) {
      console.log(`Button ${id}: Triggering action "${actionId}"`);
      onAction(actionId, id);
    }
  };

  const getVariantClass = () => {
    switch (variant) {
      case 'primary': return 'btn-primary';
      case 'success': return 'btn-success';
      case 'danger': return 'btn-danger';
      case 'secondary': return 'btn-secondary';
      default: return '';
    }
  }

  const style = {
    gridArea: gridArea || undefined,
    margin: margin || undefined,
    width: width || undefined,
  };

  return (
    <button
      type="button"
      id={id}
      onClick={handleClick}
      disabled={disabled}
      className={`btn ${getVariantClass()} primitive-button`}
      style={style}
      title={title || label}
      aria-label={label}
    >
      {label}
    </button>
  );
}

export default React.memo(Button);