#!/bin/bash
set -e

echo "📦 Using database: ${APPDB}"

# Split clusters and tables passed via env
IFS=' ' read -r -a clusters <<< "$CLUSTERS"
IFS=' ' read -r -a tables <<< "${TABLES:-}"

echo "📡 Clusters: ${clusters[*]}"
if [ ${#tables[@]} -gt 0 ]; then
  echo "📑 Tables for replication: ${tables[*]}"
fi

# Wait until all primary pods are ready
for cluster in "${clusters[@]}"; do
  host="$cluster-rw.${NAMESPACE}.svc.cluster.local"
  pw_var="PGPASSWORD_$(echo $cluster | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
  cluster_pw=${!pw_var}

  echo "⏳ Waiting for $cluster primary pod to accept connections..."
  until PGPASSWORD="$cluster_pw" psql -h "$host" -U postgres -d "$APPDB" -c '\q' 2>/dev/null; do
    sleep 5
  done
  echo "✅ $cluster primary ready"
done

echo "🚀 Creating Spock nodes, tables, and replication sets..."
for cluster in "${clusters[@]}"; do
  host="$cluster-rw.${NAMESPACE}.svc.cluster.local"
  node_name=$(echo "$cluster" | tr '-' '_')
  pw_var="PGPASSWORD_$(echo $cluster | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
  cluster_pw=${!pw_var}

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
DO '
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM spock.replication_set WHERE set_name = ''default''
    ) THEN
        PERFORM spock.repset_create(''default'');
    END IF;
END';
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

    echo "➕ Adding $tbl to replication set on $cluster"
    PGPASSWORD="$cluster_pw" psql -h "$host" -U postgres -d "$APPDB" <<SQL
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
END;
\$\$;
SQL
  done
done

echo "🔗 Creating Spock subscriptions (full mesh)..."
for src in "${clusters[@]}"; do
  src_host="$src-rw.${NAMESPACE}.svc.cluster.local"
  src_pw_var="PGPASSWORD_$(echo "$src" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
  src_pw=${!src_pw_var}
  
  for tgt in "${clusters[@]}"; do
    if [ "$src" != "$tgt" ]; then
      tgt_host="$tgt-rw.${NAMESPACE}.svc.cluster.local"
      tgt_pw_var="PGPASSWORD_$(echo "$tgt" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
      tgt_pw=${!tgt_pw_var}
      sub_name="sub_$(echo "$src" | tr '-' '_')_to_$(echo "$tgt" | tr '-' '_')"
  
      # Create subscription only if it doesn’t exist
      sub_exists=$(PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -tAc \
        "SELECT 1 FROM spock.subscription WHERE sub_name='$sub_name';")

      if [ "$sub_exists" == "1" ]; then
        echo "✅ Subscription $sub_name already exists, skipping."
      else
        echo "Creating subscription $sub_name from $src to $tgt"
        PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "
SELECT spock.sub_create(
  subscription_name := '$sub_name',
  provider_dsn := 'host=$tgt_host port=5432 dbname=$APPDB user=postgres password=$tgt_pw',
  replication_sets := ARRAY['default'],
  synchronize_data := true,
  forward_origins := '{}'
);"
        PGPASSWORD="$src_pw" psql -h "$src_host" -U postgres -d "$APPDB" -c "
SELECT spock.sub_enable('$sub_name', true);"
      fi
    fi
  done
done

echo "🎉 Spock replication setup completed."

