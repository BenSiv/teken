-- Smoke test of the home target: a dotfile linked into a scratch
-- folder (~/.teken-smoke), and luam built from GitHub onto PATH.
return {
    target = "home",
    units = {"smoke", "luam"},
}
