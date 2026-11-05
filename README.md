# MaintenancePro — reprise d'un système en crise

Reprise de la base héritée `interventions_legacy` de MaintenancePro : audit, schéma normalisé, migration rejouable et application de pilotage no-code.

- Sujet : [sujet-tp.md](sujet-tp.md)
- Jeu de données : [seed/seed_4.sql](seed/seed_4.sql), exécuté tel quel, sans modification

## Stack

| Service | Image | URL locale |
|---|---|---|
| PostgreSQL | `postgres:17.11-alpine3.23` | `localhost:5433` |
| Directus (no-code) | `directus/directus:11.17.4` | http://localhost:8055 |
| pgAdmin | `dpage/pgadmin4:9.18.0` | http://localhost:5050 |

Toutes les versions sont figées pour que l'environnement soit reproductible.

## Démarrage

Prérequis : Docker Desktop et PowerShell.

```powershell
Copy-Item .env.example .env      # puis remplacer chaque valeur "change-me"
./scripts/reset.ps1              # base vide + exécution du seed tel quel
```

Le premier démarrage d'une base vide exécute, dans l'ordre :
1. `docker/initdb/00-roles.sh` : crée le rôle de connexion `directus_app` ;
2. `seed/seed_4.sql` : crée et remplit `interventions_legacy`.

Pour exécuter un fichier SQL du projet dans le conteneur :

```powershell
./scripts/run-sql.ps1 sql/migration.sql
```

`scripts/reset.ps1` supprime les conteneurs **et les volumes** : toutes les données sont recréées de zéro.
