-- =====================================================================
-- Audit of the legacy table interventions_legacy (read-only).
-- Every finding in audit/audit.md quotes the output of one query below.
-- The only write (A03) runs inside a transaction that is rolled back.
-- Run: ./scripts/run-sql.ps1 audit/queries.sql
-- =====================================================================
\pset null '(NULL)'

\echo '=== A00 Volume'
SELECT count(*) AS lignes, min(id) AS id_min, max(id) AS id_max
FROM interventions_legacy;

-- ---------------------------------------------------------------------
-- INTEGRITY
-- ---------------------------------------------------------------------
\echo '=== A01 No constraint at all (no PK, FK, UNIQUE, CHECK)'
SELECT count(*) AS nb_contraintes
FROM pg_constraint
WHERE conrelid = 'interventions_legacy'::regclass;

\echo '=== A02 Every business column is nullable TEXT'
SELECT data_type, is_nullable, count(*) AS nb_colonnes,
       string_agg(column_name, ', ' ORDER BY ordinal_position) AS colonnes
FROM information_schema.columns
WHERE table_name = 'interventions_legacy'
GROUP BY data_type, is_nullable;

\echo '=== A03 Duplicate id and empty row accepted (rolled back)'
BEGIN;
INSERT INTO interventions_legacy (id) VALUES (1);
INSERT INTO interventions_legacy DEFAULT VALUES;
SELECT count(*) FILTER (WHERE id = 1) AS lignes_avec_id_1,
       count(*) FILTER (WHERE client_nom IS NULL AND date_ouverture IS NULL) AS lignes_vides
FROM interventions_legacy;
ROLLBACK;

\echo '=== A04 Opening dates: three formats in one column'
SELECT CASE
         WHEN date_ouverture ~ '^\d{4}-\d{2}-\d{2}$' THEN 'YYYY-MM-DD'
         WHEN date_ouverture ~ '^\d{2}/\d{2}/\d{4}$' THEN 'DD/MM/YYYY'
         WHEN date_ouverture ~ '^\d{2}-\d{2}-\d{2}$' THEN 'DD-MM-YY'
         ELSE 'autre'
       END AS format, count(*) AS nb
FROM interventions_legacy GROUP BY 1 ORDER BY 2 DESC;

\echo '=== A05 Closing dates: three formats + three ways to say "no date"'
SELECT CASE
         WHEN date_cloture IS NULL THEN 'NULL'
         WHEN date_cloture = '' THEN 'chaine vide'
         WHEN date_cloture = 'N/A' THEN '''N/A'''
         WHEN date_cloture ~ '^\d{4}-\d{2}-\d{2}$' THEN 'YYYY-MM-DD'
         WHEN date_cloture ~ '^\d{2}/\d{2}/\d{4}$' THEN 'DD/MM/YYYY'
         WHEN date_cloture ~ '^\d{2}-\d{2}-\d{2}$' THEN 'DD-MM-YY'
         ELSE 'autre'
       END AS format, count(*) AS nb
FROM interventions_legacy GROUP BY 1 ORDER BY 2 DESC;

\echo '=== A06 Text dates sort wrongly: first 6 rows of ORDER BY date_ouverture, with the real date'
SELECT date_ouverture AS valeur_texte,
       CASE
         WHEN date_ouverture ~ '^\d{4}-\d{2}-\d{2}$' THEN to_date(date_ouverture, 'YYYY-MM-DD')
         WHEN date_ouverture ~ '^\d{2}/\d{2}/\d{4}$' THEN to_date(date_ouverture, 'DD/MM/YYYY')
         WHEN date_ouverture ~ '^\d{2}-\d{2}-\d{2}$' THEN to_date(date_ouverture, 'DD-MM-YY')
       END AS date_reelle
FROM interventions_legacy ORDER BY date_ouverture LIMIT 6;

\echo '=== A07 Costs stored as text with 4 spellings of the currency'
SELECT regexp_replace(cout_total, '[0-9]+', 'N', 'g') AS motif, count(*) AS nb
FROM interventions_legacy GROUP BY 1 ORDER BY 2 DESC;

\echo '=== A08 Text max() of the costs is not the real maximum'
SELECT max(cout_total) AS max_texte,
       max(replace(regexp_replace(cout_total, '[^0-9,.]', '', 'g'), ',', '.')::numeric) AS max_reel
FROM interventions_legacy;

\echo '=== A09 Status: 10 spellings for 3 business states'
SELECT '«' || statut || '»' AS statut_brut, count(*) AS nb
FROM interventions_legacy GROUP BY statut ORDER BY lower(statut);

\echo '=== A10 SLA: 12 spellings for 4 values'
SELECT contrat_sla, count(*) AS nb
FROM interventions_legacy GROUP BY 1 ORDER BY 1;

\echo '=== A11 Same client written up to 6 different ways (same phone)'
SELECT client_tel, count(DISTINCT client_nom) AS nb_variantes,
       string_agg(DISTINCT '«' || client_nom || '»', ' ') AS variantes
FROM interventions_legacy
GROUP BY client_tel
HAVING count(DISTINCT client_nom) > 1
ORDER BY 2 DESC, 1;

\echo '=== A12 Distinct raw names vs real clients'
SELECT count(DISTINCT client_nom) AS noms_bruts_distincts,
       count(DISTINCT client_tel) AS clients_reels
FROM interventions_legacy;

\echo '=== A13 E-mails: missing or upper-cased'
SELECT count(*) FILTER (WHERE client_email IS NULL) AS email_absent,
       count(*) FILTER (WHERE client_email <> lower(client_email)) AS email_majuscules,
       count(DISTINCT client_email) AS emails_bruts_distincts,
       count(DISTINCT lower(client_email)) AS emails_reels
FROM interventions_legacy;

\echo '=== A14 Natural keys are 1:1 (0 = no conflict): basis of deduplication'
SELECT 'telephone -> contrat' AS correspondance, count(*) AS conflits
FROM (SELECT client_tel FROM interventions_legacy GROUP BY 1 HAVING count(DISTINCT contrat_ref) > 1) x
UNION ALL SELECT 'contrat -> telephone', count(*)
FROM (SELECT contrat_ref FROM interventions_legacy GROUP BY 1 HAVING count(DISTINCT client_tel) > 1) x
UNION ALL SELECT 'telephone -> email (minuscules)', count(*)
FROM (SELECT client_tel FROM interventions_legacy GROUP BY 1 HAVING count(DISTINCT lower(client_email)) > 1) x
UNION ALL SELECT 'telephone -> adresse', count(*)
FROM (SELECT client_tel FROM interventions_legacy GROUP BY 1 HAVING count(DISTINCT client_adresse) > 1) x
UNION ALL SELECT 'contrat -> SLA (valeur numerique)', count(*)
FROM (SELECT contrat_ref FROM interventions_legacy GROUP BY 1
      HAVING count(DISTINCT substring(contrat_sla FROM '^\s*(\d+)')) > 1) x
UNION ALL SELECT 'numero de serie -> type', count(*)
FROM (SELECT equipement_serie FROM interventions_legacy GROUP BY 1 HAVING count(DISTINCT equipement) > 1) x
UNION ALL SELECT 'numero de serie -> client', count(*)
FROM (SELECT equipement_serie FROM interventions_legacy GROUP BY 1 HAVING count(DISTINCT client_tel) > 1) x
UNION ALL SELECT 'technicien -> telephone', count(*)
FROM (SELECT technicien FROM interventions_legacy GROUP BY 1 HAVING count(DISTINCT technicien_tel) > 1) x
UNION ALL SELECT 'telephone technicien -> technicien', count(*)
FROM (SELECT technicien_tel FROM interventions_legacy GROUP BY 1 HAVING count(DISTINCT technicien) > 1) x;

\echo '=== A15 Real entity counts hidden in the flat table'
SELECT count(DISTINCT client_tel) AS clients,
       count(DISTINCT technicien_tel) AS techniciens,
       count(DISTINCT equipement_serie) AS equipements,
       count(DISTINCT equipement) AS types_equipement
FROM interventions_legacy;

\echo '=== A16 Redundancy: client data copied on every row (update anomaly)'
SELECT client_tel, count(*) AS copies_des_coordonnees
FROM interventions_legacy GROUP BY 1 ORDER BY 2 DESC LIMIT 5;

\echo '=== A17 Parts: several values in one field (1NF violation) + 3 ways to say "none"'
SELECT CASE
         WHEN pieces_utilisees IS NULL THEN 'NULL'
         WHEN pieces_utilisees = '' THEN 'chaine vide'
         WHEN pieces_utilisees = 'aucune' THEN '''aucune'''
         ELSE (array_length(string_to_array(pieces_utilisees, ';'), 1))::text || ' piece(s)'
       END AS contenu, count(*) AS nb
FROM interventions_legacy GROUP BY 1 ORDER BY 1;

\echo '=== A18 Parts: lines hidden in the text field, catalogue size, prices'
WITH lignes AS (
  SELECT id, btrim(l) AS ligne
  FROM interventions_legacy, regexp_split_to_table(pieces_utilisees, ';') AS l
  WHERE pieces_utilisees ~ 'REF-'
)
SELECT count(*) AS lignes_de_pieces,
       count(DISTINCT substring(ligne FROM '^(REF-\d+)')) AS references_distinctes,
       count(*) FILTER (WHERE ligne !~ '^REF-\d+ x\d+$') AS lignes_mal_formees,
       (SELECT count(*) FROM (SELECT id, substring(ligne FROM '^(REF-\d+)') FROM lignes GROUP BY 1, 2 HAVING count(*) > 1) d)
         AS references_en_double_dans_une_intervention
FROM lignes;

\echo '=== A19 Incoherent rows (dates parsed on the fly)'
WITH p AS (
  SELECT id, statut, date_cloture AS cloture_brute,
         CASE
           WHEN date_ouverture ~ '^\d{4}-\d{2}-\d{2}$' THEN to_date(date_ouverture, 'YYYY-MM-DD')
           WHEN date_ouverture ~ '^\d{2}/\d{2}/\d{4}$' THEN to_date(date_ouverture, 'DD/MM/YYYY')
           WHEN date_ouverture ~ '^\d{2}-\d{2}-\d{2}$' THEN to_date(date_ouverture, 'DD-MM-YY')
         END AS ouverture,
         CASE
           WHEN date_cloture ~ '^\d{4}-\d{2}-\d{2}$' THEN to_date(date_cloture, 'YYYY-MM-DD')
           WHEN date_cloture ~ '^\d{2}/\d{2}/\d{4}$' THEN to_date(date_cloture, 'DD/MM/YYYY')
           WHEN date_cloture ~ '^\d{2}-\d{2}-\d{2}$' THEN to_date(date_cloture, 'DD-MM-YY')
         END AS cloture,
         lower(btrim(statut)) IN ('clos', 'cloture', 'clôturé') AS est_cloturee
  FROM interventions_legacy
)
SELECT id, '«' || statut || '»' AS statut, ouverture, coalesce(cloture::text, '«' || coalesce(cloture_brute, 'NULL') || '»') AS cloture,
       CASE WHEN cloture < ouverture THEN 'cloture avant ouverture'
            WHEN est_cloturee AND cloture IS NULL THEN 'cloturee sans date de cloture' END AS anomalie
FROM p
WHERE cloture < ouverture OR (est_cloturee AND cloture IS NULL)
ORDER BY anomalie, id;

\echo '=== A20 Coherence checks that come back clean (they were verified, not assumed)'
WITH p AS (
  SELECT CASE
           WHEN date_ouverture ~ '^\d{4}-\d{2}-\d{2}$' THEN to_date(date_ouverture, 'YYYY-MM-DD')
           WHEN date_ouverture ~ '^\d{2}/\d{2}/\d{4}$' THEN to_date(date_ouverture, 'DD/MM/YYYY')
           WHEN date_ouverture ~ '^\d{2}-\d{2}-\d{2}$' THEN to_date(date_ouverture, 'DD-MM-YY')
         END AS ouverture,
         date_cloture ~ '\d' AS a_une_cloture,
         lower(btrim(statut)) IN ('clos', 'cloture', 'clôturé') AS est_cloturee,
         replace(regexp_replace(cout_total, '[^0-9,.]', '', 'g'), ',', '.')::numeric AS cout
  FROM interventions_legacy
)
SELECT count(*) FILTER (WHERE NOT est_cloturee AND a_une_cloture) AS non_cloturee_avec_date,
       count(*) FILTER (WHERE ouverture IS NULL) AS ouverture_illisible,
       count(*) FILTER (WHERE ouverture > current_date) AS ouverture_dans_le_futur,
       count(*) FILTER (WHERE cout <= 0) AS cout_nul_ou_negatif
FROM p;

-- ---------------------------------------------------------------------
-- PERFORMANCE
-- ---------------------------------------------------------------------
\echo '=== P01 No index on the table'
SELECT count(*) AS nb_index FROM pg_indexes WHERE tablename = 'interventions_legacy';

\echo '=== P02 Filtering a technician by month: full scan + parsing every row'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM interventions_legacy
WHERE technicien = 'Durand Karim'
  AND CASE
        WHEN date_ouverture ~ '^\d{4}-\d{2}-\d{2}$' THEN to_date(date_ouverture, 'YYYY-MM-DD')
        WHEN date_ouverture ~ '^\d{2}/\d{2}/\d{4}$' THEN to_date(date_ouverture, 'DD/MM/YYYY')
        ELSE to_date(date_ouverture, 'DD-MM-YY')
      END BETWEEN DATE '2025-10-01' AND DATE '2025-10-31';

\echo '=== P03 Finding a part needs a non-indexable LIKE on free text'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM interventions_legacy WHERE pieces_utilisees LIKE '%REF-005%';

\echo '=== P04 Searching a client by name misses rows as soon as one spelling differs'
SELECT (SELECT count(*) FROM interventions_legacy WHERE client_nom = 'Transports Berthet') AS trouvees_par_nom_exact,
       (SELECT count(*) FROM interventions_legacy WHERE client_tel = '0490433061') AS interventions_reelles;

-- ---------------------------------------------------------------------
-- EVOLVABILITY
-- ---------------------------------------------------------------------
\echo '=== E01 Changing one contract SLA means rewriting every row of that client'
SELECT contrat_ref, count(*) AS lignes_a_modifier,
       string_agg(DISTINCT contrat_sla, ' | ') AS valeurs_actuelles
FROM interventions_legacy GROUP BY 1 ORDER BY 2 DESC LIMIT 5;

\echo '=== E02 One technician per row, one contract per client: no room for more'
SELECT column_name FROM information_schema.columns
WHERE table_name = 'interventions_legacy'
  AND column_name IN ('technicien', 'technicien_tel', 'contrat_ref', 'contrat_sla', 'pieces_utilisees', 'cout_total')
ORDER BY ordinal_position;

-- ---------------------------------------------------------------------
-- SECURITY
-- ---------------------------------------------------------------------
\echo '=== S01 Personal data stored next to operational data in one table'
SELECT column_name, 'donnee personnelle / commerciale' AS nature
FROM information_schema.columns
WHERE table_name = 'interventions_legacy'
  AND column_name IN ('client_email', 'client_tel', 'client_adresse', 'technicien', 'technicien_tel', 'contrat_ref')
ORDER BY ordinal_position;

\echo '=== S02 Only the superuser owns and reaches the table: no role model'
SELECT c.relname AS table_name, pg_get_userbyid(c.relowner) AS proprietaire,
       r.rolsuper AS proprietaire_superuser, c.relrowsecurity AS rls_active,
       coalesce(c.relacl::text, '(droits par defaut du proprietaire)') AS acl
FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner
WHERE c.relname = 'interventions_legacy';

\echo '=== S03 Technician access would expose every client (no row or column split possible)'
SELECT count(DISTINCT client_tel) AS clients_visibles_par_un_technicien
FROM interventions_legacy;

\echo '=== S04 No traceability: no audit column, no history'
SELECT count(*) FILTER (WHERE column_name ~ '(created|updated|modifie|cree|auteur|user)') AS colonnes_de_tracabilite
FROM information_schema.columns
WHERE table_name = 'interventions_legacy';
