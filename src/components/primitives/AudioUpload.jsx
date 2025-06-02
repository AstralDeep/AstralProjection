// src/components/primitives/AudioUpload.jsx
import React, { useState, useCallback, useRef, useEffect } from 'react';

// URL now points to the generic file proxy endpoint in the main.py server
const UPLOAD_URL = '/api/upload-file/mcp_audio';

function AudioUpload({ id, config = {}, content, onValueChange, gridArea }) {
  const {
    label = 'Choose Audio File',
    acceptedFormats = 'audio/*',
    buttonLabel = 'Select Audio File',
    clearButtonLabel = 'Clear',
    maxFileSize, // Example: 5 * 1024 * 1024 (5MB)
  } = config;

  const [fileName, setFileName] = useState('');
  const [isUploaded, setIsUploaded] = useState(false);
  const [error, setError] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [previewUrl, setPreviewUrl] = useState(null);

  const fileInputRef = useRef(null);

  useEffect(() => {
    if (previewUrl) {
      URL.revokeObjectURL(previewUrl);
      setPreviewUrl(null);
    }
    if (typeof content === 'string' && content) {
      try {
        const parsedContent = JSON.parse(content);
        if (parsedContent && parsedContent.original_filename) {
          setFileName(parsedContent.original_filename);
          setIsUploaded(true);
          setError('');
        } else {
          setFileName('');
          setIsUploaded(false);
        }
      } catch (e) {
        console.warn(`AudioUpload (id: ${id}): Initial content string is not a valid file reference JSON. Content:`, content);
        setFileName('');
        setIsUploaded(false);
      }
    } else if (content === null || content === undefined || content === '') {
        setFileName('');
        setIsUploaded(false);
        setError('');
    } else if (typeof content === 'object' && content !== null && content.filename && content.dataUrl) {
        console.warn(`AudioUpload (id: ${id}): Received old base64 content structure. Displaying filename, but upload required.`);
        setFileName(content.filename);
        setIsUploaded(false);
        setError('Please re-select and upload the file.');
    } else {
        setFileName('');
        setIsUploaded(false);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [content, id]);

  const handleFileChange = useCallback(async (event) => {
    const file = event.target.files[0];
    if (fileInputRef.current) {
        fileInputRef.current.value = '';
    }

    if (previewUrl) {
      URL.revokeObjectURL(previewUrl);
      setPreviewUrl(null);
    }

    if (!file) {
      if (!isUploaded) {
        setFileName('');
        setError('');
        if (onValueChange) {
          onValueChange(id, null);
        }
      }
      return;
    }

    setError('');
    setFileName(file.name);
    setIsUploaded(false);
    setIsLoading(true);

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

    setPreviewUrl(URL.createObjectURL(file));

    const formData = new FormData();
    // Use the standardized key 'file'
    formData.append('file', file);

    try {
      const response = await fetch(UPLOAD_URL, {
        method: 'POST',
        body: formData,
      });

      setIsLoading(false);

      const responseData = await response.json();

      if (response.ok) {
        if (onValueChange) {
          onValueChange(id, JSON.stringify(responseData));
        }
        setFileName(responseData.original_filename || file.name);
        setIsUploaded(true);
        setError('');
      } else {
        // Handle errors from the server (including our 415 validation error)
        console.error('Upload failed:', responseData);
        setError(responseData.error || `Upload failed. Server responded with ${response.status}.`);
        setFileName(file.name);
        setIsUploaded(false);
        if (previewUrl) URL.revokeObjectURL(previewUrl);
        setPreviewUrl(null);
        if (onValueChange) {
          onValueChange(id, null);
        }
      }
    } catch (err) {
      setIsLoading(false);
      console.error('Upload network error:', err);
      setError(`Upload failed: ${err.message}. Check network or server.`);
      setFileName(file.name);
      setIsUploaded(false);
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      setPreviewUrl(null);
      if (onValuechange) {
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
    color: isUploaded ? 'green' : '#555',
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
        id={id}
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
      {previewUrl && !isUploaded && (
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