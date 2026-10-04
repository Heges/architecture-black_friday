#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

if ! docker info >/dev/null; then
  printf 'Docker API is unavailable. Check Docker Desktop/WSL integration and access to /var/run/docker.sock.\n' >&2
  exit 1
fi

wait_for_mongo() {
  local service="$1"
  local port="$2"
  local description="$3"
  local expression="${4-}"
  if [[ -z "${expression}" ]]; then
    expression='quit(db.adminCommand({ ping: 1 }).ok ? 0 : 1)'
  fi

  for attempt in $(seq 1 60); do
    if docker compose exec -T "${service}" mongosh \
      --port "${port}" --quiet --eval "${expression}" >/dev/null 2>&1; then
      printf '%s is ready.\n' "${description}"
      return 0
    fi
    sleep 2
  done

  printf 'Timed out waiting for %s.\n' "${description}" >&2
  return 1
}

wait_for_mongo configSrv 27017 "configSrv"
wait_for_mongo shard1 27018 "shard1"
wait_for_mongo shard2 27019 "shard2"

docker compose exec -T configSrv mongosh --port 27017 --quiet <<'EOF'
try {
  rs.status();
  print("Replica set config_server is already initialized.");
} catch (error) {
  if (error.code === 94 || error.codeName === "NotYetInitialized") {
    printjson(rs.initiate({
      _id: "config_server",
      configsvr: true,
      members: [{ _id: 0, host: "configSrv:27017" }]
    }));
  } else {
    throw error;
  }
}
EOF

wait_for_mongo configSrv 27017 "config_server primary" \
  'quit(db.hello().isWritablePrimary ? 0 : 1)'

docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
try {
  rs.status();
  print("Replica set shard1 is already initialized.");
} catch (error) {
  if (error.code === 94 || error.codeName === "NotYetInitialized") {
    printjson(rs.initiate({
      _id: "shard1",
      members: [{ _id: 0, host: "shard1:27018" }]
    }));
  } else {
    throw error;
  }
}
EOF

docker compose exec -T shard2 mongosh --port 27019 --quiet <<'EOF'
try {
  rs.status();
  print("Replica set shard2 is already initialized.");
} catch (error) {
  if (error.code === 94 || error.codeName === "NotYetInitialized") {
    printjson(rs.initiate({
      _id: "shard2",
      members: [{ _id: 0, host: "shard2:27019" }]
    }));
  } else {
    throw error;
  }
}
EOF

wait_for_mongo shard1 27018 "shard1 primary" \
  'quit(db.hello().isWritablePrimary ? 0 : 1)'
wait_for_mongo shard2 27019 "shard2 primary" \
  'quit(db.hello().isWritablePrimary ? 0 : 1)'
wait_for_mongo mongos 27020 "mongos"

docker compose exec -T mongos mongosh --port 27020 --quiet <<'EOF'
const adminDb = db.getSiblingDB("admin");
const configDb = db.getSiblingDB("config");
const dataDb = db.getSiblingDB("somedb");

const registeredShards = adminDb.runCommand({ listShards: 1 }).shards;
if (!registeredShards.some((shard) => shard._id === "shard1")) {
  printjson(sh.addShard("shard1/shard1:27018"));
}
if (!registeredShards.some((shard) => shard._id === "shard2")) {
  printjson(sh.addShard("shard2/shard2:27019"));
}

if (!configDb.databases.findOne({ _id: "somedb" })) {
  printjson(sh.enableSharding("somedb"));
}

if (!dataDb.getCollectionNames().includes("helloDoc")) {
  dataDb.createCollection("helloDoc");
}

if (!configDb.collections.findOne({ _id: "somedb.helloDoc", dropped: { $ne: true } })) {
  printjson(sh.shardCollection("somedb.helloDoc", { name: "hashed" }));
}

dataDb.helloDoc.deleteMany({});
const documents = [];
for (let index = 0; index < 1000; index += 1) {
  documents.push({ age: index, name: `ly${index}` });
}
printjson(dataDb.helloDoc.insertMany(documents).acknowledged);
print(`Total documents: ${dataDb.helloDoc.countDocuments({})}`);
EOF

sleep 2

total_count="$(docker compose exec -T mongos mongosh --port 27020 --quiet \
  --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments({})')"
shard1_count="$(docker compose exec -T shard1 mongosh --port 27018 --quiet \
  --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments({})')"
shard2_count="$(docker compose exec -T shard2 mongosh --port 27019 --quiet \
  --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments({})')"

printf '\nDocument distribution:\n'
printf '  total:  %s\n' "${total_count}"
printf '  shard1: %s\n' "${shard1_count}"
printf '  shard2: %s\n' "${shard2_count}"

if (( total_count != 1000 || shard1_count == 0 || shard2_count == 0 )); then
  printf 'Unexpected document distribution.\n' >&2
  exit 1
fi

if (( shard1_count + shard2_count != total_count )); then
  printf 'Shard counts do not add up to the total count.\n' >&2
  exit 1
fi

printf '\nMongoDB sharding initialization completed successfully.\n'
