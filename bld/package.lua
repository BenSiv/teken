-- Declarative static build manifest for teken (`tkn`).
return {
    bin = "tkn",
    entry = "main.lua",
    luam = "581e17f220da6cee2b84002eb6f018836ff5f69a",
    with = {"lfs", "crypto"},
    define_git_commit = "build_commit",
}
