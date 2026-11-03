# Smoke test

A manual test of teken on a real machine, with real podman: the
automated suite (`bld/test.sh`) uses a fake podman and does not run
this. Two small envs, built from the same units:

| Env | Target | What it makes |
|---|---|---|
| `envs/smoke-home.lua` | home | `~/.teken-smoke/rc` linked into the store; `luam` on PATH via `env.sh` |
| `envs/smoke-box.lua` | container | a container `teken-smoke` (Ubuntu 24.04, `sleep infinity`) with the same file, link and `luam`, and a volume `teken-smoke-data` at `/data` |

Neither touches anything else. To keep the test's store apart from a
real one, set `TEKEN_STATE` for the whole session:

```sh
export TEKEN_STATE=~/.local/state/teken-smoke
```

## Build tkn

Needs git, gcc, make and readline headers (`libreadline-dev` /
`readline-devel`); the container test needs podman.

```sh
cd ~/Projects                      # any folder; luam and teken side by side
git clone https://github.com/BenSiv/luam && cd luam
bash bld/build_lang.sh
gcc -O2 -shared -fPIC -Isrc/ -o lib/lfs/lfs.so lib/lfs/src/lfs.c   # or bash bld/build_libs.sh
cd .. && git clone https://github.com/BenSiv/teken && cd teken
./bld/build.sh                     # -> bin/tkn
alias tkn="$PWD/bin/tkn"
cd tst/smoke
```

## Home target

```sh
tkn lock envs/smoke-home.lua               # pins luam's commit in lock.lua
tkn plan envs/smoke-home.lua               # + build luam, + ~/.teken-smoke/rc
tkn switch envs/smoke-home.lua -y          # build, verify, switch, health check
cat ~/.teken-smoke/rc                      # teken smoke test
readlink ~/.teken-smoke/rc                 # .../envs/smoke-home/current/files/smoke-rc
(. "$TEKEN_STATE/envs/smoke-home/current/env.sh" && luam -e 'print(1)')
tkn status envs/smoke-home.lua; echo $?    # 0: active is the spec
tkn switch envs/smoke-home.lua -y          # Nothing to do.
```

Change, then roll back:

```sh
sed -i 's/teken smoke test/teken smoke test 2/' units/smoke.lua
tkn switch envs/smoke-home.lua -y          # luam is cached; only the file changes
cat ~/.teken-smoke/rc                      # ... 2
tkn gens envs/smoke-home.lua               # two generations, * on the new one
tkn rollback envs/smoke-home.lua -y
cat ~/.teken-smoke/rc                      # back to the first
```

Failures must leave the active generation as it was:

```sh
# verify fails in the candidate: nothing switches
sed -i 's/= 1",/= 2",/' units/smoke.lua                 # TEKEN_SMOKE must now be 2
tkn switch envs/smoke-home.lua -y; echo $?  # 1, "verify failed"
git checkout units/smoke.lua

# a real file where a link goes is moved aside (adopted), never deleted
rm ~/.teken-smoke/rc && echo mine > ~/.teken-smoke/rc
sed -i 's/teken smoke test/teken smoke test 3/' units/smoke.lua
tkn switch envs/smoke-home.lua -y          # "adopting ~/.teken-smoke/rc -> .../adopted/..."
cat "$TEKEN_STATE"/envs/smoke-home/adopted/*   # mine
git checkout units/smoke.lua
```

## Container target

```sh
tkn lock envs/smoke-box.lua                # pins the base image digest too
tkn switch envs/smoke-box.lua -y           # podman build, verify in a throwaway container, start
podman ps --filter name=teken-smoke        # running, image teken/smoke-box:<id>
podman exec teken-smoke luam -e 'print(1)'
podman exec teken-smoke cat /root/.teken-smoke/rc
tkn status envs/smoke-box.lua; echo $?     # 0
```

Replace, refuse, roll back:

```sh
sed -i 's/teken smoke test/teken smoke test 2/' units/smoke.lua
tkn switch envs/smoke-box.lua -y           # new image; old container stopped, swapped, removed
podman ps -a --filter name=teken-smoke     # one container

podman exec teken-smoke touch /root/notes.txt   # work outside declared state
podman exec teken-smoke touch /data/kept.txt    # work inside it (the volume)
git checkout units/smoke.lua
tkn switch envs/smoke-box.lua -y           # refused: lists /root/notes.txt, not /data
tkn switch envs/smoke-box.lua -y --discard-undeclared
podman exec teken-smoke ls /data           # kept.txt survived the swap

tkn rollback envs/smoke-box.lua -y         # fresh container from the previous image
```

The old container is stopped with podman's default 10 s timeout, since
`sleep infinity` ignores SIGTERM; a switch therefore takes at least that
long.

## Clean up

```sh
podman rm -f teken-smoke; podman volume rm teken-smoke-data
podman images --filter reference='teken/smoke-box' -q | xargs -r podman rmi
rm -rf ~/.teken-smoke "$TEKEN_STATE"
unset TEKEN_STATE
```
