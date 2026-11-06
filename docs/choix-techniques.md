# Choix techniques : décisions, alternatives, preuves

Chaque décision est présentée de la même façon : **le choix**, les **alternatives écartées**, les **arguments** et la **preuve** (requête, test, mesure ou source officielle). Les références de l'audit (D1 à D17, requêtes A, P, E, S) renvoient à [`audit/audit.md`](../audit/audit.md).

## Critères de décision

Par ordre de priorité, tirés du sujet :
1. **Ne perdre aucune intervention**, et signaler les incohérences sans les corriger en silence.
2. **Rejouabilité et reproductibilité** : n'importe qui reconstruit le même résultat à partir de zéro.
3. **Règles garanties quel que soit le client** : application, pgAdmin, future API.
4. **Explicable et modifiable à l'oral** : pas de magie, tout est dans des fichiers lisibles.
5. **Gratuit.**

---

## 1. Plateforme

### PostgreSQL 17.11, en conteneur Docker
| | |
|---|---|
| Choix | `postgres:17.11-alpine3.23`, version figée, port hôte 5433 |
| Écarté | PostgreSQL 18 (sorti le 25/09/2025) ; une base hébergée (Supabase, Neon) |
| Arguments | 17 est supportée jusqu'au **8 novembre 2029** et en est à sa 11e version corrective. Le projet n'utilise aucune fonction propre à la 18. Directus « supporte les versions LTS de PostgreSQL ». Le port 5433 évite un conflit avec un PostgreSQL déjà installé. Une base hébergée rendrait la correction dépendante d'un compte externe. |
| Sources | [Politique de versions PostgreSQL](https://www.postgresql.org/support/versioning/) (5 ans de support par version majeure) ; [prérequis Directus](https://directus.com/docs/self-hosting/requirements) |

### Docker Compose, versions figées, installation en une commande
| | |
|---|---|
| Choix | 3 services (`db`, `directus`, `pgadmin`), plus un conteneur `outils` (Python 3.13.16) pour les scripts. Toutes les images ont une version exacte. `scripts/install.ps1` ou `install.sh` rejoue tout depuis zéro. |
| Écarté | Des tags flottants (`latest`, `17`) ; une installation locale de PostgreSQL ou de Python |
| Arguments | Une image `latest` peut changer entre le rendu et la correction. Le conteneur `outils` fait que le correcteur n'a besoin **que de Docker**. |
| Preuve | Installation complète rejouée depuis des volumes vides, avec les scripts PowerShell puis bash : migration, 15 tests SQL et 14 contrôles de droits, tous au vert |

---

## 2. Modèle de données

### 3NF, le client se retrouve via l'équipement
| | |
|---|---|
| Choix | Une entité par table. `intervention` référence `equipement`, qui référence `client`. |
| Écarté | Garder `client_id` dans `intervention` « pour aller plus vite » |
| Arguments | Un équipement appartient à un seul client (A14 : « numéro de série → client », 0 conflit). Un `client_id` en plus dans `intervention` serait une dépendance transitive : il pourrait contredire celui de l'équipement. |
| Preuve | A14 ; [benchmark](benchmark.md) Q2 : avec ses deux jointures, le chiffre d'affaires par client prend 77 ms à 271 000 lignes, contre 2,2 s dans la table héritée, et il est juste (21 clients au lieu de 60 groupes) |

### Clés : `bigint GENERATED ALWAYS AS IDENTITY` + `UNIQUE` sur les clés naturelles
| | |
|---|---|
| Choix | Une clé technique simple par table. `UNIQUE` sur le téléphone, la référence de contrat, le n° de série et la référence de pièce. |
| Écarté | `serial` ; des clés naturelles comme clés primaires ; des clés composées sur les tables de liaison |
| Arguments | Le wiki PostgreSQL recommande les colonnes identité : *« For new applications, identity columns should be used instead »*. La clé naturelle `UNIQUE` sert de cible à `ON CONFLICT`, ce qui rend la migration rejouable. Directus *« does not currently support composite keys »*. |
| Sources | [PostgreSQL wiki, Don't Do This](https://wiki.postgresql.org/wiki/Don't_Do_This) ; [Directus, Collections](https://directus.com/docs/guides/data-model/collections) |

### Types
| Donnée | Type | Écarté | Raison |
|---|---|---|---|
| Dates | `date` | `text` (l'existant) | 3 formats et 3 façons de dire « vide » (D3). Seul un vrai type est indexable : un index sur `to_date(...)` est refusé (*« functions in index expression must be marked IMMUTABLE »*, testé, voir [benchmark](benchmark.md#3-analyse)). |
| Montants | `numeric(10,2)` | `money`, `float` | Calcul exact au centime. Le wiki déconseille `money`, qui *« doesn't handle fractions of a cent »* et ne stocke pas la devise. Le total de 172 806,02 € est conservé au centime (test T03). |
| Horodatage | `timestamptz` | `timestamp` | Recommandation du wiki : *« use timestamptz »*. |
| Texte | `text` + `CHECK` | `varchar(n)` | Le wiki recommande *« varchar (without the length limit) or text »*. Les formats sont contrôlés par des `CHECK` explicites (téléphone `^0\d{9}$`, code postal, e-mail). |

### Statuts : table de référence et transitions en données
| | |
|---|---|
| Choix | `statut_intervention` (code, libellé, ordre, initial, final) et `transition_statut` (départ → arrivée) |
| Écarté | `ENUM` ; `CHECK (statut IN (...))` ; des transitions codées dans le trigger |
| Arguments | Doc PostgreSQL sur les `ENUM` : *« Existing values cannot be removed from an enum type, nor can the sort ordering of such values be changed, short of dropping and re-creating the enum type »*. Avec une table, ajouter un statut se fait par `INSERT`. Le trigger lit les transitions sans connaître aucun statut en dur. Directus affiche la table comme une liste déroulante. |
| Preuve | [Évolutivité, scénario A](evolutivite.md) : nouveau statut ajouté par 3 `INSERT`, règle appliquée sans modifier le trigger, contrat d'export intact |
| Source | [PostgreSQL 17, § 8.7.4](https://www.postgresql.org/docs/17/datatype-enum.html) |

### Anomalies : colonnes calculées par la base
| | |
|---|---|
| Choix | `anomalie_date_incoherente` et `anomalie_cloture_sans_date` en `GENERATED ALWAYS AS (…) STORED` |
| Écarté | Une colonne booléenne remplie par la migration ; un trigger ; une vue seule |
| Arguments | Doc PostgreSQL : *« A generated column cannot be written to directly »*. Le drapeau ne peut donc être ni oublié ni falsifié, et il est recalculé à chaque modification. Une vue seule ne suffit pas : Directus *« does not currently support […] SQL views »* et ne pourrait pas filtrer dessus. |
| Définition | Clôture antérieure à l'ouverture, ou statut clôturé sans date. Ce sont les seuls cas où **l'intervention se contredit elle-même**. Quatre autres incohérences ont été recherchées et ne sont pas présentes (A20 : 0 ligne). Les défauts de fiche client (e-mail, orthographe) sont nettoyés de façon traçable, sans marquer l'intervention. |
| Preuve | 10 anomalies (A19). Test T05 : le drapeau correspond exactement à la définition. Test T14 : une ligne incohérente ne peut pas être « corrigée » par une autre date incohérente. |
| Source | [PostgreSQL 17, colonnes générées](https://www.postgresql.org/docs/17/ddl-generated-columns.html) |

### Index sur toutes les clés étrangères
| | |
|---|---|
| Arguments | Doc PostgreSQL : *« the declaration of a foreign key constraint does not automatically create an index on the referencing columns »*. Ces colonnes portent les filtres de l'application : technicien et période, statut, équipement. |
| Preuve | [Benchmark](benchmark.md) : planning d'un technicien en 1,9 ms contre 231 ms à 271 000 lignes, par `Bitmap Index Scan` sur `(technicien_id, date_ouverture)` |
| Source | [PostgreSQL 17, contraintes](https://www.postgresql.org/docs/17/ddl-constraints.html) |

---

## 3. Migration

### Rejouable par `IF NOT EXISTS` et `ON CONFLICT DO NOTHING`, dans une seule transaction
| | |
|---|---|
| Écarté | `DROP … CASCADE` puis recréation ; des scripts numérotés (outil de migration) |
| Arguments | Supprimer puis recréer effacerait ce que les utilisateurs ont saisi dans l'application depuis la migration. Ici, relancer le script **n'écrase rien** et ne duplique rien. En une seule transaction, c'est tout ou rien. Un outil de migration (Flyway, Sqitch) se justifierait sur un projet qui dure, mais pas pour un seul script demandé par le sujet. |
| Preuve | Test T00 : l'empreinte MD5 de l'export est identique avant et après une deuxième exécution (`442ab8da0eec0b951010aa1278acafa1`) |

### Échouer bruyamment plutôt que perdre en silence
| | |
|---|---|
| Choix | Les fonctions `mp_parse_date`, `mp_parse_cout` et `mp_norm_statut` **lèvent une exception** sur un format inconnu. Des contrôles avant et après la migration comparent les volumes. |
| Écarté | `NULL` par défaut, ou une conversion « au mieux » |
| Arguments | Un format nouveau dans un futur seed doit arrêter la migration, et non produire une date vide. |
| Preuve | Test T02 : chaque valeur migrée est comparée à une **relecture indépendante** de la table héritée, faite dans le test lui-même |

### Dédoublonnage des clients par téléphone, nom canonique = variante la plus fréquente
| | |
|---|---|
| Écarté | Une correspondance approchée sur le nom (`pg_trgm`, distance de Levenshtein) |
| Arguments | Le téléphone correspond 1:1 au contrat, à l'e-mail et à l'adresse (A14 : 0 conflit). C'est une clé déterministe. La correspondance approchée dépend d'un seuil arbitraire et peut fusionner deux vrais clients. `mode()` est reproductible. |
| Preuve | 78 noms bruts → 21 clients (A11, A12, A15) ; T06 |

---

## 4. Logique côté base et sécurité

### Triggers pour le cycle de vie
| | |
|---|---|
| Écarté | Validations ou Flows Directus seuls |
| Arguments | La règle porte sur le couple (**ancien**, **nouveau**) statut. Un trigger `BEFORE UPDATE` voit `OLD` et `NEW`. En base, la règle s'applique à tous les clients, y compris l'admin Directus et pgAdmin. |
| Preuve | `verify.py` : même l'admin Directus est refusé (« Transition de statut interdite ») ; T10, T12 |

### Historique infalsifiable : `SECURITY DEFINER` avec `search_path` fixé
| | |
|---|---|
| Arguments | L'application lit `historique_statut` mais n'a aucun droit d'écriture dessus : seul le trigger y écrit. La doc PostgreSQL exige, pour une fonction `SECURITY DEFINER`, que *« search_path should be set to exclude any schemas writable by untrusted users »*, et de révoquer `EXECUTE` à `PUBLIC`. Les deux sont faits : `SET search_path = public, pg_temp` et `REVOKE ALL … FROM PUBLIC`. |
| Preuve | T09 : l'application ne peut pas écrire l'historique. T11 : chaque clôture est historisée. |
| Source | [PostgreSQL 17, CREATE FUNCTION](https://www.postgresql.org/docs/17/sql-createfunction.html) |

### Moindre privilège
| | |
|---|---|
| Choix | `mp_owner` possède les objets. `mp_application` a `SELECT`, `INSERT`, `UPDATE`, **jamais `DELETE`**. `directus_app` est membre de `mp_application` et n'a pas accès à la table héritée. |
| Arguments | « Aucune intervention ne doit être supprimée » devient une garantie technique, et pas une consigne. Directus ne peut pas modifier le schéma : sa tentative de recréer une clé étrangère a été refusée par la base (`must be owner of table intervention`). |
| Preuve | T08, T09 ; `verify.py` (suppression refusée pour le manager et le technicien) |

---

## 5. Application no-code

Comparatif détaillé et sources : [application.md](application.md#choix-de-loutil--directus-11174).

| | |
|---|---|
| Choix | Directus 11.17.4, configuré **entièrement par son API REST** (`directus/setup.py`, rejouable) |
| Écarté | NocoDB (droits par ligne absents de la version Community) ; Appsmith (rôles fins payants) ; Budibase (écrans non créables par API) ; Baserow (passe par une synchronisation au lieu de lire la base) ; Directus 12 (version gratuite limitée à 3 comptes) |
| Arguments | Filtres par ligne `$CURRENT_USER`, droits par champ et par action, et lecture directe de notre schéma avec ses clés étrangères. Une configuration par script est versionnée, relisible et reconstructible, ce que des clics dans une interface ne sont pas. |

---

## 6. Compromis assumés

| Compromis | Impact | Pourquoi l'accepter |
|---|---|---|
| Écriture environ 0,4 ms par intervention, contre 0,002 ms dans la table héritée | Mesuré : [benchmark § 4](benchmark.md#4-le-prix-de-lintégrité--lécriture) | Environ 14 interventions par mois aujourd'hui. Les contrôles coûtent quelques millisecondes par mois. |
| Un technicien voit « erreur inattendue » sur une transition interdite | Directus masque les erreurs de base aux non-admins | La règle est appliquée et testée. La note du champ rappelle les transitions autorisées. |
| Métadonnées des relations écrites en SQL dans `directus_relations` (`directus/relations.sql`) | Seule une table interne de Directus est touchée | Sinon, l'API Directus essaie de recréer nos clés étrangères, ce que la base refuse à juste titre. |
| Tables `directus_*` dans le schéma `public` | Elles ajoutent leurs propres clés étrangères au comptage de C10 | Nos 13 clés étrangères et 12 `CHECK` suffisent déjà au contrôle (T07). Les tables métier ne référencent jamais celles de Directus. |

## 7. Pour aller en production

- **Sauvegardes** : `pg_dump` quotidien et archivage WAL pour une restauration à une date donnée, avec une restauration testée.
- **Intégration continue** : `scripts/install.sh` rejoué à chaque modification (migration, tests SQL, contrôles de droits).
- **Sécurité** : Directus derrière un reverse proxy HTTPS, secrets dans un coffre plutôt que dans un `.env`, Row Level Security PostgreSQL en défense en profondeur pour les accès qui ne passent pas par Directus.
- **Supervision** : `pg_stat_statements` pour repérer les requêtes lentes quand le volume augmente.
