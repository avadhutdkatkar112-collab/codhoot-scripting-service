# codhoot-scripting-service

Execution server for CodHoot's **scripting** languages — Ruby, Perl, PHP, Lua,
Tcl, Bash, sh, AWK, R, Raku and Julia. One service for all eleven, because
eleven single-language services would each carry a copy of the same Debian base
and buy nothing: these are eleven interpreters, not eleven toolchains.

Python keeps its own service (`codhoot-python-service`) and JavaScript,
TypeScript and Rust keep theirs; this service does not duplicate any of them.

## Why this service exists

CodHoot's single-language services each hard-code one compiler and one entry
filename, so they cannot be reused for a language they were not built for —
pointing Ruby at the Python service would just run `python3` over Ruby source.
The backend routes every scripting language here through the shared runtime
image URL:

```
COMPILER_IMAGE_SCRIPTING_SERVICE_URL=https://codhoot-scripting-service-<suffix>.onrender.com
```

One variable covers all eleven languages. The mapping is read at backend
startup, so set the variable and restart the backend service.

## Contract

`POST /compile`, signed with
`HMAC-SHA256(secret, timestamp + path + hex(sha256(body)))` keyed by
`CODHOOT_INTERNAL_SECRET`, headers `X-CodHoot-Timestamp` (unix seconds) and
`X-CodHoot-Signature` (hex digest). Unsigned, tampered or stale requests get
401.

```json
{ "language": "ruby", "source": "puts \"hi\"" }
```

`GET /health` and `GET /health/live` are open — Render's health check and the
keepalive pinger must never need a signature.

| language | entry file  | run command                                    |
|----------|-------------|------------------------------------------------|
| awk      | `main.awk`  | `awk -f {src}`                                 |
| bash     | `main.bash` | `bash {src}`                                   |
| julia    | `main.jl`   | `julia --startup-file=no --history-file=no {src}` |
| lua      | `main.lua`  | `lua {src}`                                    |
| perl     | `main.pl`   | `perl {src}`                                   |
| php      | `main.php`  | `php {src}`                                    |
| r        | `main.r`    | `Rscript {src}`                                |
| raku     | `main.raku` | `raku {src}`                                   |
| ruby     | `main.rb`   | `ruby {src}`                                   |
| sh       | `main.sh`   | `sh {src}`                                     |
| tcl      | `main.tcl`  | `tclsh {src}`                                  |

Those command lines are the backend registry's own `RunCommand` for each
language, so a job behaves identically to the local `codhoot-runner-scripting`
docker path.

## Toolchains

Debian bookworm packages for Lua 5.4, Ruby, Perl, PHP, Tcl, Bash, Rakudo and
Rscript — the same versions `codhoot-runner-scripting` installs, so a rebuild
cannot silently change the interpreter a cached result was produced by. Julia
1.10.5 is the upstream archive, sha256-pinned.

## Deployment

Render blueprint: **New → Blueprint**, point it at this repo, apply. Set
`CODHOOT_INTERNAL_SECRET` to the same value the backend uses.

The service listens on `PORT` (Render sets it to 10000; the image default is
8081). `MAX_CONCURRENT_JOBS` defaults to 4 — interpreters are cheap next to a
compiler.

## Sandbox

Each job gets its own uid from a 32-entry pool, a private random 0700 working
directory, a minimal environment, rlimits applied by a trampoline re-exec, and
process-group kill on timeout. The service runs as root only to chown and
setuid; the boundary is the child. See `harden.go` / `harden_unix.go`.