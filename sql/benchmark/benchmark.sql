-- ============================================================
-- Benchmark : table héritée contre schéma normalisé
--
-- Même question métier, posée aux deux modèles, à 4 volumes
-- (x1, x10, x100, x1000 la volumétrie du seed).
--
-- Sans effet sur la base : tout est construit dans le schéma
-- « bench », à l'intérieur d'une transaction annulée à la fin.
-- À lancer après la migration :
--   ./scripts/run-sql.ps1 sql/benchmark/benchmark.sql
--
-- Méthode
-- - Montée en volume : chaque ligne est recopiée f fois avec un
--   nouvel id. La répartition (dates, techniciens, pièces, anomalies)
--   reste donc identique à celle du seed.
-- - Table héritée : aucun index et aucune contrainte, comme
--   l'original. Pour filtrer une date ou sommer un coût, il faut
--   convertir le texte à chaque ligne. On utilise pour cela les
--   fonctions de conversion de la migration (mp_parse_*).
-- - Schéma normalisé : mêmes index que la production
--   (sql/migration.sql).
-- - Mesure : 1 exécution d'échauffement, puis la médiane de 7.
--   Toutes les lignes et toutes les colonnes sont lues jusqu'au bout,
--   pour que PostgreSQL ne puisse pas sauter le calcul d'une colonne.
-- ============================================================
\set ON_ERROR_STOP on
\pset footer off

BEGIN;
SET LOCAL client_min_messages = warning;
CREATE SCHEMA bench;

-- -------- Les requêtes (une ligne par question et par modèle) --------
CREATE TABLE bench.requete (
  code    text,
  libelle text,
  modele  text,
  sql     text
);

INSERT INTO bench.requete VALUES
('Q1', 'Planning d''un technicien sur un mois', 'heritee', $q$
  SELECT id, client_nom, equipement, statut
  FROM bench.legacy
  WHERE technicien = 'Durand Karim'
    AND mp_parse_date(date_ouverture) >= date '2025-10-01'
    AND mp_parse_date(date_ouverture) <  date '2025-11-01' $q$),
('Q1', 'Planning d''un technicien sur un mois', 'normalise', $q$
  SELECT i.id, c.nom, e.numero_serie, i.statut_code
  FROM bench.intervention i
  JOIN equipement e ON e.id = i.equipement_id
  JOIN client c     ON c.id = e.client_id
  WHERE i.technicien_id = (SELECT id FROM technicien WHERE nom = 'Durand' AND prenom = 'Karim')
    AND i.date_ouverture >= date '2025-10-01'
    AND i.date_ouverture <  date '2025-11-01' $q$),

('Q2', 'Chiffre d''affaires 2025 par client', 'heritee', $q$
  SELECT client_nom, sum(mp_parse_cout(cout_total)) AS ca
  FROM bench.legacy
  WHERE mp_parse_date(date_ouverture) >= date '2025-01-01'
    AND mp_parse_date(date_ouverture) <  date '2026-01-01'
  GROUP BY client_nom $q$),
('Q2', 'Chiffre d''affaires 2025 par client', 'normalise', $q$
  SELECT c.id, c.nom, sum(i.cout_total) AS ca
  FROM bench.intervention i
  JOIN equipement e ON e.id = i.equipement_id
  JOIN client c     ON c.id = e.client_id
  WHERE i.date_ouverture >= date '2025-01-01'
    AND i.date_ouverture <  date '2026-01-01'
  GROUP BY c.id, c.nom $q$),

('Q3', 'Interventions ayant utilisé la pièce REF-005', 'heritee', $q$
  SELECT id FROM bench.legacy WHERE pieces_utilisees LIKE '%REF-005%' $q$),
('Q3', 'Interventions ayant utilisé la pièce REF-005', 'normalise', $q$
  SELECT ip.intervention_id
  FROM bench.intervention_piece ip
  JOIN piece p ON p.id = ip.piece_id
  WHERE p.reference = 'REF-005' $q$),

('Q4', 'Anomalies à vérifier', 'heritee', $q$
  SELECT id FROM bench.legacy
  WHERE mp_parse_date(date_cloture) < mp_parse_date(date_ouverture)
     OR (mp_norm_statut(statut) = 'cloturee' AND mp_parse_date(date_cloture) IS NULL) $q$),
('Q4', 'Anomalies à vérifier', 'normalise', $q$
  SELECT id FROM bench.intervention
  WHERE anomalie_date_incoherente OR anomalie_cloture_sans_date $q$),

('Q5', '20 interventions les plus récentes (tableau de bord)', 'heritee', $q$
  SELECT id, client_nom, date_ouverture
  FROM bench.legacy
  ORDER BY mp_parse_date(date_ouverture) DESC, id DESC
  LIMIT 20 $q$),
('Q5', '20 interventions les plus récentes (tableau de bord)', 'normalise', $q$
  SELECT id, equipement_id, date_ouverture
  FROM bench.intervention
  ORDER BY date_ouverture DESC
  LIMIT 20 $q$);

CREATE TABLE bench.resultat (
  facteur          int,
  nb_interventions bigint,
  code             text,
  modele           text,
  mediane_ms       numeric,
  lignes           bigint
);

-- -------- Construction des deux modèles au volume f --------
CREATE FUNCTION bench.construire(f int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DROP TABLE IF EXISTS bench.legacy, bench.intervention_piece, bench.intervention;

  -- Copie conforme de la table héritée : aucun index, aucune contrainte
  CREATE TABLE bench.legacy AS
    SELECT (g - 1) * 1000 + l.id AS id,
           l.client_nom, l.client_email, l.client_tel, l.client_adresse, l.contrat_ref,
           l.contrat_sla, l.technicien, l.technicien_tel, l.equipement, l.equipement_serie,
           l.pieces_utilisees, l.date_ouverture, l.date_cloture, l.statut, l.cout_total
    FROM interventions_legacy l CROSS JOIN generate_series(1, f) g;

  -- Schéma normalisé : mêmes index que la production
  CREATE TABLE bench.intervention AS
    SELECT (g - 1) * 1000 + i.id AS id,
           i.equipement_id, i.technicien_id, i.statut_code, i.date_ouverture, i.date_cloture,
           i.cout_total, i.anomalie_date_incoherente, i.anomalie_cloture_sans_date
    FROM intervention i CROSS JOIN generate_series(1, f) g;
  ALTER TABLE bench.intervention ADD PRIMARY KEY (id);
  CREATE INDEX ON bench.intervention (equipement_id);
  CREATE INDEX ON bench.intervention (technicien_id, date_ouverture);
  CREATE INDEX ON bench.intervention (statut_code);
  CREATE INDEX ON bench.intervention (date_ouverture);

  CREATE TABLE bench.intervention_piece AS
    SELECT (g - 1) * 1000 + ip.intervention_id AS intervention_id, ip.piece_id, ip.quantite
    FROM intervention_piece ip CROSS JOIN generate_series(1, f) g;
  ALTER TABLE bench.intervention_piece ADD UNIQUE (intervention_id, piece_id);
  CREATE INDEX ON bench.intervention_piece (piece_id);

  ANALYZE bench.legacy;
  ANALYZE bench.intervention;
  ANALYZE bench.intervention_piece;
END $$;

-- -------- Mesure : échauffement puis médiane de n exécutions --------
CREATE FUNCTION bench.mesurer(f int, n int DEFAULT 7) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  q record; r record; t0 timestamptz; nb bigint; durees numeric[];
BEGIN
  FOR q IN SELECT * FROM bench.requete ORDER BY code, modele LOOP
    durees := '{}';
    FOR k IN 0..n LOOP
      nb := 0;
      t0 := clock_timestamp();
      FOR r IN EXECUTE q.sql LOOP nb := nb + 1; END LOOP;   -- reads every row
      IF k > 0 THEN                                          -- k = 0: warm-up
        durees := durees || (extract(epoch FROM clock_timestamp() - t0) * 1000)::numeric;
      END IF;
    END LOOP;
    INSERT INTO bench.resultat
    SELECT f, (SELECT count(*) FROM bench.intervention), q.code, q.modele,
           round((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY d) FROM unnest(durees) d)::numeric, 3),
           nb;
  END LOOP;
END $$;

-- Plan d'exécution réel d'une requête, sans les durées (pour qu'il soit stable)
CREATE FUNCTION bench.plan(p_code text, p_modele text) RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE l text;
BEGIN
  FOR l IN EXECUTE 'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) '
                   || (SELECT sql FROM bench.requete WHERE code = p_code AND modele = p_modele) LOOP
    RETURN NEXT l;
  END LOOP;
END $$;

SELECT bench.construire(1);    SELECT bench.mesurer(1);
SELECT bench.construire(10);   SELECT bench.mesurer(10);
SELECT bench.construire(100);  SELECT bench.mesurer(100);
SELECT bench.construire(1000); SELECT bench.mesurer(1000);

\echo
\echo '=== Environnement'
SELECT version() AS postgresql,
       current_setting('max_parallel_workers_per_gather') AS workers_paralleles,
       current_setting('jit') AS jit,
       current_setting('shared_buffers') AS shared_buffers;

\echo '=== Résultats : médiane en millisecondes, gain = héritée / normalisé'
SELECT h.code, rq.libelle, h.nb_interventions AS interventions,
       h.mediane_ms AS heritee_ms, n.mediane_ms AS normalise_ms,
       round(h.mediane_ms / nullif(n.mediane_ms, 0), 1) AS gain,
       h.lignes AS lignes_heritee, n.lignes AS lignes_normalise
FROM bench.resultat h
JOIN bench.resultat n ON n.facteur = h.facteur AND n.code = h.code AND n.modele = 'normalise'
JOIN (SELECT DISTINCT code, libelle FROM bench.requete) rq ON rq.code = h.code
WHERE h.modele = 'heritee'
ORDER BY h.code, h.facteur;

\echo '=== Plans d''exécution à 271 000 interventions'
\echo '--- Q1 héritée'
SELECT * FROM bench.plan('Q1', 'heritee');
\echo '--- Q1 normalisé'
SELECT * FROM bench.plan('Q1', 'normalise');
\echo '--- Q3 héritée'
SELECT * FROM bench.plan('Q3', 'heritee');
\echo '--- Q3 normalisé'
SELECT * FROM bench.plan('Q3', 'normalise');
\echo '--- Q5 héritée'
SELECT * FROM bench.plan('Q5', 'heritee');
\echo '--- Q5 normalisé'
SELECT * FROM bench.plan('Q5', 'normalise');

-- -------- Le prix de l'intégrité : coût d'écriture --------
-- 10 000 nouvelles interventions, insérées dans :
-- - la table héritée (aucun contrôle) ;
-- - la vraie table intervention : 3 clés étrangères, CHECK,
--   colonnes calculées, 5 index, trigger de règles et trigger
--   d'historique (une ligne d'historique par création).
\echo '=== Écriture de 10 000 interventions (médiane de 5, après échauffement)'
CREATE TABLE bench.legacy_ecriture (LIKE interventions_legacy INCLUDING DEFAULTS);

CREATE FUNCTION bench.mesurer_ecriture(p_sql text, n int DEFAULT 5) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; durees numeric[] := '{}';
BEGIN
  FOR k IN 0..n LOOP
    t0 := clock_timestamp();
    EXECUTE p_sql;
    IF k > 0 THEN
      durees := durees || (extract(epoch FROM clock_timestamp() - t0) * 1000)::numeric;
    END IF;
  END LOOP;
  RETURN round((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY d) FROM unnest(durees) d)::numeric, 1);
END $$;

SELECT
  bench.mesurer_ecriture($q$
    INSERT INTO bench.legacy_ecriture (client_nom, technicien, equipement_serie, date_ouverture, statut, cout_total)
    SELECT 'Client ' || g % 21, 'Durand Karim', 'SN-' || g % 40, '01/02/2026', 'ouvert', '120,00 €'
    FROM generate_series(1, 10000) g $q$) AS heritee_ms,
  bench.mesurer_ecriture($q$
    INSERT INTO intervention (equipement_id, technicien_id, date_ouverture, cout_total)
    SELECT 1 + g % 40, 1 + g % 8, date '2026-02-01', 120
    FROM generate_series(1, 10000) g $q$) AS normalise_ms;

\echo '--- Détail du coût d''une écriture de 10 000 interventions dans le schéma normalisé'
EXPLAIN (ANALYZE, COSTS OFF)
INSERT INTO intervention (equipement_id, technicien_id, date_ouverture, cout_total)
SELECT 1 + g % 40, 1 + g % 8, date '2026-02-01', 120
FROM generate_series(1, 10000) g;

ROLLBACK;
