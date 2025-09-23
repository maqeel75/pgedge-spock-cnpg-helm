#!/bin/bash
set -euo pipefail

echo "📦 Using database: ${APPDB}"

# Split clusters and tables passed via env
IFS=' ' read -r -a clusters <<< "${CLUSTERS:-}"
IFS=' ' read -r -a tables <<< "${TABLES:-}"

echo "📡 Clusters: ${clusters[*]}"
if [ ${#tables[@]} -gt 0 ]; then
  echo "📑 Tables for replication: ${tables[*]}"
fi

# helper to get PGPASSWORD var value that job already injects
get_pw() {
  local cluster="$1"
  # env var name uses upper and - -> _
  local ev="PGPASSWORD_$(echo "$cluster" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
  # Use indirect expansion
  printf '%s' "${!ev:-}"
}

# helper: comma-quoted list for SQL (for table-name checks)
tables_quoted_sql() {
  printf "%s" "$(printf "'%s'," "${tables[@]}" | sed 's/,$//')"
}

# Wait until all primary pods are ready (we rely on service DNS)
for cluster in "${clusters[@]}"; do
  host="${cluster}-rw.${NAMESPACE}.svc.cluster.local"
  cluster_pw=$(get_pw "$cluster")

  echo "⏳ Waiting for $cluster primary pod to accept connections..."
  until PGPASSWORD="$cluster_pw" psql -h "$host" -U postgres -d "$APPDB" -c '\q' >/dev/null 2>&1; do
    sleep 5
  done
  echo "✅ $cluster primary ready"
done

echo "🚀 Creating Spock nodes, tables, and replication sets..."
for cluster in "${clusters[@]}"; do
  host="${cluster}-rw.${NAMESPACE}.svc.cluster.local"
  node_name=$(echo "$cluster" | tr '-' '_')
  cluster_pw=$(get_pw "$cluster")

  echo "🔹 Processing cluster: $cluster"

  # --- Cleanup stale nodes & subscriptions on this cluster: remove any node/sub that refer to clusters not in $clusters
  echo "🧹 Cleaning up stale spock.node / spock.subscription entries on $cluster (if any)"
  # build list of allowed node_names (underscore)
  allowed_nodes_sql=$(printf "'%s', " "${clusters[@]}" | sed "s/'/''/g" | sed "s/, $//")
  # but convert names to node_name style (underscores). We'll pass as array check in SQL using string manipulation.
  # We'll construct an SQL that drops nodes/subscriptions whose node_name not in our allowed set.
  # Drop nodes not in allowed list (safe drop with ifexists)
  PGPASSWORD="$cluster_pw" psql -h "$host" -U postgres -d "$APPDB" -v ON_ERROR_STOP=1 -X -q -c "
DO \$\$
DECLARE
  r record;
  allowed text[] := ARRAY[$(printf "'%s'," "${clusters[@]}" | sed 's/,$//')];
  allowed_node_names text[] := ARRAY[]::text[];
  item text;
BEGIN
  -- build underscore-style allowed node names
  FOREACH item IN ARRAY allowed LOOP
    allowed_node_names := allowed_node_names || replace(item, '-', '_');
  END LOOP;

  FOR r IN SELECT node_name FROM spock.node LOOP
    IF NOT (r.node_name = ANY(allowed_node_names)) THEN
      RAISE NOTICE 'Dropping stale node on %: %', '$cluster', r.node_name;
      PERFORM spock.node_drop(r.node_name, true);
    END IF;
  END LOOP;

  -- Drop subscriptions which reference providers not in allowed list
  FOR r IN SELECT sub_name, (SELECT node_name FROM spock.node WHERE node_id = sub_target) AS target_node
           FROM spock.subscription LOOP
    IF r.target_node IS NULL OR NOT (r.target_node = ANY(allowed_node_names)) THEN
      RAISE NOTICE 'Dropping stale subscription on %: % (target_node=%)', '$cluster', r.sub_name, r.target_node;
      PERFORM spock.sub_drop(r.sub_name, true);
    END IF;
  END LOOP;
END
\$\$;
"

  # 1️⃣ Create node if not exists
  PGPASSWORD="$cluster_pw" psql -h "$host" -U postgres -d "$APPDB" -c "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM spock.node WHERE node_name = '$node_name') THEN
    PERFORM spock.node_create(
      node_name := '$node_name',
      dsn := 'host=$host dbname=$APPDB user=postgres password=$cluster_pw'
    );
  END IF;
END
\$\$;
"

  # 2️⃣ Ensure default repset exists
  echo "📦 Ensuring default replication set exists on $cluster"
  PGPASSWORD="$cluster_pw" psql -h "$host" -U postgres -d "$APPDB" -c "
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM spock.replication_set WHERE set_name = 'default'
    ) THEN
        PERFORM spock.repset_create('default');
    END IF;
END
\$\$;
"

  # 3️⃣ Create tables if not exist and add them to repset
  for tbl in "${tables[@]}"; do
    echo "📑 Ensuring table $tbl exists on $cluster"
    PGPASSWORD="$cluster_pw" psql -h "$host" -U postgres -d "$APPDB" -c "
CREATE TABLE IF NOT EXISTS $tbl (
  id SERIAL PRIMARY KEY,
  val TEXT
);
"

    echo "➕ Adding $tbl to replication set on $cluster (idempotent)"
    PGPASSWORD="$cluster_pw" psql -h "$host" -U postgres -d "$APPDB" -c "
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM spock.replication_set r
        JOIN spock.replication_set_table rt ON r.set_id = rt.set_id
        WHERE r.set_name = 'default'
          AND rt.set_reloid = '$tbl'::regclass
    ) THEN
        PERFORM spock.repset_add_table('default', '$tbl'::regclass, true);
    END IF;
END
\$\$;
"
  done
done

echo "🔗 Creating (or repairing) Spock subscriptions (full mesh)..."

for src in "${clusters[@]}"; do
  src_host="${src}-rw.${NAMESPACE}.svc.cluster.local"
  src_pw=$(get_pw "$src")

  for tgt in "${clusters[@]}"; do
    if [ "$src" = "$tgt" ]; then
      continue
    fi

    tgt_host="${tgt}-rw.${NAMESPACE}.svc.cluster.local"
    tgt_pw=$(get_pw "$tgt")
    sub_name="sub_$(echo "$src" | tr '-' '_')_to_$(echo "$tgt" | tr '-' '_')"

    # Check if subscription exists (get sub_id and sub_target)
    sub_row=$(PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA -F '|' -c "SELECT sub_id, sub_target FROM spock.subscription WHERE sub_name='${sub_name}';" || true)

    if [ -n "$sub_row" ]; then
      sub_id=$(printf '%s' "$sub_row" | cut -d'|' -f1)
      sub_target=$(printf '%s' "$sub_row" | cut -d'|' -f2)

      # get current node_id of the target cluster (node_name uses _)
      tgt_node_name=$(echo "$tgt" | tr '-' '_')
      tgt_node=$(PGPASSWORD="$tgt_pw" psql -h "$tgt_host" -U postgres -d "$APPDB" -tA -c "SELECT node_id FROM spock.node WHERE node_name='${tgt_node_name}';" || true)

      # check subscription status via spock.sub_show_status (status column)
      sub_status=$(PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA -c "SELECT status FROM spock.sub_show_status('${sub_name}');" || true)

      # If sub_target mismatches or subscription is DOWN -> repair (drop & recreate)
      if [ "${sub_target:-}" != "${tgt_node:-}" ] || [ "${sub_status:-}" = "down" ]; then
        echo "⚠️ Subscription ${sub_name} on ${src} points to node_id ${sub_target:-} but target node is ${tgt_node:-}, or status=${sub_status:-}. Repairing..."

        # Try to drop gracefully (if fails try disable -> drop)
        if ! PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA -c "SELECT spock.sub_drop('${sub_name}', true);" >/dev/null 2>&1; then
          echo "  ⚠ drop failed; trying to disable then drop..."
          PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA -c "SELECT spock.sub_disable('${sub_name}', true);" || true
          sleep 1
          PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA -c "SELECT spock.sub_drop('${sub_name}', true);" || {
            echo "  ❌ Failed to drop subscription ${sub_name}. Skipping repair for this subscription and continuing."
            continue
          }
        fi

        # Decide synchronize_data based on whether the SUBSCRIBER (src) already has data.
        # If subscriber is empty -> synchronize_data = true (seed it). If it has data -> false.
        # We'll check first table from ${tables[@]} (assumes same schema across clusters).
        sync_data="false"
        if [ ${#tables[@]} -gt 0 ]; then
          sample_tbl="${tables[0]}"
          subscriber_has_data=$(PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA -c "SELECT EXISTS (SELECT 1 FROM public.$sample_tbl LIMIT 1);" || echo "true")
          # psql returns 't' or 'f' (or may be empty on error)
          if [ "$subscriber_has_data" = "f" ] || [ "$subscriber_has_data" = "false" ]; then
            sync_data="true"
            echo "  🔄 Subscriber ${src} appears empty for table ${sample_tbl}, using synchronize_data=true"
          else
            echo "  ℹ Subscriber ${src} has data; using synchronize_data=false to avoid double-seed conflicts"
          fi
        else
          echo "  ⚠ No tables provided; defaulting to synchronize_data=false"
        fi

        # Enable repair mode on SUBSCRIBER (src) BEFORE enabling subscription to tolerate conflicts during setup
        echo "  🔧 Enabling spock.repair_mode on subscriber ${src}"
        PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.repair_mode(true);" || true

        # Recreate subscription with appropriate sync setting
        echo "  ➕ Creating subscription ${sub_name} from ${src} -> ${tgt} (synchronize_data=${sync_data})"
        PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "
SELECT spock.sub_create(
  subscription_name := '${sub_name}',
  provider_dsn := 'host=${tgt_host} port=5432 dbname=${APPDB} user=postgres password=${tgt_pw}',
  replication_sets := ARRAY['default'],
  synchronize_data := ${sync_data},
  forward_origins := '{}'
);" || {
          echo "  ❌ Failed to create subscription ${sub_name} on ${src}. Disabling repair_mode and continuing."
          PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.repair_mode(false);" || true
          continue
        }

        # Enable subscription
        PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.sub_enable('${sub_name}', true);" || {
          echo "  ⚠ Could not enable subscription ${sub_name} immediately; will continue."
        }

        # Wait for sync only if we asked to synchronize data or if sub_status was 'initializing'
        if [ "$sync_data" = "true" ] || [ "${sub_status:-}" = "initializing" ]; then
          echo "  ⏳ Waiting for ${sub_name} to synchronize..."
          # This may block until sync is complete. Use spock.sub_wait_for_sync to block (some versions may support).
          PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.sub_wait_for_sync('${sub_name}');" >/dev/null 2>&1 || {
            echo "  ⚠ spock.sub_wait_for_sync failed or not available; proceed to monitor manually."
          }
        fi

        # Disable repair mode now that initial sync is done/attempted
        echo "  🔧 Disabling spock.repair_mode on subscriber ${src}"
        PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.repair_mode(false);" || true

        echo "  ✅ Recreated and enabled ${sub_name} (synchronize_data=${sync_data})."
      else
        echo "🔎 Subscription ${sub_name} on ${src} exists and points to correct node (${tgt_node}), status=${sub_status}."
      fi

    else
      # subscription does not exist -> create with synchronize_data := true only if subscriber empty
      echo "➕ Creating subscription ${sub_name} from ${src} to ${tgt} (creating if missing)"

      sync_data="false"
      if [ ${#tables[@]} -gt 0 ]; then
        sample_tbl="${tables[0]}"
        subscriber_has_data=$(PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA -c "SELECT EXISTS (SELECT 1 FROM public.$sample_tbl LIMIT 1);" || echo "true")
        if [ "$subscriber_has_data" = "f" ] || [ "$subscriber_has_data" = "false" ]; then
          sync_data="true"
          echo "  🔄 Subscriber ${src} appears empty for table ${sample_tbl}, using synchronize_data=true"
        else
          echo "  ℹ Subscriber ${src} has data; using synchronize_data=false"
        fi
      fi

      # Enable repair mode on SUBSCRIBER before creation/enabling
      echo "  🔧 Enabling spock.repair_mode on subscriber ${src}"
      PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.repair_mode(true);" || true

      PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "
SELECT spock.sub_create(
  subscription_name := '${sub_name}',
  provider_dsn := 'host=${tgt_host} port=5432 dbname=${APPDB} user=postgres password=${tgt_pw}',
  replication_sets := ARRAY['default'],
  synchronize_data := ${sync_data},
  forward_origins := '{}'
);" || {
        echo "  ❌ Failed to create subscription ${sub_name} on ${src}. Disabling repair_mode and continuing."
        PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.repair_mode(false);" || true
        continue
      }

      PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.sub_enable('${sub_name}', true);" || {
        echo "  ⚠ Could not enable subscription ${sub_name} immediately; will continue."
      }

      if [ "$sync_data" = "true" ]; then
        echo "  ⏳ Waiting for ${sub_name} to synchronize initial data..."
        PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.sub_wait_for_sync('${sub_name}');" >/dev/null 2>&1 || {
          echo "  ⚠ spock.sub_wait_for_sync failed or not available; proceed to monitor manually."
        }
      fi

      echo "  🔧 Disabling spock.repair_mode on subscriber ${src}"
      PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.repair_mode(false);" || true

      echo "  ✅ Created and enabled ${sub_name} (synchronize_data=${sync_data})."
    fi
  done
done

echo "🎉 Spock replication setup & repair completed."

