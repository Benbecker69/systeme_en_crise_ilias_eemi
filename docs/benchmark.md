# Benchmark : table héritée contre schéma normalisé

## En bref

- **À la volumétrie actuelle (271 interventions)**, toutes les requêtes répondent en moins de 3 ms dans les deux modèles. Les performances **ne justifient pas** la refonte à elles seules. Ce qui la justifie, c'est l'exactitude des résultats.
- **Résultats faux dans la table héritée.** Le chiffre d'affaires par client y renvoie **60 « clients » au lieu de 21**, à cause des variantes de noms. Le schéma normalisé donne le bon résultat, quel que soit le volume.
- **À 1 000 fois le volume (271 000 interventions)** :
  - la table héritée est 6 à 9 500 fois plus lente selon la requête ;
  - son temps croît **proportionnellement au volume**, alors que celui du schéma normalisé reste **presque constant** grâce aux index.
- **Ce que ça coûte.** Écrire dans le schéma normalisé est plus lent : environ 0,4 ms par intervention, du fait des contrôles d'intégrité et de l'historique. C'est négligeable au rythme réel de l'entreprise (§ 4).

## 1. Méthode

| Point | Choix |
|---|---|
| Script | [`sql/benchmark/benchmark.sql`](../sql/benchmark/benchmark.sql). Sortie brute : [`sql/benchmark/resultats.txt`](../sql/benchmark/resultats.txt) |
| Sans effet sur la base | Tout est construit dans un schéma `bench`, dans une transaction **annulée** à la fin |
| Volumes | x1, x10, x100, x1000 le seed (271 → 271 000 interventions). Chaque ligne est recopiée avec un nouvel id, donc la répartition des dates, techniciens, pièces et anomalies ne change pas |
| Table héritée | Copie conforme : aucun index, aucune contrainte. Pour filtrer une date ou sommer un coût, il faut convertir le texte à chaque ligne (fonctions `mp_parse_*` de la migration) |
| Schéma normalisé | Mêmes index que la production (`sql/migration.sql`) |
| Mesure | 1 exécution d'échauffement, puis la **médiane de 7**. Chaque ligne et chaque colonne est lue jusqu'au bout, pour que PostgreSQL ne puisse pas sauter un calcul |
| Environnement | PostgreSQL 17.11 en conteneur (Docker Desktop, Windows Server 2022), configuration par défaut : `shared_buffers` 128 Mo, JIT actif, 2 workers parallèles |
| Reproductibilité | Deux exécutions complètes donnent les mêmes ordres de grandeur. À 271 000 lignes, l'écart est de 0 à 13 % sur la table héritée (Q1 : 230 puis 231 ms ; Q3 : 62 puis 54 ms). Les mesures de quelques millisecondes varient davantage (Q3 normalisé : 12,4 puis 9,1 ms), sans changer les conclusions |

Relancer : `./scripts/run-sql.ps1 sql/benchmark/benchmark.sql` (≈ 1 min 30).

## 2. Résultats (médianes, en ms)

| Requête métier | 271 lignes : héritée / normalisé | 271 000 lignes : héritée / normalisé | Gain à 271 000 |
|---|---|---|---|
| **Q1** Planning d'un technicien sur un mois | 0,41 / 0,82 | 231 / **1,9** | ×122 |
| **Q2** Chiffre d'affaires 2025 par client | 2,6 / 0,8 | 2 172 / **77** | ×28 |
| **Q3** Interventions ayant utilisé la pièce REF-005 | 0,09 / 0,30 | 54 / **9** | ×6 |
| **Q4** Anomalies à vérifier | 2,4 / 0,05 | 2 252 / **21** | ×106 |
| **Q5** 20 interventions les plus récentes (tableau de bord) | 0,94 / 0,09 | 890 / **0,09** | ×9 572 |

Évolution avec le volume (Q1, Q5) :

| Interventions | Q1 héritée | Q1 normalisé | Q5 héritée | Q5 normalisé |
|---|---|---|---|---|
| 271 | 0,41 | 0,82 | 0,94 | 0,09 |
| 2 710 | 2,4 | 0,74 | 8,8 | 0,12 |
| 27 100 | 22 | 0,76 | 86 | 0,12 |
| 271 000 | 231 | 1,9 | 890 | 0,09 |

### Exactitude

| Requête | Lignes, table héritée | Lignes, schéma normalisé | Lecture |
|---|---|---|---|
| Q2 Chiffre d'affaires par client | **60** | **21** | La table héritée découpe un même client en plusieurs groupes selon l'orthographe de son nom (audit D7). Le **chiffre d'affaires par client y est faux**, à n'importe quel volume. |
| Q1, Q3, Q4, Q5 | identiques | identiques | Même réponse, mais beaucoup plus lente dans la table héritée. |

## 3. Analyse

1. **Coût linéaire contre coût logarithmique.**
   - Table héritée : chaque requête est un parcours complet (`Seq Scan`) qui convertit le texte ligne par ligne. Multiplier le volume par 10 multiplie le temps par 10.
   - Schéma normalisé : les index B-tree ne lisent que les lignes utiles. Q5 reste à 0,09 ms à tous les volumes, car elle lit l'index `date_ouverture` à l'envers et s'arrête après 20 lignes.

   Extraits des plans d'exécution réels à 271 000 lignes :
   ```
   Q5 héritée :    Sort (top-N heapsort) -> Seq Scan on legacy (actual rows=271000)
   Q5 normalisé :  Limit -> Index Scan Backward using intervention_date_ouverture_idx (actual rows=20)
   Q1 héritée :    Seq Scan on legacy ... Rows Removed by Filter: 270000
   Q1 normalisé :  Bitmap Index Scan on intervention_technicien_id_date_ouverture_idx (actual rows=1000)
   ```
2. **La table héritée ne peut même pas être indexée sur ses dates.** On a essayé de créer un index sur la date convertie :
   ```sql
   CREATE INDEX ON interventions_legacy (to_date(date_ouverture, 'DD/MM/YYYY'));
   -- ERROR:  functions in index expression must be marked IMMUTABLE
   ```
   PostgreSQL refuse parce que `to_date` dépend des paramètres de session. De plus, les dates sont écrites en 3 formats (audit D3), donc un seul format ne suffirait pas. **Seul un vrai type `date` rend la date indexable.**
3. **Q3 : un `LIKE '%…%'` ne peut pas utiliser un index B-tree.** La table de liaison `intervention_piece`, indexée sur `piece_id`, transforme la recherche en accès direct.
4. **Q4 : les drapeaux d'anomalie calculés une fois pour toutes.** Dans la table héritée, chaque lecture doit reconvertir deux dates et un statut. Dans le schéma normalisé, les colonnes `GENERATED … STORED` sont calculées **à l'écriture**, et la lecture ne fait qu'un test booléen.
5. **Honnêteté sur les petits volumes.** À 271 lignes, Q1 et Q3 sont un peu plus rapides sur la table héritée (0,4 contre 0,8 ms, 0,09 contre 0,30 ms) : une jointure coûte plus qu'un petit parcours. Les écarts sont de quelques dixièmes de milliseconde, et ils s'inversent dès 2 700 lignes.

## 4. Le prix de l'intégrité : l'écriture

Insertion de 10 000 interventions (médiane de 5) :

| Cible | Durée | Par intervention |
|---|---|---|
| Table héritée (aucun contrôle) | 18,6 ms | 0,002 ms |
| Table `intervention` (contraintes, index, triggers) | 4 278 ms | 0,43 ms |

Détail mesuré par `EXPLAIN ANALYZE` (sortie brute dans `resultats.txt`) :

| Poste | Temps pour 10 000 lignes | Ce qu'il garantit |
|---|---|---|
| 3 clés étrangères (équipement, technicien, statut) | ≈ 1 580 ms | Aucune intervention orpheline |
| Trigger de règles `trg_intervention_avant_ecriture` | ≈ 1 010 ms | Statut initial obligatoire, pas de clôture à la création |
| Trigger d'historique (avec ses propres clés étrangères) | ≈ 1 570 ms | Traçabilité de chaque création et changement de statut |
| Insertion et 6 index | ≈ 170 ms | Lectures rapides (§ 2) |

**Ce coût est-il acceptable ?** Le seed couvre 271 interventions entre le 6 janvier 2025 et le 28 août 2026, soit environ **14 par mois**.
- Au rythme actuel, les contrôles coûtent environ **6 ms par mois**.
- À un rythme 1 000 fois plus élevé (14 000 par mois), ils coûteraient 6 s par mois.

Le temps passé à vérifier est sans commune mesure avec celui que coûtent aujourd'hui les erreurs de saisie (audit D1 à D11).

**Si un jour il faut importer en masse** : chargement dans une table intermédiaire, puis `INSERT … SELECT` en une seule opération, comme le fait déjà `migration.sql`. Les lignes reprises de l'historique (`id_legacy` renseigné) ne déclenchent pas l'historisation.

## 5. Limites de la mesure

- **Données recopiées.** Une vraie base de 271 000 interventions aurait plus de clients, de techniciens et d'équipements. Les tables de référence (21 clients, 40 équipements) restent petites ici, ce qui avantage un peu les jointures du schéma normalisé.
- **Données en mémoire.** Les deux modèles sont mesurés sur des données en cache (après échauffement). Sur disque froid, l'écart serait plus grand pour la table héritée, qui lit plus de pages.
- **Une seule machine**, configuration PostgreSQL par défaut, sans réglage.
