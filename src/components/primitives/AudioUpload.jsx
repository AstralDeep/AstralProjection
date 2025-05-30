// src/components/primitives/AudioUpload.jsx
import React, { useState, useCallback, useRef, useEffect } from 'react';

const UPLOAD_URL = '/upload-audio'; // Assuming frontend served from same origin as MCP server

function AudioUpload({ id, config = {}, content, onValueChange, gridArea }) {
  const {
    label = 'Choose Audio File',
    acceptedFormats = 'audio/*',
    buttonLabel = 'Select Audio File', // Changed for clarity
    clearButtonLabel = 'Clear',
    maxFileSize, // Example: 5 * 1024 * 1024 (5MB)
  } = config;

  const [fileName, setFileName] = useState('');
  const [isUploaded, setIsUploaded] = useState(false); // Is current fileName from a successful upload reference?
  const [error, setError] = useState('');
  const [isLoading, setIsLoading] = useState(false); // For upload progress feedback
  const [previewUrl, setPreviewUrl] = useState(null); // For local preview of newly selected file

  const fileInputRef = useRef(null);

  // Effect to parse initial content or when content prop changes
  useEffect(() => {
    if (previewUrl) {
      URL.revokeObjectURL(previewUrl); // Clean up previous local preview if content changes externally
      setPreviewUrl(null);
    }
    if (typeof content === 'string' && content) {
      try {
        const parsedContent = JSON.parse(content);
        if (parsedContent && parsedContent.original_filename) {
          setFileName(parsedContent.original_filename);
          setIsUploaded(true);
          setError(''); // Clear any previous errors if content is now a valid ref
        } else {
          // Content string is not the expected file reference format
          setFileName('');
          setIsUploaded(false);
        }
      } catch (e) {
        // Content is a string but not valid JSON (could be an error message or old format)
        console.warn(`AudioUpload (id: ${id}): Initial content string is not a valid file reference JSON. Content:`, content);
        setFileName('');
        setIsUploaded(false);
      }
    } else if (content === null || content === undefined || content === '') { // Explicitly cleared or empty
        setFileName('');
        setIsUploaded(false);
        setError('');
    } else if (typeof content === 'object' && content !== null && content.filename && content.dataUrl) {
        // Handling for potential old base64 content structure for display purposes, though it won't be re-processed.
        console.warn(`AudioUpload (id: ${id}): Received old base64 content structure. Displaying filename, but upload required.`);
        setFileName(content.filename);
        setIsUploaded(false); // Mark as not an uploaded reference
        setError('Please re-select and upload the file.'); // Prompt user to use new upload
    } else {
        setFileName('');
        setIsUploaded(false);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [content, id]); // Rerun if content prop changes

  const handleFileChange = useCallback(async (event) => {
    const file = event.target.files[0];
    if (fileInputRef.current) { // Reset input field to allow re-selection of the same file
        fileInputRef.current.value = '';
    }

    if (previewUrl) {
      URL.revokeObjectURL(previewUrl); // Clean up previous local object URL
      setPreviewUrl(null);
    }

    if (!file) {
      // If no file is selected (e.g., user cancels file dialog),
      // keep current state unless it was an uploaded reference
      if (!isUploaded) { // only clear if not already representing a valid upload
        setFileName('');
        setError('');
        if (onValueChange) {
          onValueChange(id, null);
        }
      }
      return;
    }

    setError('');
    setFileName(file.name); // Show selected file name immediately
    setIsUploaded(false); // Mark as a new selection, not yet an uploaded reference
    setIsLoading(true);

    // Client-side file size check (optional)
    if (maxFileSize && file.size > maxFileSize) {
      const maxSizeMB = (maxFileSize / 1024 / 1024).toFixed(2);
      setError(`File is too large (${(file.size / 1024 / 1024).toFixed(2)}MB). Max size: ${maxSizeMB}MB.`);
      setFileName('');
      setIsLoading(false);
      if (onValueChange) {
        onValueChange(id, null);
      }
      return;
    }

    // Set local preview for the newly selected file
    setPreviewUrl(URL.createObjectURL(file));

    const formData = new FormData();
    formData.append('audiofile', file); // Key "audiofile" must match server expectation

    try {
      const response = await fetch(UPLOAD_URL, {
        method: 'POST',
        body: formData,
      });

      setIsLoading(false);

      if (response.ok) {
        const responseData = await response.json();
        if (onValueChange) {
          // Update the primitive's content with the JSON *string* reference
          onValueChange(id, JSON.stringify(responseData));
        }
        setFileName(responseData.original_filename || file.name); // Prefer server's original_filename
        setIsUploaded(true); // Mark as successfully uploaded reference
        setError(''); // Clear any previous errors
        // Local preview (previewUrl) will remain until cleared or new file selected
      } else {
        const errorData = await response.json().catch(() => ({ error: 'Upload failed with status: ' + response.status }));
        console.error('Upload failed:', errorData);
        setError(errorData.error || `Upload failed. Server responded with ${response.status}.`);
        setFileName(file.name); // Keep the initially selected file name for context
        setIsUploaded(false);
        if (previewUrl) URL.revokeObjectURL(previewUrl); // Remove preview on error
        setPreviewUrl(null);
        if (onValueChange) {
          onValueChange(id, null); // Clear any potentially stale reference
        }
      }
    } catch (err) {
      setIsLoading(false);
      console.error('Upload network error:', err);
      setError(`Upload failed: ${err.message}. Check network or server.`);
      setFileName(file.name); // Keep initially selected name
      setIsUploaded(false);
      if (previewUrl) URL.revokeObjectURL(previewUrl); // Remove preview on error
      setPreviewUrl(null);
      if (onValueChange) {
        onValueChange(id, null);
      }
    }
  }, [id, onValueChange, maxFileSize, previewUrl, isUploaded]);

  const handleButtonClick = () => {
    fileInputRef.current?.click();
  };

  const handleClear = useCallback(() => {
    setFileName('');
    setError('');
    setIsUploaded(false);
    setIsLoading(false);
    if (fileInputRef.current) {
      fileInputRef.current.value = '';
    }
    if (previewUrl) {
      URL.revokeObjectURL(previewUrl);
      setPreviewUrl(null);
    }
    if (onValueChange) {
      onValueChange(id, null);
    }
  }, [id, onValueChange, previewUrl]);

  const style = {
    gridArea: gridArea || undefined,
    margin: config.margin || undefined,
    width: config.width || undefined,
  };

  const primitiveStyle = {
    padding: '10px',
    border: '1px solid #ccc',
    borderRadius: '4px',
    display: 'flex',
    flexDirection: 'column',
    gap: '8px',
    ...style,
  };

  const buttonStyle = {
    padding: '8px 12px',
    cursor: 'pointer',
    opacity: isLoading ? 0.7 : 1,
  };

  const fileNameStyle = {
    marginTop: '5px',
    fontStyle: 'italic',
    wordBreak: 'break-all',
    color: isUploaded ? 'green' : '#555', // Indicate if it's an uploaded reference
  };

  const errorStyle = {
    color: 'red',
    fontSize: '0.9em',
    marginTop: '5px',
  };

  return (
    <div id={`${id}-container`} style={primitiveStyle} className="primitive-audioupload">
      {config.label && <label htmlFor={id} style={{ fontWeight: 'bold' }}>{config.label}</label>}
      <input
        type="file"
        id={id} // Keep id for label association, though MCP value comes from onValueChange
        ref={fileInputRef}
        onChange={handleFileChange}
        accept={acceptedFormats}
        style={{ display: 'none' }}
        aria-label={config.label || 'Audio file uploader'}
        disabled={isLoading}
      />
      <button type="button" onClick={handleButtonClick} style={buttonStyle} className="btn" disabled={isLoading}>
        {isLoading ? 'Uploading...' : buttonLabel}
      </button>
      {fileName && (
        <div style={{ display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: '10px' }}>
          <span style={fileNameStyle}>
            {isUploaded ? 'Uploaded: ' : 'Selected: '} {fileName}
          </span>
          <button 
            type="button" 
            onClick={handleClear} 
            style={{...buttonStyle, fontSize: '0.8em', padding: '4px 8px'}} 
            className="btn btn-secondary"
            disabled={isLoading}
          >
            {clearButtonLabel}
          </button>
        </div>
      )}
      {error && <div style={errorStyle}>{error}</div>}
      {previewUrl && !isUploaded && ( // Show local preview only for newly selected files not yet "uploaded" reference
        <div style={{marginTop: '10px'}}>
          <p style={{fontSize: '0.9em', margin: '0 0 5px 0'}}>Local Preview:</p>
          <audio controls src={previewUrl} style={{ width: '100%' }} onError={() => setError('Could not play audio preview.')}>
            Your browser does not support the audio element.
          </audio>
        </div>
      )}
    </div>
  );
}

export default React.memo(AudioUpload);