-- scripts/tables.sql
CREATE TABLE IF NOT EXISTS test_table (
  id SERIAL PRIMARY KEY,
  val TEXT
);

CREATE TABLE IF NOT EXISTS orders (
  id SERIAL PRIMARY KEY,
  item TEXT,
  quantity INT
);


CREATE TABLE IF NOT EXISTS new_table (
  id SERIAL PRIMARY KEY,
  item TEXT,
  quantity INT
);
