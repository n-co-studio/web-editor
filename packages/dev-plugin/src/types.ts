/**
 * Options for @frontend-editor/dev-plugin.
 */
export interface DevPluginOptions {
  /**
   * Absolute path to the project root.
   * data-source-file paths will be relative to this directory.
   * Defaults to Vite's resolved root (Vite) or process.cwd() (Babel).
   */
  readonly root?: string;

  /**
   * File extensions to process.
   * @default ['.jsx', '.tsx']
   */
  readonly include?: readonly string[];

  /**
   * Patterns to exclude (substring matches or RegExp).
   * node_modules is always excluded.
   * @default []
   */
  readonly exclude?: readonly (string | RegExp)[];
}
