# TP — Reprise d'un système en crise (SQL + no-code)

**Durée** : 3h30 en distanciel · **Travail** : individuel · **Niveau** : M2 Lead Dev

## Contexte

MaintenancePro est une PME de maintenance d'équipements techniques (chaudières, climatisations, onduleurs, ascenseurs…). Depuis des années, toute son activité est saisie dans **une seule table** : `interventions_legacy`. Le développeur qui l'a conçue est parti. La direction veut une application de pilotage fiable, utilisable par les techniciens et par les managers, **sans perdre une seule intervention**.

Vous êtes le Lead Dev chargé de reprendre le système.

## Mise en place

1. Créez une base PostgreSQL vide (hébergée ou locale, au choix).
2. Exécutez **tel quel** votre fichier `seed_<numéro>.sql` (votre numéro vous est communiqué individuellement). Votre jeu de données est **unique** : ne comparez pas vos résultats chiffrés avec vos camarades.
3. Choisissez et justifiez votre outil no-code (NocoDB, Baserow, Appsmith, Retool, Budibase… ou autre, à condition qu'il se branche sur PostgreSQL).

## Partie 1 — Audit (≈ 30 min)

Produisez un diagnostic de la table héritée, **chaque défaut étant appuyé par une requête SQL** et son résultat. Classez les défauts par gravité (intégrité des données, performance, évolutivité, sécurité). Une liste de défauts non prouvés ne rapporte pas de points.

## Partie 2 — Refonte et migration (≈ 1h15)

- Concevez un schéma normalisé (modèle conceptuel ou schéma relationnel à fournir).
- Migrez **toutes** les données vers ce schéma via un script **rejouable** (`migration.sql`) : relancé deux fois, il ne doit ni échouer ni dupliquer.
- Aucune intervention ne doit être supprimée. Les données incohérentes sont **conservées et signalées**, pas effacées ni corrigées en silence.
- Ajoutez les contraintes qui s'imposent (clés primaires et étrangères, `UNIQUE`, `CHECK`, types adaptés).

### Contrat d'interface (obligatoire, noms de colonnes figés)

Votre travail est évalué en partie automatiquement par des requêtes de contrôle. Exposez donc ces deux vues :

```
v_export_interventions(id_legacy int, date_ouverture date, date_cloture date,
                       statut text, cout_total numeric, anomalie boolean)
v_export_entites(entite text, nb int)
```

- `statut` ne prend que les valeurs `ouverte`, `en_cours`, `cloturee`.
- `v_export_entites` contient 4 lignes : `clients`, `techniciens`, `equipements`, `lignes_pieces` (nombre d'éléments distincts, après nettoyage).
- `anomalie` vaut `true` pour toute intervention dont les données sont incohérentes (à vous de définir et de justifier les cas détectés).

## Partie 3 — Évolution imprévue (révélée en cours de séance)

Un nouvel énoncé vous sera envoyé en cours de TP. Il modifie les règles métier et impose de faire évoluer le **schéma**, pas seulement l'interface.

## Partie 4 — Application no-code (≈ 1h)

Branchez l'outil choisi sur votre base et livrez :

- une interface **technicien** (ses interventions, mise à jour du statut) ;
- une interface **manager** (vue d'ensemble, filtres, indicateurs) ;
- une **séparation des droits** effective entre les deux profils ;
- au moins **une logique côté base** (vue, fonction ou trigger) que l'outil no-code ne saurait pas faire seul, avec justification.

## Livrables (à déposer avant la fin de la séance)

1. `audit.md` : défauts + requêtes + résultats
2. `migration.sql` : rejouable
3. Schéma (image ou fichier de modélisation)
4. Fichier(s) pour la partie 3
5. Lien ou export de l'application no-code + 3 captures d'écran
6. `journal.md` : choix techniques, difficultés, et **toute utilisation d'un outil d'IA** (prompt, réponse, ce que vous en avez gardé ou rejeté et pourquoi)
7. Un **enregistrement d'écran continu** de la séance (fichier ou lien)

## Règles

- L'usage d'outils d'IA est **autorisé à condition d'être consigné** dans `journal.md`. Un rendu que vous ne savez pas expliquer sera plafonné, quelle que soit sa qualité.
- Chacun est évalué **à l'oral** (≈ 10 min, en visio, planning communiqué). Vous modifierez votre base en direct à la demande de l'enseignant.
- Toute copie entre étudiants est sanctionnée. Les jeux de données sont différents : les rendus identiques se repèrent.

## Barème (20 points)

| Partie | Points |
|---|---|
| Audit (qualité et preuves) | 2 |
| Schéma, migration, contraintes, contrôles automatiques | 5 |
| Évolution imprévue | 3 |
| Application no-code (profils, droits, logique côté base) | 2 |
| Défense orale (modification en direct, justification des choix) | 8 |
