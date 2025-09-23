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
  printf '%s' "${!ev}"
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
    PGPASSWORD="$cluster_pw" psql -h "$host" -U postgres -d "$APPDB" <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM spock.replication_set r
        JOIN spock.replication_set_table rt ON r.set_id = rt.set_id
        WHERE r.set_name = 'default'
          AND rt.set_reloid = TG_TABLE_NAME::regclass -- placeholder, replaced below
    ) THEN
        PERFORM spock.repset_add_table('default', TG_TABLE_NAME::regclass, true);
    END IF;
END;
$$;
SQL
   # The heredoc above can't easily substitute shell var inside DO $$ (and we want to keep same structure).
    # So run an inline safe variant instead:
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
    sub_row=$(PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA -F '|' -c "SELECT sub_id, sub_target FROM spock.subscription WHERE sub_name='${sub_name}';")

    if [ -n "$sub_row" ]; then
      sub_id=$(printf '%s' "$sub_row" | cut -d'|' -f1)
      sub_target=$(printf '%s' "$sub_row" | cut -d'|' -f2)

      # get current node_id of the target cluster (node_name uses _)
      tgt_node_name=$(echo "$tgt" | tr '-' '_')
      tgt_node=$(PGPASSWORD="$tgt_pw" psql -h "$tgt_host" -U postgres -d "$APPDB" -tA -c "SELECT node_id FROM spock.node WHERE node_name='${tgt_node_name}';")

      # check subscription status via spock.sub_show_status (status column)
      sub_status=$(PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tA -c "SELECT status FROM spock.sub_show_status('${sub_name}');" || true)

      # If sub_target mismatches or subscription is DOWN -> repair (drop & recreate)
      if [ "${sub_target:-}" != "${tgt_node:-}" ] || [ "${sub_status:-}" = "down" ]; then
        echo "⚠️Subscription ${sub_name} on ${src} points to node_id ${sub_target:-} but target node is ${tgt_node:-}, or status=${sub_status:-}. Repairing..."

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

        # Check if target cluster has data in our tables
        target_has_data=$(PGPASSWORD="$tgt_pw" psql -h "$tgt_host" -U postgres -d "$APPDB" -tA -c "
SELECT EXISTS(
  SELECT 1 FROM information_schema.tables 
  WHERE table_schema = 'public' 
  AND table_name IN ($(printf "'%s'," "${tables[@]}" | sed 's/,$//'))
) AND EXISTS(
  SELECT 1 FROM ${tables[0]} LIMIT 1
);" 2>/dev/null || echo "false")

        # Use synchronize_data=true only if target is empty
        sync_data="false"
        if [ "$target_has_data" = "f" ] || [ "$target_has_data" = "false" ]; then
          sync_data="true"
          echo "  🔄 Target appears empty, using synchronize_data=true"
        fi

        # Recreate subscription with appropriate sync setting
        PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "
SELECT spock.sub_create(
  subscription_name := '${sub_name}',
  provider_dsn := 'host=${tgt_host} port=5432 dbname=${APPDB} user=postgres password=${tgt_pw}',
  replication_sets := ARRAY['default'],
  synchronize_data := $sync_data,
  forward_origins := '{}'
);"
        PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.sub_enable('${sub_name}', true);"
        echo "  ✅ Recreated ${sub_name} (synchronize_data=${sync_data})."
      else
        echo "🔎 Subscription ${sub_name} on ${src} exists and points to correct node (${tgt_node}), status=${sub_status}."
      fi

    else
      # subscription does not exist -> create with synchronize_data := true (seed)
      echo "Creating subscription ${sub_name} from ${src} to ${tgt} (synchronize_data=true)"
      PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "
SELECT spock.sub_create(
  subscription_name := '${sub_name}',
  provider_dsn := 'host=${tgt_host} port=5432 dbname=${APPDB} user=postgres password=${tgt_pw}',
  replication_sets := ARRAY['default'],
  synchronize_data := true,
  forward_origins := '{}'
);"
      PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "SELECT spock.sub_enable('${sub_name}', true);"
      echo "  ✅ Created and enabled ${sub_name}."
    fi
  done
done

echo "🎉 Spock replication setup completed."
