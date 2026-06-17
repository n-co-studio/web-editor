import { defineConfig } from 'tsup';

export default defineConfig([
  {
    entry: { server: 'src/server.ts' },
    format: ['esm'],
    dts: true,
    noExternal: ['@nco-studio/shared'],
    external: ['ws', 'chokidar', 'react-docgen', '@modelcontextprotocol/sdk', 'zod'],
    outDir: 'dist',
    clean: true,
    target: 'node20',
    splitting: false,
  },
  {
    entry: { 'bin/cli': 'src/bin/cli.ts' },
    format: ['esm'],
    dts: false,
    noExternal: ['@nco-studio/shared'],
    external: ['ws', 'chokidar', 'react-docgen', '@modelcontextprotocol/sdk', 'zod'],
    outDir: 'dist',
    clean: false,
    target: 'node20',
    splitting: false,
    banner: { js: '#!/usr/bin/env node' },
  },
]);
