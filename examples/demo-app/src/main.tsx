import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './tokens.css';
import App from './App';
import MotionApp from './motion/MotionApp';

// Two coexisting pages: the classic editorial guide at "/", and the dark
// "kinetic blueprint" variant at "/motion". Vite's SPA fallback serves
// index.html for the deep link, so this pathname switch is all that's needed.
const isMotion = window.location.pathname.replace(/\/+$/, '').endsWith('/motion');

createRoot(document.getElementById('root')!).render(
  <StrictMode>{isMotion ? <MotionApp /> : <App />}</StrictMode>,
);
