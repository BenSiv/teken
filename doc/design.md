# teken design

teken (Hebrew תקן, "standard", "spec") builds working environments from a
declarative spec written in luam data files, and switches to them all at
once or not at all. The CLI is `tkn`.

## Principles

1. **Never change a running environment.** A new environment is built
   beside the active one, checked, then swapped in by one atomic step. A
   failure anywhere before that step leaves the active environment exactly
   as it was.
2. **Keep the previous one.** Every activation keeps the generation it
   replaced. Rollback is the same atomic step pointed backwards.
3. **An orchestrator, not a package manager.** teken composes tools that
   already exist (podman, apt inside images, git, the projects' own build
   scripts). It never builds, tracks or resolves packages itself. A feature
   that needs a package store, hermetic builds or dependency resolution is
   out of scope.
4. **Specs are data.** Env and unit files run in luam's data-only sandbox
   (no `os`, `io`, `require`), return a table, and are validated in full
   before anything runs.
5. **State is declared.** Anything that must outlive a generation (repos,
   databases, caches) is listed as state and kept on a volume or outside
   the generation. Everything else is rebuilt every time and may be thrown
   away.
6. **Say what is guaranteed.** Where a step is not atomic (see
   [Home: the link set](#the-link-set)), the docs and the output say so.

## Concepts

| Term | Meaning |
|---|---|
| **spec** | A directory of env and unit files, kept in its own repo |
| **env** | One environment to build and activate: a target and the units it uses |
| **target** | How an env is built and activated: `container` or `home` |
| **unit** | A reusable group of things to put in an env (packages, sources, builds, files) |
| **generation** | One immutable, fully built result of an env; identified by a hash |
| **lock** | Pins every input that can change under the same spec |
| **state** | Paths that outlive generations; declared, never rebuilt |
| **secret** | A named value supplied at build or activation, never stored in a generation |

## Spec layout

```
envs/devenv.lua       -- one env: target, units, state, target options
envs/home.lua
units/base-tools.lua  -- what to put in an env, by kind
units/luam-stack.lua
lock.lua              -- written by tkn, committed with the spec
```

`tkn <command> envs/devenv.lua` names an env. With no argument, `tkn`
reads `envs/<hostname>.lua` from the current directory (like seder).

## Env files

```lua
-- envs/devenv.lua
return {
    requires_teken = "0.3.0",
    target = "container",
    vars = {rnd_path = "~/rnd"},
    units = {"base-tools", "cloud-clis", "luam-stack", "python", "dotfiles"},
    state = {
        {path = "/root/src", volume = "devenv-src"},   -- repos and worktrees
        {path = "/data", volume = "celleste-bensiv-data"},
        {path = "/root/rnd", bind = "${rnd_path}"},
    },
    secrets = {
        github_token = {from = "env:GITHUB_TOKEN", use = "build"},
    },
    container = {
        name = "celleste-bensiv",
        base = "ubuntu:24.04",
        hostname = "celleste-bensiv",
        ports = {"8000:8000", "8080:8080"},
        tty = true,
        restart = "always",
        command = {"bash"},
        ephemeral = {"/root/.cache"},   -- may change without being state
    },
    keep = 3,   -- generations kept, active one included
}
```

`container` fields: `name` and `base` (required), `hostname`, `ports`,
`tty`, `restart`, `command`, `home` (default `/root`), `ephemeral` (see
[Activate](#target-container)), `health_wait` (seconds before the
health check, default 3), `start_timeout` (seconds the health check
waits for [start](#runtime-start), default 300), `passenv` (host
environment variables passed through when the container is created)
and `sockets` (host paths, `$VAR` expanded from tkn's environment when
the container is created, bind-mounted at the same path; skipped when
missing). `passenv` and `sockets` belong to the session running tkn, so
their values are not part of the generation.

`vars` work as in seder: `${name}` from `vars` plus built-ins (`home`,
`user`, `uid`, `env` for the env's name), and a leading `~/` becomes the
home directory of the side that uses the path: the host's in a `bind`,
otherwise the env's (the user's for a home env, `container.home` for a
container env). A `~` inside a var stays until the var is used, so one
var can serve both sides.

## Unit files

```lua
-- units/luam-stack.lua
return {
    apt = {"build-essential", "libreadline-dev", "libsqlite3-dev"},
    sources = {
        luam = {git = "https://github.com/BenSiv/luam"},
        brex = {git = "https://github.com/BenSiv/brain-ex"},
    },
    build = {
        {name = "luam", from = "luam",
         cmd = "bash bld/build_lang.sh && bash bld/build_libs.sh",
         install = {["bin/luam"] = "bin/luam"}},
        {name = "brex", from = "brex", needs = {"luam"},
         env = {LUAM_DIR = "${build.luam}"},
         cmd = "bash bld/build.sh",
         install = {["bin/brex"] = "bin/brex"}},
    },
    verify = {"luam -v", "brex --version"},
}
```

| Field | What it declares | Targets |
|---|---|---|
| `apt` | Packages installed in the image | container |
| `fetch` | Files by URL (`url`, `path`, `mode`), their sha256 pinned by the lock | both |
| `sources` | Git repos, pinned to a commit by the lock, used by builds | both |
| `build` | Commands run in a source; `install` copies outputs into the generation | both |
| `files` | Files placed in the generation (`path`, then `source` in the spec or inline `content`; `mode`) | both |
| `links` | Paths outside the generation (`path`) that point into it (`target`, relative to the generation), or into state (an absolute `target` inside a state path) | both |
| `env` | Environment variables for the env's shell | both |
| `verify` | Commands that must exit 0 in the built generation | both |
| `repos` | Checkouts (`path` inside a state path, `git`), cloned only when the path is missing | both |
| `start` | Commands run on every container start (`name`, `cmd`, `background`) | container |

A unit that uses a field its env's target can't handle is a load error
that names the unit and field.

A build step runs in a fresh checkout of its source at the pinned
commit. `needs` lists earlier steps it uses, and `${build.<step>}` is
the finished tree of one of them (a step may only refer to steps in its
`needs`). Finished trees stay in the store for as long as a kept
generation uses them, so a binary may keep paths into its tree.

There is no `absent` and there are no `creates`/`unless` guards. Anything
not declared is simply not in the next generation, and build steps never
rerun in place, so they need no guard. They are cached by the hash of
their inputs instead.

### Sources and state are different things

`sources` are read-only inputs: teken clones them at the locked commit to
build from. The checkouts you work in (`~/software`, worktrees) are
**state**: they live on a declared volume, and teken never touches them
after the first clone (see [State](#state)).

## Lifecycle

```
eval -> lock -> build -> verify -> activate -> health -> commit
                                        \-> rollback on any failure
```

| Phase | What happens | On failure |
|---|---|---|
| eval | Load env and units in the sandbox; validate; expand vars; compute the generation id | Nothing ran |
| lock | Check that every input is pinned in `lock.lua` (`tkn update` is the only thing that moves pins) | Nothing ran |
| build | Produce the generation in isolation, steps cached by input hash | Active env untouched; partial build discarded |
| verify | Run `verify` commands inside the candidate, without live state | Active env untouched; candidate kept for inspection |
| activate | The target's atomic switch, after an intent record is written | Target switches back |
| health | Run the generation's own `verify` (recorded in its `meta.lua` at build) against it live | Target switches back |
| commit | Mark the generation active; remove generations beyond `keep` | -- |

The **generation id** is a hash of the resolved env (after var expansion),
the lock entries it uses, the contents of every spec file it reads, and
the teken version. The same spec and lock always give the same id, so
`tkn switch` on an unchanged spec is a no-op, and `tkn status` reports
drift by comparing the active id with the one the spec would build.

A generation records how it runs (its verify commands and env vars, its
state and `repos`; for a container, its container section, state mounts
and whether its image has a [start](#runtime-start) script to wait for)
in `meta.lua`.
Activation always uses the record of the generation being activated, so
`tkn rollback` brings back the old generation exactly as it was built,
even after the spec has moved on.

### Intent records and crash recovery

Before activating, teken writes `activating: <from> -> <to>` to the
target's store. It is removed at commit or after rollback. If teken finds
one at startup (power loss, killed process), it finishes the rollback to
`<from>` before doing anything else and reports what it did. Activation
steps are written so this is always possible: nothing is deleted until
commit.

## Lock

`lock.lua` is data, written only by `tkn lock` / `tkn update`, and
committed with the spec:

```lua
return {
    images = {["ubuntu:24.04"] = "sha256:..."},
    sources = {luam = {git = "https://github.com/BenSiv/luam", commit = "a1b2c3d"}},
    fetch = {["https://.../awscli-exe-linux-x86_64.zip"] = "sha256:..."},
}
```

Pinned: base image digests, git commits, URL hashes. Not pinned: apt
package versions. They float within the pinned base image and its apt
snapshot at build time, because mirrors drop old versions. A spec that
needs a specific version uses `fetch` for that `.deb`.

`tkn update [name...]` moves pins forward (all, or the named inputs) and
prints what changed. `tkn plan` then shows the effect on each env.

## Target: container

**Generation:** an OCI image tagged `teken/<env>:<id>`. Inside it the
generation lives at `/opt/teken` (`bin/` first on PATH, `files/`, ...),
laid out as in the home target, so one unit serves a home env and a
container env alike. `links` become symlinks in the image.

**Build:** teken lays out a build context in `gens/<id>.tmp/`: a
checkout of each build step's source at its pinned commit, the step's
script, fetched files and spec files. Sources are cloned on the host
with the host's git credentials, so private repos need no token inside
the build. It then renders a Containerfile and runs `podman build`:

1. `FROM <base>@<digest>`;
2. `apt` packages, one layer;
3. per build step: copy its checkout to `/opt/teken-build/<step>`, run
   it there (`${build.<step>}` is that path), copy its `install` paths
   into `/opt/teken`;
4. fetched files, spec files, links;
5. `ENV` for PATH and the env's vars; labels `teken.env` and `teken.id`.

podman's layer cache decides which steps rerun. Step trees stay in the
image so built binaries may keep paths into them. The Containerfile is
kept in `gens/<id>/` for inspection.

**Verify:** each `verify` command runs in a throwaway container of the
new image (`podman run --rm`), with no state mounted, so a candidate can
never touch live data. A failed verify keeps the image for inspection.

**Activate:**

1. If a container with the name exists that teken did not create
   (there is no active generation), stop: teken never replaces a
   container it doesn't own.
2. Check the running container's own layer (`podman diff`). Changes
   outside declared state, `container.ephemeral` and scratch paths
   (`/tmp`, `/run`, `/var/tmp`, `/var/cache`, `/var/log`, ...) would be
   lost by the swap; teken lists them and stops unless
   `--discard-undeclared` is given.
3. Create `<name>-next` from the new image with the declared state
   mounts.
4. Stop `<name>` and rename it to `<name>-<from id>`.
5. Rename `<name>-next` to `<name>`, start it, point `current` at the new
   generation.
6. Health: after `health_wait` seconds the container must be running,
   and every `verify` command must pass through `podman exec`.

**Rollback** undoes whatever of 3-5 happened: removes `<name>-next` and
a `<name>` running the new generation, renames `<name>-<from id>` back
and starts it, points `current` back. **Commit** removes
`<name>-<from id>`. `tkn rollback` later creates a fresh container from
the previous image; nothing is lost, since state lives on the declared
volumes and bind mounts. Images of generations that drop out of `keep`
are removed.

### Runtime start

What can't be baked into the image happens when the container starts,
in a generated entrypoint, `/opt/teken/start` (kept as `gens/<id>/start`
and checked with `sh -n` before the image build). On every start it:

1. creates the state paths;
2. clones each `repos` entry whose path is missing. A failed clone (no
   network, no credentials yet) is a warning: the next start retries;
3. runs the `start` entries in order. A failing one stops the start;
   `background = true` runs an entry detached, logged to
   `/var/log/teken/<name>.log`, and never restarted if it dies;
4. execs the container's command (`bash` when there is none).

It writes `running`, then `done` or `failed`, to `/run/teken/start.status`.
The health check waits for `done` (at most `start_timeout` seconds), so a
failed start, or a container that stops while starting, rolls the switch
back. `start` entries run again on every restart and must be idempotent.
They may change state (restore a database into a volume); rollback does
not undo that.

Links into state (an absolute `target`) are symlinks baked into the
image; they dangle until the state is mounted. A file something writes
over one of them later is a change in the container's own layer, so the
next switch lists it before it would be lost.

## Target: home

The store root is `~/.local/state/teken`, or `$TEKEN_STATE` when set.

**Generation:** a directory, `~/.local/state/teken/envs/<env>/gens/<id>/`,
holding `bin/`, `files/`, `env.sh` and `meta.lua`.

**Build:** in `gens/<id>.tmp/`, renamed to `gens/<id>/` only when every
step and `verify` succeeded, so a partial build never looks complete.
Build steps run on the host in a scratch checkout of each source at its
locked commit (not hermetic: they see the host's compilers, libraries
and `$HOME`). Step outputs are cached in `~/.local/state/teken/steps/<hash>/`
and reused across generations and envs.

**Activate:** state paths are created and missing `repos` cloned (a
failed clone is a warning). `~/.local/state/teken/envs/<env>/current` is a symlink to the
active generation. Activation creates `current.new` pointing at the new
one and `rename(2)`s it over `current`, which is atomic. Every declared
link points through `current`
(`~/.bashrc -> ~/.local/state/teken/envs/home/current/files/bashrc`), and one
PATH entry covers all binaries (`.../current/bin`), so the whole content
of the environment changes in that one rename. A link into state (an
absolute target) points straight at its target and is placed, adopted
and dropped like the others.

### The link set

Content changes are atomic; changes to *which* links exist are not,
because each link is its own path. teken orders them so the gap is
harmless and journals them in the intent record:

- links added by the new generation are created **after** the rename;
- links dropped by it are removed **after** the rename;
- a real file where a new link goes is moved to
  `~/.local/state/teken/envs/<env>/adopted/` (never deleted), and rollback
  puts it back.

A crash between the rename and the link updates is completed or undone by
the intent record on the next run.

## State

Each state entry is a path plus where it lives: `volume` (container),
`bind` (host path), or, for home, just the path (teken only checks it is
not inside a generation). teken:

- refuses an env whose `files`, `links` or `install` paths fall inside a
  state path, or the other way around;
- creates missing state paths on activation (home) or start (container),
  and clones `repos` entries only when their path is missing;
- never modifies, pulls or deletes inside a state path.

Data migrations (a schema change in a state database) are out of scope
for the first version. When added, they will be declared steps that run
after a backup the spec names, during activation, and they will be part
of rollback.

## Secrets

Not built yet; env files with `secrets` are rejected until it is.
Private git sources need no secret: they are cloned on the host.

Declared per env with a source (`env:NAME`, `file:/path`,
`cmd:camopass show github/work-token`) and a use (`build` or `run`).
Build secrets go through `podman build --secret`, run secrets through
`podman secret` or a file mounted at activation. teken never writes a
secret value into a generation, a log, the lock or the store; `tkn plan`
shows secrets by name only.

## CLI

```
tkn plan     [env]      # what switch would build and change; nothing runs
tkn build    [env]      # eval, lock check, build, verify; no activation
tkn switch   [env] [-y] # the full lifecycle
tkn rollback [env]      # activate the previous kept generation
tkn gens     [env]      # list generations; mark the active one
tkn status   [env]      # active id vs the id the spec would build
tkn lock     [env]      # pin inputs not yet in lock.lua
tkn update   [name...]  # move pins forward; print what changed
tkn gc                  # remove generations and cached steps nothing keeps
tkn --version
```

Exit codes: 0 done (or nothing to do), 1 failed and rolled back cleanly,
2 `status`/`plan` found differences, 3 failed and could not roll back
(the message says what state it left and why).

## Code layout

```
src/main.lua            -- CLI
src/loader.lua          -- sandboxed loading, validation, var expansion
src/lock.lua            -- read, check and update lock.lua
src/hash.lua            -- generation and step ids
src/data.lua            -- teken's own data files, written atomically
src/store.lua           -- generations, history, intent records, run lock
src/lifecycle.lua       -- the phases, rollback on failure, gc
src/sources.lua         -- git mirrors and checkouts at pinned commits
src/shell.lua           -- every command goes through here
src/targets/home.lua
src/targets/container.lua
bld/build.sh            -- static build through luam, like seder
tst/unit/, tst/integration/  -- integration tests use local git repos and a fake podman
```

A target implements:

| Function | Does |
|---|---|
| `build(env, pins, id)` | Builds and verifies generation `id`; reuses one already built |
| `has_gen(name, id)` | Whether generation `id` is built and usable |
| `activate(env, from, to, options)` | Switches to `to`, health check included; errors on failure |
| `rollback(env, intent)` | Undoes an activation `{from, to}` from any point it reached |
| `commit(env, from, to)` | Optional: drops what was kept for rollback |
| `remove(name, id)` | Removes a generation that dropped out of history |
| `steps(env, pins)`, `link_changes(env, from)` | What `tkn plan` shows |

Adding a target (a bootc host, a remote machine) means adding one module.

## Not in scope

- Building or tracking packages; dependency resolution; hermetic builds.
- System packages on a mutable host. A possible later target is a host
  built as an image and switched with bootc.
- Remote hosts, inventories, fleets.
- Data migrations (see [State](#state)).
- Supervising start's background entries (restarts, health), and
  `start` for home envs.

## Open questions

- **Base apt snapshot:** pin `snapshot.ubuntu.com` by date in the lock to
  make apt layers reproducible too?
- **Shared step cache between targets:** build luam tools once on the
  host and copy them into the image, or always build inside the image so
  they link against its libraries? The second is safer and is the default
  until measured.
- **Health beyond `verify`:** is "still running after N seconds" plus the
  verify commands enough, or do envs need their own `health` field?
- **Home builds against host libraries:** a host apt upgrade can break a
  home generation without its id changing. Detect it (record library
  versions in `meta.lua`) or accept it?
