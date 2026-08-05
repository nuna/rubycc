# Distroless-style image

This sample shows the intended installation boundary for applications that use
rubycc: compile native gems in a builder image, then copy only the compiled gems
and runtime libraries into the final Ruby image.

Run it from the repository root:

```sh
docker build -f examples/distroless/Dockerfile -t rubycc-distroless-example .
docker run --rm rubycc-distroless-example
```

The build stage installs rubycc and builds `json`, `msgpack`, `sqlite3`, and
`pg` with `RUBYCC=1 RUBYCC_HERMETIC_HEADERS=1`. The final image keeps Ruby,
the compiled extensions, and `libsqlite3`/`libpq` runtime libraries, while
removing the compiler, `make`, shell, and development headers. The final
`CMD` uses exec form because there is no shell in the image.

The example uses glibc (`ruby:4.0-slim`). For musl, use the same two-stage
boundary with `ruby:4.0-alpine`, `apk add sqlite-dev libpq-dev pkgconf` in the
builder, and `sqlite-libs libpq` in the runtime stage.

The default Debian library directory is x86-64. On an arm64 Debian image, pass
`--build-arg DEB_MULTIARCH=aarch64-linux-gnu`.
