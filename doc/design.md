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
    requires_teken = "0.1.0",
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
        env = {TZ = "Asia/Jerusalem"},
        entrypoint = {"/root/.teken/start"},
    },
    keep = 3,   -- generations kept, active one included
}
```

`vars` work as in seder: `${name}` from `vars` plus built-ins (`home`,
`user`, `uid`, `env` for the env's name), and a leading `~/` becomes the
home directory of the side that uses the path (host for `bind`, container
otherwise).

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
         env = {LUAM_DIR = "${source.luam}"},
         cmd = "bash bld/build.sh",
         install = {["bin/brex"] = "bin/brex"}},
    },
    verify = {"luam -v", "brex --version"},
}
```

| Field | What it declares | Targets |
|---|---|---|
| `apt` | Packages installed in the image | container |
| `fetch` | Files by URL with `sha256` (installers, .deb, certificates) | both |
| `sources` | Git repos, pinned to a commit by the lock, used by builds | both |
| `build` | Commands run in a source; `install` copies outputs into the generation | both |
| `files` | Files placed in the generation, from the spec or inline | both |
| `links` | Paths outside the generation that point into it | home |
| `env` | Environment variables for the env's shell | both |
| `verify` | Commands that must exit 0 in the built generation | both |

A unit that uses a field its env's target can't handle is a load error
that names the unit and field.

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
| health | Run `verify` again against the live generation | Target switches back |
| commit | Mark the generation active; remove generations beyond `keep` | -- |

The **generation id** is a hash of the resolved env (after var expansion),
the lock entries it uses, the contents of every spec file it reads, and
the teken version. The same spec and lock always give the same id, so
`tkn switch` on an unchanged spec is a no-op, and `tkn status` reports
drift by comparing the active id with the one the spec would build.

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

**Generation:** an OCI image tagged `teken/<env>:<id>`.

**Build:** teken renders a Containerfile into the store
(`gens/<id>/Containerfile`, kept for inspection) and runs `podman build`.
Its layers follow unit order so podman's layer cache does the step
caching: base image by digest; `apt` (one layer); `fetch`; each
source + build; `files`; `env`; a generated `/root/.teken/start`
entrypoint. Build secrets go through `podman build --secret`, so they
never land in image history.

**Verify:** `podman run --rm teken/<env>:<id> sh -c '<verify cmds>'`, with
no state volumes mounted, so a candidate can never touch live data.

**Activate:**

1. Create `<name>-next` from the new image with the declared state
   mounts (created, not started).
2. Check the active container's writable layer (`podman diff`). Changes
   outside declared state paths would be lost by the swap; teken lists
   them and stops unless `--discard-undeclared` is given.
3. Stop `<name>`; rename it to `<name>-prev` (removing the older `-prev`
   only at commit).
4. Rename `<name>-next` to `<name>` and start it.
5. Health: `verify` through `podman exec`, plus "still running after N
   seconds".

Rollback: stop and remove the new `<name>`, rename `<name>-prev` back,
start it. The old image is never removed before commit, and `keep` decides
how many old images stay for `tkn rollback`.

**Runtime start:** `/root/.teken/start` does only what can't be baked into
the image: ensure state paths exist, clone missing state repos, create
links into bind mounts, run the declared `start` commands, then `exec` the
command. It is generated from the spec, idempotent, and never builds.

## Target: home

**Generation:** a directory, `~/.local/state/teken/<env>/gens/<id>/`,
holding `bin/`, `files/`, `env.sh` and `meta.lua`.

**Build:** in `gens/<id>.tmp/`, renamed to `gens/<id>/` only when every
step and `verify` succeeded, so a partial build never looks complete.
Build steps run on the host in a scratch checkout of each source at its
locked commit (not hermetic: they see the host's compilers and
libraries). Step outputs are cached in `~/.local/state/teken/steps/<hash>/`
and reused across generations and envs.

**Activate:** `~/.local/state/teken/<env>/current` is a symlink to the
active generation. Activation creates `current.new` pointing at the new
one and `rename(2)`s it over `current`, which is atomic. Every declared
link points through `current`
(`~/.bashrc -> ~/.local/state/teken/home/current/files/bashrc`), and one
PATH entry covers all binaries (`.../current/bin`), so the whole content
of the environment changes in that one rename.

### The link set

Content changes are atomic; changes to *which* links exist are not,
because each link is its own path. teken orders them so the gap is
harmless and journals them in the intent record:

- links added by the new generation are created **after** the rename;
- links dropped by it are removed **after** the rename;
- a real file where a new link goes is moved to
  `~/.local/state/teken/<env>/adopted/` (never deleted), and rollback
  puts it back.

A crash between the rename and the link updates is completed or undone by
the intent record on the next run.

## State

Each state entry is a path plus where it lives: `volume` (container),
`bind` (host path), or, for home, just the path (teken only checks it is
not inside a generation). teken:

- refuses an env whose `files`, `links` or `install` paths fall inside a
  state path, or the other way around;
- creates missing state paths on first activation, and clones state repos
  (`{path = "/root/src/software", git = "..."}`) only when the path is
  missing;
- never modifies, pulls or deletes inside a state path.

Data migrations (a schema change in a state database) are out of scope
for the first version. When added, they will be declared steps that run
after a backup the spec names, during activation, and they will be part
of rollback.

## Secrets

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
src/store.lua           -- generations, intent records, keep/gc
src/lifecycle.lua       -- the phases, rollback on failure
src/shell.lua           -- every command goes through here (stubbed in tests)
src/targets/container.lua
src/targets/home.lua
bld/build.sh            -- static build through luam, like seder
tst/unit/, tst/integration/  -- integration tests drive tkn against stub podman/git
```

A target implements `validate(env)`, `build(env, gen)`, `verify(gen)`,
`activate(from, to)`, `rollback(from, to)`, `active()` and `remove(gen)`.
Adding a target (a bootc host, a remote machine) means adding one module.

## Not in scope

- Building or tracking packages; dependency resolution; hermetic builds.
- System packages on a mutable host. A possible later target is a host
  built as an image and switched with bootc.
- Remote hosts, inventories, fleets.
- Data migrations (see [State](#state)).

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
