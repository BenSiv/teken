-- CLI help text for `tkn` and its subcommands.

help = {}

HELP_STRINGS = {
    ["tkn"] = """
Usage: tkn <command> [env.lua] [options]

  plan     [env]          what switch would build and change; nothing runs
  build    [env]          build and verify the spec's generation, no activation
  switch   [env] [-y]     build, verify, activate, health check; roll back on failure
  rollback [env] [-y]     activate the previous generation
  gens     [env]          list generations; * marks the active one
  status   [env]          exit 2 when the active generation is not the spec's
  lock     [env]          pin inputs not yet in lock.lua
  update   [env] [name..] move pins forward (all, or the named inputs)
  gc                      remove generations and build steps nothing keeps
  --version

env defaults to envs/<hostname>.lua. Exit codes: 0 done, 1 failed (rolled
back cleanly), 2 drift (status), 3 failed and could not roll back.

tkn <command> -h or --help for more info
    """,
    ["tkn plan"] = """
Usage: tkn plan [env.lua]

Description:
Evaluates and validates the env spec and shows what `tkn switch` would build
and change without building or activating anything. Reports the active
generation, any unpinned inputs in lock.lua, the target generation id, build
steps (+ to build, = cached), and symlink changes.

Arguments:
[env.lua]  Path to the env file (default: envs/<hostname>.lua).

Options:
-h --help  Show this help message.

Examples:
tkn plan
tkn plan envs/devenv.lua
    """,
    ["tkn build"] = """
Usage: tkn build [env.lua]

Description:
Evaluates the env spec, requires all inputs to be pinned in lock.lua, builds
the candidate generation in isolation, and runs its verify commands without
mounting live state. Does not activate the generation or touch the running
environment. Reuses the generation if it is already built.

Arguments:
[env.lua]  Path to the env file (default: envs/<hostname>.lua).

Options:
-h --help  Show this help message.

Examples:
tkn build
tkn build envs/devenv.lua
    """,
    ["tkn switch"] = """
Usage: tkn switch [env.lua] [options]

Description:
Runs the full lifecycle: builds and verifies the spec's generation, swaps it
in atomically, runs health checks against the live environment, records it in
history, and prunes generations beyond `keep`. Any failure during activation
or health checking rolls back to the previous generation.

For container envs, refuses to replace a running container that has changes
outside declared state and container.ephemeral unless --discard-undeclared is
given.

Arguments:
[env.lua]               Path to the env file (default: envs/<hostname>.lua).

Options:
-y --yes                Skip confirmation prompt (required when stdin is not a TTY).
   --discard-undeclared (container) Replace the container even when its own layer
                        has changes outside declared state.
-h --help               Show this help message.

Exit codes:
0  Switched (or already at the spec's generation).
1  Failed before activation, cancelled, or failed and rolled back cleanly.
3  Activation failed and automatic rollback also failed.

Examples:
tkn switch
tkn switch envs/devenv.lua -y
tkn switch envs/devenv.lua -y --discard-undeclared
    """,
    ["tkn rollback"] = """
Usage: tkn rollback [env.lua] [options]

Description:
Activates the generation immediately before the active one in history, using
that generation's own recorded settings and verify commands.

For container envs, refuses to replace a running container that has changes
outside declared state and container.ephemeral unless --discard-undeclared is
given.

Arguments:
[env.lua]               Path to the env file (default: envs/<hostname>.lua).

Options:
-y --yes                Skip confirmation prompt (required when stdin is not a TTY).
   --discard-undeclared (container) Replace the container even when its own layer
                        has changes outside declared state.
-h --help               Show this help message.

Exit codes:
0  Rolled back to the previous generation.
1  No previous generation, cancelled, or failed and restored the prior state.
3  Activation failed and recovery also failed.

Examples:
tkn rollback
tkn rollback envs/devenv.lua -y
    """,
    ["tkn gens"] = """
Usage: tkn gens [env.lua]

Description:
Lists generations of the environment from newest to oldest, with `*` marking
the active generation and timestamps from build metadata. Also lists any
generations on disk that were built (for example with `tkn build`) but never
activated.

Arguments:
[env.lua]  Path to the env file (default: envs/<hostname>.lua).

Options:
-h --help  Show this help message.

Examples:
tkn gens
tkn gens envs/devenv.lua
    """,
    ["tkn status"] = """
Usage: tkn status [env.lua]

Description:
Prints the same plan summary as `tkn plan` and checks whether the active
generation matches what the spec would build.

Arguments:
[env.lua]  Path to the env file (default: envs/<hostname>.lua).

Options:
-h --help  Show this help message.

Exit codes:
0  All inputs are pinned and the active generation matches the spec.
1  Spec validation or runtime error.
2  Drift: inputs are unpinned or the active generation differs from the spec.

Examples:
tkn status
tkn status envs/devenv.lua
    """,
    ["tkn lock"] = """
Usage: tkn lock [env.lua]

Description:
Resolves and records pins in lock.lua for any inputs of the env that are not
yet pinned (base image digests, git source commits, and fetched URL sha256
digests). Existing valid pins are left untouched; use `tkn update` to move
them forward.

Arguments:
[env.lua]  Path to the env file (default: envs/<hostname>.lua).

Options:
-h --help  Show this help message.

Examples:
tkn lock
tkn lock envs/devenv.lua
    """,
    ["tkn update"] = """
Usage: tkn update [env.lua] [name...]

Description:
Moves pins in lock.lua forward to what their image tags, git refs, or URLs
currently resolve to, and prints each change. When one or more input names are
given, only those inputs (plus any unpinned inputs) are resolved; otherwise
all inputs of the env are updated.

Arguments:
[env.lua]  Path to the env file, matched by .lua suffix (default: envs/<hostname>.lua).
[name...]  Source names, base image tags, or fetch URLs to update.

Options:
-h --help  Show this help message.

Examples:
tkn update
tkn update envs/devenv.lua
tkn update envs/devenv.lua luam brex
tkn update luam
    """,
    ["tkn gc"] = """
Usage: tkn gc

Description:
Removes generations across the store ($TEKEN_STATE or ~/.local/state/teken)
that are no longer in their env's history (including container images and
built-but-never-activated candidates), along with cached build steps not used
by any kept generation. Git mirrors and fetched-file caches are kept.

Arguments:
None.

Options:
-h --help  Show this help message.

Examples:
tkn gc
    """,
}

function get_help_string(command)
    s = HELP_STRINGS[command]
    if s == nil then
        return nil
    end
    return string.dedent(s)
end
help.get_help_string = get_help_string

return help
