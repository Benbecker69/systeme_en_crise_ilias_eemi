-- =====================================================================
-- Registers the "one-to-many" side of our foreign keys in Directus.
--
-- Directus' API recreates the foreign key constraint whenever relation
-- metadata is saved. Our tables belong to mp_owner, so the application
-- role cannot do that (by design: only sql/migration.sql changes the
-- schema). The metadata is therefore written directly in Directus' own
-- table. No business table is touched. Re-runnable.
-- Run: ./scripts/run-sql.ps1 directus/relations.sql
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO directus_relations (many_collection, many_field, one_collection, one_field, one_deselect_action)
SELECT v.many_collection, v.many_field, v.one_collection, v.one_field, 'nullify'
FROM (VALUES
  -- Application user of the last change: metadata only, no foreign key
  -- from business tables toward Directus' internal users table
  ('intervention',       'modifie_par',     'directus_users', NULL),
  ('historique_statut',  'utilisateur_app', 'directus_users', NULL),
  ('intervention',       'technicien_id',   'technicien',   'interventions'),
  ('intervention',       'equipement_id',   'equipement',   'interventions'),
  ('equipement',         'client_id',       'client',       'equipements'),
  ('contrat',            'client_id',       'client',       'contrats'),
  ('intervention_piece', 'intervention_id', 'intervention', 'pieces'),
  ('historique_statut',  'intervention_id', 'intervention', 'historique')
) AS v(many_collection, many_field, one_collection, one_field)
WHERE NOT EXISTS (
  SELECT 1 FROM directus_relations r
  WHERE r.many_collection = v.many_collection AND r.many_field = v.many_field
);

-- Keep the one_field in sync if the row already existed
UPDATE directus_relations r
SET one_field = v.one_field
FROM (VALUES
  ('intervention',       'technicien_id',   'interventions'),
  ('intervention',       'equipement_id',   'interventions'),
  ('equipement',         'client_id',       'equipements'),
  ('contrat',            'client_id',       'contrats'),
  ('intervention_piece', 'intervention_id', 'pieces'),
  ('historique_statut',  'intervention_id', 'historique')
) AS v(many_collection, many_field, one_field)
WHERE r.many_collection = v.many_collection AND r.many_field = v.many_field
  AND r.one_field IS DISTINCT FROM v.one_field;

COMMIT;
