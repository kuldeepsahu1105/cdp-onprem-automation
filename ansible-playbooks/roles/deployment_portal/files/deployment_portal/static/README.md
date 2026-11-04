# Deployment portal favicon assets

Static icons served from the portal www root (`/favicon.ico`, `/apple-touch-icon.png`, etc.).

## Source

Cloudera logo thumbnail from [StickPNG — Cloudera logo thumbnail](https://www.stickpng.com/img/icons-logos-emojis/tech-companies/cloudera-logo-thumbnail) (400×400 PNG: `https://assets.stickpng.com/images/62a37ac16209494ec2b1707e.png`). Personal-use license per StickPNG; bundled here for portal tab/bookmark icons only.

Checked-in sizes were resized from that PNG:

- `favicon.ico` (16/32/48)
- `favicon-16x16.png`
- `favicon-32x32.png`
- `apple-touch-icon.png` (180×180)
- `android-chrome-192x192.png`

Ansible copies these via `sync_deployment_portal_content.yml` into `deployment_portal_www_dir`. Re-run **PORTAL** or `35_refresh_deployment_portal.yml` after updating files.
