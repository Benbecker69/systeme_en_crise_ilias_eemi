# Journal de bord

TP « Reprise d'un système en crise », MaintenancePro, seed 4. Travail individuel, du 5 au 6 novembre 2026.

## 1. Chronologie

| Étape | Ce qui a été fait | Résultat |
|---|---|---|
| **Cadrage** | Lecture du sujet et du barème. Premier examen du seed : formats de date, de montant et de statut, séparateur des pièces. Plan écrit avant tout code : stack, ordre des parties, une branche Git par partie, critères de choix de l'outil no-code. | Plan validé, décisions de stack prises (§ 2) |
| **Infrastructure** | Docker Compose avec PostgreSQL 17.11, Directus 11.17.4 et pgAdmin 9.18.0, toutes les versions figées. Le seed est exécuté **tel quel** au premier démarrage d'une base vide. Scripts `reset`, `run-sql` et `test`. | Base reproductible en une commande |
| **Partie 1 : audit** | 31 requêtes numérotées (`audit/queries.sql` : A00 à A20, P01 à P04, E01-E02, S01 à S04), exécutées sur la vraie base, avec la sortie brute conservée (`audit/resultats.txt`). Deux requêtes réécrites parce qu'elles ne prouvaient pas assez bien leur défaut (A06 sur le tri des dates, P04 sur la recherche par nom). | 17 défauts classés par gravité, chacun prouvé |
| **Partie 2 : schéma et migration** | Schéma 3NF de 11 tables. `migration.sql` rejouable en une transaction. Triggers de cycle de vie et d'historique, vues du contrat, rôles en moindre privilège. Tests SQL avec une relecture indépendante des données héritées. | 15 tests au vert, export identique après une deuxième exécution |
| **Partie 3** | Annoncée dans le sujet, mais l'enseignant a indiqué qu'il n'y en aurait pas. Pour traiter quand même le risque D14 (structure figée), trois évolutions plausibles ont été jouées sur la vraie base ([évolutivité](docs/evolutivite.md)). | 3 scénarios testés, contrat d'interface intact |
| **Partie 4 : application** | Directus configuré entièrement par son API REST (`directus/setup.py`) : collections, champs, policies, rôles, comptes, signets, tableau de bord. Contrôle automatique des droits avec les vrais comptes (`directus/verify.py`). 3 captures. | 14 contrôles de droits au vert |
| **Finalisation** | Benchmark de la table héritée contre le schéma normalisé, de 271 à 271 000 interventions. Installation complète en une commande, sans Python local. Documentation de correction. Réinstallation de bout en bout depuis des volumes vides, sous PowerShell et sous bash. | Tout se reconstruit avec `scripts/install.ps1` ou `install.sh` |

L'historique Git suit ces étapes : une branche par partie (`chore/infra`, `feat/audit`, `feat/migration`, `feat/nocode-app`, `docs/final-delivery`), fusionnée dans `main` en `--no-ff`.

## 2. Choix techniques

Le détail, avec les alternatives, les arguments et les sources, est dans [docs/choix-techniques.md](docs/choix-techniques.md). En résumé :

| Sujet | Choix | Raison principale |
|---|---|---|
| Base | PostgreSQL 17.11 en conteneur | Supportée jusqu'en 2029, reproductible, aucune dépendance à un compte externe |
| Modèle | 3NF, clés `bigint` identité + `UNIQUE` sur les clés naturelles | Supprime la redondance (D10). Les clés naturelles rendent la migration rejouable (`ON CONFLICT`). |
| Statuts | Table de référence et table des transitions | Ajouter un statut se fait par `INSERT`, sans toucher au code (prouvé, scénario A) |
| Anomalies | Colonnes `GENERATED … STORED` | Ni oubliables ni falsifiables. Filtrables dans Directus, qui ne gère pas les vues. |
| Règles métier | Triggers `BEFORE` / `AFTER`, historique en `SECURITY DEFINER` | La règle dépend de l'ancien et du nouveau statut. Elle s'applique à tous les clients, y compris l'admin. |
| Sécurité | Rôles séparés, jamais de `DELETE` pour l'application | « Aucune intervention supprimée » devient une garantie technique |
| No-code | Directus 11.17.4, configuré par script | Droits par ligne et par champ, lecture directe du schéma, gratuit sans limite de comptes |

## 3. Difficultés rencontrées et solutions

| Difficulté | Symptôme | Cause | Solution |
|---|---|---|---|
| Fins de ligne | Au commit, Git annonçait `LF will be replaced by CRLF` : un script shell en CRLF échoue dans un conteneur Linux | `core.autocrlf=true` sous Windows | `.gitattributes` force LF pour `sh`, `sql`, `py`, `yml` et `md` |
| Dates `DD-MM-YY` | Risque de mauvais siècle | `to_date('YY')` choisit l'année la plus proche de 2020 | Vérifié : aucune date dans le futur, aucune ouverture illisible (A20 : 0 ligne) |
| Faux positif du test d'idempotence | Le test passait alors que l'empreinte était vide avant et après | Guillemets mal transmis entre PowerShell et le conteneur | Requête d'empreinte dans un fichier (`sql/tests/snapshot.sql`), et échec si l'empreinte est vide |
| Test de l'utilisateur historisé | `session_user` restait `postgres` | `SET ROLE` ne change pas `session_user` | `SET SESSION AUTHORIZATION directus_app` dans le test |
| Droits sur les séquences | `GRANT … ON ALL SEQUENCES` donnait aussi des droits sur les séquences de Directus | Les tables de Directus partagent le schéma `public` | Boucle limitée aux séquences appartenant à `mp_owner` |
| Relations dans Directus | `must be owner of table intervention` | L'API Directus recrée la clé étrangère à chaque déclaration de relation | Métadonnées écrites directement dans `directus_relations` (`directus/relations.sql`). La base protège son schéma, comme prévu. |
| Messages d'erreur côté technicien | « Erreur inattendue » sur une transition interdite | Directus masque les erreurs de base aux non-admins | Limite acceptée et documentée. `verify.py` relit le statut et vérifie le message exact côté admin. Une note sur le champ rappelle les transitions. |
| Colonnes vides pour le technicien | Équipement et client affichés vides | Directus exige la lecture des deux côtés d'une relation | Lecture des champs inverses ajoutée aux droits du technicien, toujours filtrée sur ses interventions |
| Tableau de bord en erreur | Erreur de validation GraphQL | Un filtre sur une relation doit être imbriqué en GraphQL | `statut_code: {code: {_neq: "cloturee"}}` |
| Déconnexion des utilisateurs | Relancer `setup.py` déconnectait tout le monde | Le script réécrivait les mots de passe | Mot de passe posé uniquement à la création du compte |
| Licence de l'outil | La v12 gratuite est limitée à 3 comptes | Changement de licence de Directus | Version 11.17.4 (BSL 1.1, gratuite sous 5 M$ de CA, sans limite de comptes) |
| Mesure faussée (risque anticipé) | Un `SELECT count(*) FROM (requête)` peut éviter de calculer les colonnes qu'il ne lit pas | Optimisation des sous-requêtes par PostgreSQL | Le benchmark lit chaque ligne et chaque colonne |
| Coût d'écriture | 10 000 insertions : 4,3 s contre 19 ms dans la table héritée | Clés étrangères, triggers, historique | Décomposé poste par poste avec `EXPLAIN ANALYZE`, puis comparé au rythme réel (≈ 14 interventions par mois) : coût négligeable ([benchmark § 4](docs/benchmark.md#4-le-prix-de-lintégrité--lécriture)) |
| Encodage PowerShell 5.1 (risque anticipé) | Des accents dans un script `.ps1` peuvent être mal lus | PowerShell 5.1 lit l'UTF-8 sans BOM comme de l'ANSI | Scripts `.ps1` en ASCII, contrôlé octet par octet |

## 4. Ce que j'en retiens

- **Prouver avant d'affirmer.** Chaque chiffre du rendu vient d'une requête exécutée, dont la sortie est conservée. Sans ça, deux requêtes d'audit seraient restées fausses, et le coût d'écriture serait passé inaperçu.
- **Les règles métier vont dans la base.** Directus est une interface parmi d'autres : la base ne doit pas compter sur lui pour se protéger. Le refus de `must be owner` l'a montré concrètement.
- **Les performances n'étaient pas le vrai problème.** À 271 lignes, tout est instantané. Le vrai problème était l'exactitude : 60 « clients » au lieu de 21 dans le chiffre d'affaires par client.
- **À améliorer** : mettre les tables de Directus dans un schéma à part, faire rejouer l'installation par l'intégration continue, et ajouter la Row Level Security pour les accès directs à la base.
