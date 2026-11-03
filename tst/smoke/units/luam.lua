-- The luam interpreter, built from GitHub at the commit lock.lua pins.
-- Needs gcc, make and readline headers where it builds (luam-deps
-- installs them in a container).
return {
    sources = {luam = {git = "https://github.com/BenSiv/luam"}},
    build = {
        {name = "luam", from = "luam", cmd = "bash bld/build_lang.sh",
         install = {["bin/luam"] = "bin/luam"}},
    },
    verify = {"luam -e 'print(\"luam ok\")'"},
}
