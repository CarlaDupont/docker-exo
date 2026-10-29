-- même calcul que seed.sh (id + status des commandes)
SELECT 'commandes=' || count(*) || ' checksum=' || coalesce(md5(string_agg(id::text || status, ',' ORDER BY id)), 'vide') FROM orders;
-- toutes les colonnes de orders et products
SELECT 'checksum_complet=' || md5(
  coalesce((SELECT string_agg(o::text, ',' ORDER BY o.id) FROM orders o), '') ||
  coalesce((SELECT string_agg(p::text, ',' ORDER BY p.id) FROM products p), ''));
