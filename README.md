# teken

Builds working environments from a declarative spec and switches to them
all at once or not at all (Hebrew תקן, "standard", "spec"). The CLI is
`tkn`.

You describe an environment (a dev container, the tools and dotfiles in
your home directory) in luam data files. teken builds a complete new
generation of it beside the one in use, checks it, and swaps it in with
one atomic step. A failure at any point leaves the running environment as
it was, and the previous generation is kept for rollback.

teken is an orchestrator, not a package manager: it composes podman, apt
inside images, git and each project's own build scripts. The spec is
yours: keep it in its own repo and point `tkn` at it.

Written in [luam](../luam/README.md).

- Design: [doc/design.md](doc/design.md)

## Building

Requires a built [luam](../luam/README.md) checkout (`obj/liblua.a` from
`bld/build_lang.sh`), `lib/lfs/lfs.so` and `lib/crypto/crypto.so` (built by
`bld/build_libs.sh` or directly), plus OpenSSL headers/libraries (`libssl-dev`
for `-lcrypto`, linked into the static `bin/tkn` binary). `bld/build.sh` looks
for `luam` at `../luam`; override with `LUAM_DIR`.

```sh
./bld/build.sh          # -> bin/tkn (via bld/package.lua)
```

## Testing

Requires `bats` and `git` on PATH, plus `lib/lfs/lfs.so` and
`lib/crypto/crypto.so` in `LUAM_DIR` (used when `tst/unit/*.lua` runs under
the `luam` interpreter).

```sh
./bld/test.sh
```

Runs the unit tests (`tst/unit/*.lua`) and the integration tests
(`tst/integration/*.bats`), which drive the built binary against a
scratch `$HOME`, a scratch store and local git repos.

[tst/smoke/](tst/smoke/README.md) is a manual test on a real machine,
with real podman, for both targets.

## Specs & Ecosystem

- [luam](../luam/README.md) — language runtime, `lib/` standard library (`data`, `crypto`, `external_tool`, `paths`), and `lib/static/build.lua` bundler
- [configs/teken](../configs/teken/README.md) — personal `teken` specs (`envs/work.lua`, `envs/personal.lua`, and the personal container `envs/devenv.lua`)
- [software/devenv/bensiv](../software/devenv/bensiv/README.md) — Celleste work container spec (`celleste-bensiv`)
