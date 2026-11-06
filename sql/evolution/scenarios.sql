-- ============================================================
-- Évolutivité : trois évolutions plausibles, jouées sur la vraie base
--
-- Chaque scénario applique l'évolution, puis vérifie :
-- - qu'aucune donnée n'est perdue ;
-- - que les règles tiennent toujours ;
-- - que le contrat d'interface (v_export_*) ne change pas.
-- Tout est annulé à la fin (ROLLBACK) : la base reste intacte.
--   ./scripts/run-sql.ps1 sql/evolution/scenarios.sql
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL client_min_messages = notice;

-- Empreinte du contrat d'interface avant toute évolution
CREATE TEMP TABLE empreinte AS
SELECT (SELECT md5(string_agg(t::text, '|' ORDER BY t.id_legacy)) FROM v_export_interventions t) AS interventions,
       (SELECT string_agg(entite || '=' || nb, ',' ORDER BY entite) FROM v_export_entites)        AS entites;

-- ------------------------------------------------------------
-- A. Nouveau statut « en attente de pièces »
--    Coût : des INSERT de données, aucune modification de table ni de trigger.
-- ------------------------------------------------------------
\echo '--- A. Nouveau statut « en attente de pièces »'
INSERT INTO statut_intervention (code, libelle, ordre, est_initial, est_final)
VALUES ('en_attente_pieces', 'En attente de pièces', 4, false, false);
INSERT INTO transition_statut (statut_depart, statut_arrivee)
VALUES ('en_cours', 'en_attente_pieces'), ('en_attente_pieces', 'en_cours');

DO $$
DECLARE v_id bigint; v_hist int;
BEGIN
  -- Nouvelle intervention (hors export) : ouverte -> en_cours -> en_attente_pieces
  INSERT INTO intervention (equipement_id, technicien_id, date_ouverture, cout_total)
  VALUES (1, 1, current_date, 0) RETURNING id INTO v_id;
  UPDATE intervention SET statut_code = 'en_cours'          WHERE id = v_id;
  UPDATE intervention SET statut_code = 'en_attente_pieces' WHERE id = v_id;

  -- Le trigger existant applique déjà la nouvelle règle : pas de clôture directe
  BEGIN
    UPDATE intervention SET statut_code = 'cloturee' WHERE id = v_id;
    RAISE EXCEPTION 'A FAIL : en_attente_pieces -> cloturee aurait dû être refusée';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'A1 PASS : en_attente_pieces -> cloturee refusée (%)', SQLERRM;
  END;

  UPDATE intervention SET statut_code = 'en_cours' WHERE id = v_id;
  UPDATE intervention SET statut_code = 'cloturee' WHERE id = v_id;
  SELECT count(*) INTO v_hist FROM historique_statut WHERE intervention_id = v_id;
  IF v_hist <> 5 THEN RAISE EXCEPTION 'A FAIL : % lignes d''historique au lieu de 5', v_hist; END IF;
  RAISE NOTICE 'A2 PASS : cycle complet accepté et historisé (% lignes : création + 4 changements)', v_hist;
END $$;

-- Le contrat impose 3 valeurs de statut. Si une intervention héritée passait
-- au nouveau statut, l'export afficherait une 4e valeur. Il faut donc dire
-- explicitement à quel statut du contrat chaque statut interne correspond.
ALTER TABLE statut_intervention ADD COLUMN statut_export text;
UPDATE statut_intervention SET statut_export = CASE code WHEN 'en_attente_pieces' THEN 'en_cours' ELSE code END;
ALTER TABLE statut_intervention
  ALTER COLUMN statut_export SET NOT NULL,
  ADD CONSTRAINT ck_statut_export CHECK (statut_export IN ('ouverte', 'en_cours', 'cloturee'));

CREATE OR REPLACE VIEW v_export_interventions AS
SELECT i.id_legacy::int, i.date_ouverture::date, i.date_cloture::date,
       s.statut_export::text AS statut,
       i.cout_total::numeric,
       (i.anomalie_date_incoherente OR i.anomalie_cloture_sans_date)::boolean AS anomalie
FROM intervention i
JOIN statut_intervention s ON s.code = i.statut_code
WHERE i.id_legacy IS NOT NULL;

DO $$
BEGIN
  -- Une intervention héritée en cours passe en attente : l'export reste à 3 valeurs
  UPDATE intervention SET statut_code = 'en_attente_pieces'
  WHERE id = (SELECT min(id) FROM intervention WHERE statut_code = 'en_cours' AND id_legacy IS NOT NULL);
  IF (SELECT count(DISTINCT statut) FROM v_export_interventions) <> 3 THEN
    RAISE EXCEPTION 'A FAIL : le contrat d''export n''a plus 3 statuts';
  END IF;
  RAISE NOTICE 'A3 PASS : le contrat d''export garde ses 3 valeurs (en_attente_pieces exporté en en_cours)';
END $$;

-- ------------------------------------------------------------
-- B. Prix des pièces
--    Le prix du catalogue peut changer. On recopie donc le prix pratiqué sur
--    chaque ligne, pour figer la valeur facturée ce jour-là.
--    Aucun prix n'existe dans les données héritées : les colonnes restent
--    vides, rien n'est inventé.
-- ------------------------------------------------------------
\echo '--- B. Prix des pièces'
ALTER TABLE piece
  ADD COLUMN prix_catalogue numeric(10,2),
  ADD CONSTRAINT ck_piece_prix CHECK (prix_catalogue >= 0);
ALTER TABLE intervention_piece
  ADD COLUMN prix_unitaire numeric(10,2),
  ADD CONSTRAINT ck_intervention_piece_prix CHECK (prix_unitaire >= 0);

DO $$
BEGIN
  IF (SELECT count(*) FROM intervention_piece) <> 362
     OR EXISTS (SELECT 1 FROM intervention_piece WHERE prix_unitaire IS NOT NULL) THEN
    RAISE EXCEPTION 'B FAIL';
  END IF;
  BEGIN
    UPDATE piece SET prix_catalogue = -1 WHERE reference = 'REF-005';
    RAISE EXCEPTION 'B FAIL : prix négatif accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'B1 PASS : 362 lignes conservées, aucun prix inventé, prix négatif refusé';
END $$;

-- ------------------------------------------------------------
-- C. Plusieurs techniciens par intervention
--    Table de liaison. technicien_id reste le responsable, ce qui préserve
--    les écrans et les droits existants.
-- ------------------------------------------------------------
\echo '--- C. Plusieurs techniciens par intervention'
CREATE TABLE intervention_technicien (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  intervention_id bigint NOT NULL REFERENCES intervention (id),
  technicien_id   bigint NOT NULL REFERENCES technicien (id),
  role            text   NOT NULL DEFAULT 'renfort' CHECK (role IN ('responsable', 'renfort')),
  CONSTRAINT uq_intervention_technicien UNIQUE (intervention_id, technicien_id)
);
-- Un seul responsable par intervention
CREATE UNIQUE INDEX uq_intervention_un_responsable
  ON intervention_technicien (intervention_id) WHERE role = 'responsable';
CREATE INDEX ix_intervention_technicien_technicien ON intervention_technicien (technicien_id);

INSERT INTO intervention_technicien (intervention_id, technicien_id, role)
SELECT id, technicien_id, 'responsable' FROM intervention;

DO $$
DECLARE v_id bigint := (SELECT min(id) FROM intervention WHERE id_legacy IS NOT NULL);
BEGIN
  IF (SELECT count(*) FROM intervention_technicien) <> (SELECT count(*) FROM intervention) THEN
    RAISE EXCEPTION 'C FAIL : reprise incomplète';
  END IF;
  INSERT INTO intervention_technicien (intervention_id, technicien_id)
  SELECT v_id, id FROM technicien
  WHERE id <> (SELECT technicien_id FROM intervention WHERE id = v_id) LIMIT 1;
  BEGIN
    INSERT INTO intervention_technicien (intervention_id, technicien_id, role)
    SELECT v_id, id, 'responsable' FROM technicien
    WHERE id NOT IN (SELECT technicien_id FROM intervention_technicien WHERE intervention_id = v_id) LIMIT 1;
    RAISE EXCEPTION 'C FAIL : deux responsables acceptés';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  RAISE NOTICE 'C1 PASS : chaque intervention reprise avec son responsable, renfort accepté, 2e responsable refusé';
END $$;

-- ------------------------------------------------------------
-- Contrat d'interface : identique à l'empreinte de départ ?
-- (seule l'intervention passée en attente au scénario A est remise en cours)
-- ------------------------------------------------------------
UPDATE intervention SET statut_code = 'en_cours' WHERE statut_code = 'en_attente_pieces' AND id_legacy IS NOT NULL;
DO $$
BEGIN
  IF (SELECT md5(string_agg(t::text, '|' ORDER BY t.id_legacy)) FROM v_export_interventions t) <> (SELECT interventions FROM empreinte)
     OR (SELECT string_agg(entite || '=' || nb, ',' ORDER BY entite) FROM v_export_entites) <> (SELECT entites FROM empreinte) THEN
    RAISE EXCEPTION 'FAIL : le contrat d''interface a changé';
  END IF;
  RAISE NOTICE 'PASS : après les 3 évolutions, le contrat d''interface est identique (%)', (SELECT entites FROM empreinte);
END $$;

ROLLBACK;
