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

Written in [luam](https://github.com/BenSiv/luam).

- Design: [doc/design.md](doc/design.md)
