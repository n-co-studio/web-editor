import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { ncoWebEditor } from '@nco-studio/web-editor-plugin';

// https://vitejs.dev/config/
export default defineConfig({
  base: process.env.VITE_BASE_PATH ?? '/',
  plugins: [
    react(),
    ncoWebEditor(),
  ],
});
