import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import './index.css';
import './styles/legacy.css';

const rootEl = document.getElementById('root');
if (!rootEl) {
  throw new Error('root element missing — check client/index.html');
}

createRoot(rootEl).render(
  <StrictMode>
    <App />
  </StrictMode>
);
