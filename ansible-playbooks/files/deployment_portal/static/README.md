# Deployment portal favicon assets

Static icons served from the portal www root (`/favicon.ico`, `/apple-touch-icon.png`, etc.).

## Replacing with the reference Cloudera thumbnail

The intended reference is the Cloudera logo thumbnail PNG shared at:

`https://share.google/7WQExFL2iWrIcGqbY`

That link redirects to StickPNG (`cloudera-logo-thumbnail`); automated download from CI/agents is blocked by Cloudflare (HTTP 403 challenge), so the checked-in PNGs are **placeholders** derived from the portal header mark (orange arc + blue dot on dark rounded square).

To use the official thumbnail instead, download the PNG locally and overwrite these files (keep filenames):

- `favicon.ico`
- `favicon-16x16.png`
- `favicon-32x32.png`
- `apple-touch-icon.png` (180×180 recommended)
- `android-chrome-192x192.png`

Then re-run the **PORTAL** Ansible phase or `sync_deployment_portal_content` so Caddy serves the updated files from `deployment_portal_www_dir`.
