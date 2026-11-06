# Évolutivité : ce que coûte un changement de règle métier

L'enseignant a annoncé qu'il n'y aurait **pas de Partie 3**. Le schéma a quand même été conçu pour encaisser une évolution des règles métier : c'est le défaut D14 de l'audit (« structure figée »).

Cette page vérifie cette affirmation sur trois évolutions plausibles. Chacune est **jouée sur la vraie base**, avec des contrôles automatiques, dans une transaction annulée à la fin :

```powershell
./scripts/run-sql.ps1 sql/evolution/scenarios.sql
```

Script : [`sql/evolution/scenarios.sql`](../sql/evolution/scenarios.sql). Sortie : [`sql/evolution/resultats.txt`](../sql/evolution/resultats.txt).

## Synthèse

| Évolution | Table héritée | Schéma normalisé | Changement de structure | Contrat d'export |
|---|---|---|---|---|
| **A.** Nouveau statut « en attente de pièces » | Une 11e orthographe libre, sans contrôle du cycle de vie | 1 + 2 `INSERT` dans `statut_intervention` et `transition_statut`. Le trigger existant applique la règle sans modification | aucun pour la règle ; 1 colonne pour l'export | inchangé (testé) |
| **B.** Prix des pièces | Impossible proprement : toutes les pièces sont dans un seul champ texte (`REF-002 x2;REF-011 x3`) | 2 colonnes `numeric` avec `CHECK` | 2 `ALTER TABLE … ADD COLUMN` | inchangé (testé) |
| **C.** Plusieurs techniciens par intervention | Ajouter des colonnes `technicien2`, `technicien3`… ou concaténer des noms | 1 table de liaison, reprise des 271 affectations existantes | 1 `CREATE TABLE` | inchangé (testé) |

Résultat de l'exécution :
```
A1 PASS : en_attente_pieces -> cloturee refusée (Transition de statut interdite : en_attente_pieces -> cloturee)
A2 PASS : cycle complet accepté et historisé (5 lignes : création + 4 changements)
A3 PASS : le contrat d'export garde ses 3 valeurs (en_attente_pieces exporté en en_cours)
B1 PASS : 362 lignes conservées, aucun prix inventé, prix négatif refusé
C1 PASS : chaque intervention reprise avec son responsable, renfort accepté, 2e responsable refusé
PASS : après les 3 évolutions, le contrat d'interface est identique (clients=21,equipements=40,lignes_pieces=362,techniciens=8)
```

## A. Nouveau statut : la machine à états est faite de données

```sql
INSERT INTO statut_intervention (code, libelle, ordre, est_initial, est_final)
VALUES ('en_attente_pieces', 'En attente de pièces', 4, false, false);
INSERT INTO transition_statut (statut_depart, statut_arrivee)
VALUES ('en_cours', 'en_attente_pieces'), ('en_attente_pieces', 'en_cours');
```

- **Pourquoi c'est simple.** Le trigger `trg_intervention_avant_ecriture` ne connaît aucun statut en dur : il lit `transition_statut`. La transition interdite `en_attente_pieces → cloturee` est donc refusée **sans toucher au code** (A1).
- **L'application suit.** La liste déroulante du statut dans Directus est une relation vers `statut_intervention`. Le nouveau statut y apparaît sans reconfiguration.
- **Comparaison avec un `ENUM`.** La documentation PostgreSQL le dit : *« Existing values cannot be removed from an enum type, nor can the sort ordering of such values be changed, short of dropping and re-creating the enum type »* ([§ 8.7.4](https://www.postgresql.org/docs/17/datatype-enum.html)). Une table de référence se modifie par un simple `UPDATE`, ou par un `DELETE` d'un statut qui n'est plus utilisé (les clés étrangères l'empêchent sinon).
- **Le point de vigilance, détecté par le test.**
  - Le contrat impose 3 valeurs de `statut` à l'export. Une intervention passée « en attente » ferait apparaître une 4e valeur et casserait le contrôle automatique C7.
  - Le scénario ajoute donc une colonne `statut_export`, avec `CHECK IN ('ouverte','en_cours','cloturee')`, qui dit à quelle valeur du contrat chaque statut interne correspond. La vue se contente de la lire.
  - Le contrat tient même quand une intervention héritée passe au nouveau statut (A3).

## B. Prix des pièces : figer le prix au moment de l'intervention

```sql
ALTER TABLE piece              ADD COLUMN prix_catalogue numeric(10,2), ADD CONSTRAINT ck_piece_prix CHECK (prix_catalogue >= 0);
ALTER TABLE intervention_piece ADD COLUMN prix_unitaire  numeric(10,2), ADD CONSTRAINT ck_intervention_piece_prix CHECK (prix_unitaire >= 0);
```

- **Deux colonnes, pas une.** Le prix du catalogue évolue, mais une intervention passée doit garder le prix réellement facturé. Le prix est donc **recopié sur la ligne** au moment de l'intervention. C'est une dénormalisation volontaire : une valeur historique n'est pas une redondance.
- **Rien n'est inventé.** Les données héritées ne contiennent aucun prix. Les 362 lignes reprises restent à `NULL`, et le coût total historique n'est pas recalculé (B1).
- **Dans la table héritée**, il faudrait réécrire un format libre (`REF-002 x2@45.00;…`) dans un champ que rien ne valide.

## C. Plusieurs techniciens : une table de liaison, sans casser l'existant

```sql
CREATE TABLE intervention_technicien (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  intervention_id bigint NOT NULL REFERENCES intervention (id),
  technicien_id   bigint NOT NULL REFERENCES technicien (id),
  role text NOT NULL DEFAULT 'renfort' CHECK (role IN ('responsable', 'renfort')),
  UNIQUE (intervention_id, technicien_id)
);
CREATE UNIQUE INDEX uq_intervention_un_responsable
  ON intervention_technicien (intervention_id) WHERE role = 'responsable';
INSERT INTO intervention_technicien (intervention_id, technicien_id, role)
SELECT id, technicien_id, 'responsable' FROM intervention;
```

- **Pas de perte.** Toutes les affectations existantes sont reprises comme « responsable » (C1).
- **Un index unique partiel** garantit un seul responsable par intervention. C'est une règle qu'aucun `CHECK` ne peut exprimer, parce qu'elle porte sur plusieurs lignes.
- **Migration progressive.** `intervention.technicien_id` reste en place pendant la transition. Les écrans et le filtre du technicien dans Directus continuent de fonctionner.
- **Étape suivante.** Élargir le filtre du technicien aux renforts (`_or` sur la relation inverse), puis supprimer la colonne quand plus rien ne la lit.

## Ce que montre l'exercice

1. Les règles métier **décrites par des données** (statuts, transitions) évoluent sans modifier le code.
2. Chaque évolution s'accompagne de **tests qui protègent le contrat d'interface**. C'est ce qui a révélé le piège du statut exporté (A) avant qu'il casse la correction automatique.
3. Les tables de liaison et les clés techniques simples permettent d'**ajouter** sans **réécrire** : aucune des trois évolutions ne touche aux 271 interventions existantes.
