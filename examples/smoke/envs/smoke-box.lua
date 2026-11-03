-- Smoke test of the container target: the same units in a container
-- named teken-smoke, with one volume as state.
return {
    target = "container",
    units = {"smoke", "luam-deps", "luam"},
    container = {
        name = "teken-smoke",
        -- Fully qualified: rootless podman refuses short names it cannot
        -- resolve without prompting.
        base = "docker.io/library/ubuntu:24.04",
        command = {"sleep", "infinity"},
    },
    state = {{path = "/data", volume = "teken-smoke-data"}},
}
