# T3 Code on the home server

[T3 Code](https://t3.codes) in a container, deployed to the home server on every
merge to `master` and reachable from the tailnet only.

## Layout

```text
Dockerfile        the image, with pinned T3 Code and Codex versions
compose.yml       how it runs: port, volumes
bin/deploy        pull, build, restart; what CI triggers on the server
bin/setup-server  one-time server setup (root, re-runnable)
bin/test          shellcheck and every test; what CI runs
tests/            script tests and a real upgrade of the real image
```

## How a deploy works

1. A pull request or a merge to `master` runs shellcheck and the tests. The tests
   build the image, boot it, and upgrade it in place from the previous release.
2. On `master`, CI then connects as `deployer` and names the commit it tested. Its
   key can only run `bin/deploy`, whatever command is requested.
3. `bin/deploy` stops if the checkout was edited or committed to on the server. If
   `master` has moved on from the tested commit, it deploys nothing and leaves that
   to the newer merge's run. Otherwise it pulls, builds, and runs
   `docker compose up -d --wait`.

So only a commit that passed the checks goes live. If the newest merge fails them,
the container stays on what it was running until `master` is fixed.

The image is built on the server, so there is no registry to manage. If the build
fails, the old container keeps running. If the new container never becomes healthy,
the run fails, but the old container is already gone. A new container that fails its
health check keeps running and still answers. One that crashes on start restart-loops
and answers nothing. There is no automatic rollback, so revert the commit.

A deploy restarts the container only when the image or configuration changed. A
restart interrupts running agents, and T3 Code resumes the threads it can.

## Why it is built this way

**Tailnet only.** A pairing grants a shell in the container, and everything behind
nginx on this server is public. The port is published on loopback, and Tailscale
Serve is the way in, like `svc:prowlarr` and `svc:torrent`. Don't publish it more
widely: Docker-published ports bypass ufw.

**Not root.** The container runs as `t3`, UID 10001, which no account on the server
has, with `no-new-privileges` on. Agents run whatever they decide on, and this server
doesn't remap container root, so escaping as root would mean root on the host. This
protects the host, not the container's contents: agents share that user, so they can
read the Codex login and everything else in the volumes.

**Never print the container's logs in CI.** T3 Code writes a live one-time pairing
token to them at startup, and CI output is readable by anyone who can see the
repository.

**Volumes, not all of T3 home.** T3 Code installs itself under
`/var/t3/home/runtime`. A volume there keeps the old release and hides the new one,
so the first upgrade dies with `t3: not found`. These are what persist instead:

| Volume | Mounted at | Holds |
| --- | --- | --- |
| `t3-code_userdata` | `/var/t3/home/userdata` | Threads, settings, paired sessions |
| `t3-code_worktrees` | `/var/t3/home/worktrees` | Agent worktrees |
| `t3-code_home` | `/home/t3` | Codex login, SSH keys, git config, `~/.local` |
| `t3-code_workspace` | `/workspace` | Cloned projects |

**Pinned versions.** The install step is a cached image layer, so an unpinned rebuild
never picks up a new release. Pinned, every upgrade is a commit you can revert.

## Setup

Define a service named `t3` on `tcp:443` in the Tailscale admin console. Then run
this from a clone on your Mac, creating an environment named `Production` limited to
the `master` branch in the repository settings before the first `gh secret set`. Use
the same public host and port that speed-dial's `SSH_HOST` and `SSH_PORT` secrets
hold. Environment secrets on a private repository need a paid GitHub plan.

```bash
git init -b master
git add .
git commit -m 'Initial commit [skip ci]'
gh repo create StefanMermans/t3-code-docker --private --source . --push

keys=$(mktemp -d)
ssh-keygen -q -t ed25519 -N '' -C github-actions@t3-code-docker -f "$keys/ci"
gh secret set SSH_PRIVATE_KEY --env Production < "$keys/ci"
gh secret set SSH_HOST --env Production --body '<public host>'
gh secret set SSH_PORT --env Production --body '<public port>'
ssh-keyscan -t ed25519 stefanserver | grep -v '^#' | cut -d' ' -f2- \
  | gh secret set SSH_HOST_KEY --env Production

scp bin/setup-server stefan@stefanserver:/tmp/
ssh -t stefan@stefanserver "sudo bash /tmp/setup-server '$(cat "$keys/ci.pub")'"
```

`[skip ci]` keeps the first push from deploying to a server that isn't ready.

The first `setup-server` run stops and prints a `gh repo deploy-key add` command. Run
that on your Mac, then repeat the `ssh -t` line. A deploy key added through `gh` is
tied to its login and disappears if you sign `gh` out of GitHub. To avoid that, add
the key in the repository settings instead.

The last step checks that `svc:t3` is approved, because `tailscale serve` reports
success without it. If your tailnet policy doesn't approve it automatically, approve
this machine in the admin console when the script says so, then run it again.

Then start the first deploy and clean up:

```bash
rm -rf "$keys"
gh workflow run deploy.yml --ref master
gh run watch
ssh stefan@stefanserver rm /tmp/setup-server
```

Finally, sign in to Codex and pair a device.

### Signing in to Codex

```bash
ssh -t stefan@stefanserver sudo docker exec -it t3-code codex login --device-auth
```

The login lands in `t3-code_home`, so it survives deploys.

### Pairing a device

```bash
ssh -t stefan@stefanserver sudo docker exec t3-code t3 pair
```

Take the `Token` from the output and open
`https://t3.<tailnet>.ts.net/pair#token=<token>`. Ignore the printed URLs, because
they use the container's internal address. The token lasts five minutes.

## Installing tools

Agents can't install system packages, because the container has no way to become
root on its own.

**Tools that don't need root** go in the home folder, which survives deploys. That
covers `uv`, `pip install --user`, `npm` with a prefix in the home folder, version
managers such as `mise`, and single binaries in `~/.local/bin`, which is on `PATH`.

**System packages** need a root shell, which takes sudo on the server:

```bash
ssh -t stefan@stefanserver sudo docker exec -u root -it t3-code bash
apt-get update
apt-get install -y <package>
```

A package installed this way survives restarts and deploys that change nothing, but
it's gone once a deploy replaces the container. Add anything you want to keep to the
`Dockerfile`. Don't run `t3` or `codex` in that root shell, because they could leave
root-owned files in the volumes that the server can't then write to.

Anything T3 Code downloads for itself under `/var/t3/home/tools` is on no volume, so
it's lost with the container too.

## Known limits

**Codex's sandbox doesn't work here.** It needs user namespaces, which Docker's
defaults block even for root. Use **Full access**, T3 Code's default, and treat the
container as the sandbox. **Supervised** and **Auto** may not be able to run commands
with Codex. Relaxing Docker's restrictions to allow it would weaken the container.

**T3 Code's built-in browser isn't set up.** `t3 browser setup` is meant for a host
machine, and the image doesn't include Chrome's libraries. T3 Code's docs offer
`T3CODE_SERVER_BROWSER_SANDBOX=0` for hosts that can't enable Chrome's sandbox, which
turns that sandbox off. That hasn't been tried here.

## Upgrading T3 Code

Change `T3CODE_VERSION` or `CODEX_RELEASE` in the `Dockerfile` and merge. Current
releases:

```bash
gh release view -R pingdotgg/t3code --json tagName --jq .tagName
```

An app newer than the server can refuse to connect until you do this. The in-app
server update does not stick, because the next rebuild returns to the pinned version.

Moving back to an older release can be blocked once a newer one has changed the
database, so reverting an upgrade is not always clean.

## Tests

```bash
bin/test
```

The tests need Docker. They don't touch a real deployment: they use their own container
name, port, and volumes, and they clean up afterwards.

## Backups

Not backed up yet. To cover it, add a `services/t3-code.conf` to the
[homelab](https://github.com/StefanMermans/homelab) repository and update its coverage
table. `t3-code_userdata` and `t3-code_home` are the volumes that can't be recreated.
