# The dictation server (server/main.ts): the handlers in supabase/functions/_shared, in one
# long-running Deno process. Build it from the repository root, so the handlers are in the context:
#
#   docker build -f server/Dockerfile --build-arg MURMUR_VERSION=$(git rev-parse --short HEAD) -t murmur-server .
#
# server/Dockerfile.dockerignore keeps everything else out of the context: no app code, no .env file.
# The Deno version is the one the functions are tested with on the Mac (deno --version).
FROM denoland/deno:2.9.7

WORKDIR /app
COPY --chown=deno:deno supabase/functions/_shared supabase/functions/_shared
COPY --chown=deno:deno supabase/functions/live/spike.ts supabase/functions/live/spike.ts
COPY --chown=deno:deno server/main.ts server/main.ts

USER deno
# The dependencies are fetched at build time: a start needs no network and can't pick up a newer one.
RUN deno cache server/main.ts

ARG MURMUR_VERSION=dev
ENV MURMUR_VERSION=${MURMUR_VERSION} \
    PORT=8080 \
    DENO_NO_UPDATE_CHECK=1
EXPOSE 8080
# A stop sends SIGTERM: the server lets what is in hand finish (DRAIN_MS) and then exits. Give the
# container at least that long before it is killed (docker stop -t 40, or the platform's setting).
STOPSIGNAL SIGTERM
CMD ["run", "--allow-net", "--allow-env", "--cached-only", "server/main.ts"]
