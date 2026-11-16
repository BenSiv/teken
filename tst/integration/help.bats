load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "no arguments prints top-level help and exits 1" {
    run "$TKN"
    [ "$status" -eq 1 ]
    [[ "$output" == "Usage: tkn <command>"* ]]
    [[ "$output" == *"tkn <command> -h or --help for more info"* ]]
}

@test "-h and --help print top-level help and exit 0" {
    run "$TKN" -h
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: tkn <command>"* ]]

    run "$TKN" --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: tkn <command>"* ]]
}

@test "per-command -h and --help print command help without needing an env file" {
    for cmd in plan build switch rollback gens status lock update gc; do
        run "$TKN" "$cmd" -h
        [ "$status" -eq 0 ]
        [[ "$output" == "Usage: tkn $cmd"* ]]
        [[ "$output" == *"Description:"* ]]

        run "$TKN" "$cmd" --help
        [ "$status" -eq 0 ]
        [[ "$output" == "Usage: tkn $cmd"* ]]
    done
}

@test "switch help documents confirmation and container flags" {
    run "$TKN" switch --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"-y --yes"* ]]
    [[ "$output" == *"--discard-undeclared"* ]]
}

@test "unknown command fails with top-level help, with or without -h" {
    run "$TKN" nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown command nope"* ]]
    [[ "$output" == *"Usage: tkn <command>"* ]]

    run "$TKN" nope -h
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown command nope"* ]]
    [[ "$output" == *"Usage: tkn <command>"* ]]
}
