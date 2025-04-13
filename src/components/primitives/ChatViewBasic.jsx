// src/components/primitives/ChatViewBasic.jsx
import React, { useState, useEffect, useRef } from 'react';
import ReactMarkdown from 'react-markdown'; // Import react-markdown
import LoadingSpinner from '../common/LoadingSpinner.jsx';
import { idGenerator } from '../../utils/idGenerator.js';

/**
 * Renders a chat conversation view.
 * Handles messages with 'role' and 'text'.
 * Supports rendering message text as plain text or Markdown via config.
 * Supports append/replace updates via the 'content' prop.
 */
function ChatViewBasic({ id, config = {}, content, gridArea }) {
  // --- Configuration ---
  const {
    title,
    autoScroll = true,
    height = '300px',
    // *** ADDED: Configuration flag for Markdown rendering ***
    renderAsMarkdown = false, // Default to false (plain text)
    // Presentation overrides (optional)
    backgroundColor = undefined,
    padding = undefined,
    border = undefined,
    borderRadius = undefined,
  } = config;

  // --- State ---
  const [messages, setMessages] = useState([]);
  const scrollRef = useRef(null);
  const [isAssistantWaiting, setIsAssistantWaiting] = useState(false);

  // --- Effects ---
  useEffect(() => {
    let newMessages = Array.isArray(content) ? [...content] : [];
    let waitingDetected = false;
    const lastMessage = newMessages[newMessages.length - 1];
    if (lastMessage && lastMessage.role === 'status' && lastMessage.text === 'assistant_waiting') {
        waitingDetected = true;
        newMessages.pop();
    }
    newMessages = newMessages.map((msg, index) => ({
        ...msg,
        uniqueId: msg.id || idGenerator.generateKey(`msg-${id}-${index}-`)
    }));
    setIsAssistantWaiting(waitingDetected);
    setMessages(newMessages);
  }, [content, id]);

  useEffect(() => {
    if (autoScroll && scrollRef.current) {
      requestAnimationFrame(() => {
          if (scrollRef.current) {
              scrollRef.current.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' });
          }
      });
    }
  }, [messages, isAssistantWaiting, autoScroll]);

  // --- Rendering Helpers ---
  const renderMessage = (message) => {
    if (!message || typeof message.text === 'undefined') {
        console.warn("ChatViewBasic: Skipping invalid message object:", message);
        return null;
    }
    const role = message.role || 'unknown';
    const roleClass = `message-${role}`;

    return (
        <div key={message.uniqueId} className={`message-bubble ${roleClass}`}>
            {/* Apply .message-text class for styling */}
            <div className="message-text">
                {/* *** Conditionally render using ReactMarkdown *** */}
                {renderAsMarkdown ? (
                    <ReactMarkdown
                        // Add remark/rehype plugins here if needed (e.g., for syntax highlighting, GFM)
                        // components={{ /* Override rendering for specific elements if needed */ }}
                    >
                        {message.text}
                    </ReactMarkdown>
                ) : (
                    // Render plain text (preserves whitespace via CSS)
                    message.text
                )}
            </div>
        </div>
    );
  };

  // --- Styles ---
  const containerStyle = {
    height: height,
    gridArea: gridArea || undefined,
    display: 'flex',
    flexDirection: 'column',
    overflow: 'hidden',
    // Apply overrides from config if provided
    backgroundColor: backgroundColor,
    padding: padding, // Note: Base padding is also set in CSS
    border: border,
    borderRadius: borderRadius,
  };

  const chatAreaStyle = {
      flexGrow: 1,
      overflowY: 'auto',
      display: 'flex',
      flexDirection: 'column',
      gap: 'var(--spacing-sm)',
  };


  // --- Render ---
  return (
    // Apply base primitive class for default styling from index.css
    <div id={id} style={containerStyle} className="primitive-chatviewbasic">
      {title && <h4 className="primitive-title">{title}</h4>}
      {/* Apply chat-area class for default padding etc. */}
      <div ref={scrollRef} style={chatAreaStyle} className="chat-area">
        {messages.length > 0 ? messages.map(renderMessage) : (
          !isAssistantWaiting && <div className="chat-empty">Conversation started.</div>
        )}
        {isAssistantWaiting && (
            <div className="waiting-indicator" title="Assistant is thinking...">
                <LoadingSpinner size="sm" message="" />
            </div>
        )}
      </div>
    </div>
  );
}
export default React.memo(ChatViewBasic);
