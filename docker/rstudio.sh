#!/usr/bin/env bash
#
# Run RStudio Server in the browser, inside the arbor Docker image.
#
# The image (repo-root Dockerfile) is built FROM rocker/geospatial, which
# already ships RStudio Server + the geospatial stack; it just overrides the
# default command with `R`. This script builds that image (once) and starts a
# container with the RStudio init (`/init`) instead, publishing port 8787 and
# bind-mounting the repo so you edit the real working tree.
#
# Usage:
#   docker/rstudio.sh [up]        build if needed, start the container, print the URL
#   docker/rstudio.sh down        stop and remove the container
#   docker/rstudio.sh restart     down + up
#   docker/rstudio.sh build       build the image
#   docker/rstudio.sh rebuild     build the image with --no-cache
#   docker/rstudio.sh pull        pull the image (for a registry IMAGE)
#   docker/rstudio.sh logs        follow the container logs
#   docker/rstudio.sh shell       open a bash shell in the running container
#   docker/rstudio.sh status      show container state and the URL
#
# Environment overrides:
#   PORT=8787            host port to publish RStudio on
#   PASSWORD=arbor       RStudio login password (user is always `rstudio`)
#   DISABLE_AUTH=false   set to `true` to skip the login screen entirely
#   IMAGE=arbor:latest   image to build / run; a registry reference such as
#                        ghcr.io/tim-devereux/arbor:latest is pulled instead
#   NAME=arbor-rstudio   container name
#   CONTAINER_ENGINE     `docker` or `podman` (auto-detected otherwise)
#   NO_BROWSER=          set to any value to not open a browser on `up`

set -euo pipefail

# --- locate the repo (this script lives in <repo>/docker/) -------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"

# --- config ----------------------------------------------------------------
PORT="${PORT:-8787}"
PASSWORD="${PASSWORD:-arbor}"
DISABLE_AUTH="${DISABLE_AUTH:-false}"
IMAGE="${IMAGE:-arbor:latest}"
NAME="${NAME:-arbor-rstudio}"

# --- container engine ----------------------------------------------------------
if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
  ENGINE="${CONTAINER_ENGINE}"
elif command -v docker &>/dev/null; then
  ENGINE="docker"
elif command -v podman &>/dev/null; then
  ENGINE="podman"
else
  echo "error: neither 'docker' nor 'podman' found on PATH" >&2
  exit 1
fi

# Bind + browse on the IPv4 loopback explicitly. Rootless podman (pasta)
# publishes on 0.0.0.0 (IPv4 only); if the browser resolves "localhost" to the
# IPv6 ::1 first it gets no listener and reports an empty response.
URL="http://127.0.0.1:${PORT}"

image_exists() { "${ENGINE}" image inspect "${IMAGE}" &>/dev/null; }
container_exists() { "${ENGINE}" container inspect "${NAME}" &>/dev/null; }
container_running() {
  [[ "$("${ENGINE}" container inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null || echo false)" == "true" ]]
}

build() {
  echo ">> building ${IMAGE} (this is slow the first time: it compiles arbor)"
  "${ENGINE}" build -t "${IMAGE}" "$@" "${REPO_DIR}"
}

pull() {
  echo ">> pulling ${IMAGE}"
  "${ENGINE}" pull "${IMAGE}"
}

# `arbor:latest` is a local tag; `ghcr.io/owner/arbor:latest` names a registry.
# Docker's rule: the first path segment is a registry when it contains a dot
# or a port. Remote images are pulled rather than built (see README: the CI
# workflow publishes to ghcr.io/tim-devereux/arbor).
is_remote_image() {
  local first="${IMAGE%%/*}"
  [[ "${IMAGE}" == */* && "${first}" == *[.:]* ]]
}

acquire() {
  image_exists && return 0
  if is_remote_image; then pull; else build; fi
}

open_browser() {
  [[ -n "${NO_BROWSER:-}" ]] && return 0
  if command -v xdg-open &>/dev/null; then xdg-open "${URL}" &>/dev/null &
  elif command -v open &>/dev/null; then open "${URL}" &>/dev/null &
  fi
}

up() {
  acquire

  if container_running; then
    echo ">> ${NAME} is already running at ${URL}"
    open_browser
    return 0
  fi
  container_exists && "${ENGINE}" rm -f "${NAME}" &>/dev/null || true

  echo ">> starting ${NAME}"

  # rootless podman logs in as root (home /root); rootful docker as rstudio.
  local login_user="rstudio" home="/home/rstudio"
  if [[ "${ENGINE}" == "podman" ]]; then login_user="root"; home="/root"; fi

  # command `/init` : rocker's s6 init -> launches RStudio Server, overriding
  #                   the image's `CMD ["R"]`.
  run_args=(
    -d
    --name "${NAME}"
    -p "127.0.0.1:${PORT}:8787"
    -e PASSWORD="${PASSWORD}"
    -e DISABLE_AUTH="${DISABLE_AUTH}"
    -v "${REPO_DIR}:${home}/arbor"
  )

  if [[ "${ENGINE}" == "podman" ]]; then
    # Rootless podman: the container must run as its own root (uid 0) so the
    # rocker init scripts can write /etc/rstudio, Renviron.site, etc. Podman
    # maps that container-root to *your* host user, so files created on the
    # bind mount still come back owned by you. Do NOT pass --userns=keep-id
    # or USERID/GROUPID here -- both drop the init below uid 0 and it fails
    # with "Permission denied" / "usermod: cannot lock /etc/passwd".
    run_args+=(-e RUNROOTLESS=true)
  else
    # Rootful docker: re-point the rstudio user at the host uid so files on
    # the bind mount are owned by you rather than by uid 1000.
    run_args+=(-e USERID="$(id -u)" -e GROUPID="$(id -g)" -e ROOT=true)
  fi

  "${ENGINE}" run "${run_args[@]}" "${IMAGE}" /init >/dev/null

  # wait for rserver itself to answer (not just for the port to be published)
  echo -n ">> waiting for RStudio Server "
  for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${URL}" 2>/dev/null || echo 000)"
    if [[ "${code}" =~ ^(200|302)$ ]]; then echo " ok"; break; fi
    echo -n "."
    sleep 1
  done

  cat <<EOF

  RStudio Server is up:  ${URL}

    user      : ${login_user}
    password  : ${PASSWORD}$( [[ "${DISABLE_AUTH}" == "true" ]] && echo "  (auth disabled)" )
    project   : ${home}/arbor   (bind-mounted from ${REPO_DIR})

  Open the workshop with:  file.edit("~/arbor/workshop/ROBSON_CHERLET_processing.Rmd")

  Stop it with:  ${BASH_SOURCE[0]##*/} down
EOF
  open_browser
}

down() {
  if container_exists; then
    echo ">> removing ${NAME}"
    "${ENGINE}" rm -f "${NAME}" >/dev/null
  else
    echo ">> ${NAME} not present"
  fi
}

status() {
  if container_running; then
    echo "running  -> ${URL}"
  elif container_exists; then
    echo "stopped  (run '${BASH_SOURCE[0]##*/} up' to start)"
  else
    echo "absent   (run '${BASH_SOURCE[0]##*/} up' to create)"
  fi
}

case "${1:-up}" in
  up)       up ;;
  down)     down ;;
  restart)  down; up ;;
  build)    build ;;
  rebuild)  build --no-cache ;;
  pull)     pull ;;
  logs)     "${ENGINE}" logs -f "${NAME}" ;;
  shell)    "${ENGINE}" exec -it "${NAME}" bash ;;
  status)   status ;;
  url)      echo "${URL}" ;;
  -h|--help|help)
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d' ;;
  *)
    echo "error: unknown command '${1}' (try: up, down, restart, build, rebuild, pull, logs, shell, status)" >&2
    exit 1 ;;
esac
