import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import { starlightBasePath } from "starlight-base-path";

// Custom domain root: https://private-s3-artifact-store.johna.kiwi
const site = "https://private-s3-artifact-store.johna.kiwi";
const base = "/";

export default defineConfig({
  site,
  base,
  integrations: [
    starlight({
      title: "Private S3 Artifact Store",
      favicon: "/favicon.svg",
      description:
        "CLI lab: private S3 via regional gateway VPC endpoints, with Sydney to Auckland replication.",
      customCss: [
        "./src/styles/patina-tokens.css",
        "./src/styles/splash-overrides.css",
      ],
      components: {
        ThemeSelect: "./src/components/ThemeSelect.astro",
        Head: "./src/components/Head.astro",
      },
      plugins: [starlightBasePath()],
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/jajera/private-s3-artifact-store",
        },
      ],
      editLink: {
        baseUrl:
          "https://github.com/jajera/private-s3-artifact-store/edit/main/",
      },
      lastUpdated: true,
      pagination: true,
      sidebar: [
        { label: "Home", link: "/" },
        {
          label: "Concepts",
          items: [
            { slug: "concepts/architecture" },
            { slug: "concepts/lab-findings-nz" },
            { slug: "concepts/gateway-vpce" },
            { slug: "concepts/crr-syd-akl" },
            { slug: "concepts/alternatives" },
          ],
        },
        {
          label: "Deploy and operate",
          items: [
            { slug: "deploy-and-operate/prerequisites" },
            { slug: "deploy-and-operate/shared-buckets" },
            { slug: "deploy-and-operate/consumer" },
            { slug: "deploy-and-operate/allowlist" },
            { slug: "deploy-and-operate/publish" },
            { slug: "deploy-and-operate/prove" },
            { slug: "deploy-and-operate/teardown" },
          ],
        },
        {
          label: "Reference",
          items: [
            { slug: "reference/commands" },
            { slug: "reference/cost" },
            { slug: "reference/troubleshooting" },
          ],
        },
      ],
    }),
  ],
});
