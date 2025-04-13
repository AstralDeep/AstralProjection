// src/components/common/LoadingSpinner.jsx
import React from 'react';

function LoadingSpinner({ message = 'Loading...', size = 'md' }) {
  const sizeMap = {
      sm: '16px',
      md: '32px',
      lg: '48px',
  };

  const spinnerSize = sizeMap[size] || sizeMap['md'];

  return (
    <div className={`loading-spinner-container size-${size}`}>
      <div className="spinner" style={{ width: spinnerSize, height: spinnerSize }}></div>
      {message && <p className="loading-message">{message}</p>}
      <style jsx="true">{`
        .loading-spinner-container {
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          padding: 20px;
          color: var(--color-text-secondary);
        }
        .loading-spinner-container.fullscreen {
            height: 100vh;
            width: 100vw;
            position: fixed;
            top: 0;
            left: 0;
            background: rgba(255,255,255,0.8);
            z-index: 9999;
        }
        .spinner {
          border: 3px solid rgba(0, 0, 0, 0.1);
          border-left-color: var(--color-primary);
          border-radius: 50%;
          display: inline-block;
          animation: spin 0.8s linear infinite;
        }
        .loading-message {
          margin-top: 10px;
          font-size: ${size === 'sm' ? '0.8rem' : '1rem'};
        }
        @keyframes spin {
          0% { transform: rotate(0deg); }
          100% { transform: rotate(360deg); }
        }
      `}</style>
    </div>
  );
}

export default LoadingSpinner;