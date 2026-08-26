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
      { label: "Docs", path: "/guides", icon: "book-open" },
      { label: "Architecture", path: "/architecture", icon: "layout" },
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
