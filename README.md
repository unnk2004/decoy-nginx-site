# decoy-nginx-site

A realistic decoy website ("Pulsewatch" — a fictional infrastructure
monitoring SaaS) plus a one-shot deploy script that turns a bare Ubuntu
box into:

- nginx terminating TLS on port 443 (using existing certs)
- HTTP→HTTPS redirect on port 80
- a multi-page static site served as the default content
- a reverse proxy on a randomized, non-obvious path forwarding to
  `127.0.0.1:12345` (where Xray / 3x-ui xhttp inbound is expected to listen)

## Usage

On the target server, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/unnk2004/decoy-nginx-site/main/deploy-nginx.sh | bash
```

or download and run manually:

```bash
wget https://raw.githubusercontent.com/unnk2004/decoy-nginx-site/main/deploy-nginx.sh
chmod +x deploy-nginx.sh
./deploy-nginx.sh
```

The script will:

1. Ask for the domain (e.g. `de.skynets.uk`)
2. Install nginx if it isn't already installed
3. Back up the entire existing `/etc/nginx` directory to `/root/nginx-backup-<timestamp>`
4. Wipe all existing site configs
5. Download the decoy site pages from this repo into `/var/www/<domain>/`
6. Generate a random, realistic-looking proxy path (e.g. `/api/v2/edge/sync-7f2a`)
7. Write a single nginx server block with that path proxying to `127.0.0.1:12345`
8. Test the config and reload nginx (rolling back automatically on failure)

At the end it prints the generated proxy path — **copy that into your
Xray/3x-ui xhttp inbound's `path` setting.** Also set that inbound's
`host` to your domain and `security` to `none`, since TLS is terminated
by nginx, not by Xray.

## Expects

- Certificates already present at `/root/cert/<domain>/fullchain.pem` and
  `/root/cert/<domain>/privkey.pem`
- An xhttp/VLESS inbound (Xray, via 3x-ui or otherwise) already configured
  to listen on `127.0.0.1:12345`

## Repo layout

```
deploy-nginx.sh      <- run this on the server
site/
  index.html         <- homepage with live-looking metrics widget
  pricing.html
  docs.html
  status.html
  about.html
  blog.html
  careers.html
  privacy.html
  terms.html
  imprint.html
  404.html
  styles.css
  robots.txt
```

## Notes

- The script rewrites `/etc/nginx/sites-available`, `/etc/nginx/sites-enabled`,
  and `/etc/nginx/conf.d` entirely. The previous state is backed up but not
  preserved in place — review the backup if you had other vhosts on this box.
- `server_tokens off` is set globally to avoid leaking the nginx version.
- Re-running the script generates a **new** random proxy path each time —
  remember to update the Xray inbound to match if you re-run it.
