    // src/main.jsx
    import React from 'react';
    import ReactDOM from 'react-dom/client';
    import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
    import App from './App.jsx';
    import './index.css';

    const queryClient = new QueryClient({
      defaultOptions: {
        queries: {
          refetchOnWindowFocus: false,
          retry: 1,
          staleTime: 30000,
        },
      },
    });

    const root = ReactDOM.createRoot(document.getElementById('root'));

    // Temporarily comment out <React.StrictMode> to potentially reduce duplicate effect runs in development
    root.render(
      // <React.StrictMode>
        <QueryClientProvider client={queryClient}>
          <App />
        </QueryClientProvider>
      // </React.StrictMode>
    );
