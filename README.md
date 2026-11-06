# MaintenancePro : reprise d'un système en crise

Reprise de la base héritée `interventions_legacy` de MaintenancePro (seed 4) : audit prouvé par SQL, schéma normalisé, migration rejouable, et application de pilotage no-code avec des droits séparés.

- Sujet : [sujet-tp.md](sujet-tp.md)
- Jeu de données : [seed/seed_4.sql](seed/seed_4.sql), exécuté **tel quel**

## En bref

| | Avant (table héritée) | Après (schéma normalisé) | Preuve |
|---|---|---|---|
| Contraintes | 0 (ni clé primaire, ni clé étrangère, ni `CHECK`) | 13 clés étrangères, 12 `CHECK`, `UNIQUE` sur chaque clé naturelle | [audit D1](audit/audit.md), test T07 |
| Interventions | 271 lignes en texte libre | 271 migrées, **aucune perdue**, coût total conservé au centime (172 806,02 €) | T01, T02, T03 |
| Clients | 78 orthographes de noms | 21 clients | audit A11, A14 ; T06 |
| Incohérences | invisibles | 10 conservées **et signalées** par des colonnes calculées par la base | audit A19 ; T05 |
| Statuts | 10 orthographes, aucun cycle de vie | 3 statuts, transitions contrôlées par trigger, historique infalsifiable | T10 à T13 |
| Migration rejouée | — | export identique au caractère près (empreinte MD5) | T00 |
| Planning d'un technicien, à 271 000 interventions | 231 ms | 1,9 ms | [benchmark](docs/benchmark.md) |
| Chiffre d'affaires par client | **faux** : 60 groupes pour 21 clients | juste | [benchmark](docs/benchmark.md) |
| Droits | table du superutilisateur | technicien et manager séparés, jamais de `DELETE` | 14 contrôles `verify.py` |

## Démarrage rapide

Prérequis : **Docker** seulement.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/install.ps1   # Windows
./scripts/install.sh                                           # macOS / Linux / Git Bash
```

L'installation part d'une base vide, exécute le seed, migre, lance les tests SQL, construit l'application et contrôle les droits. Ensuite :

| Service | Adresse |
|---|---|
| Application Directus | http://localhost:8055 |
| pgAdmin | http://localhost:5050 |
| PostgreSQL | `localhost:5433`, base `maintenancepro` |

Comptes, mots de passe, commande `checks.sql` et dépannage : **[guide d'installation et de correction](docs/guide-installation.md)**.

## Livrables

| # | Livrable demandé | Où le trouver |
|---|---|---|
| 1 | `audit.md` : défauts, requêtes, résultats | [audit/audit.md](audit/audit.md) : 17 défauts classés par gravité. Requêtes : [audit/queries.sql](audit/queries.sql). Sortie brute : [audit/resultats.txt](audit/resultats.txt) |
| 2 | `migration.sql` rejouable | [sql/migration.sql](sql/migration.sql). Tests : [sql/tests/test_migration.sql](sql/tests/test_migration.sql) |
| 3 | Schéma | [docs/schema.png](docs/schema.png) (source Mermaid : [docs/schema.mmd](docs/schema.mmd)), justifié dans [docs/schema.md](docs/schema.md) |
| 4 | Fichiers de la partie 3 | L'enseignant a annoncé qu'il n'y aurait **pas de partie 3**. L'évolutivité est démontrée sur trois scénarios testés : [docs/evolutivite.md](docs/evolutivite.md) et [sql/evolution/scenarios.sql](sql/evolution/scenarios.sql) |
| 5 | Application no-code et 3 captures | [docs/application.md](docs/application.md). Captures : [docs/captures/](docs/captures/). L'application se reconstruit entièrement par [directus/setup.py](directus/setup.py). Export du modèle : [directus/schema-snapshot.yaml](directus/schema-snapshot.yaml) |
| 6 | `journal.md` | [journal.md](journal.md) : chronologie, choix techniques, difficultés |
| 7 | Enregistrement d'écran | Fourni séparément |

## Correspondance avec le barème

| Partie | Ce qui est livré | Pour vérifier |
|---|---|---|
| **Audit** (2 pts) | 17 défauts dans les 4 catégories du sujet, chacun avec sa requête, son résultat réel, sa gravité, sa conséquence et sa correction | `scripts/run-sql.ps1 audit/queries.sql` |
| **Schéma, migration, contraintes, contrôles automatiques** (5 pts) | 3NF, 11 tables, migration en une transaction, rejouable. Échec explicite sur tout format inconnu. Contrat d'interface respecté. | `scripts/test.ps1` (15 tests), puis `checks.sql` ([commande](docs/guide-installation.md#4-lancer-les-contrôles-automatiques-checkssql)) |
| **Évolution imprévue** (3 pts) | Partie non donnée. Trois évolutions jouées sur la vraie base, contrat d'interface vérifié intact | `scripts/run-sql.ps1 sql/evolution/scenarios.sql` |
| **Application no-code** (2 pts) | Interfaces technicien et manager, droits par ligne et par champ, tableau de bord. Logique en base : cycle de vie, historique, drapeaux d'anomalie. | `scripts/verify-app.ps1` (14 contrôles), puis connexion avec les comptes de démonstration |
| **Défense orale** (8 pts) | Choix argumentés, alternatives et sources, mesures | [docs/choix-techniques.md](docs/choix-techniques.md), [docs/benchmark.md](docs/benchmark.md) |

## Documentation

| Document | Contenu |
|---|---|
| [docs/guide-installation.md](docs/guide-installation.md) | Installation, accès, `checks.sql`, commandes, dépannage |
| [audit/audit.md](audit/audit.md) | Diagnostic de la table héritée, avec preuves |
| [docs/schema.md](docs/schema.md) | Schéma, anomalies, triggers, rôles, contrat d'interface |
| [docs/choix-techniques.md](docs/choix-techniques.md) | Chaque décision : alternatives, arguments, preuves, sources officielles |
| [docs/benchmark.md](docs/benchmark.md) | Mesures de 271 à 271 000 interventions, plans d'exécution, coût de l'intégrité |
| [docs/evolutivite.md](docs/evolutivite.md) | Trois évolutions de règles métier jouées et testées |
| [docs/application.md](docs/application.md) | Outil no-code : choix, interfaces, matrice des droits, logique côté base, limites |
| [journal.md](journal.md) | Chronologie, choix, difficultés et solutions |

## Structure du dépôt

```
├── audit/                 audit.md, queries.sql, resultats.txt
├── directus/              setup.py (construit l'application), verify.py (contrôle les droits),
│                          relations.sql, schema-snapshot.yaml
├── docker/                initialisation PostgreSQL, configuration pgAdmin
├── docs/                  documentation, schéma, captures
├── scripts/               install, reset, run-sql, test, setup-app, verify-app, init-env (.ps1 et .sh)
├── seed/                  seed_4.sql (inchangé)
├── sql/
│   ├── migration.sql      schéma + reprise des données + règles + vues + droits
│   ├── tests/             tests d'intégrité et d'idempotence
│   ├── benchmark/         benchmark et résultats bruts
│   └── evolution/         scénarios d'évolution et résultats bruts
├── docker-compose.yml     PostgreSQL, Directus, pgAdmin, conteneur d'outils
├── .env.example           modèle de configuration (le .env est généré par l'installation)
└── journal.md
```

## Stack

| Service | Image (version figée) | Rôle |
|---|---|---|
| PostgreSQL | `postgres:17.11-alpine3.23` | Base de données, règles métier |
| Directus | `directus/directus:11.17.4` | Application no-code |
| pgAdmin | `dpage/pgadmin4:9.18.0` | Client SQL, déjà connecté à la base |
| Outils | `python:3.13.16-alpine3.23` | Exécute `setup.py` et `verify.py` (aucun Python local nécessaire) |
