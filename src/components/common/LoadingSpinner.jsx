// src/components/common/LoadingSpinner.jsx
import React from 'react';

function LoadingSpinner({ message = 'Loading...', size = 'md', fullscreen = false }) {
  const sizeMap = {
    sm: '16px',
    md: '32px',
    lg: '48px',
  };

  const spinnerSize = sizeMap[size] || sizeMap['md'];

  // Conditionally build the class name string
  let containerClasses = `loading-spinner-container size-${size}`;
  if (fullscreen) {
    containerClasses += ' fullscreen';
  }

  return (
    <div
      className={containerClasses}
      role="status" // Accessibility: Informs assistive technologies this region is a live status.
      aria-live="polite" // Accessibility: Suggests changes should be announced when the user is idle.
    >
      <div
        className="spinner"
        style={{ width: spinnerSize, height: spinnerSize }}
        aria-hidden="true" // Accessibility: Hides the purely visual spinning element from screen readers.
      ></div>
      {message && message.trim() !== '' && ( // Render message only if it's not empty or just whitespace
        <p className="loading-message">{message}</p>
      )}
      {/* Scoped styles using styled-jsx */}
      <style jsx="true">{`
        .loading-spinner-container {
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          padding: var(--spacing-md, 20px); /* Using CSS var with fallback */
          color: var(--color-text-secondary, #555); /* Using CSS var with fallback */
        }
        .loading-spinner-container.fullscreen {
          height: 100vh;
          width: 100vw;
          position: fixed;
          top: 0;
          left: 0;
          background: rgba(255, 255, 255, 0.85); /* Slightly more opaque */
          z-index: 9999; /* Ensure it's on top */
        }
        .spinner {
          border: 3px solid var(--color-spinner-track, rgba(0, 0, 0, 0.1)); /* Using CSS var */
          border-left-color: var(--color-primary, #007bff); /* Using CSS var */
          border-radius: 50%;
          display: inline-block; /* Changed from 'block' if only spinner is shown without message */
          animation: spin 0.8s linear infinite;
        }
        .loading-message {
          margin-top: var(--spacing-sm, 10px); /* Using CSS var */
          font-size: ${size === 'sm' ? '0.8rem' : '1rem'};
          text-align: center;
        }
        @keyframes spin {
          0% {
            transform: rotate(0deg);
          }
          100% {
            transform: rotate(360deg);
          }
        }
      `}</style>
    </div>
  );
}

export default LoadingSpinner;