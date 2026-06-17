import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { ncoWebEditor } from '@nco-studio/web-editor-plugin';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [
    react(),
    ncoWebEditor(),
  ],
});
