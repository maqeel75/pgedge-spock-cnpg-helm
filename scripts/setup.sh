#!/bin/bash
set -euo pipefail

echo "📦 Using database: ${APPDB}"

# --- Parse environment variables ---
IFS=' ' read -r -a clusters <<< "${CLUSTERS:-}"
IFS=' ' read -r -a tables <<< "${TABLES:-}"

echo "📡 Clusters: ${clusters[*]}"
[ ${#tables[@]} -gt 0 ] && echo "📑 Tables for replication: ${tables[*]}"

# --- Helpers ---
get_pw() {
  local cluster="$1"
  local ev="PGPASSWORD_$(echo "$cluster" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
  printf '%s' "${!ev:-}"
}

# --- Ensure cluster is ready ---
wait_for_cluster() {
  local cluster="$1" host pw
  host="${cluster}-rw.${NAMESPACE}.svc.cluster.local"
  pw=$(get_pw "$cluster")
  echo "⏳ Waiting for $cluster primary pod..."
  until PGPASSWORD="$pw" psql -h "$host" -U postgres -d "$APPDB" -c '\q' >/dev/null 2>&1; do sleep 5; done
  echo "✅ $cluster primary ready"
}

# --- Cleanup stale nodes/subscriptions ---
cleanup_cluster() {
  local cluster="$1" host pw
  host="${cluster}-rw.${NAMESPACE}.svc.cluster.local"
  pw=$(get_pw "$cluster")

  echo "🧹 Cleaning stale nodes/subscriptions on $cluster"
  PGPASSWORD="$pw" psql -h "$host" -U postgres -d "$APPDB" -q -c "
DO \$\$
DECLARE r record;
  allowed text[] := ARRAY[$(printf "'%s'," "${clusters[@]}" | sed 's/,$//')];
  allowed_node_names text[] := ARRAY[]::text[];
  item text;
BEGIN
  FOREACH item IN ARRAY allowed LOOP
    allowed_node_names := allowed_node_names || replace(item, '-', '_');
  END LOOP;

  FOR r IN SELECT node_name FROM spock.node LOOP
    IF NOT (r.node_name = ANY(allowed_node_names)) THEN
      PERFORM spock.node_drop(r.node_name, true);
    END IF;
  END LOOP;

  FOR r IN SELECT sub_name, (SELECT node_name FROM spock.node WHERE node_id=sub_target) AS tgt
           FROM spock.subscription LOOP
    IF r.tgt IS NULL OR NOT (r.tgt = ANY(allowed_node_names)) THEN
      PERFORM spock.sub_drop(r.sub_name, true);
    END IF;
  END LOOP;
END
\$\$;"
}

# --- Setup node, repset, and tables ---
setup_cluster() {
  local cluster="$1" host pw node
  host="${cluster}-rw.${NAMESPACE}.svc.cluster.local"
  pw=$(get_pw "$cluster")
  node=$(echo "$cluster" | tr '-' '_')

  cleanup_cluster "$cluster"

  # Node
  PGPASSWORD="$pw" psql -h "$host" -U postgres -d "$APPDB" -c "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM spock.node WHERE node_name='$node') THEN
    PERFORM spock.node_create(
      node_name := '$node',
      dsn := 'host=$host dbname=$APPDB user=postgres password=$pw'
    );
  END IF;
END
\$\$;"

  # Repset
  PGPASSWORD="$pw" psql -h "$host" -U postgres -d "$APPDB" -c "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM spock.replication_set WHERE set_name='default') THEN
    PERFORM spock.repset_create('default');
  END IF;
END
\$\$;"

  # Tables
  for tbl in "${tables[@]}"; do
    PGPASSWORD="$pw" psql -h "$host" -U postgres -d "$APPDB" -c "
CREATE TABLE IF NOT EXISTS $tbl (id SERIAL PRIMARY KEY, val TEXT);"
    PGPASSWORD="$pw" psql -h "$host" -U postgres -d "$APPDB" -c "
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM spock.replication_set r
    JOIN spock.replication_set_table t ON r.set_id=t.set_id
    WHERE r.set_name='default' AND t.set_reloid='$tbl'::regclass
  ) THEN
    PERFORM spock.repset_add_table('default', '$tbl'::regclass, true);
  END IF;
END
\$\$;"
  done
}

# --- Create or repair subscription ---
ensure_subscription() {
  local src="$1" tgt="$2"
  local src_host src_pw tgt_host tgt_pw sub_name tgt_node_name
  src_host="${src}-rw.${NAMESPACE}.svc.cluster.local"
  tgt_host="${tgt}-rw.${NAMESPACE}.svc.cluster.local"
  src_pw=$(get_pw "$src")
  tgt_pw=$(get_pw "$tgt")
  sub_name="sub_${src//-/_}_to_${tgt//-/_}"
  tgt_node_name="${tgt//-/_}"

  # Current subscription status
  sub_row=$(PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA -F '|' -c \
    "SELECT sub_id, sub_target FROM spock.subscription WHERE sub_name='${sub_name}';" || true)

  tgt_node=$(PGPASSWORD="$tgt_pw" psql -h "$tgt_host" -U postgres -d "$APPDB" -tA -c \
    "SELECT node_id FROM spock.node WHERE node_name='${tgt_node_name}';" || true)

  # Decide sync_data (true if subscriber empty)
  sync_data="false"
  if [ ${#tables[@]} -gt 0 ]; then
    tbl="${tables[0]}"
    empty=$(PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA \
      -c "SELECT NOT EXISTS (SELECT 1 FROM $tbl LIMIT 1);" || echo "false")
    [ "$empty" = "t" ] && sync_data="true"
  fi

  # If subscription exists, verify/repair
  if [ -n "$sub_row" ]; then
    sub_target=$(cut -d'|' -f2 <<<"$sub_row")
    sub_status=$(PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA \
      -c "SELECT status FROM spock.sub_show_status('${sub_name}');" || true)
    if [ "$sub_target" != "$tgt_node" ] || [ "$sub_status" = "down" ]; then
      echo "⚠️ Repairing $sub_name on $src"
      PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.sub_drop('${sub_name}', true);" || true
      sub_row=""
    else
      echo "🔎 Subscription $sub_name OK on $src (status=$sub_status)"
    fi
  fi

  # If missing -> create
  if [ -z "$sub_row" ]; then
    echo "➕ Creating subscription $sub_name (sync=$sync_data)"
    PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.repair_mode(true);" || true
    PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "
SELECT spock.sub_create(
  subscription_name := '${sub_name}',
  provider_dsn := 'host=${tgt_host} dbname=${APPDB} user=postgres password=${tgt_pw}',
  replication_sets := ARRAY['default'],
  synchronize_data := ${sync_data},
  forward_origins := '{}'
);" || true
    PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.sub_enable('${sub_name}', true);" || true
    PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.repair_mode(false);" || true
  fi
}

# --- Main flow ---
for c in "${clusters[@]}"; do wait_for_cluster "$c"; done
for c in "${clusters[@]}"; do setup_cluster "$c"; done
for s in "${clusters[@]}"; do for t in "${clusters[@]}"; do [ "$s" != "$t" ] && ensure_subscription "$s" "$t"; done; done

echo "🎉 Spock replication setup & repair completed."

