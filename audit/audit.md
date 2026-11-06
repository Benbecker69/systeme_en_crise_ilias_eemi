# Audit de la table héritée `interventions_legacy` (seed 4)

## Méthode

- Toutes les requêtes sont dans [`queries.sql`](queries.sql), numérotées (A = intégrité, P = performance, E = évolutivité, S = sécurité).
- La sortie brute et complète de l'exécution est dans [`resultats.txt`](resultats.txt). Les résultats cités ci-dessous en sont extraits sans modification.
- L'audit est en **lecture seule**. La seule écriture (A03) a lieu dans une transaction annulée par `ROLLBACK`.
- Pour le rejouer : `./scripts/run-sql.ps1 audit/queries.sql`

Échelle de gravité :

| Gravité | Signification |
|---|---|
| **Critique** | Des données peuvent être fausses, perdues ou mal interprétées, ou un chiffre de pilotage est faux |
| **Majeure** | Fiabilité ou maintenance fortement dégradées, ou risque important |
| **Mineure** | Gêne réelle mais contournable |

Volume (A00) : **271 interventions**, `id` de 1 à 271.

---

## Synthèse

| # | Défaut | Catégorie | Gravité | Preuve |
|---|---|---|---|---|
| D1 | Aucune contrainte : pas de clé primaire, doublons et lignes vides acceptés | Intégrité | Critique | A01, A03 |
| D2 | Toutes les colonnes métier en `TEXT` nullable | Intégrité | Critique | A02 |
| D3 | Dates en 3 formats, 3 façons d'écrire « pas de date », tri faux | Intégrité | Critique | A04, A05, A06 |
| D4 | Coûts en texte, 4 écritures de la devise, `max()` faux | Intégrité | Critique | A07, A08 |
| D5 | 10 orthographes pour 3 statuts | Intégrité | Critique | A09 |
| D6 | 10 interventions incohérentes (dates / statut) | Intégrité | Critique | A19 |
| D7 | Un même client écrit jusqu'à 6 façons (78 noms pour 21 clients) | Intégrité | Majeure | A11, A12, P04 |
| D8 | E-mails absents ou en majuscules | Intégrité | Majeure | A13 |
| D9 | Pièces multivaluées dans un seul champ (violation de la 1NF) | Intégrité / Évolutivité | Majeure | A17, A18 |
| D10 | Redondance massive des coordonnées (anomalies de mise à jour) | Intégrité | Majeure | A16, E01 |
| D11 | SLA écrit de 12 façons pour 4 valeurs | Intégrité | Mineure | A10 |
| D12 | Aucun index, filtres en parcours complet avec conversion ligne par ligne | Performance | Majeure | P01, P02, P03 |
| D13 | Recherche par nom de client non fiable | Performance / Intégrité | Majeure | P04 |
| D14 | Structure figée : un technicien par intervention, pas de prix de pièce, SLA recopié | Évolutivité | Majeure | E01, E02, A18 |
| D15 | Aucun modèle de droits : table du superutilisateur, pas de RLS | Sécurité | Critique | S02, S03 |
| D16 | Données personnelles mêlées aux données opérationnelles | Sécurité | Majeure | S01 |
| D17 | Aucune traçabilité (qui a modifié quoi, quand) | Sécurité | Majeure | S04 |

---

## 1. Intégrité des données

### D1 — Aucune contrainte · Critique
**Constat.** La table n'a ni clé primaire, ni clé étrangère, ni `UNIQUE`, ni `CHECK`. `id` est un `SERIAL` **sans** `PRIMARY KEY` : rien n'empêche deux lignes d'avoir le même identifiant.

```sql
-- A01
SELECT count(*) AS nb_contraintes FROM pg_constraint
WHERE conrelid = 'interventions_legacy'::regclass;
```
```
 nb_contraintes
----------------
              0
```
Démonstration dans une transaction annulée (A03) : un `id` en double et une ligne entièrement vide sont acceptés.
```sql
BEGIN;
INSERT INTO interventions_legacy (id) VALUES (1);
INSERT INTO interventions_legacy DEFAULT VALUES;
SELECT count(*) FILTER (WHERE id = 1) AS lignes_avec_id_1,
       count(*) FILTER (WHERE client_nom IS NULL AND date_ouverture IS NULL) AS lignes_vides
FROM interventions_legacy;
ROLLBACK;
```
```
 lignes_avec_id_1 | lignes_vides
------------------+--------------
                2 |            2
```
**Conséquence.** Une intervention peut être dupliquée ou créée sans client, sans date ni montant. Aucune donnée n'est garantie.
**Correction.** Clé primaire sur chaque table, `NOT NULL` sur les champs obligatoires, `UNIQUE` sur les clés naturelles, `CHECK` métier, clés étrangères.

### D2 — Toutes les colonnes métier en TEXT nullable · Critique
```sql
-- A02
SELECT data_type, is_nullable, count(*) AS nb_colonnes,
       string_agg(column_name, ', ' ORDER BY ordinal_position) AS colonnes
FROM information_schema.columns WHERE table_name = 'interventions_legacy'
GROUP BY data_type, is_nullable;
```
```
 data_type | is_nullable | nb_colonnes | colonnes
-----------+-------------+-------------+------------------------------------------------------------
 integer   | NO          |           1 | id
 text      | YES         |          15 | client_nom, client_email, client_tel, client_adresse,
           |             |             | contrat_ref, contrat_sla, technicien, technicien_tel,
           |             |             | equipement, equipement_serie, pieces_utilisees,
           |             |             | date_ouverture, date_cloture, statut, cout_total
```
**Conséquence.** Les dates, montants et durées n'ont pas de type. La base ne peut ni valider, ni calculer, ni trier correctement (voir D3 et D4).
**Correction.** `date` pour les dates, `numeric(10,2)` pour les montants, `integer` pour le SLA et les quantités, référentiels pour les statuts et les types.

### D3 — Dates : 3 formats, 3 façons de dire « pas de date », tri faux · Critique
```
-- A04 date_ouverture              -- A05 date_cloture
   format   | nb                       format    | nb
------------+-----                  -------------+----
 DD-MM-YY   | 126                    DD/MM/YYYY  | 87
 DD/MM/YYYY | 117                    DD-MM-YY    | 85
 YYYY-MM-DD |  28                    NULL        | 29
                                     'N/A'       | 28
                                     chaine vide | 22
                                     YYYY-MM-DD  | 20
```
Le tri sur le texte ne suit pas la chronologie (A06, premières lignes de `ORDER BY date_ouverture`) :
```
 valeur_texte | date_reelle
--------------+-------------
 01-03-25     | 2025-03-01
 01-04-25     | 2025-04-01
 01-05-25     | 2025-05-01
 01/03/2025   | 2025-03-01
 01/04/2026   | 2026-04-01   <- 2026 classé avant des dates de 2025
 01/05/2026   | 2026-05-01
```
**Conséquence.** Tout filtre ou tri par période est faux, et `DD-MM-YY` est ambigu sans règle explicite. L'absence de date est codée de 3 façons (`NULL`, `''`, `'N/A'`).
**Correction.** Conversion explicite des 3 formats vers `date`. Les 3 valeurs « vides » deviennent `NULL`. Un format inconnu **fait échouer la migration** au lieu d'être perdu en silence.

### D4 — Coûts en texte, 4 écritures de la devise · Critique
```
-- A07                   -- A08
  motif  | nb             max_texte | max_reel
---------+----           -----------+----------
 N.N€    | 73             980.45€   |  2074.68
 N.N     | 72
 N,N €   | 64
 N,N EUR | 62
```
**Conséquence.** `max()` sur le texte renvoie 980,45 alors que le vrai maximum est 2074,68. Toute somme ou tout chiffre d'affaires calculé directement est faux ou impossible.
**Correction.** `numeric(10,2)` après suppression de la devise et normalisation du séparateur décimal, plus `CHECK (cout_total >= 0)`.

### D5 — 10 orthographes pour 3 statuts · Critique
```
-- A09
 statut_brut | nb
-------------+----
 «Clos»      | 49
 «clos»      | 49
 «CLOTURE»   | 54
 «Clôturé»   | 46
 «en cours»  | 12
 «En Cours»  | 15
 «EN COURS » | 17      <- espace final
 «nouveau»   |  6
 «ouvert»    | 11
 «Ouvert»    | 12
```
**Conséquence.** `WHERE statut = 'clos'` ne trouve que 49 interventions clôturées sur 198. Les indicateurs par statut sont faux.
**Correction.** Référentiel `statut_intervention` (`ouverte`, `en_cours`, `cloturee`) relié par clé étrangère, et une table des transitions autorisées. La correspondance est explicite : `clos`, `cloture`, `clôturé` → `cloturee` ; `en cours` → `en_cours` ; `ouvert`, `nouveau` → `ouverte`. Une valeur inconnue fait échouer la migration.

### D6 — Interventions incohérentes · Critique
Les dates sont converties à la volée pour comparer clôture et ouverture (A19) :
```
 id  |  statut   | ouverture  |  cloture   |           anomalie
-----+-----------+------------+------------+-------------------------------
  45 | «clos»    | 2025-10-09 | 2025-10-07 | cloture avant ouverture
 134 | «Clos»    | 2025-04-02 | 2025-03-31 | cloture avant ouverture
 192 | «clos»    | 2026-06-17 | 2026-06-16 | cloture avant ouverture
 235 | «CLOTURE» | 2025-11-09 | 2025-11-08 | cloture avant ouverture
   3 | «CLOTURE» | 2025-09-27 | «»         | cloturee sans date de cloture
  51 | «CLOTURE» | 2025-10-19 | «N/A»      | cloturee sans date de cloture
 102 | «CLOTURE» | 2026-08-14 | «NULL»     | cloturee sans date de cloture
 135 | «CLOTURE» | 2025-09-25 | «N/A»      | cloturee sans date de cloture
 150 | «Clos»    | 2025-06-24 | «»         | cloturee sans date de cloture
 174 | «Clos»    | 2026-01-04 | «»         | cloturee sans date de cloture
(10 rows)
```
D'autres incohérences possibles ont été **vérifiées**, et non supposées absentes (A20) :
```
 non_cloturee_avec_date | ouverture_illisible | ouverture_dans_le_futur | cout_nul_ou_negatif
------------------------+---------------------+-------------------------+---------------------
                      0 |                   0 |                       0 |                   0
```
**Définition retenue pour le drapeau `anomalie`.** Une intervention est incohérente si ses propres données se contredisent :
1. **sa date de clôture est antérieure à sa date d'ouverture** (impossible dans le temps) ;
2. **son statut est « clôturée » mais elle n'a pas de date de clôture** (le statut et la date se contredisent).

Les autres défauts (e-mail manquant, nom mal orthographié) concernent la **qualité de la fiche client**, pas la cohérence de l'intervention. Ils sont nettoyés de manière traçable (D7, D8), sans marquer l'intervention.

**Correction.** Les 10 lignes sont **migrées telles quelles**, sans correction silencieuse. Elles sont signalées par deux colonnes calculées par la base, et toute nouvelle saisie est contrôlée.

### D7 — Un même client écrit jusqu'à 6 façons · Majeure
```
-- A12                                        -- A11 (extrait)
 noms_bruts_distincts | clients_reels          client_tel | nb_variantes | variantes
----------------------+---------------         0484067373 | 6 | « Supermarché Fresh» «SUPERMARCHÉ FRESH»
                   78 |            21                     |   | «Supermarche Fresh» «Supermarché Fresh »
                                                          |   | «Supermarché Fresh» «supermarché fresh»
                                               0490433061 | 6 | « Transports Berthet» «SARL Transports Berthet»
                                                          |   | «TRANSPORTS BERTHET» «Transports Berthet » ...
```
Les variantes combinent majuscules et minuscules, espaces en début, en fin ou doublés, accents supprimés et préfixe `SARL`. 20 clients sur 21 ont au moins 2 orthographes.

**Clé de dédoublonnage.** Le nom n'est pas fiable, mais le **téléphone** l'est. A14 prouve que téléphone, contrat, e-mail (en minuscules) et adresse sont en correspondance 1:1 :
```
           correspondance           | conflits
------------------------------------+----------
 telephone -> contrat               |        0
 contrat -> telephone               |        0
 telephone -> email (minuscules)    |        0
 telephone -> adresse               |        0
 contrat -> SLA (valeur numerique)  |        0
 numero de serie -> type            |        0
 numero de serie -> client          |        0
 technicien -> telephone            |        0
 telephone technicien -> technicien |        0
```
Entités réelles cachées dans la table (A15) :
```
 clients | techniciens | equipements | types_equipement
---------+-------------+-------------+------------------
      21 |           8 |          40 |                7
```
**Correction.** Une ligne par client, identifiée par son téléphone. Le nom retenu est la variante la plus fréquente, après suppression des espaces en trop. Les variantes d'origine restent consultables dans la table héritée, qui est conservée intacte.

### D8 — E-mails absents ou en majuscules · Majeure
```
-- A13
 email_absent | email_majuscules | emails_bruts_distincts | emails_reels
--------------+------------------+------------------------+--------------
            8 |               76 |                     41 |           21
```
**Correction.** E-mail stocké en minuscules, `UNIQUE`, et récupéré sur les autres lignes du même client quand une ligne ne l'a pas.

### D9 — Pièces multivaluées dans un seul champ · Majeure
```
-- A17                         -- A18
   contenu   | nb               lignes_de_pieces | references_distinctes | lignes_mal_formees | references_en_double_dans_une_intervention
-------------+----             ------------------+-----------------------+--------------------+--------------------------------------------
 'aucune'    | 34                            362 |                    15 |                  0 |                                          0
 1 piece(s)  | 58
 2 piece(s)  | 53
 3 piece(s)  | 66
 NULL        | 31
 chaine vide | 29
```
**Conséquence.** Le champ `"REF-002 x2;REF-011 x3"` contient plusieurs valeurs, ce qui viole la 1NF. On ne peut ni compter la consommation d'une pièce, ni contrôler une quantité, ni relier une pièce à un catalogue. « Aucune pièce » est codé de 3 façons. **Aucun prix unitaire n'existe dans les données.**
**Correction.** Table `piece` (15 références) et table de liaison `intervention_piece` (362 lignes) avec `quantite > 0`. Le prix unitaire n'est pas inventé.

### D10 — Redondance des coordonnées · Majeure
```
-- A16
 client_tel | copies_des_coordonnees
------------+------------------------
 0416394078 |                     26
 0484067373 |                     24
 0439380857 |                     20
```
**Conséquence.** Les coordonnées d'un client sont recopiées sur chacune de ses interventions (jusqu'à 26 fois). Changer une adresse oblige à modifier toutes ces lignes : c'est une anomalie de mise à jour, et c'est précisément ce qui a produit D7 et D8.
**Correction.** Normalisation en 3NF : client, contrat, technicien et équipement stockés une seule fois.

### D11 — SLA écrit de 12 façons · Mineure
A10 : `4`, `4h`, `4 heures`, `8`, `8h`, `8 heures`… soit 12 écritures pour 4 valeurs (4, 8, 24, 48 h). A14 prouve qu'il y a un seul SLA par contrat.
**Correction.** `contrat.sla_heures integer CHECK (sla_heures > 0)`.

---

## 2. Performance

### D12 — Aucun index, conversion à chaque lecture · Majeure
```
-- P01
 nb_index
----------
        0
```
Filtrer les interventions d'un technicien sur un mois (P02) : **parcours complet** et conversion de la date sur chaque ligne.
```
 Seq Scan on interventions_legacy (actual rows=1 loops=1)
   Filter: ((technicien = 'Durand Karim'::text) AND (CASE WHEN (date_ouverture ~ '^\d{4}-\d{2}-\d{2}$'::text)
           THEN to_date(...) ... END >= '2025-10-01'::date) AND (CASE ... END <= '2025-10-31'::date))
   Rows Removed by Filter: 270
```
Chercher une pièce (P03) demande un `LIKE '%…%'`, qui ne peut pas utiliser d'index B-tree :
```
 Aggregate (actual rows=1 loops=1)
   ->  Seq Scan on interventions_legacy (actual rows=33 loops=1)
         Filter: (pieces_utilisees ~~ '%REF-005%'::text)
         Rows Removed by Filter: 238
```
**Conséquence.** À 271 lignes le coût est invisible. Mais il augmente avec chaque intervention ajoutée, et aucune date ne peut être indexée tant qu'elle reste du texte : PostgreSQL refuse un index sur `to_date(date_ouverture, …)` (*functions in index expression must be marked IMMUTABLE*).
**Mesure.** À 271 000 interventions, ce planning prend **231 ms** dans la table héritée, contre **1,9 ms** dans le schéma normalisé. La recherche de pièce prend 54 ms contre 9 ms. Détail dans le [benchmark](../docs/benchmark.md).
**Correction.** Colonnes typées, index sur toutes les clés étrangères et sur `date_ouverture`, pièces dans une table de liaison indexée.

### D13 — Recherche par nom non fiable · Majeure
```
-- P04
 trouvees_par_nom_exact | interventions_reelles
------------------------+-----------------------
                     10 |                    18
```
Chercher « Transports Berthet » par son nom exact ne renvoie que **10 interventions sur 18**. Le reste est perdu à cause des variantes (D7).

---

## 3. Évolutivité

### D14 — Structure figée · Majeure
- **SLA recopié** (E01) : modifier le SLA d'un contrat oblige à réécrire toutes les lignes du client, qui portent déjà 3 écritures différentes.
```
 contrat_ref | lignes_a_modifier |  valeurs_actuelles
-------------+-------------------+----------------------
 CTR-8520    |                26 | 4 | 4 heures | 4h
 CTR-6617    |                24 | 8 | 8 heures | 8h
```
- **Une seule colonne par concept** (E02) : `technicien`, `contrat_ref`, `pieces_utilisees` et `cout_total` n'admettent qu'une valeur par intervention. Un deuxième technicien, un deuxième contrat par client, un prix unitaire ou une ventilation main-d'œuvre / pièces imposeraient de changer la structure de toutes les lignes.
- **Statuts non contrôlés** (A09) : n'importe quel texte est accepté, il n'existe pas de cycle de vie.

**Correction.** Une entité par table, des référentiels (statuts, transitions, types d'équipement), des contrats séparés des clients et une table de liaison pour les pièces. Une nouvelle règle se traduit alors par un ajout de lignes ou de colonnes, sans réécrire l'existant.

---

## 4. Sécurité

### D15 — Aucun modèle de droits · Critique
```
-- S02
      table_name      | proprietaire | proprietaire_superuser | rls_active | acl
----------------------+--------------+------------------------+------------+-------------------------------------
 interventions_legacy | postgres     | t                      | f          | (droits par defaut du proprietaire)
```
```
-- S03
 clients_visibles_par_un_technicien
------------------------------------
                                 21
```
**Conséquence.** La table appartient au superutilisateur, sans RLS ni droits accordés. Une application doit donc s'y connecter avec un compte très privilégié. Comme toutes les données sont dans une seule table, il est impossible de ne donner à un technicien que ses interventions et que certaines colonnes : il verrait les 21 clients.
**Correction.** Rôles PostgreSQL dédiés et sans superpouvoir (propriétaire du schéma, compte applicatif sans droit de modifier la structure, lecture seule). Tables séparées pour pouvoir accorder des droits fins, et séparation technicien / manager dans l'application (filtre par ligne et par champ).

### D16 — Données personnelles mêlées aux données opérationnelles · Majeure
S01 : `client_email`, `client_tel`, `client_adresse`, `contrat_ref`, `technicien` et `technicien_tel` sont dans la même table que les données d'intervention, recopiés jusqu'à 26 fois (D10).
**Conséquence.** Toute personne qui lit les interventions lit aussi les coordonnées. Rectifier ou effacer une donnée personnelle (RGPD) oblige à modifier des dizaines de lignes.
**Correction.** Coordonnées isolées dans `client` et `technicien`, stockées une seule fois, avec des droits de lecture limités par profil.

### D17 — Aucune traçabilité · Majeure
```
-- S04
 colonnes_de_tracabilite
-------------------------
                       0
```
**Conséquence.** Impossible de savoir qui a clôturé une intervention, ni quand.
**Correction.** Colonnes `created_at` et `updated_at`, et une table `historique_statut` alimentée **par trigger** : chaque changement de statut est enregistré, quel que soit l'outil qui écrit.
