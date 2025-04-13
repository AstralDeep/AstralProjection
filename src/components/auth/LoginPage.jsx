// src/components/auth/LoginPage.jsx
import React, { useState, useCallback } from 'react'; // Removed unused useEffect
import { useNavigate } from 'react-router-dom';
import { useAuthStore } from '../../stores/useAuthStore.jsx';
import LoadingSpinner from '../common/LoadingSpinner.jsx';

function LoginPage() {
  const [username, setUsername] = useState('public_user');
  const [password, setPassword] = useState('$2b$12$EixZaYVK1fsbw1ZfbX3OXePaWxn96p36WQoeG6Lruj3vjPGga31lW');

  const login = useAuthStore((state) => state.login);
  const isLoading = useAuthStore((state) => state.isLoading);
  const error = useAuthStore((state) => state.error);
  const navigate = useNavigate();

  const handleSubmit = useCallback(async (e) => {
    e.preventDefault();
    const success = await login(username, password);
    if (success) {
      navigate('/', { replace: true });
    }
  }, [username, password, login, navigate]);

  return (
    <div className="login-page">
      <div className="login-container">
        <h1 className="login-title">Login</h1>
        <form className="login-form" onSubmit={handleSubmit}>
          <div className="form-group">
            <label htmlFor="username">Username</label>
            <input
              type="text"
              id="username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              disabled={isLoading}
              autoComplete="username"
            />
          </div>
          <div className="form-group">
            <label htmlFor="password">Password</label>
            <input
              type="password"
              id="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              disabled={isLoading}
              autoComplete="current-password"
            />
          </div>

          {error && <div className="login-error">{error}</div>}

          <button
            type="submit"
            className="login-button"
            disabled={isLoading}
          >
            {isLoading ? <LoadingSpinner size="sm" /> : 'Login'}
          </button>
        </form>
      </div>
    </div>
  );
}

export default LoginPage;