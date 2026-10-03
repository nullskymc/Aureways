import { defineConfig } from 'vite'

// The whole main-window UI. Output lands inside the app target as a folder
// reference (Aureways/WebAppBundle -> Aureways.app/Contents/Resources/WebAppBundle)
// and is committed, so Xcode builds never need Node.
export default defineConfig({
  base: './',
  esbuild: { jsx: 'automatic', jsxImportSource: 'preact' },
  build: {
    outDir: '../Aureways/WebAppBundle',
    emptyOutDir: true,
    target: 'safari18',
    modulePreload: { polyfill: false },
    cssCodeSplit: false,
    reportCompressedSize: false,
    rollupOptions: {
      output: {
        entryFileNames: 'assets/main.js',
        assetFileNames: 'assets/[name][extname]',
        chunkFileNames: 'assets/[name]-[hash].js',
      },
    },
  },
})
