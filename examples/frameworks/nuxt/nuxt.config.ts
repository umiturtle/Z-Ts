export default defineNuxtConfig({
  ssr: true,
  telemetry: false,
  app: { head: { title: 'Z-Ts — framework demo' } },
  nitro: { preset: 'static' },
});
