import { defineConfig } from "blume";

export default defineConfig({
  title: "TouchBridge",
  description:
    "Use your phone's fingerprint or Face ID to authenticate on any Mac — no $199 Touch ID keyboard required.",

  github: {
    owner: "HMAKT99",
    repo: "UnTouchID",
  },

  lastModified: true,

  navigation: {
    tabs: [
      { label: "Docs", path: "/", icon: "book-open" },
      { label: "CLI", path: "/cli", icon: "terminal" },
      { label: "Changelog", path: "/changelog", href: "/changelog", icon: "history" },
    ],
  },

  seo: {
    og: { enabled: true },
    rss: { enabled: true, types: ["changelog"] },
    sitemap: true,
    robots: true,
    structuredData: true,
  },

  deployment: {
    site: "https://touchbridge.dev",
  },
});
