#!/usr/bin/env node
import { createServer } from '../server.js';

createServer().catch((error: unknown) => {
  console.error('[frontend-editor] Fatal error:', error);
  process.exit(1);
});
