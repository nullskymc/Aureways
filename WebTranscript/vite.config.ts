import { defineConfig } from 'vite'

// Output lands inside the app target as a folder reference
// (Aureways/WebTranscriptBundle -> Aureways.app/Contents/Resources/WebTranscriptBundle).
// The built output is committed so the Xcode build never needs Node.
export default defineConfig({
  base: './',
  build: {
    outDir: '../Aureways/WebTranscriptBundle',
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
