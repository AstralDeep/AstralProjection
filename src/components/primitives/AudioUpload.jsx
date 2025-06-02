// src/components/primitives/AudioUpload.jsx
import React, { useState, useCallback, useRef, useEffect } from 'react';

const UPLOAD_URL = '/api/upload-file/mcp_audio';

function AudioUpload({ id, config = {}, content, onValueChange, gridArea }) {
  const {
    label = 'Choose Audio File',
    acceptedFormats = 'audio/*',
    buttonLabel = 'Select Audio File',
    clearButtonLabel = 'Clear',
    maxFileSize,
  } = config;

  // State for the component's value
  const [fileName, setFileName] = useState('');
  const [isUploaded, setIsUploaded] = useState(false);
  
  // State for the upload process and UI
  const [error, setError] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [previewUrl, setPreviewUrl] = useState(null);

  const fileInputRef = useRef(null);

  // Effect to sync component state FROM the parent `content` prop
  useEffect(() => {
    // This effect should only manage the component's persistent value (filename, uploaded status)
    // It should NOT manage the transient previewUrl state.
    if (typeof content === 'string' && content) {
      try {
        const parsedContent = JSON.parse(content);
        if (parsedContent && parsedContent.original_filename) {
          setFileName(parsedContent.original_filename);
          setIsUploaded(true);
          setError('');
          return; // Exit after successfully setting state
        }
      } catch (e) {
        // Fall through to clear state if JSON is invalid
      }
    }

    // If content is null, empty, or not our valid JSON, clear the value-related state.
    setFileName('');
    setIsUploaded(false);
    // Do not clear 'error' here as it might be an upload error we want to show.
  }, [content]);

  // Effect to clean up the blob URL when the component is unmounted
  // or when the previewUrl changes.
  useEffect(() => {
    return () => {
      if (previewUrl) {
        URL.revokeObjectURL(previewUrl);
      }
    };
  }, [previewUrl]);

  const handleFileChange = useCallback(async (event) => {
    const file = event.target.files[0];
    if (!file) return;

    // Reset state for the new file upload
    setIsUploaded(false);
    setError('');
    setIsLoading(true);
    setFileName(file.name);
    
    // Set a new preview URL for the selected file
    setPreviewUrl(URL.createObjectURL(file));

    if (maxFileSize && file.size > maxFileSize) {
      const maxSizeMB = (maxFileSize / 1024 / 1024).toFixed(2);
      setError(`File is too large (${(file.size / 1024 / 1024).toFixed(2)}MB). Max size: ${maxSizeMB}MB.`);
      setIsLoading(false);
      return;
    }

    const formData = new FormData();
    formData.append('file', file);

    try {
      const response = await fetch(UPLOAD_URL, {
        method: 'POST',
        body: formData,
      });

      const responseData = await response.json();
      setIsLoading(false);

      if (response.ok) {
        onValueChange?.(id, JSON.stringify(responseData));
        setFileName(responseData.original_filename || file.name);
        setIsUploaded(true);
      } else {
        setError(responseData.error || `Upload failed. Server responded with ${response.status}.`);
        onValueChange?.(id, null);
      }
    } catch (err) {
      setIsLoading(false);
      setError(`Upload failed: ${err.message}. Check network or server.`);
      onValueChange?.(id, null);
    }
  }, [id, maxFileSize, onValueChange]);

  const handleButtonClick = () => {
    fileInputRef.current?.click();
  };

  const handleClear = useCallback(() => {
    setFileName('');
    setError('');
    setIsUploaded(false);
    setIsLoading(false);
    setPreviewUrl(null); // This will trigger the cleanup effect for the old URL
    if (fileInputRef.current) {
      fileInputRef.current.value = '';
    }
    onValueChange?.(id, null);
  }, [id, onValueChange]);

  const style = { gridArea: gridArea || undefined, ...config };
  const primitiveStyle = { padding: '10px', border: '1px solid #ccc', borderRadius: '4px', display: 'flex', flexDirection: 'column', gap: '8px', ...style };
  const buttonStyle = { padding: '8px 12px', cursor: 'pointer', opacity: isLoading ? 0.7 : 1 };
  const fileNameStyle = { marginTop: '5px', fontStyle: 'italic', wordBreak: 'break-all', color: isUploaded ? 'green' : (error ? 'red' : '#555') };
  const errorStyle = { color: 'red', fontSize: '0.9em', marginTop: '5px' };

  return (
    <div id={`${id}-container`} style={primitiveStyle} className="primitive-audioupload">
      {label && <label htmlFor={id} style={{ fontWeight: 'bold' }}>{label}</label>}
      <input type="file" id={id} ref={fileInputRef} onChange={handleFileChange} accept={acceptedFormats} style={{ display: 'none' }} disabled={isLoading} />
      <button type="button" onClick={handleButtonClick} style={buttonStyle} className="btn" disabled={isLoading}>
        {isLoading ? 'Uploading...' : buttonLabel}
      </button>
      {fileName && (
        <div style={{ display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: '10px' }}>
          <span style={fileNameStyle}>
            {isUploaded ? '✅ Uploaded: ' : (isLoading ? 'Uploading: ' : 'Selected: ')} {fileName}
          </span>
          <button type="button" onClick={handleClear} style={{ ...buttonStyle, fontSize: '0.8em', padding: '4px 8px' }} className="btn btn-secondary" disabled={isLoading}>
            {clearButtonLabel}
          </button>
        </div>
      )}
      {error && <div style={errorStyle}>{error}</div>}
      {previewUrl && (
        <div style={{ marginTop: '10px' }}>
          <p style={{ fontSize: '0.9em', margin: '0 0 5px 0' }}>Preview:</p>
          <audio controls src={previewUrl} style={{ width: '100%' }} onError={() => setError('Could not play audio preview.')}>
            Your browser does not support the audio element.
          </audio>
        </div>
      )}
    </div>
  );
}

export default React.memo(AudioUpload);