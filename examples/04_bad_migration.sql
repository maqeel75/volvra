-- Volvra example 4: undo a bad migration across several tables.
--
--   psql -f examples/04_bad_migration.sql
--
-- One transaction is the unit a person remembers, and it spans every table
-- the migration touched.  The transaction id is captured inside the
-- transaction, so there is no guessing which one to revert.

DROP TABLE IF EXISTS stock;
DROP TABLE IF EXISTS products;
CREATE TABLE products (id int PRIMARY KEY, sku text, price numeric);
CREATE TABLE stock    (id int PRIMARY KEY, product_id int, qty int);

SELECT volvra.enable('products');
SELECT volvra.enable('stock');
INSERT INTO products VALUES (1,'widget',9.99), (2,'gizmo',19.99);
INSERT INTO stock    VALUES (10,1,100), (11,2,200);

\echo ''
\echo '=== 1. the migration: one transaction, two tables, all wrong ==='
SET volvra.actor = 'deploy:migration-042';
BEGIN;
  SELECT txid_current() AS bad_txid \gset
  UPDATE products SET price = price * 100;
  UPDATE stock    SET qty = 0;
  INSERT INTO stock VALUES (12,1,-5);
COMMIT;

SELECT * FROM products ORDER BY id;
SELECT * FROM stock ORDER BY id;

\echo '=== 2. how you would find it without knowing the id ==='
SELECT txid, actors, tables, inserts, updates, deletes
FROM volvra.transactions() LIMIT 3;

\echo '=== 3. preview the whole transaction ==='
SELECT seq, table_name, op, inverse_op, pk
FROM volvra.preview_undo_txid(:bad_txid);

\echo '=== 4. one identifier undoes all of it ==='
SELECT seq, table_name, inverse_op, pk, status
FROM volvra.undo_txid(:bad_txid, confirm => true);

\echo '=== 5. both tables restored, the accidental row gone ==='
SELECT * FROM products ORDER BY id;
SELECT * FROM stock ORDER BY id;
