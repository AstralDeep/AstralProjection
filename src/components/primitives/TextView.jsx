// src/components/primitives/TextView.jsx
import React from 'react';

function TextView({ id, config = {}, content, gridArea }) {
  const {
    initialText = '',
    fontSize = 'inherit',
    fontWeight = 'normal',
    textAlign = 'left',
    color,
    padding = '0',
    margin = '0',
    backgroundColor,
    borderRadius,
    whiteSpace: configWhiteSpace = 'pre-wrap',
    width,
    height,
    debugJsonIndent = 2,
  } = config;

  let textToDisplay = initialText;
  let isJsonForPreTag = false;

  if (content !== null && content !== undefined) {
    let processedContent = content;

    // Check if the content is a string that can be parsed into JSON
    if (typeof content === 'string') {
      try {
        const parsed = JSON.parse(content);

        // If parsing succeeds, check for our specific 'display_text' key
        if (typeof parsed === 'object' && parsed !== null && parsed.hasOwnProperty('display_text')) {
          // Use the 'display_text' value as the content to display
          processedContent = String(parsed.display_text);
        } else {
          // It's a different kind of JSON object, so we'll display it formatted
          processedContent = parsed;
        }
      } catch (e) {
        // Not a JSON string, so we'll treat it as plain text.
        // `processedContent` is already the original `content` string.
      }
    }

    // Now, determine the final text based on the processed content
    if (typeof processedContent === 'object' && processedContent !== null) {
      isJsonForPreTag = true;
      try {
        textToDisplay = JSON.stringify(processedContent, null, debugJsonIndent);
      } catch (e) {
        textToDisplay = '[Error stringifying object]';
        console.error(`TextView (${id}): Error stringifying content object:`, e, processedContent);
      }
    } else {
      textToDisplay = String(processedContent);
    }
  }

  // Determine the final whiteSpace style based on content type and config
  const finalWhiteSpace = isJsonForPreTag ? 'pre-wrap' : configWhiteSpace;

  // Construct the style object inline
  const style = {
    gridArea: gridArea || undefined,
    width: width || undefined,
    height: height || undefined,
    fontSize,
    fontWeight,
    textAlign,
    color: color || undefined,
    padding,
    margin,
    backgroundColor: backgroundColor || undefined,
    borderRadius: borderRadius || undefined,
    whiteSpace: finalWhiteSpace,
    wordBreak: 'break-word',
    boxSizing: 'border-box',
    fontFamily: isJsonForPreTag ? 'var(--font-family-monospace)' : 'inherit',
  };

  // Render as 'pre' if we decided to display a full JSON object, otherwise 'div'
  const Tag = isJsonForPreTag ? 'pre' : (config.as || 'div');

  return (
    <Tag id={id} style={style} className="primitive-textview">
      {textToDisplay}
    </Tag>
  );
}

export default React.memo(TextView);