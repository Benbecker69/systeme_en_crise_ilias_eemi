-- =====================================================================
-- MaintenancePro: migration of interventions_legacy to a normalized schema
--
-- Re-runnable: running it twice neither fails nor duplicates anything.
--   * objects are created with IF NOT EXISTS / CREATE OR REPLACE;
--   * data is inserted with ON CONFLICT (natural key) DO NOTHING, so a
--     re-run keeps the changes made in the application since the first run.
-- Safe: one transaction. Every assumption on the legacy data is checked
-- first and the migration aborts (nothing written) if one does not hold.
-- No legacy row is deleted or silently corrected: the legacy table stays
-- untouched and incoherent interventions are migrated as-is and flagged.
--
-- Run: ./scripts/run-sql.ps1 sql/migration.sql   (as the postgres superuser)
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;
-- Hide the "already exists, skipping" notices of a re-run; errors still show
SET LOCAL client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 1. Roles (cluster-wide, created only if missing)
--    mp_owner       owns every business object (no login)
--    mp_application read/write privileges for the application, no DDL
--    mp_lecture     read-only access to the reporting views
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mp_owner') THEN
    CREATE ROLE mp_owner NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mp_application') THEN
    CREATE ROLE mp_application NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mp_lecture') THEN
    CREATE ROLE mp_lecture NOLOGIN;
  END IF;
  -- The no-code tool login role exists only in the Docker stack
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'directus_app') THEN
    GRANT mp_application TO directus_app;
  END IF;
END $$;

GRANT USAGE, CREATE ON SCHEMA public TO mp_owner;
GRANT USAGE ON SCHEMA public TO mp_application, mp_lecture;
REVOKE ALL ON interventions_legacy FROM PUBLIC;
GRANT SELECT ON interventions_legacy TO mp_owner;

-- Everything below is created by, and belongs to, mp_owner
SET LOCAL ROLE mp_owner;

-- ---------------------------------------------------------------------
-- 2. Cleaning functions: strict, an unknown format raises an error
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mp_norm_texte(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(regexp_replace(btrim(p), '\s+', ' ', 'g'), '')
$$;

CREATE OR REPLACE FUNCTION mp_parse_date(p text) RETURNS date
LANGUAGE plpgsql STABLE AS $$
DECLARE v text := btrim(p);
BEGIN
  IF v IS NULL OR v IN ('', 'N/A') THEN
    RETURN NULL;                                  -- the 3 legacy ways to say "no date"
  ELSIF v ~ '^\d{4}-\d{2}-\d{2}$' THEN
    RETURN to_date(v, 'YYYY-MM-DD');
  ELSIF v ~ '^\d{2}/\d{2}/\d{4}$' THEN
    RETURN to_date(v, 'DD/MM/YYYY');
  ELSIF v ~ '^\d{2}-\d{2}-\d{2}$' THEN
    RETURN to_date(v, 'DD-MM-YY');                -- YY resolves to the closest year to 2020
  END IF;
  RAISE EXCEPTION 'Format de date inconnu : «%»', p USING ERRCODE = 'invalid_datetime_format';
END $$;

CREATE OR REPLACE FUNCTION mp_parse_cout(p text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v text := regexp_replace(btrim(p), '\s*(€|EUR)$', '');
BEGIN
  IF v ~ '^\d+([.,]\d{1,2})?$' THEN
    RETURN replace(v, ',', '.')::numeric(10,2);
  END IF;
  RAISE EXCEPTION 'Format de montant inconnu : «%»', p USING ERRCODE = 'invalid_text_representation';
END $$;

CREATE OR REPLACE FUNCTION mp_norm_statut(p text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  CASE lower(btrim(p))
    WHEN 'clos', 'cloture', 'clôturé' THEN RETURN 'cloturee';
    WHEN 'en cours'                   THEN RETURN 'en_cours';
    WHEN 'ouvert', 'nouveau'          THEN RETURN 'ouverte';
    ELSE RAISE EXCEPTION 'Statut inconnu : «%»', p USING ERRCODE = 'invalid_text_representation';
  END CASE;
END $$;

CREATE OR REPLACE FUNCTION mp_parse_sla(p text) RETURNS integer
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE m text[] := regexp_match(btrim(p), '^(\d+)\s*(h|heures)?$');
BEGIN
  IF m IS NULL THEN
    RAISE EXCEPTION 'Format de SLA inconnu : «%»', p USING ERRCODE = 'invalid_text_representation';
  END IF;
  RETURN m[1]::integer;
END $$;

-- ---------------------------------------------------------------------
-- 3. Pre-checks: the deduplication keys proven 1:1 in the audit (A14)
--    must still hold, otherwise the migration stops here.
-- ---------------------------------------------------------------------
DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) - count(DISTINCT id) + count(*) FILTER (WHERE id IS NULL) INTO n FROM interventions_legacy;
  IF n > 0 THEN RAISE EXCEPTION 'Identifiants hérités en double ou nuls : %', n; END IF;

  SELECT count(*) INTO n FROM (
    SELECT btrim(client_tel) FROM interventions_legacy GROUP BY 1
    HAVING count(DISTINCT btrim(contrat_ref)) > 1
        OR count(DISTINCT lower(btrim(client_email))) > 1
        OR count(DISTINCT btrim(client_adresse)) > 1) x;
  IF n > 0 THEN RAISE EXCEPTION 'Téléphones client ambigus (contrat, e-mail ou adresse multiples) : %', n; END IF;

  SELECT count(*) INTO n FROM (
    SELECT btrim(contrat_ref) FROM interventions_legacy GROUP BY 1
    HAVING count(DISTINCT btrim(client_tel)) > 1 OR count(DISTINCT mp_parse_sla(contrat_sla)) > 1) x;
  IF n > 0 THEN RAISE EXCEPTION 'Contrats ambigus (plusieurs clients ou SLA) : %', n; END IF;

  SELECT count(*) INTO n FROM (
    SELECT btrim(equipement_serie) FROM interventions_legacy GROUP BY 1
    HAVING count(DISTINCT btrim(equipement)) > 1 OR count(DISTINCT btrim(client_tel)) > 1) x;
  IF n > 0 THEN RAISE EXCEPTION 'Numéros de série ambigus (plusieurs types ou clients) : %', n; END IF;

  SELECT count(*) INTO n FROM (
    SELECT btrim(technicien_tel) FROM interventions_legacy GROUP BY 1
    HAVING count(DISTINCT mp_norm_texte(technicien)) > 1) x;
  IF n > 0 THEN RAISE EXCEPTION 'Téléphones technicien ambigus : %', n; END IF;

  SELECT count(*) INTO n FROM interventions_legacy
  WHERE client_adresse !~ '^.+, \d{5} .+$' OR mp_norm_texte(technicien) !~ '^\S+ \S+$';
  IF n > 0 THEN RAISE EXCEPTION 'Adresses ou noms de technicien hors format : %', n; END IF;

  SELECT count(*) INTO n
  FROM interventions_legacy, regexp_split_to_table(pieces_utilisees, '\s*[;,|]\s*') AS t
  WHERE pieces_utilisees ~ 'REF-' AND btrim(t) !~ '^REF-\d+ x\d+$';
  IF n > 0 THEN RAISE EXCEPTION 'Lignes de pièces hors format : %', n; END IF;
END $$;

-- ---------------------------------------------------------------------
-- 4. Schema
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS client (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nom         text NOT NULL,
  email       text,
  telephone   text NOT NULL,
  adresse     text NOT NULL,
  code_postal text NOT NULL,
  ville       text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_client_telephone UNIQUE (telephone),
  CONSTRAINT uq_client_email UNIQUE (email),
  CONSTRAINT ck_client_nom CHECK (nom = mp_norm_texte(nom)),
  CONSTRAINT ck_client_email CHECK (email = lower(email) AND email ~ '^[^@\s]+@[^@\s]+\.[a-z]+$'),
  CONSTRAINT ck_client_telephone CHECK (telephone ~ '^0\d{9}$'),
  CONSTRAINT ck_client_code_postal CHECK (code_postal ~ '^\d{5}$')
);

CREATE TABLE IF NOT EXISTS contrat (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reference  text NOT NULL,
  client_id  bigint NOT NULL,
  sla_heures integer NOT NULL,
  CONSTRAINT uq_contrat_reference UNIQUE (reference),
  CONSTRAINT fk_contrat_client FOREIGN KEY (client_id) REFERENCES client (id),
  CONSTRAINT ck_contrat_sla CHECK (sla_heures > 0)
);

CREATE TABLE IF NOT EXISTS technicien (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nom        text NOT NULL,
  prenom     text NOT NULL,
  telephone  text NOT NULL,
  email      text,                                -- links the person to an application account
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_technicien_telephone UNIQUE (telephone),
  CONSTRAINT uq_technicien_email UNIQUE (email),
  CONSTRAINT ck_technicien_telephone CHECK (telephone ~ '^0\d{9}$'),
  CONSTRAINT ck_technicien_email CHECK (email = lower(email))
);

CREATE TABLE IF NOT EXISTS type_equipement (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  libelle text NOT NULL,
  CONSTRAINT uq_type_equipement_libelle UNIQUE (libelle)
);

CREATE TABLE IF NOT EXISTS equipement (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  numero_serie text NOT NULL,
  type_id      bigint NOT NULL,
  client_id    bigint NOT NULL,
  CONSTRAINT uq_equipement_numero_serie UNIQUE (numero_serie),
  CONSTRAINT fk_equipement_type FOREIGN KEY (type_id) REFERENCES type_equipement (id),
  CONSTRAINT fk_equipement_client FOREIGN KEY (client_id) REFERENCES client (id)
);

CREATE TABLE IF NOT EXISTS piece (
  id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reference text NOT NULL,                        -- no unit price exists in the legacy data
  CONSTRAINT uq_piece_reference UNIQUE (reference)
);

-- Status reference table (not an ENUM): adding a status is an INSERT
CREATE TABLE IF NOT EXISTS statut_intervention (
  code        text PRIMARY KEY,
  libelle     text NOT NULL,
  ordre       smallint NOT NULL,
  est_initial boolean NOT NULL DEFAULT false,
  est_final   boolean NOT NULL DEFAULT false,
  CONSTRAINT uq_statut_ordre UNIQUE (ordre),
  CONSTRAINT ck_statut_code CHECK (code ~ '^[a-z_]+$')
);

-- Allowed lifecycle, described as data and enforced by trigger
CREATE TABLE IF NOT EXISTS transition_statut (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  statut_depart  text NOT NULL,
  statut_arrivee text NOT NULL,
  CONSTRAINT uq_transition UNIQUE (statut_depart, statut_arrivee),
  CONSTRAINT fk_transition_depart FOREIGN KEY (statut_depart) REFERENCES statut_intervention (code),
  CONSTRAINT fk_transition_arrivee FOREIGN KEY (statut_arrivee) REFERENCES statut_intervention (code),
  CONSTRAINT ck_transition_distincte CHECK (statut_depart <> statut_arrivee)
);

CREATE TABLE IF NOT EXISTS intervention (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_legacy      integer,                         -- NULL for interventions created after the migration
  equipement_id  bigint NOT NULL,
  technicien_id  bigint NOT NULL,
  statut_code    text NOT NULL DEFAULT 'ouverte',
  date_ouverture date NOT NULL DEFAULT current_date,
  date_cloture   date,
  cout_total     numeric(10,2) NOT NULL DEFAULT 0,
  -- Incoherences computed by the database itself, impossible to forget or forge
  anomalie_date_incoherente  boolean GENERATED ALWAYS AS (coalesce(date_cloture < date_ouverture, false)) STORED,
  anomalie_cloture_sans_date boolean GENERATED ALWAYS AS (statut_code = 'cloturee' AND date_cloture IS NULL) STORED,
  modifie_par    uuid,                            -- application user of the last change
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_intervention_id_legacy UNIQUE (id_legacy),
  CONSTRAINT fk_intervention_equipement FOREIGN KEY (equipement_id) REFERENCES equipement (id),
  CONSTRAINT fk_intervention_technicien FOREIGN KEY (technicien_id) REFERENCES technicien (id),
  CONSTRAINT fk_intervention_statut FOREIGN KEY (statut_code) REFERENCES statut_intervention (code),
  CONSTRAINT ck_intervention_cout CHECK (cout_total >= 0),
  -- Legacy rows are kept as they are; new rows must be coherent
  CONSTRAINT ck_intervention_dates_saisie
    CHECK (id_legacy IS NOT NULL OR date_cloture IS NULL OR date_cloture >= date_ouverture)
);

CREATE TABLE IF NOT EXISTS intervention_piece (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  intervention_id bigint NOT NULL,
  piece_id        bigint NOT NULL,
  quantite        integer NOT NULL,
  CONSTRAINT uq_intervention_piece UNIQUE (intervention_id, piece_id),
  CONSTRAINT fk_intervention_piece_intervention FOREIGN KEY (intervention_id) REFERENCES intervention (id),
  CONSTRAINT fk_intervention_piece_piece FOREIGN KEY (piece_id) REFERENCES piece (id),
  CONSTRAINT ck_intervention_piece_quantite CHECK (quantite > 0)
);

CREATE TABLE IF NOT EXISTS historique_statut (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  intervention_id bigint NOT NULL,
  statut_avant    text,
  statut_apres    text NOT NULL,
  modifie_le      timestamptz NOT NULL DEFAULT now(),
  role_bdd        text NOT NULL DEFAULT session_user,  -- database login that made the change
  utilisateur_app uuid,                                -- application user, when the change came from the app
  CONSTRAINT fk_historique_intervention FOREIGN KEY (intervention_id) REFERENCES intervention (id),
  CONSTRAINT fk_historique_statut_avant FOREIGN KEY (statut_avant) REFERENCES statut_intervention (code),
  CONSTRAINT fk_historique_statut_apres FOREIGN KEY (statut_apres) REFERENCES statut_intervention (code)
);

-- Foreign keys are not indexed automatically by PostgreSQL
CREATE INDEX IF NOT EXISTS ix_contrat_client          ON contrat (client_id);
CREATE INDEX IF NOT EXISTS ix_equipement_type         ON equipement (type_id);
CREATE INDEX IF NOT EXISTS ix_equipement_client       ON equipement (client_id);
CREATE INDEX IF NOT EXISTS ix_transition_arrivee      ON transition_statut (statut_arrivee);
CREATE INDEX IF NOT EXISTS ix_intervention_equipement ON intervention (equipement_id);
CREATE INDEX IF NOT EXISTS ix_intervention_technicien ON intervention (technicien_id, date_ouverture);
CREATE INDEX IF NOT EXISTS ix_intervention_statut     ON intervention (statut_code);
CREATE INDEX IF NOT EXISTS ix_intervention_ouverture  ON intervention (date_ouverture);
CREATE INDEX IF NOT EXISTS ix_intervention_piece_piece ON intervention_piece (piece_id);
CREATE INDEX IF NOT EXISTS ix_historique_intervention ON historique_statut (intervention_id, modifie_le);
CREATE INDEX IF NOT EXISTS ix_historique_avant        ON historique_statut (statut_avant);
CREATE INDEX IF NOT EXISTS ix_historique_apres        ON historique_statut (statut_apres);

COMMENT ON TABLE intervention IS 'Intervention de maintenance. id_legacy = id de interventions_legacy (NULL si créée après la migration).';
COMMENT ON COLUMN intervention.anomalie_date_incoherente IS 'Calculé : date de clôture antérieure à la date d''ouverture.';
COMMENT ON COLUMN intervention.anomalie_cloture_sans_date IS 'Calculé : statut clôturé sans date de clôture.';
COMMENT ON TABLE transition_statut IS 'Cycle de vie autorisé, appliqué par le trigger trg_intervention_avant_ecriture.';
COMMENT ON TABLE historique_statut IS 'Journal des changements de statut, alimenté uniquement par trigger.';

-- ---------------------------------------------------------------------
-- 5. Reference data
-- ---------------------------------------------------------------------
INSERT INTO statut_intervention (code, libelle, ordre, est_initial, est_final) VALUES
  ('ouverte',  'Ouverte',  1, true,  false),
  ('en_cours', 'En cours', 2, false, false),
  ('cloturee', 'Clôturée', 3, false, true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO transition_statut (statut_depart, statut_arrivee) VALUES
  ('ouverte',  'en_cours'),   -- the technician starts the job
  ('en_cours', 'ouverte'),    -- the job is put back on hold
  ('en_cours', 'cloturee')    -- the job is done; a closed intervention is final
ON CONFLICT (statut_depart, statut_arrivee) DO NOTHING;

-- ---------------------------------------------------------------------
-- 6. Data migration, in dependency order
-- ---------------------------------------------------------------------
-- Clients: one per phone number (A14). Name = most frequent spelling once
-- spaces are normalized; the raw spellings remain in the legacy table.
INSERT INTO client (nom, email, telephone, adresse, code_postal, ville)
SELECT mode() WITHIN GROUP (ORDER BY mp_norm_texte(client_nom)),
       max(lower(btrim(client_email))),
       btrim(client_tel),
       max(substring(btrim(client_adresse) FROM '^(.+), \d{5} .+$')),
       max(substring(btrim(client_adresse) FROM '^.+, (\d{5}) .+$')),
       max(substring(btrim(client_adresse) FROM '^.+, \d{5} (.+)$'))
FROM interventions_legacy
GROUP BY btrim(client_tel)
ON CONFLICT (telephone) DO NOTHING;

INSERT INTO contrat (reference, client_id, sla_heures)
SELECT btrim(l.contrat_ref), c.id, min(mp_parse_sla(l.contrat_sla))
FROM interventions_legacy l
JOIN client c ON c.telephone = btrim(l.client_tel)
GROUP BY btrim(l.contrat_ref), c.id
ON CONFLICT (reference) DO NOTHING;

INSERT INTO technicien (nom, prenom, telephone)
SELECT DISTINCT split_part(mp_norm_texte(technicien), ' ', 1),
                split_part(mp_norm_texte(technicien), ' ', 2),
                btrim(technicien_tel)
FROM interventions_legacy
ON CONFLICT (telephone) DO NOTHING;

INSERT INTO type_equipement (libelle)
SELECT DISTINCT mp_norm_texte(equipement) FROM interventions_legacy
ON CONFLICT (libelle) DO NOTHING;

INSERT INTO equipement (numero_serie, type_id, client_id)
SELECT DISTINCT btrim(l.equipement_serie), t.id, c.id
FROM interventions_legacy l
JOIN type_equipement t ON t.libelle = mp_norm_texte(l.equipement)
JOIN client c ON c.telephone = btrim(l.client_tel)
ON CONFLICT (numero_serie) DO NOTHING;

-- Parts: the multi-valued text field becomes rows. Splitting on ; , or |
-- covers every separator the legacy generator may use.
CREATE TEMP TABLE tmp_ligne_piece ON COMMIT DROP AS
SELECT l.id AS id_legacy,
       (regexp_match(btrim(t), '^(REF-\d+) x(\d+)$'))[1] AS reference,
       (regexp_match(btrim(t), '^(REF-\d+) x(\d+)$'))[2]::integer AS quantite
FROM interventions_legacy l,
     regexp_split_to_table(l.pieces_utilisees, '\s*[;,|]\s*') AS t
WHERE l.pieces_utilisees ~ 'REF-';

INSERT INTO piece (reference)
SELECT DISTINCT reference FROM tmp_ligne_piece
ON CONFLICT (reference) DO NOTHING;

INSERT INTO intervention (id_legacy, equipement_id, technicien_id, statut_code,
                          date_ouverture, date_cloture, cout_total)
SELECT l.id, e.id, t.id,
       mp_norm_statut(l.statut),
       mp_parse_date(l.date_ouverture),
       mp_parse_date(l.date_cloture),
       mp_parse_cout(l.cout_total)
FROM interventions_legacy l
JOIN equipement e ON e.numero_serie = btrim(l.equipement_serie)
JOIN technicien t ON t.telephone = btrim(l.technicien_tel)
ON CONFLICT (id_legacy) DO NOTHING;

INSERT INTO intervention_piece (intervention_id, piece_id, quantite)
SELECT i.id, p.id, lp.quantite
FROM tmp_ligne_piece lp
JOIN intervention i ON i.id_legacy = lp.id_legacy
JOIN piece p ON p.reference = lp.reference
ON CONFLICT (intervention_id, piece_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- 7. Post-checks: nothing lost. Any failure rolls the whole run back.
-- ---------------------------------------------------------------------
DO $$
DECLARE n_legacy bigint; n_new bigint;
BEGIN
  SELECT count(*) INTO n_legacy FROM interventions_legacy;
  SELECT count(*) INTO n_new FROM intervention WHERE id_legacy IS NOT NULL;
  IF n_legacy <> n_new THEN
    RAISE EXCEPTION 'Interventions perdues : % héritées, % migrées', n_legacy, n_new;
  END IF;

  SELECT count(*) INTO n_legacy FROM tmp_ligne_piece;
  SELECT count(*) INTO n_new FROM intervention_piece ip
    JOIN intervention i ON i.id = ip.intervention_id WHERE i.id_legacy IS NOT NULL;
  IF n_new < n_legacy THEN
    RAISE EXCEPTION 'Lignes de pièces perdues : % héritées, % migrées', n_legacy, n_new;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 8. Business rules enforced by the database (whatever the client)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_intervention_avant_ecriture() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_final boolean;
BEGIN
  SELECT est_final INTO v_final FROM statut_intervention WHERE code = NEW.statut_code;

  IF TG_OP = 'INSERT' THEN
    -- Legacy rows (id_legacy set) are loaded as they are, only by the migration
    IF NEW.id_legacy IS NULL THEN
      IF NOT EXISTS (SELECT 1 FROM statut_intervention WHERE code = NEW.statut_code AND est_initial) THEN
        RAISE EXCEPTION 'Une nouvelle intervention doit commencer au statut initial (reçu : %)', NEW.statut_code
          USING ERRCODE = 'check_violation';
      END IF;
      IF NEW.date_cloture IS NOT NULL THEN
        RAISE EXCEPTION 'Une nouvelle intervention ne peut pas avoir de date de clôture'
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF NEW.id_legacy IS DISTINCT FROM OLD.id_legacy THEN
    RAISE EXCEPTION 'id_legacy est la trace de l''origine et ne peut pas être modifié'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.statut_code IS DISTINCT FROM OLD.statut_code THEN
    IF NOT EXISTS (SELECT 1 FROM transition_statut
                   WHERE statut_depart = OLD.statut_code AND statut_arrivee = NEW.statut_code) THEN
      RAISE EXCEPTION 'Transition de statut interdite : % -> %', OLD.statut_code, NEW.statut_code
        USING ERRCODE = 'check_violation',
              HINT = 'Les transitions autorisées sont listées dans la table transition_statut.';
    END IF;
    -- Closing: the closing date is set automatically when not provided
    IF v_final AND NEW.date_cloture IS NULL THEN
      NEW.date_cloture := greatest(current_date, NEW.date_ouverture);
    END IF;
  END IF;

  IF NEW.date_cloture IS DISTINCT FROM OLD.date_cloture OR NEW.date_ouverture IS DISTINCT FROM OLD.date_ouverture THEN
    IF NEW.date_cloture < NEW.date_ouverture THEN
      RAISE EXCEPTION 'La date de clôture (%) ne peut pas précéder la date d''ouverture (%)',
        NEW.date_cloture, NEW.date_ouverture USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.date_cloture IS NOT NULL AND NOT v_final THEN
      RAISE EXCEPTION 'Seule une intervention clôturée peut avoir une date de clôture'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- SECURITY DEFINER: the application can read the history but never write it directly
CREATE OR REPLACE FUNCTION fn_intervention_historiser() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO historique_statut (intervention_id, statut_avant, statut_apres, role_bdd, utilisateur_app)
  VALUES (NEW.id,
          CASE WHEN TG_OP = 'UPDATE' THEN OLD.statut_code END,
          NEW.statut_code,
          session_user,
          CASE WHEN pg_has_role(session_user, 'mp_application', 'MEMBER') THEN NEW.modifie_par END);
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION fn_maj_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER trg_client_updated_at
  BEFORE UPDATE ON client FOR EACH ROW EXECUTE FUNCTION fn_maj_updated_at();
CREATE OR REPLACE TRIGGER trg_technicien_updated_at
  BEFORE UPDATE ON technicien FOR EACH ROW EXECUTE FUNCTION fn_maj_updated_at();

REVOKE ALL ON FUNCTION fn_maj_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_intervention_avant_ecriture() FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_intervention_historiser() FROM PUBLIC;

CREATE OR REPLACE TRIGGER trg_intervention_avant_ecriture
  BEFORE INSERT OR UPDATE ON intervention
  FOR EACH ROW EXECUTE FUNCTION fn_intervention_avant_ecriture();

CREATE OR REPLACE TRIGGER trg_intervention_historique_creation
  AFTER INSERT ON intervention
  FOR EACH ROW WHEN (NEW.id_legacy IS NULL)
  EXECUTE FUNCTION fn_intervention_historiser();

CREATE OR REPLACE TRIGGER trg_intervention_historique_statut
  AFTER UPDATE OF statut_code ON intervention
  FOR EACH ROW WHEN (OLD.statut_code IS DISTINCT FROM NEW.statut_code)
  EXECUTE FUNCTION fn_intervention_historiser();

-- ---------------------------------------------------------------------
-- 9. Interface contract (column names and types are fixed by the subject)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_export_interventions AS
SELECT i.id_legacy::int                AS id_legacy,
       i.date_ouverture::date          AS date_ouverture,
       i.date_cloture::date            AS date_cloture,
       i.statut_code::text             AS statut,
       i.cout_total::numeric           AS cout_total,
       (i.anomalie_date_incoherente OR i.anomalie_cloture_sans_date)::boolean AS anomalie
FROM intervention i
WHERE i.id_legacy IS NOT NULL;

CREATE OR REPLACE VIEW v_export_entites AS
SELECT 'clients'::text AS entite, (SELECT count(*) FROM client)::int AS nb
UNION ALL SELECT 'techniciens',   (SELECT count(*) FROM technicien)::int
UNION ALL SELECT 'equipements',   (SELECT count(*) FROM equipement)::int
UNION ALL SELECT 'lignes_pieces', (SELECT count(*) FROM intervention_piece)::int;

-- Reporting views
CREATE OR REPLACE VIEW v_anomalies AS
SELECT i.id, i.id_legacy, c.nom AS client, e.numero_serie,
       t.nom || ' ' || t.prenom AS technicien,
       i.statut_code AS statut, i.date_ouverture, i.date_cloture,
       CASE WHEN i.anomalie_date_incoherente THEN 'date_cloture_avant_ouverture'
            ELSE 'cloturee_sans_date' END AS type_anomalie
FROM intervention i
JOIN equipement e ON e.id = i.equipement_id
JOIN client c ON c.id = e.client_id
JOIN technicien t ON t.id = i.technicien_id
WHERE i.anomalie_date_incoherente OR i.anomalie_cloture_sans_date;

CREATE OR REPLACE VIEW v_indicateurs AS
SELECT count(*)                                                        AS interventions,
       count(*) FILTER (WHERE statut_code <> 'cloturee')               AS non_cloturees,
       count(*) FILTER (WHERE anomalie_date_incoherente OR anomalie_cloture_sans_date) AS anomalies,
       sum(cout_total)                                                 AS cout_total,
       round(avg(date_cloture - date_ouverture)
             FILTER (WHERE date_cloture >= date_ouverture), 1)         AS delai_moyen_cloture_jours
FROM intervention;

-- ---------------------------------------------------------------------
-- 10. Privileges (least privilege; DELETE is never granted: no
--     intervention may disappear)
-- ---------------------------------------------------------------------
REVOKE ALL ON client, contrat, technicien, type_equipement, equipement, piece,
              statut_intervention, transition_statut, intervention,
              intervention_piece, historique_statut FROM PUBLIC;

GRANT SELECT ON statut_intervention, transition_statut, historique_statut TO mp_application;
GRANT SELECT, INSERT, UPDATE ON client, contrat, technicien, type_equipement,
                                equipement, piece, intervention, intervention_piece TO mp_application;
-- Identity sequences of our own tables only (not the no-code tool's)
DO $$
DECLARE s regclass;
BEGIN
  FOR s IN SELECT c.oid::regclass FROM pg_class c
           WHERE c.relkind = 'S' AND c.relowner = 'mp_owner'::regrole LOOP
    EXECUTE format('GRANT USAGE ON SEQUENCE %s TO mp_application', s);
  END LOOP;
END $$;

GRANT SELECT ON v_export_interventions, v_export_entites, v_anomalies, v_indicateurs
  TO mp_application, mp_lecture;

COMMIT;
