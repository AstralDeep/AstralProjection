// src/stores/useNotificationStore.jsx
import { create } from 'zustand';
import { idGenerator } from '../utils/idGenerator';

export const useNotificationStore = create((set, get) => ({
  notifications: [], // { id, type: 'error' | 'notification', message, timestamp }

  addNotification: (notification) => {
    const id = idGenerator.generate('notif-');
    const newNotification = {
        id,
        timestamp: Date.now(),
        type: 'notification', // Default type
        ...notification // Allow overriding type, message
    };

    set(state => ({
      // Add new notification and keep only the last N (e.g., 5)
      notifications: [...state.notifications, newNotification].slice(-5)
    }));

    // Automatically remove after a delay
    setTimeout(() => {
      get().removeNotification(id);
    }, 5000); // Remove after 5 seconds
  },

  removeNotification: (id) => {
    set(state => ({
      notifications: state.notifications.filter(n => n.id !== id)
    }));
  },

  // Convenience functions
  notify: (message) => {
      get().addNotification({ type: 'notification', message });
  },
  notifyError: (message) => {
      get().addNotification({ type: 'error', message });
  }

}));