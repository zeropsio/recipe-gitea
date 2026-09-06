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
- `volume` – [local storage](https://docs.zerops.io/local-storage/overview) for repositories, LFS objects and logs
- `web` – Gitea itself, built from this repository, with subdomain access
  enabled

All secrets are generated for you: `DB_PASSWORD` by the Zerops import
preprocessor, and the Gitea secrets (`JWT_SECRET`, `LFS_JWT_SECRET`,
`SECRET_KEY`, `INTERNAL_TOKEN`) by the Gitea binary during the first init
(`init.sh`), which also creates the database role and prepares the work dir on
the volume. The very first start of `web` fails on purpose (`start.sh` exits
until the secrets land in the environment) and Zerops restarts it with them
present – there is nothing to prepare by hand.

## 2. Collect the admin credentials

There is no step here — `admin-init.sh` has already run. Registration is
disabled and Gitea has no bootstrap endpoint, so the recipe creates the first
user the only way there is, from inside the service, and then publishes what it
made the same way it publishes Gitea's own secrets:

| Variable                | What it is                                             |
| ----------------------- | ------------------------------------------------------ |
| `GITEA_ADMIN_USERNAME`  | the admin's name, `mate` unless you changed it          |
| `GITEA_ADMIN_PASSWORD`  | its password, generated                                |
| `GITEA_ADMIN_TOKEN`     | an API token scoped `all`, for automation              |

Read them in the GUI under the `web` service's **Environment variables**, or
with `zcli`. Nothing is printed to the log and nothing is passed on argv, so the
values exist only in the environment.

Reading them over the API needs an **integration token**, not a user session: a
user access token answers `REDACTED` for anything marked sensitive. One scoped to
this project alone is enough — `roleCode: NO_ACCESS` at the organization with
`projects: [{projectId, roleCode: "ADMIN"}]`.

To rotate them, delete `GITEA_ADMIN_TOKEN` and restart the service: a fresh
password and token are minted and republished. The token being replaced stays
valid until you remove it — Gitea's CLI cannot delete one — so if you are
rotating because a token leaked, revoke the old entries under **Settings →
Applications** as well.

To use a different name, set `GITEA_ADMIN_USERNAME` in `zerops.yaml` before the
first start.

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
   ssh://zerops@git.example.com:2222/you/repo.git
   ```

## 5. Optional addon: CI runners (Gitea Actions)

Gitea Actions is enabled by default; what's missing are runners to execute the
jobs. This addon imports a `runner` service into the existing project — each of
its containers registers itself as a separate runner and picks up jobs
directly on the container (**host mode**, no Docker involved), using the
[`gitea-runner` binary](https://docs.gitea.com/runner/installation/binary/).

First get a registration token. With the admin token from step 2 that is one
call:

```sh
curl -X POST -H "Authorization: token $GITEA_ADMIN_TOKEN" \
  https://<your-gitea>/api/v1/admin/actions/runners/registration-token
```

The Gitea UI has the same thing under **Site administration → Actions → Runners
→ Create new Runner**, and inside the `web` service `gitea actions
generate-runner-token --config /etc/gitea/app.ini` works once the server is up.

Put the token into `zerops-runner-import.yaml` in place of `<generated-token>`
and import it into the project (**Import services** in the GUI, or zcli):

```sh
zcli project service-import zerops-runner-import.yaml
```

```yaml
services:
  - hostname: runner
    type: ubuntu@26.04
    vault:
      RUNNER_REGISTRATION_TOKEN:
        value: <generated-token>
        sensitive: true
    minContainers: 3
    verticalAutoscaling:
      minRam: 0.5
    buildFromGit: https://github.com/zeropsio/recipe-gitea
    zeropsSetup: runner
```

Each container registers itself on its first start — one runner per
container, named after the container's hostname — and shows up as idle under
**Site administration → Actions → Runners**. (Without a valid token the
containers just keep restarting until one lands in
`RUNNER_REGISTRATION_TOKEN`, so a forgotten or rotated token is fixed by
setting the variable, no re-import needed.)

Try it out: in any repo, enable Actions (**Settings → Units**, on by default
for new repos) and push a workflow:

```yaml
# .gitea/workflows/demo.yaml
name: demo
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "hello from $(hostname)"
```

**Scaling** is just the service's horizontal scaling: the import starts with 3
containers to make the pattern visible, and changing the range in the GUI
adds or removes runners — every new container registers itself with the same
token.

**Deploying to Zerops from workflows:** the runner image ships
[zcli](https://github.com/zeropsio/zcli), so Gitea Actions can drive your
Zerops deployments. Create a Zerops integration token scoped to just the target
project (in the GUI under "Access Token Management") and store it
as the repo's `ZEROPS_TOKEN` secret (**Settings → Actions → Secrets**) - zcli
picks that env variable up directly, no `zcli login` needed and nothing is
persisted on the shared runner:

```yaml
# .gitea/workflows/deploy.yaml
name: deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Deploy
        env:
          ZEROPS_TOKEN: ${{ secrets.ZEROPS_TOKEN }}
        run: zcli push <service> --project-id <project-id> --version-name "${GITHUB_SHA::7}"
```

**Good to know:**

- Containers are volatile. Every redeploy of the service, scale-down or
  container recreation leaves the old registrations behind as *offline*
  runners in **Site administration → Actions → Runners**. That's harmless —
  jobs are only sent to online runners — just delete the stale entries there
  (or via `DELETE /api/v1/admin/actions/runners/{id}`) whenever they bother
  you. Scaling down doesn't drain: a container removed mid-job fails that
  job.
- Host mode runs job steps directly on the runner container as the `zerops`
  user. `docker://` actions, `container:` jobs and `services:` blocks won't
  work — stick to plain `run:` steps and JS actions (`actions/checkout` works;
  that's why the recipe installs `nodejs` and `git`). Add whatever else your
  jobs need to the `prepareCommands` of the `runner` setup in `zerops.yaml`.
- Anyone who can push a workflow to the instance runs code on the runner
  containers, including access to their environment variables. Treat the
  runners as shared by everyone you give push access to.

## 6. Take ownership, customize, extend

The `web` service is built from this repository, so to make changes fork or
clone it, edit what you need and deploy it as your own:

- `app.ini` – Gitea configuration; values in `{{.VAR}}` are filled from the
  service's environment variables at start (`zsc envReplace`). The API answers
  cross-origin requests (`[cors]`), which is what lets a browser-based client
  read this instance; no credentials are allowed with them, so a Gitea session
  cookie is never usable from another origin.
- `zerops.yaml` – build/run recipe: Gitea version, installed packages, ports,
  environment variables.
- `init.sh` / `start.sh` – one-time init (database, work dir, secrets) and
  the start command.
- `admin-init.sh` – the first admin user and its API token, published as
  environment variables.
- `runner-init.sh` / `zerops-runner-import.yaml` – the CI runners addon:
  per-container registration, and the service import.

Deploy your version with `zcli push web` from the clone, or point the service
at your own git repository (**Build & deploy → connect repository**) for
automatic deploys on push.
