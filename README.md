# AstralProjection

## Introduction

Welcome to AstralProjection! This frontend application represents a novel approach to user interfaces, serving as a dynamic visual **projection** or **portal** into the inner workings of backend AI and agentic systems running on the "AstralPlane" backend. Its primary purpose is **not** to implement complex frontend logic itself, but rather to dynamically render the state and activities of the backend, offering a real-time, transparent view into AI processes, agent operations, and data streams.

**AstralProjection is fundamentally AI-driven.** The UI you interact with is entirely conceived, defined, and controlled by the AstralPlane backend, potentially leveraging visual AI models to determine the optimal interface configuration based on the user, the project context, and the specific task at hand. This means the interface can **change drastically** even within a single session as the backend adapts. It is, perhaps, one of the first examples of a purely AI-driven frontend architecture in existence.

## Core Concepts

* **AI-Driven & Backend-Controlled UI**: The layout, components, content, and behavior are dictated by the AstralPlane backend's AI, allowing for completely dynamic and context-aware interfaces.
* **Projection, Not Application**: Functions as a live visual stream of the backend's state and processes, rather than a traditional frontend application with its own logic.
* **Primitive-Based Rendering**: The backend sends configurations for basic UI elements ("primitives"), which the frontend renders dynamically. This flexible system allows the backend AI to construct virtually any interface structure.
* **Real-time Updates**: Leverages WebSockets for receiving live UI updates, status changes, and data streams (e.g., AI model outputs) from the backend.
* **State Visualization**: Aims to reflect the current state of backend processes and agent interactions accurately and transparently.

## Features

* Dynamic rendering of UI based entirely on backend AI instructions.
* Real-time content updates via WebSockets (e.g., streaming text, logs, chat messages, UI structure changes).
* Component library of UI "primitives" mapped to React components.
* User authentication and project selection.
* Robust WebSocket connection management with status indicators and reconnect logic.
* Client-side state management for UI, authentication, and project context using Zustand.
* Efficient server state management and caching via TanStack Query (React Query).

## Architecture

AstralProjection is built with modern web technologies:

* **Framework**: React (v19)
* **Build Tool**: Vite
* **State Management**:
    * **Zustand**: For managing client-side state (authentication, current project, UI notifications, WebSocket connection status, view state). Stores include `useAuthStore`, `useProjectStore`, `useViewStore`, `useNotificationStore`, `useToolSchemaStore`.
    * **TanStack Query (React Query)**: For managing server state, caching, and fetching data via REST APIs (like project lists).
* **Routing**: React Router DOM (v7)
* **Communication**:
    * **REST API**: Used for initial actions like login (`/api/auth/login`) and fetching static data like project lists (`/api/projects/`). Handled in `src/services/api.js`.
    * **WebSockets**: The primary channel for receiving dynamic UI definitions (`initial_ui_state`), real-time content updates (`primitive_content_update`, `mcp_progress`), backend notifications (`mcp_notification`), tool schemas (`tool_schemas`), and handling actions. Managed by the `useWebSocket` hook (`src/hooks/useWebSocket.jsx`).
* **Component Structure**:
    * **`src/components/primitives`**: Contains the React components that correspond to the UI elements the backend can request (e.g., `TextView`, `InputField`, `Button`, `StackLayout`, `ChatViewBasic`, `LogView`, `StreamingTextView`, `McpStructuredLogView`).
    * **`src/components/navigation`**: UI for navigation (e.g., `NavBar` for project selection, user menu).
    * **`src/components/workspace`**: The main area where the dynamic UI is rendered (`WorkspaceLayout`).
    * **`src/components/controls`**: Side panel for managing connections or other controls (`ControlPanel`, `StreamsTab`).
    * **`src/components/status`**: Bottom bar showing connection status and notifications (`StatusBar`).
    * **`src/components/auth`**: Login page component (`LoginPage`).
    * **`src/components/common`**: Reusable utility components (`LoadingSpinner`).
    * **`DynamicRenderer.jsx`**: The core component responsible for mapping backend primitive definitions to the actual React components in `src/components/primitives`.

## Getting Started

### Prerequisites

* **Node.js**: (Version recommended by your project, e.g., v18 or later). Download from [nodejs.org](https://nodejs.org/).
* **npm** (usually included with Node.js) or **Yarn**.
* Access to a running instance of the **AstralPlane backend**.

### Installation

1.  **Clone the repository** (if applicable):
    ```bash
    git clone <your-repository-url>
    cd astralprojection-frontend
    ```
2.  **Navigate to the project directory**:
    Ensure your terminal is in the root directory of this frontend project (where `package.json` is located).
3.  **Install dependencies**:
    * Using npm:
        ```bash
        npm install
        ```
    * Using Yarn:
        ```bash
        yarn install
        # or simply:
        # yarn
        ```

### Running the Development Server

1.  **Start the frontend**:
    * Using npm:
        ```bash
        npm run dev
        ```
    * Using Yarn:
        ```bash
        yarn dev
        ```
    This will typically start the Vite development server, often available at `http://localhost:5173` (check your terminal output for the exact address).

2.  **Access the Application**: Open your web browser and navigate to the address provided by the development server.

3.  **Login**: Use credentials provided by or configured for your AstralPlane backend instance.

4.  **Connect**: After logging in, the application should attempt to connect to the WebSocket endpoint associated with your selected project. You can monitor the connection status in the status bar or control panel.

## Dynamic Primitives Rendering

The user interface is dynamically generated based on instructions received from the AstralPlane backend via WebSocket. The backend AI determines *what* primitives to show, *how* they are configured, and *how* they are laid out.

### Implemented Primitives

The frontend currently supports rendering the following primitive types defined by the backend:

* **`StackLayout`**: A container that arranges child primitives vertically or horizontally (using Flexbox). Configurable properties include `direction`, `gap`, `padding`, `alignItems`, `justifyContent`.
* **`TextView`**: Displays static text or JSON content. Configurable properties include `fontSize`, `fontWeight`, `color`, `backgroundColor`, etc. Can render JSON with formatting.
* **`InputField`**: A text input field (single or multi-line). Configurable properties include `label`, `placeholder`, `multiline`, `rows`, `initialValue`, `disabled`, `enterKeyAction`. Its content can be read by actions triggered by other primitives.
* **`Button`**: A clickable button that triggers a backend action. Configurable properties include `label`, `variant` (style), `disabled`, `actionId`. Can be configured to read content from `InputField` primitives when clicked.
* **`ChatViewBasic`**: Displays a list of messages, typically used for chat interactions. Supports roles (user, assistant, system) and can render message content as plain text or Markdown. Updates via appending new messages.
* **`LogView`**: Displays a list of log entries (plain text or JSON). Supports auto-scrolling and limiting the number of lines displayed. Updates via appending new entries.
* **`McpStructuredLogView`**: Displays structured log entries, often with log levels (info, warning, error) and specific formatting. Updates via appending new entries.
* **`StreamingTextView`**: Displays text content that arrives in chunks over time (e.g., from an AI model response). Supports auto-scrolling and appends incoming text chunks to the existing content.

### Rendering Lifecycle Example

Here’s how a simple interaction involving dynamic UI creation and updates might work:

1.  **Initial State (`initial_ui_state` message)**: The backend AI decides to present a simple query interface. It sends a WebSocket message like this:
    ```json
    {
      "type": "initial_ui_state",
      "payload": {
        "rootElement": {
          "id": "root-stack",
          "type": "StackLayout",
          "config": { "direction": "vertical", "gap": "10px", "padding": "15px" },
          "children": [
            {
              "id": "query-input",
              "type": "InputField",
              "config": { "label": "Enter your query:", "placeholder": "Ask something..." }
            },
            {
              "id": "submit-button",
              "type": "Button",
              "config": {
                "label": "Submit Query",
                "actionId": "process_user_query",
                "valueSourceElementIds": ["query-input"], // Read from input field
                "frontendActions": [ // Actions to run immediately on click
                   {"type": "echoToView", "sourceElementId": "query-input", "targetBinding": "chat-area", "role": "user"},
                   {"type": "clearElement", "targetElementId": "query-input"}
                ]
              }
            },
            {
              "id": "response-stream",
              "type": "StreamingTextView",
              "config": { "title": "AI Response", "height": "300px" },
              "updateBinding": "chat-area" // Binding for echoToView
            }
          ]
        }
      }
    }
    ```
    The frontend receives this, and `DynamicRenderer` builds the UI with a vertical stack containing the input field, button, and streaming text view.

2.  **User Interaction**: The user types "What is the weather?" into the `query-input` field. The `InputField` component updates its internal state and the corresponding state in `useViewStore`.

3.  **Action Trigger (`ui_action` message)**: The user clicks the `submit-button`.
    * The configured `frontendActions` run immediately:
        * `echoToView`: Reads "What is the weather?" from `query-input`'s state and appends `{ role: 'user', text: 'What is the weather?' }` to the `content` array of the element with `updateBinding: 'chat-area'` (the `StreamingTextView` in this case, though `ChatViewBasic` is more typical for echo).
        * `clearElement`: Sets the `content` of `query-input` back to `''`.
    * The `handleAction` function in `DynamicRenderer` constructs and sends a `ui_action` message via WebSocket:
        ```json
        {
          "type": "ui_action",
          "payload": {
            "actionId": "process_user_query",
            "sourceElementId": "submit-button",
            "arguments": {
              "query": "What is the weather?" // Primary argument from valueSourceElementIds[0]
            }
          }
        }
        ```

4.  **Backend Processing & Streaming Updates (`primitive_content_update` messages)**: The backend processes the query. As the AI generates the response, the backend sends multiple update messages:
    * Message 1:
        ```json
        { "type": "primitive_content_update", "payload": { "targetId": "response-stream", "content": "The weather in Lexington", "updateType": "append" } }
        ```
    * Message 2:
        ```json
        { "type": "primitive_content_update", "payload": { "targetId": "response-stream", "content": " is currently sunny and ", "updateType": "append" } }
        ```
    * Message 3:
        ```json
        { "type": "primitive_content_update", "payload": { "targetId": "response-stream", "content": "75°F.", "updateType": "append" } }
        ```
    The frontend's `useViewStore` receives these, and the `StreamingTextView` component appends each chunk, rendering the response progressively.

5.  **Dynamic UI Replacement**: If the conversation shifts and the backend AI determines a completely different interface is needed (e.g., showing a map primitive), it could simply send a *new* `initial_ui_state` message. The frontend would discard the old UI tree and render the entirely new one, demonstrating the complete dynamic control the backend possesses. Primitives are implicitly "removed" when they are not part of the new UI state sent by the backend.

## Communication Flow

1.  **Authentication**: User logs in via a REST API call (`/api/auth/login`). Successful login returns an access token and user profile information.
2.  **Project Fetching**: Authenticated users fetch a list of available projects via a REST API call (`/api/projects/`).
3.  **Project Selection**: User selects a project from the NavBar.
4.  **WebSocket Connection**: The `useWebSocket` hook attempts to establish a WebSocket connection to the backend endpoint specific to the selected project (e.g., `ws://<host>:<port>/api/ws/stream/mcp:<project_id>?token=<token>`).
5.  **Initial UI Load**: Upon successful WebSocket connection, the backend sends the `initial_ui_state` and `tool_schemas` messages.
6.  **Rendering**: The frontend renders the UI based on `initial_ui_state` using `DynamicRenderer`.
7.  **Interaction**: User interacts with UI elements (e.g., clicks a Button, types in an InputField).
8.  **Action Sending**: For interactive elements like Buttons, clicking triggers the `handleAction` function in `DynamicRenderer`. This function constructs a `ui_action` message containing the `actionId` and any necessary arguments (often taken from the `content` of specified InputFields) and sends it to the backend via WebSocket using `sendJson`.
9.  **Backend Processing**: AstralPlane receives the `ui_action`, performs the corresponding AI or agentic function.
10. **Real-time Updates**: During or after processing, the backend sends messages back over the WebSocket:
    * `primitive_content_update`: To update text, logs, chat messages, clear inputs, etc.
    * `mcp_progress`: To show progress messages.
    * `mcp_notification`: General notifications about backend events.
    * `error`: If an error occurs during processing.
    * A new `initial_ui_state`: To completely change the interface.
11. **UI Updates**: The frontend's WebSocket message handlers update the relevant Zustand stores (`useViewStore`, `useNotificationStore`), causing the UI to re-render reflectively.

## Contributing

We welcome contributions to AstralProjection! Please follow these general guidelines:

### Reporting Bugs

* Search existing issues to see if the bug has already been reported.
* If not, open a new issue. Provide a clear title and description, including steps to reproduce the bug, expected behavior, and actual behavior.
* Include relevant details like your browser version, OS, and any console errors.

### Suggesting Enhancements

* Open a new issue to discuss your idea. Explain the enhancement, why it's needed, and potential implementation approaches.
* This allows for discussion before significant development effort is invested.

### Pull Request Process

1.  **Fork the repository** and create your branch from `main` (or the primary development branch).
2.  **Make your changes**. Adhere to the project's coding style (e.g., run linters/formatters if configured).
3.  **Add tests** for any new functionality or bug fixes, if applicable.
4.  **Ensure tests pass**.
5.  **Commit your changes** with clear and concise commit messages.
6.  **Push your branch** to your fork.
7.  **Open a Pull Request** against the main repository's primary branch.
8.  Provide a clear description of the changes in the PR description. Link to the relevant issue if applicable.
9.  Be prepared to discuss your changes and address any feedback from maintainers.


## License

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
