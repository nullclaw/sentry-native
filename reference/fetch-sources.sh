#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repos=(
  "https://github.com/getsentry/sentry-native.git"
  "https://github.com/getsentry/sentry-rust.git"
  "https://github.com/getsentry/sentry-python.git"
  "https://github.com/getsentry/sentry-javascript.git"
  "https://github.com/getsentry/sentry-java.git"
  "https://github.com/getsentry/sentry-cocoa.git"
  "https://github.com/getsentry/sentry-dotnet.git"
  "https://github.com/getsentry/sentry-go.git"
)

for repo in "${repos[@]}"; do
  name="$(basename "${repo}" .git)"
  target="${ROOT_DIR}/${name}"

  if [[ -d "${target}/.git" ]]; then
    echo "Updating ${name}..."
    git -C "${target}" fetch --depth 1 origin
    git -C "${target}" reset --hard origin/HEAD
  else
    echo "Cloning ${name}..."
    git clone --depth 1 "${repo}" "${target}"
  fi
done

echo "Reference SDK sources are ready under ${ROOT_DIR}"
