// Unit and component tests (IS216 Week 10: Vitest + Vue Test Utils), run with `npm run test:unit`.
// The same Vite setup as the app, in a jsdom page; the database and Supabase are mocked in each test.
import { fileURLToPath } from 'node:url'
import { mergeConfig, defineConfig, configDefaults } from 'vitest/config'
import viteConfig from './vite.config.js'

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: 'jsdom',
      include: ['src/**/__tests__/**/*.spec.js'],
      exclude: [...configDefaults.exclude, 'e2e/**', 'android/**', 'ios/**', 'dist/**'],
      root: fileURLToPath(new URL('./', import.meta.url)),
    },
  }),
)
