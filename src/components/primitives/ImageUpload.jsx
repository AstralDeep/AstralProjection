// src/components/primitives/ImageUpload.jsx
import React, { useState, useCallback, useRef, useEffect } from 'react';

function ImageUpload({ id, config = {}, content, onValueChange, gridArea }) {
  const {
    label = 'Choose Image',
    acceptedFormats = 'image/*',
    buttonLabel = 'Select Image',
    clearButtonLabel = 'Clear',
    maxFileSize,
  } = config;

  const [fileName, setFileName] = useState('');
  const [isUploaded, setIsUploaded] = useState(false);
  const [error, setError] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [previewUrl, setPreviewUrl] = useState(null);
  const fileInputRef = useRef(null);

  useEffect(() => {
    if (typeof content === 'string' && content) {
      try {
        const parsedContent = JSON.parse(content);
        if (parsedContent && parsedContent.name) {
          setFileName(parsedContent.name);
          setIsUploaded(true);
          setError('');
          return;
        }
      } catch (e) {}
    }
    setFileName('');
    setIsUploaded(false);
  }, [content]);

  useEffect(() => {
    return () => {
      if (previewUrl) {
        URL.revokeObjectURL(previewUrl);
      }
    };
  }, [previewUrl]);

  const handleFileChange = useCallback((event) => {
    const file = event.target.files[0];
    if (!file) return;
    setIsUploaded(false);
    setError('');
    setIsLoading(true);
    setFileName(file.name);
    setPreviewUrl(URL.createObjectURL(file));
    if (maxFileSize && file.size > maxFileSize) {
      const maxSizeMB = (maxFileSize / 1024 / 1024).toFixed(2);
      setError(`File is too large (${(file.size / 1024 / 1024).toFixed(2)}MB). Max size: ${maxSizeMB}MB.`);
      setIsLoading(false);
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      const base64 = reader.result.split(',')[1];
      onValueChange?.(id, JSON.stringify({ base64, name: file.name, type: file.type }));
      setIsUploaded(true);
      setIsLoading(false);
    };
    reader.onerror = (err) => {
      setError('File read failed: ' + err.message);
      setIsLoading(false);
    };
    reader.readAsDataURL(file);
  }, [id, maxFileSize, onValueChange]);

  const handleButtonClick = () => {
    fileInputRef.current?.click();
  };

  const handleClear = useCallback(() => {
    setFileName('');
    setError('');
    setIsUploaded(false);
    setIsLoading(false);
    setPreviewUrl(null);
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
    <div id={`${id}-container`} style={primitiveStyle} className="primitive-imageupload">
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
          <img src={previewUrl} alt="preview" style={{ width: '100%', maxHeight: 300, objectFit: 'contain', border: '1px solid #eee', borderRadius: 4 }} onError={() => setError('Could not display image preview.')} />
        </div>
      )}
    </div>
  );
}

export default React.memo(ImageUpload);
