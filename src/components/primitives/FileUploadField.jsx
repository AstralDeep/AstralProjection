import React, { useRef, useState } from 'react';
import PropTypes from 'prop-types';

/**
 * FileUploadField - allows user to select and upload a file, then returns a file reference to parent
 * Props:
 *   primitive: primitive config object
 *   onFileUploaded: function({ fileId, url, name })
 */
export default function FileUploadField({ primitive, onFileUploaded }) {
  const inputRef = useRef();
  const [uploading, setUploading] = useState(false);
  const [fileInfo, setFileInfo] = useState(null);

  // When a file is selected and converted to base64, call onFileUploaded with base64 info
  const handleFileChange = async (e) => {
    const file = e.target.files[0];
    if (!file) return;
    setUploading(true);
    const reader = new FileReader();
    reader.onload = () => {
      const base64 = reader.result.split(',')[1]; // Remove data URL prefix
      setFileInfo({ name: file.name, type: file.type, base64 });
      // Call onFileUploaded with all info needed for payload
      if (onFileUploaded) onFileUploaded({ base64, name: file.name, type: file.type });
      setUploading(false);
    };
    reader.onerror = (err) => {
      alert('File read failed: ' + err.message);
      setUploading(false);
    };
    reader.readAsDataURL(file);
  };

  return (
    <div style={{ margin: '8px 0' }}>
      <input
        type="file"
        ref={inputRef}
        onChange={handleFileChange}
        disabled={uploading}
        style={{ marginRight: 8 }}
      />
      {uploading && <span>Uploading...</span>}
      {fileInfo && (
        <span style={{ marginLeft: 8 }}>
          Uploaded: {fileInfo.name}
        </span>
      )}
    </div>
  );
}

// Instruct parent to include base64, name, and type in the chat message payload:
// Example payload: { type: 'chat_message', payload: { text: '...', file: { base64, name, type } } }

FileUploadField.propTypes = {
  primitive: PropTypes.object.isRequired,
  onFileUploaded: PropTypes.func,
};
