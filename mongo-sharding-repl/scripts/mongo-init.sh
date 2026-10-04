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
for service in shard1-1 shard1-2 shard1-3; do
  wait_for_mongo "${service}" 27018 "${service}"
done
for service in shard2-1 shard2-2 shard2-3; do
  wait_for_mongo "${service}" 27019 "${service}"
done

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

docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<'EOF'
const desiredHosts = ["shard1-1:27018", "shard1-2:27018", "shard1-3:27018"];
try {
  const currentHosts = rs.conf().members.map((member) => member.host).sort();
  if (JSON.stringify(currentHosts) !== JSON.stringify([...desiredHosts].sort())) {
    throw new Error(`Unexpected shard1 configuration: ${currentHosts.join(", ")}`);
  }
  print("Replica set shard1 is already initialized.");
} catch (error) {
  if (error.code === 94 || error.codeName === "NotYetInitialized") {
    printjson(rs.initiate({
      _id: "shard1",
      members: desiredHosts.map((host, index) => ({ _id: index, host }))
    }));
  } else {
    throw error;
  }
}
EOF

docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<'EOF'
const desiredHosts = ["shard2-1:27019", "shard2-2:27019", "shard2-3:27019"];
try {
  const currentHosts = rs.conf().members.map((member) => member.host).sort();
  if (JSON.stringify(currentHosts) !== JSON.stringify([...desiredHosts].sort())) {
    throw new Error(`Unexpected shard2 configuration: ${currentHosts.join(", ")}`);
  }
  print("Replica set shard2 is already initialized.");
} catch (error) {
  if (error.code === 94 || error.codeName === "NotYetInitialized") {
    printjson(rs.initiate({
      _id: "shard2",
      members: desiredHosts.map((host, index) => ({ _id: index, host }))
    }));
  } else {
    throw error;
  }
}
EOF

replica_set_ready='const members = rs.status().members; const primary = members.filter((member) => member.stateStr === "PRIMARY").length; const secondary = members.filter((member) => member.stateStr === "SECONDARY").length; quit(members.length === 3 && primary === 1 && secondary === 2 ? 0 : 1)'
wait_for_mongo shard1-1 27018 "shard1 replica set" "${replica_set_ready}"
wait_for_mongo shard2-1 27019 "shard2 replica set" "${replica_set_ready}"
wait_for_mongo mongos 27020 "mongos"

docker compose exec -T mongos mongosh --port 27020 --quiet <<'EOF'
const adminDb = db.getSiblingDB("admin");
const configDb = db.getSiblingDB("config");
const dataDb = db.getSiblingDB("somedb");

const registeredShards = adminDb.runCommand({ listShards: 1 }).shards;
if (!registeredShards.some((shard) => shard._id === "shard1")) {
  printjson(sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018"));
}
if (!registeredShards.some((shard) => shard._id === "shard2")) {
  printjson(sh.addShard("shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019"));
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
shard1_count="$(docker compose exec -T shard1-1 mongosh \
  'mongodb://shard1-1:27018,shard1-2:27018,shard1-3:27018/?replicaSet=shard1' \
  --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments({})')"
shard2_count="$(docker compose exec -T shard2-1 mongosh \
  'mongodb://shard2-1:27019,shard2-2:27019,shard2-3:27019/?replicaSet=shard2' \
  --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments({})')"

shard1_members="$(docker compose exec -T shard1-1 mongosh --port 27018 --quiet \
  --eval 'rs.status().members.length')"
shard1_primary="$(docker compose exec -T shard1-1 mongosh --port 27018 --quiet \
  --eval 'rs.status().members.filter((member) => member.stateStr === "PRIMARY").length')"
shard1_secondary="$(docker compose exec -T shard1-1 mongosh --port 27018 --quiet \
  --eval 'rs.status().members.filter((member) => member.stateStr === "SECONDARY").length')"
shard2_members="$(docker compose exec -T shard2-1 mongosh --port 27019 --quiet \
  --eval 'rs.status().members.length')"
shard2_primary="$(docker compose exec -T shard2-1 mongosh --port 27019 --quiet \
  --eval 'rs.status().members.filter((member) => member.stateStr === "PRIMARY").length')"
shard2_secondary="$(docker compose exec -T shard2-1 mongosh --port 27019 --quiet \
  --eval 'rs.status().members.filter((member) => member.stateStr === "SECONDARY").length')"

printf '\nReplica sets:\n'
printf '  shard1: members=%s primary=%s secondary=%s\n' "${shard1_members}" "${shard1_primary}" "${shard1_secondary}"
printf '  shard2: members=%s primary=%s secondary=%s\n' "${shard2_members}" "${shard2_primary}" "${shard2_secondary}"
printf '\nDocument distribution:\n'
printf '  total:  %s\n' "${total_count}"
printf '  shard1: %s\n' "${shard1_count}"
printf '  shard2: %s\n' "${shard2_count}"

if (( shard1_members != 3 || shard1_primary != 1 || shard1_secondary != 2 )); then
  printf 'Unexpected shard1 replica set state.\n' >&2
  exit 1
fi
if (( shard2_members != 3 || shard2_primary != 1 || shard2_secondary != 2 )); then
  printf 'Unexpected shard2 replica set state.\n' >&2
  exit 1
fi
if (( total_count != 1000 || shard1_count == 0 || shard2_count == 0 )); then
  printf 'Unexpected document distribution.\n' >&2
  exit 1
fi
if (( shard1_count + shard2_count != total_count )); then
  printf 'Shard counts do not add up to the total count.\n' >&2
  exit 1
fi

printf '\nMongoDB sharding and replication initialization completed successfully.\n'
