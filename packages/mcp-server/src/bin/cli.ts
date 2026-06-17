#!/usr/bin/env node
import { createServer } from '../server.js';

createServer().catch((error: unknown) => {
  console.error('[nco-web-editor] Fatal error:', error);
  process.exit(1);
});
