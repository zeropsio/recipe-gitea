# Gitea on Zerops

Self-hosted [Gitea](https://about.gitea.com/) backed by HA PostgreSQL and a
local storage volume. Import one YAML file and you have a working
instance on an HTTPS subdomain; then take it over and make it yours.

## 1. Import the project

Import `zerops-project-import.yaml` either in the Zerops GUI
(**Import project** – paste the YAML below) or with zcli:

```sh
zcli project project-import zerops-project-import.yaml
```

```yaml
#zeropsPreprocessor=on
project:
  name: gitea
services:
  - hostname: db
    type: postgresql:ha@18
    profile: oltp-staging
    priority: 10

  - hostname: volume
    type: local-storage@1
    priority: 10

  - hostname: web
    type: ubuntu@26.04
    vault:
      DB_PASSWORD:
        value: <@generateRandomString(<32>)>
        sensitive: true
      GITEA_DOMAIN: web-${zeropsSubdomainHost}-3000.app-prg1.zerops.app
    maxContainers: 1
    verticalAutoscaling:
      minRam: 0.25
    buildFromGit: https://github.com/zeropsio/recipe-gitea
    enableSubdomainAccess: true
```

This creates and wires up everything on Zerops:

- `db` – HA PostgreSQL
- `volume` – shared local storage for repositories, LFS objects and logs
- `web` – Gitea itself, built from this repository, with subdomain access
  enabled

All secrets are generated for you: `DB_PASSWORD` by the Zerops import
preprocessor, and the Gitea secrets (`JWT_SECRET`, `LFS_JWT_SECRET`,
`SECRET_KEY`, `INTERNAL_TOKEN`) by the Gitea binary during the first init
(`init.sh`), which also creates the database role and prepares the work dir on
the volume. The very first start of `web` fails on purpose (`start.sh` exits
until the secrets land in the environment) and Zerops restarts it with them
present – there is nothing to prepare by hand.

## 2. Create the admin user

Registration is disabled, so create the first (admin) user from inside the
`web` service. Open a webshell in the GUI (`web` → **Remote Web Terminal**), or SSH in
over the Zerops VPN:

```sh
zcli vpn up
ssh web
```

Then run:

```sh
gitea admin user create \
  --config /etc/gitea/app.ini \
  --admin \
  --username admin \
  --email you@example.com \
  --password 'choose-a-strong-one' \
  --must-change-password=false
```

## 3. Explore the instance

Open the `web` service's HTTPS subdomain (shown in the GUI under **Public
access**) and log in with the admin user. Optionally add your SSH public key
under **Settings → SSH/GPG Keys** – it will be used once SSH is routed in
step 4.

The instance is already usable for demos: git operations work over the HTTPS
subdomain (git asks for your Gitea username and password, or an access token).

## 4. Add your own domain and SSH port

For real use, give the instance a domain and expose Gitea's SSH server:

1. In the GUI, add your domain to the `web` service (**Public access →
   Domain access**), pointing it to port `3000`, and point your DNS records at
   the project's public IP as instructed there. Every project has a public
   IPv6 address out of the box; if you also want IPv4 connectivity, enable the
   optional public IPv4 address on the project first.
2. In the same place, add a **port routing** rule `:2222 → web:2222` – that is
   Gitea's built-in SSH server.
3. Change the `GITEA_DOMAIN` environment variable of the `web` service to your
   domain and **restart** the service. `app.ini` derives `ROOT_URL` and
   `SSH_DOMAIN` from it, so web links and clone URLs will use your domain:

   ```
   https://git.example.com/you/repo.git
   ssh://git@git.example.com:2222/you/repo.git
   ```

## 5. Take ownership, customize, extend

The `web` service is built from this repository, so to make changes fork or
clone it, edit what you need and deploy it as your own:

- `app.ini` – Gitea configuration; values in `{{.VAR}}` are filled from the
  service's environment variables at start (`zsc envReplace`).
- `zerops.yaml` – build/run recipe: Gitea version, installed packages, ports,
  environment variables.
- `init.sh` / `start.sh` – one-time init (database, work dir, secrets) and
  the start command.

Deploy your version with `zcli push web` from the clone, or point the service
at your own git repository (**Build & deploy → connect repository**) for
automatic deploys on push.
