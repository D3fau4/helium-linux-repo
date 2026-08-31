#!/usr/bin/env bash

UPSTREAM_REPO="${UPSTREAM_REPO:-imputnet/helium-linux}"
PACKAGE="${PACKAGE:-helium-bin}"
ARCHES=(${ARCHES:-amd64 arm64})
KEEP_RELEASES="${KEEP_RELEASES:-5}"

REPO_URL="${REPO_URL:-https://helium-linux-repo.pages.dev}"

SUITE="${SUITE:-stable}"
COMPONENT="${COMPONENT:-main}"
ORIGIN="${ORIGIN:-helium-linux-repo}"
LABEL="${LABEL:-Helium Linux}"
RELEASE_DESCRIPTION="${RELEASE_DESCRIPTION:-Unofficial APT repository for Helium on Debian/Ubuntu}"

POOL_DIR="${POOL_DIR:-pool/main/h/${PACKAGE}}"
KEYRING_NAME="${KEYRING_NAME:-helium-linux.gpg}"
GPG_KEY_ID="${GPG_KEY_ID:-}"
