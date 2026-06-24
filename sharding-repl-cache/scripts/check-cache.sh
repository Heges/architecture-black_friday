#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

BASE_URL="${BASE_URL:-http://localhost:8080}"
CACHE_URL="${BASE_URL}/helloDoc/users"

if ! docker info >/dev/null; then
  echo 'Docker API is unavailable.' >&2
  exit 1
fi

for attempt in $(seq 1 30); do
  if curl --noproxy '*' --fail --silent --output /dev/null "${BASE_URL}/"; then
    break
  fi
  if (( attempt == 30 )); then
    echo 'API did not become ready.' >&2
    exit 1
  fi
  sleep 1
done

docker compose exec -T redis redis-cli FLUSHALL >/dev/null

measure_request() {
  curl --noproxy '*' --silent --show-error --output /dev/null \
    --write-out '%{http_code} %{time_total}' "${CACHE_URL}"
}

assert_success() {
  local label="$1"
  local status="$2"
  local elapsed="$3"

  echo "${label}: HTTP ${status}, ${elapsed} s"
  if [[ "${status}" != "200" ]]; then
    echo "${label} returned HTTP ${status}." >&2
    exit 1
  fi
}

read -r cold_status cold_time <<< "$(measure_request)"
assert_success 'Cold request' "${cold_status}" "${cold_time}"

for request_number in 1 2 3; do
  read -r cached_status cached_time <<< "$(measure_request)"
  assert_success "Cached request ${request_number}" "${cached_status}" "${cached_time}"
  if ! awk -v elapsed="${cached_time}" 'BEGIN { exit !(elapsed < 0.1) }'; then
    echo "Cached request ${request_number} took ${cached_time} s; expected less than 0.1 s." >&2
    exit 1
  fi
done

cache_keys="$(docker compose exec -T redis redis-cli DBSIZE)"
if (( cache_keys == 0 )); then
  echo 'Redis does not contain cache keys.' >&2
  exit 1
fi

echo "Redis keys: ${cache_keys}"
echo 'Cache performance check completed successfully.'
