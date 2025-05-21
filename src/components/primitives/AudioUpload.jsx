// src/components/primitives/AudioUpload.jsx
import React, { useState, useCallback, useRef } from 'react';

function AudioUpload({ id, config = {}, content, onValueChange, gridArea }) {
  const {
    label = 'Choose Audio File',
    acceptedFormats = 'audio/*', // e.g., "audio/mp3, audio/wav, audio/ogg"
    buttonLabel = 'Select Audio',
    clearButtonLabel = 'Clear',
    // maxFileSize = 5 * 1024 * 1024, // Optional: 5MB example, client-side check
  } = config;

  // content could be an object like { filename: string, dataUrl: string, fileType: string }
  const initialFileName = typeof content === 'object' && content !== null ? content.filename : '';
  const [fileName, setFileName] = useState(initialFileName);
  const [error, setError] = useState('');

  const fileInputRef = useRef(null);

  const handleFileChange = useCallback((event) => {
    const file = event.target.files[0];
    if (!file) {
      return;
    }

    setError('');
    setFileName(file.name);

    const reader = new FileReader();
    reader.onload = (loadEvent) => {
      if (onValueChange) {
        // Update the primitive's content in the global state
        onValueChange(id, {
          filename: file.name,
          dataUrl: loadEvent.target.result, // This will be the base64 Data URL
          fileType: file.type,
        });
      }
    };
    reader.onerror = () => {
      setError('Error reading file.');
      setFileName('');
      if (onValueChange) {
        onValueChange(id, null);
      }
    };
    reader.readAsDataURL(file); // Read as base64 Data URL
  }, [id, onValueChange/*, maxFileSize*/]);

  const handleButtonClick = () => {
    fileInputRef.current?.click(); // Programmatically click the hidden file input
  };

  const handleClear = () => {
    setFileName('');
    setError('');
    if (fileInputRef.current) {
      fileInputRef.current.value = ''; // Reset the file input
    }
    if (onValueChange) {
      onValueChange(id, null); // Clear the content in the global state
    }
  };

  const style = {
    gridArea: gridArea || undefined,
    // Add other layout styles from config if needed (e.g., margin, width)
    margin: config.margin || undefined,
    width: config.width || undefined,
  };

  // Basic styling, you'll want to adapt this to your app's design system
  const primitiveStyle = {
    padding: '10px',
    border: '1px solid #ccc',
    borderRadius: '4px',
    display: 'flex',
    flexDirection: 'column',
    gap: '8px',
    ...style, // Apply layout styles
  };

  const buttonStyle = { // Example inline style for buttons, use classes ideally
    padding: '8px 12px',
    cursor: 'pointer',
  };

  const fileNameStyle = {
    marginTop: '5px',
    fontStyle: 'italic',
    wordBreak: 'break-all',
  };

  const errorStyle = {
    color: 'red',
    fontSize: '0.9em',
  };


  return (
    <div id={`${id}-container`} style={primitiveStyle} className="primitive-audioupload">
      {config.label && <label htmlFor={id} style={{ fontWeight: 'bold' }}>{config.label}</label>}
      <input
        type="file"
        id={id}
        ref={fileInputRef}
        onChange={handleFileChange}
        accept={acceptedFormats}
        style={{ display: 'none' }} // Hidden, triggered by the button
        aria-label={config.label || 'Audio file uploader'}
      />
      <button type="button" onClick={handleButtonClick} style={buttonStyle} className="btn">
        {buttonLabel}
      </button>
      {fileName && (
        <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
          <span style={fileNameStyle}>Selected: {fileName}</span>
          <button type="button" onClick={handleClear} style={{...buttonStyle, fontSize: '0.8em'}} className="btn btn-secondary">
            {clearButtonLabel}
          </button>
        </div>
      )}
      {error && <div style={errorStyle}>{error}</div>}
        {content && content.dataUrl && (
            <audio controls src={content.dataUrl} style={{ marginTop: '10px', width: '100%' }}>
            Your browser does not support the audio element.
            </audio>
        )}
      
    </div>
  );
}

export default React.memo(AudioUpload);