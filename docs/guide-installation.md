# Guide d'installation et de correction

Il permet de tout reconstruire depuis zéro sur n'importe quel poste, puis de vérifier chaque livrable.

## 1. Prérequis

| Outil | Remarque |
|---|---|
| **Docker** avec Docker Compose v2 | Docker Desktop sous Windows et macOS. Testé avec Docker Compose v2.35. |
| Git | Pour cloner le dépôt |
| Ports libres | `5433` (PostgreSQL), `8055` (Directus), `5050` (pgAdmin) |

**Aucune installation de PostgreSQL ni de Python n'est nécessaire** : tout tourne en conteneur. Les scripts existent en deux versions, PowerShell (`.ps1`, Windows) et shell (`.sh`, macOS, Linux, Git Bash).

## 2. Installation en une commande

```powershell
git clone https://github.com/Benbecker69/systeme_en_crise_ilias_eemi.git
cd systeme_en_crise_ilias_eemi

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File scripts/install.ps1

# macOS / Linux / Git Bash
./scripts/install.sh
```

Durée : 2 à 3 minutes la première fois, le temps de télécharger les images.

> ⚠️ L'installation **supprime les conteneurs et volumes** du projet `maintenancepro` avant de repartir de zéro.

Le script enchaîne 6 étapes et s'arrête à la première erreur :

| Étape | Ce qui se passe | Résultat attendu |
|---|---|---|
| 1. `.env` | Créé à partir de `.env.example`, avec des mots de passe aléatoires. S'il existe déjà, il est conservé. | `.env created with random secrets` |
| 2. Base vide + seed | `docker compose down -v` puis `up`. Au premier démarrage, PostgreSQL crée le rôle de connexion de Directus, puis exécute **`seed/seed_4.sql` tel quel**. | 3 conteneurs `Healthy` |
| 3. Migration | `sql/migration.sql` : schéma normalisé, reprise des données, triggers, vues, droits | aucune erreur |
| 4. Tests SQL | La migration est relancée (idempotence), puis 14 tests d'intégrité tournent dans une transaction annulée | `T00` à `T14` en `PASS` |
| 5. Application | `directus/relations.sql`, puis `directus/setup.py` dans le conteneur `outils` | 7 lignes `[ok]` |
| 6. Contrôle des droits | `directus/verify.py` se connecte avec les vrais comptes de démonstration | 14 lignes `[PASS]` |

## 3. Accès

Tous les mots de passe sont dans le fichier **`.env`**, généré à l'étape 1.

| Service | Adresse | Identifiant | Mot de passe (`.env`) |
|---|---|---|---|
| Application Directus : administrateur | http://localhost:8055 | `admin@example.com` | `DIRECTUS_ADMIN_PASSWORD` |
| Application : **manager** | http://localhost:8055 | `manager@example.com` | `APP_MANAGER_PASSWORD` |
| Application : **technicien** (Karim Durand) | http://localhost:8055 | `karim.durand@example.com` | `APP_TECH_PASSWORD` |
| Application : **technicien** (Inès Vidal) | http://localhost:8055 | `ines.vidal@example.com` | `APP_TECH_PASSWORD` |
| pgAdmin | http://localhost:5050 | `admin@example.com` | `PGADMIN_PASSWORD` |
| PostgreSQL : superutilisateur | `localhost:5433`, base `maintenancepro` | `postgres` | `POSTGRES_PASSWORD` |

**pgAdmin.** Le serveur « TP › MaintenancePro » est déjà déclaré. Au premier accès, pgAdmin demande le mot de passe `postgres` (`POSTGRES_PASSWORD`).

**psql sans rien installer :**
```powershell
docker compose exec db psql -U postgres -d maintenancepro
```

**Client externe** (DBeaver, DataGrip, psql local) : hôte `localhost`, port `5433`, base `maintenancepro`, utilisateur `postgres`.

## 4. Lancer les contrôles automatiques (`checks.sql`)

Le contrat d'interface est en place : `v_export_interventions` et `v_export_entites`. Depuis le dossier du dépôt, avec `checks.sql` copié à la racine :

```powershell
docker compose cp checks.sql db:/tmp/checks.sql
docker compose exec db psql -U postgres -d maintenancepro -f /tmp/checks.sql `
  -v n_interventions=… -v n_clients=… -v n_techniciens=… -v n_equipements=… `
  -v n_lignes_pieces=… -v cout_total=… -v n_non_cloturees=… -v n_anomalies=…
```

Sous Git Bash, préfixer par `MSYS_NO_PATHCONV=1` pour que `/tmp/checks.sql` ne soit pas converti en chemin Windows. Avec un psql local, passer la chaîne de connexion à la place de `docker compose exec` : `psql "postgresql://postgres:<POSTGRES_PASSWORD>@localhost:5433/maintenancepro" -f checks.sql -v …`

Valeurs obtenues par nos propres tests, pour comparaison :

| Variable | Valeur obtenue | Où elle est prouvée |
|---|---|---|
| `n_interventions` | 271 | audit A00, test T01 |
| `n_clients` | 21 | audit A12, A15 ; T06 |
| `n_techniciens` | 8 | audit A15 ; T06 |
| `n_equipements` | 40 | audit A15 ; T06 |
| `n_lignes_pieces` | 362 | audit A18 ; T06 |
| `cout_total` | 172806.02 | T03 (au centime) |
| `n_non_cloturees` | 73 (44 en cours + 29 ouvertes) | audit A09 |
| `n_anomalies` | 10 (4 clôtures avant ouverture + 6 clôturées sans date) | audit A19 ; T05 |

## 5. Commandes à la carte

| Action | PowerShell | Shell |
|---|---|---|
| Tout réinstaller depuis zéro | `scripts/install.ps1` | `scripts/install.sh` |
| Base vide + seed seulement | `scripts/reset.ps1` | `scripts/reset.sh` |
| Exécuter un fichier SQL du projet | `scripts/run-sql.ps1 sql/migration.sql` | `scripts/run-sql.sh sql/migration.sql` |
| Idempotence + tests SQL | `scripts/test.ps1` | `scripts/test.sh` |
| (Re)construire l'application | `scripts/setup-app.ps1` | `scripts/setup-app.sh` |
| Contrôler les droits de l'application | `scripts/verify-app.ps1` | `scripts/verify-app.sh` |
| Rejouer l'audit | `scripts/run-sql.ps1 audit/queries.sql` | `scripts/run-sql.sh audit/queries.sql` |
| Benchmark (≈ 1 min 30, sans effet sur la base) | `scripts/run-sql.ps1 sql/benchmark/benchmark.sql` | idem en `.sh` |
| Scénarios d'évolution (sans effet sur la base) | `scripts/run-sql.ps1 sql/evolution/scenarios.sql` | idem en `.sh` |

`run-sql` n'accepte que les fichiers des dossiers `sql/`, `audit/` et `directus/`, qui sont montés dans le conteneur.

## 6. Requêtes utiles pour explorer

```sql
SELECT * FROM v_indicateurs;                        -- vue d'ensemble
SELECT * FROM v_anomalies ORDER BY id_legacy;       -- les 10 anomalies, avec leur type
SELECT * FROM v_export_entites;                     -- contrat d'interface
SELECT * FROM transition_statut;                    -- cycle de vie autorisé

-- La règle de transition est appliquée par la base, quel que soit le client :
UPDATE intervention SET statut_code = 'cloturee'
WHERE id = (SELECT min(id) FROM intervention WHERE statut_code = 'ouverte');
-- ERROR:  Transition de statut interdite : ouverte -> cloturee
```

## 7. État de la base après installation

- Les 271 interventions sont migrées. La table héritée `interventions_legacy` est **conservée intacte**, comme référence.
- Les tests SQL (étape 4) annulent tout ce qu'ils modifient.
- Le contrôle des droits (étape 6) fait passer une intervention du technicien Karim Durand de `ouverte` à `en_cours`, puis de nouveau à `ouverte`, pour prouver l'historisation. Cela laisse **2 lignes dans `historique_statut`** et ne change pas l'export.

## 8. Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `port is already allocated` | Un autre service utilise 5433, 8055 ou 5050 | Changer `POSTGRES_HOST_PORT`, `DIRECTUS_PORT` ou `PGADMIN_PORT` dans `.env`, puis relancer l'installation |
| `password authentication failed` | `.env` modifié après la création de la base | Relancer l'installation : elle recrée les volumes avec le `.env` actuel |
| `running scripts is disabled on this system` | Politique d'exécution PowerShell | Lancer avec `powershell -ExecutionPolicy Bypass -File …` |
| `/usr/bin/env: 'sh\r'` | Fins de ligne Windows sur un script shell | Le dépôt force LF via `.gitattributes`. Recloner sans réécrire les fins de ligne. |
| Directus répond `503` juste après le démarrage | Il n'a pas fini de démarrer | Le script attend que le service soit `healthy`. En manuel : `docker compose up -d --wait` |
