-- =====================================================================
-- Automated tests of the migration. Each check raises on failure.
-- Expected values are recomputed from interventions_legacy with an
-- implementation independent from the migration functions.
-- Everything runs in a transaction that is rolled back: no side effect.
-- Run: ./scripts/test.ps1  (also checks that a second migration run is a no-op)
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;

-- Independent reading of the legacy data (regexes only, no mp_* function)
CREATE TEMP TABLE attendu ON COMMIT DROP AS
SELECT l.id,
       CASE WHEN date_ouverture ~ '^\d{4}-' THEN to_date(date_ouverture, 'YYYY-MM-DD')
            WHEN date_ouverture ~ '/'       THEN to_date(date_ouverture, 'DD/MM/YYYY')
            ELSE to_date(date_ouverture, 'DD-MM-YY') END AS ouverture,
       CASE WHEN date_cloture !~ '\d'      THEN NULL
            WHEN date_cloture ~ '^\d{4}-'  THEN to_date(date_cloture, 'YYYY-MM-DD')
            WHEN date_cloture ~ '/'        THEN to_date(date_cloture, 'DD/MM/YYYY')
            ELSE to_date(date_cloture, 'DD-MM-YY') END AS cloture,
       CASE WHEN statut ~* '^(clos|clotur|clôtur)' THEN 'cloturee'
            WHEN statut ~* 'cours' THEN 'en_cours' ELSE 'ouverte' END AS statut,
       translate(substring(cout_total FROM '[0-9]+[.,][0-9]+'), ',', '.')::numeric AS cout,
       coalesce(array_length(regexp_matches_count.n, 1), 0) AS n_pieces
FROM interventions_legacy l
LEFT JOIN LATERAL (SELECT array_agg(m) AS n FROM regexp_matches(coalesce(l.pieces_utilisees, ''), 'REF-\d+', 'g') m)
       AS regexp_matches_count ON true;

\echo '--- T01 no intervention lost, every legacy id present exactly once'
DO $$
DECLARE manquants bigint; doublons bigint;
BEGIN
  SELECT count(*) INTO manquants FROM attendu a
  WHERE NOT EXISTS (SELECT 1 FROM v_export_interventions v WHERE v.id_legacy = a.id);
  SELECT count(*) - count(DISTINCT id_legacy) INTO doublons FROM v_export_interventions;
  IF manquants <> 0 OR doublons <> 0 OR (SELECT count(*) FROM v_export_interventions) <> (SELECT count(*) FROM attendu) THEN
    RAISE EXCEPTION 'T01 FAIL: % manquants, % doublons', manquants, doublons;
  END IF;
  RAISE NOTICE 'T01 PASS';
END $$;

\echo '--- T02 each migrated value equals the independent reading'
DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM attendu a JOIN v_export_interventions v ON v.id_legacy = a.id
  WHERE v.date_ouverture IS DISTINCT FROM a.ouverture
     OR v.date_cloture IS DISTINCT FROM a.cloture
     OR v.statut IS DISTINCT FROM a.statut
     OR v.cout_total IS DISTINCT FROM a.cout;
  IF n <> 0 THEN RAISE EXCEPTION 'T02 FAIL: % lignes differentes', n; END IF;
  RAISE NOTICE 'T02 PASS';
END $$;

\echo '--- T03 total cost preserved to the cent'
DO $$
BEGIN
  IF (SELECT sum(cout_total) FROM v_export_interventions) <> (SELECT sum(cout) FROM attendu) THEN
    RAISE EXCEPTION 'T03 FAIL';
  END IF;
  RAISE NOTICE 'T03 PASS';
END $$;

\echo '--- T04 exactly the 3 allowed status values'
DO $$
BEGIN
  IF (SELECT count(DISTINCT statut) FROM v_export_interventions) <> 3
     OR EXISTS (SELECT 1 FROM v_export_interventions WHERE statut NOT IN ('ouverte', 'en_cours', 'cloturee')) THEN
    RAISE EXCEPTION 'T04 FAIL';
  END IF;
  RAISE NOTICE 'T04 PASS';
END $$;

\echo '--- T05 anomaly flag matches the documented definition'
DO $$
DECLARE attendues bigint;
BEGIN
  SELECT count(*) INTO attendues FROM attendu
  WHERE cloture < ouverture OR (statut = 'cloturee' AND cloture IS NULL);
  IF (SELECT count(*) FILTER (WHERE anomalie) FROM v_export_interventions) <> attendues
     OR EXISTS (SELECT 1 FROM attendu a JOIN v_export_interventions v ON v.id_legacy = a.id
                WHERE v.anomalie <> (coalesce(a.cloture < a.ouverture, false) OR (a.statut = 'cloturee' AND a.cloture IS NULL))) THEN
    RAISE EXCEPTION 'T05 FAIL';
  END IF;
  RAISE NOTICE 'T05 PASS (% anomalies)', attendues;
END $$;

\echo '--- T06 entity counts after cleaning'
DO $$
DECLARE e record;
BEGIN
  FOR e IN
    SELECT v.entite, v.nb, x.attendu FROM v_export_entites v JOIN (VALUES
      ('clients',       (SELECT count(DISTINCT btrim(client_tel)) FROM interventions_legacy)),
      ('techniciens',   (SELECT count(DISTINCT btrim(technicien_tel)) FROM interventions_legacy)),
      ('equipements',   (SELECT count(DISTINCT btrim(equipement_serie)) FROM interventions_legacy)),
      ('lignes_pieces', (SELECT sum(n_pieces) FROM attendu))
    ) AS x(entite, attendu) ON x.entite = v.entite
  LOOP
    IF e.nb <> e.attendu THEN RAISE EXCEPTION 'T06 FAIL: % = % au lieu de %', e.entite, e.nb, e.attendu; END IF;
  END LOOP;
  IF (SELECT count(*) FROM v_export_entites) <> 4 THEN RAISE EXCEPTION 'T06 FAIL: 4 lignes attendues'; END IF;
  RAISE NOTICE 'T06 PASS';
END $$;

\echo '--- T07 structural integrity: >= 4 foreign keys and >= 1 CHECK'
DO $$
DECLARE n_fk bigint; n_ck bigint;
BEGIN
  SELECT count(*) INTO n_fk FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
  WHERE c.contype = 'f' AND pg_get_userbyid(t.relowner) = 'mp_owner';
  SELECT count(*) INTO n_ck FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
  WHERE c.contype = 'c' AND pg_get_userbyid(t.relowner) = 'mp_owner';
  IF n_fk < 4 OR n_ck < 1 THEN RAISE EXCEPTION 'T07 FAIL'; END IF;
  RAISE NOTICE 'T07 PASS (% FK, % CHECK)', n_fk, n_ck;
END $$;

-- ---------------------------------------------------------------------
-- Negative tests, executed as the application login role
-- ---------------------------------------------------------------------
SET SESSION AUTHORIZATION directus_app;

\echo '--- T08 the application cannot delete an intervention'
DO $$
BEGIN
  DELETE FROM intervention WHERE id_legacy = 1;
  RAISE EXCEPTION 'T08 FAIL: suppression acceptee';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'T08 PASS';
END $$;

\echo '--- T09 the application cannot read the legacy table, write the history or alter the schema'
DO $$
BEGIN
  BEGIN PERFORM 1 FROM interventions_legacy LIMIT 1; RAISE EXCEPTION 'T09 FAIL: legacy lisible';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN INSERT INTO historique_statut (intervention_id, statut_apres) VALUES (1, 'ouverte'); RAISE EXCEPTION 'T09 FAIL: historique modifiable';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN ALTER TABLE intervention ADD COLUMN pirate text; RAISE EXCEPTION 'T09 FAIL: schema modifiable';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  RAISE NOTICE 'T09 PASS';
END $$;

\echo '--- T10 forbidden transition is rejected (ouverte -> cloturee)'
DO $$
DECLARE v_id bigint;
BEGIN
  SELECT id INTO v_id FROM intervention WHERE statut_code = 'ouverte' ORDER BY id LIMIT 1;
  UPDATE intervention SET statut_code = 'cloturee' WHERE id = v_id;
  RAISE EXCEPTION 'T10 FAIL: transition acceptee';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'T10 PASS (%)', SQLERRM;
END $$;

\echo '--- T11 closing sets the closing date and writes the history'
DO $$
DECLARE v_id bigint; v_date date; v_hist bigint;
BEGIN
  SELECT id INTO v_id FROM intervention WHERE statut_code = 'en_cours' ORDER BY id LIMIT 1;
  UPDATE intervention SET statut_code = 'cloturee' WHERE id = v_id RETURNING date_cloture INTO v_date;
  SELECT count(*) INTO v_hist FROM historique_statut
  WHERE intervention_id = v_id AND statut_avant = 'en_cours' AND statut_apres = 'cloturee' AND role_bdd = 'directus_app';
  IF v_date IS NULL OR v_hist <> 1 THEN RAISE EXCEPTION 'T11 FAIL: date %, historique %', v_date, v_hist; END IF;
  RAISE NOTICE 'T11 PASS (date de cloture %)', v_date;
END $$;

\echo '--- T12 a closed intervention is final (no reopening)'
DO $$
DECLARE v_id bigint;
BEGIN
  SELECT id INTO v_id FROM intervention WHERE statut_code = 'cloturee' AND NOT anomalie_date_incoherente ORDER BY id LIMIT 1;
  UPDATE intervention SET statut_code = 'en_cours' WHERE id = v_id;
  RAISE EXCEPTION 'T12 FAIL';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'T12 PASS';
END $$;

\echo '--- T13 a new intervention must start open and without closing date'
DO $$
DECLARE v_eq bigint; v_tech bigint;
BEGIN
  SELECT id INTO v_eq FROM equipement LIMIT 1;
  SELECT id INTO v_tech FROM technicien LIMIT 1;
  BEGIN
    INSERT INTO intervention (equipement_id, technicien_id, statut_code) VALUES (v_eq, v_tech, 'cloturee');
    RAISE EXCEPTION 'T13 FAIL: statut initial accepte';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO intervention (equipement_id, technicien_id, date_ouverture, date_cloture)
    VALUES (v_eq, v_tech, DATE '2026-01-10', DATE '2026-01-05');
    RAISE EXCEPTION 'T13 FAIL: date de cloture acceptee';
  EXCEPTION WHEN check_violation THEN NULL; END;
  INSERT INTO intervention (equipement_id, technicien_id, cout_total) VALUES (v_eq, v_tech, 120);
  RAISE NOTICE 'T13 PASS';
END $$;

\echo '--- T14 an incoherent legacy row stays flagged, and cannot be "fixed" with another incoherent date'
DO $$
DECLARE v_id bigint; v_ouv date;
BEGIN
  SELECT id, date_ouverture INTO v_id, v_ouv FROM intervention WHERE anomalie_date_incoherente ORDER BY id LIMIT 1;
  BEGIN
    UPDATE intervention SET date_cloture = v_ouv - 1 WHERE id = v_id;
    RAISE EXCEPTION 'T14 FAIL: date incoherente acceptee';
  EXCEPTION WHEN check_violation THEN NULL; END;
  UPDATE intervention SET date_cloture = v_ouv WHERE id = v_id;     -- explicit, coherent correction
  IF (SELECT anomalie_date_incoherente FROM intervention WHERE id = v_id) THEN
    RAISE EXCEPTION 'T14 FAIL: drapeau non recalcule';
  END IF;
  RAISE NOTICE 'T14 PASS';
END $$;

RESET SESSION AUTHORIZATION;
ROLLBACK;
\echo '=== all tests passed (changes rolled back)'
