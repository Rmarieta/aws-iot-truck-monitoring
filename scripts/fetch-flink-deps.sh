#!/usr/bin/env bash
# Fetch the Flink SQL Kinesis connector JAR (version-pinned, checksum-verified)
# into flink/lib/. This is a BUILD dependency, deliberately NOT committed to git
# (it is a ~66 MB binary that bundles the AWS SDK). Re-run any time; it no-ops if
# the verified JAR is already present.
#
# The connector version is pinned to the Flink RUNTIME version (1.18). If you
# change the runtime in terraform/modules/processing/main.tf, bump both here.
#
# Source: Maven Central (the canonical public source) by default.
#
# If your network blocks the public download (e.g. a proxy that rejects large
# archives), point this at an internal Maven mirror by exporting
# FLINK_CONNECTOR_BASE_URL in your shell — it is NOT committed, so no internal
# host lands in the repo. Example (do not commit this):
#   export FLINK_CONNECTOR_BASE_URL="https://<your-mirror>/maven-remote"
set -euo pipefail

# --- pinned dependency ------------------------------------------------------
CONNECTOR_VERSION="4.3.0-1.18"   # matches FLINK-1_18 runtime
JAR="flink-sql-connector-kinesis-${CONNECTOR_VERSION}.jar"
REL_PATH="org/apache/flink/flink-sql-connector-kinesis/${CONNECTOR_VERSION}/${JAR}"
EXPECTED_SHA1="95f1d7fa3f87779239173342f2a5aabfb0f338c7"

# Default to the canonical public source. Override with an internal mirror via
# the FLINK_CONNECTOR_BASE_URL env var (never hardcode an internal host here).
BASE_URL="${FLINK_CONNECTOR_BASE_URL:-https://repo1.maven.org/maven2}"

# --- paths ------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${HERE}/../flink/lib"
mkdir -p "${LIB_DIR}"
DEST="${LIB_DIR}/${JAR}"

verify() {
  local got
  got="$(sha1sum "${DEST}" | awk '{print $1}')"
  [ "${got}" = "${EXPECTED_SHA1}" ]
}

if [ -f "${DEST}" ] && verify; then
  echo "connector JAR already present and verified: ${JAR}"
  exit 0
fi

echo "fetching ${JAR} (~66 MB) from ${BASE_URL} …"
curl -fsSL "${BASE_URL}/${REL_PATH}" -o "${DEST}"

if ! verify; then
  echo "ERROR: SHA-1 mismatch for ${JAR}" >&2
  echo "  expected ${EXPECTED_SHA1}" >&2
  echo "  got      $(sha1sum "${DEST}" | awk '{print $1}')" >&2
  rm -f "${DEST}"
  exit 1
fi

echo "verified ${JAR} (sha1 ${EXPECTED_SHA1})"
