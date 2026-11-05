#!/usr/bin/env python3
"""Builds the MaintenancePro application in Directus through its REST API.

Idempotent: every object is looked up before being created, and the
permissions, presets and dashboard panels of the objects managed here are
rebuilt from the declarations below, so the result always matches this file.

Usage:  python directus/setup.py          (reads ../.env)
"""
from __future__ import annotations

import json
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_env() -> dict[str, str]:
    env = {}
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()
    return env


ENV = load_env()
BASE_URL = f"http://localhost:{ENV.get('DIRECTUS_PORT', '8055')}"


class DirectusError(RuntimeError):
    pass


class Directus:
    def __init__(self, base_url: str):
        self.base_url = base_url
        self.token: str | None = None

    def login(self, email: str, password: str) -> "Directus":
        data = self.request("POST", "/auth/login", {"email": email, "password": password})
        self.token = data["access_token"]
        return self

    def request(self, method: str, path: str, body=None, params: dict | None = None):
        url = self.base_url + path
        if params:
            url += "?" + urllib.parse.urlencode(
                {k: json.dumps(v) if isinstance(v, (dict, list)) else v for k, v in params.items()})
        req = urllib.request.Request(url, method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req) as res:
                raw = res.read()
                return json.loads(raw)["data"] if raw else None
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")
            raise DirectusError(f"{method} {path} -> HTTP {err.code}: {detail}") from None

    def find(self, path: str, flt: dict, fields: str = "*") -> list:
        return self.request("GET", path, params={"filter": flt, "fields": fields, "limit": -1})

    def exists(self, path: str) -> bool:
        try:
            self.request("GET", path)
            return True
        except DirectusError as err:
            if "HTTP 403" in str(err) or "HTTP 404" in str(err):
                return False
            raise


def fr(label: str, singular: str | None = None, plural: str | None = None) -> list[dict]:
    t = {"language": "fr-FR", "translation": label}
    if singular:
        t |= {"singular": singular, "plural": plural or label}
    return [t]


# ---------------------------------------------------------------------------
# Data model presentation
# ---------------------------------------------------------------------------
COLLECTIONS = {
    "intervention": dict(icon="build", sort=1, display_template="#{{id}} · {{equipement_id.numero_serie}} · {{statut_code.libelle}}",
                         note="Interventions de maintenance. Les règles de statut sont appliquées par la base.",
                         translations=fr("Interventions", "Intervention", "Interventions")),
    "client": dict(icon="storefront", sort=2, display_template="{{nom}}",
                   translations=fr("Clients", "Client", "Clients")),
    "equipement": dict(icon="precision_manufacturing", sort=3, display_template="{{numero_serie}} · {{type_id.libelle}}",
                       translations=fr("Équipements", "Équipement", "Équipements")),
    "technicien": dict(icon="engineering", sort=4, display_template="{{prenom}} {{nom}}",
                       translations=fr("Techniciens", "Technicien", "Techniciens")),
    "contrat": dict(icon="contract", sort=5, display_template="{{reference}} · SLA {{sla_heures}} h",
                    translations=fr("Contrats", "Contrat", "Contrats")),
    "historique_statut": dict(icon="history", sort=6, display_template="{{statut_avant}} → {{statut_apres}}",
                              note="Alimenté uniquement par trigger : lecture seule.",
                              translations=fr("Historique des statuts", "Changement de statut", "Historique des statuts")),
    "referentiels": dict(icon="folder", sort=7, collapse="closed",
                         translations=fr("Référentiels", "Référentiel", "Référentiels")),
    "statut_intervention": dict(icon="flag", sort=1, group="referentiels", display_template="{{libelle}}",
                                translations=fr("Statuts", "Statut", "Statuts")),
    "transition_statut": dict(icon="alt_route", sort=2, group="referentiels",
                              display_template="{{statut_depart}} → {{statut_arrivee}}",
                              translations=fr("Transitions autorisées", "Transition", "Transitions")),
    "type_equipement": dict(icon="category", sort=3, group="referentiels", display_template="{{libelle}}",
                            translations=fr("Types d'équipement", "Type d'équipement", "Types d'équipement")),
    "piece": dict(icon="settings", sort=4, group="referentiels", display_template="{{reference}}",
                  translations=fr("Pièces", "Pièce", "Pièces")),
    "intervention_piece": dict(icon="inventory_2", sort=5, group="referentiels", hidden=True,
                               display_template="{{piece_id.reference}} × {{quantite}}",
                               translations=fr("Lignes de pièces", "Ligne de pièce", "Lignes de pièces")),
    "interventions_legacy": dict(icon="block", sort=99, hidden=True,
                                 note="Table héritée conservée intacte, inaccessible à l'application."),
}
FOLDERS = {"referentiels"}


def m2o(template: str, label: str, width: str = "half", **extra) -> dict:
    return dict(interface="select-dropdown-m2o", options={"template": template},
                display="related-values", display_options={"template": template},
                width=width, translations=fr(label), **extra)


def plain(label: str, width: str = "half", **extra) -> dict:
    return dict(width=width, translations=fr(label), **extra)


def o2m(template: str, label: str, **extra) -> dict:
    return dict(special=["o2m"], interface="list-o2m", options={"template": template, "enableSelect": False},
                display="related-values", display_options={"template": template},
                width="full", translations=fr(label), **extra)


ANOMALY = dict(interface="boolean", display="boolean", readonly=True,
               display_options={"labelOn": "Anomalie", "labelOff": "OK", "iconOn": "warning",
                                "iconOff": "check", "colorOn": "#E35169", "colorOff": "#2ECDA7"})

FIELDS = {
    "intervention": {
        "id": plain("N°", readonly=True),
        "id_legacy": plain("N° hérité", readonly=True, note="Identifiant dans l'ancienne table"),
        "statut_code": m2o("{{libelle}}", "Statut",
                           note="Ouverte → En cours → Clôturée (retour possible En cours → Ouverte). "
                                "Une clôture est définitive et fixe la date de clôture. "
                                "Toute autre transition est refusée par la base."),
        "technicien_id": m2o("{{prenom}} {{nom}}", "Technicien"),
        "equipement_id": m2o("{{numero_serie}} · {{type_id.libelle}} · {{client_id.nom}}", "Équipement", width="full"),
        "date_ouverture": plain("Ouverture", interface="datetime", display="datetime", display_options={"format": "short"}),
        "date_cloture": plain("Clôture", interface="datetime", display="datetime", display_options={"format": "short"},
                              note="Remplie automatiquement à la clôture"),
        "cout_total": plain("Coût total (€)", interface="input", display="formatted-value",
                            display_options={"suffix": " €"}),
        "anomalie_date_incoherente": plain("Clôture avant ouverture", **ANOMALY),
        "anomalie_cloture_sans_date": plain("Clôturée sans date", **ANOMALY),
        "pieces": o2m("{{piece_id.reference}} × {{quantite}}", "Pièces utilisées"),
        "historique": o2m("{{modifie_le}} : {{statut_avant}} → {{statut_apres}}", "Historique", readonly=True),
        "modifie_par": plain("Modifié par", special=["user-updated"], interface="select-dropdown-m2o",
                             display="user", readonly=True),
        "created_at": plain("Créée le", readonly=True, display="datetime"),
        "updated_at": plain("Mise à jour", readonly=True, display="datetime"),
    },
    "client": {
        "nom": plain("Nom"), "email": plain("E-mail"), "telephone": plain("Téléphone"),
        "adresse": plain("Adresse", width="full"), "code_postal": plain("Code postal"), "ville": plain("Ville"),
        "equipements": o2m("{{numero_serie}} · {{type_id.libelle}}", "Équipements"),
        "contrats": o2m("{{reference}} · SLA {{sla_heures}} h", "Contrats"),
        "created_at": plain("Créé le", readonly=True), "updated_at": plain("Mis à jour", readonly=True),
    },
    "equipement": {
        "numero_serie": plain("N° de série"),
        "type_id": m2o("{{libelle}}", "Type"),
        "client_id": m2o("{{nom}}", "Client"),
        "interventions": o2m("#{{id}} · {{date_ouverture}} · {{statut_code}}", "Interventions", readonly=True),
    },
    "technicien": {
        "nom": plain("Nom"), "prenom": plain("Prénom"), "telephone": plain("Téléphone"),
        "email": plain("E-mail du compte", note="Relie le technicien à son compte de connexion"),
        "interventions": o2m("#{{id}} · {{date_ouverture}} · {{statut_code}}", "Interventions", readonly=True),
        "created_at": plain("Créé le", readonly=True), "updated_at": plain("Mis à jour", readonly=True),
    },
    "contrat": {
        "reference": plain("Référence"), "client_id": m2o("{{nom}}", "Client"),
        "sla_heures": plain("SLA (heures)"),
    },
    "intervention_piece": {
        "intervention_id": m2o("#{{id}}", "Intervention"),
        "piece_id": m2o("{{reference}}", "Pièce"),
        "quantite": plain("Quantité"),
    },
    "historique_statut": {
        "intervention_id": m2o("#{{id}}", "Intervention", readonly=True),
        "statut_avant": m2o("{{libelle}}", "Avant", readonly=True),
        "statut_apres": m2o("{{libelle}}", "Après", readonly=True),
        "modifie_le": plain("Date", readonly=True, display="datetime"),
        "role_bdd": plain("Connexion base", readonly=True),
        "utilisateur_app": plain("Utilisateur", readonly=True, interface="select-dropdown-m2o", display="user"),
    },
    "statut_intervention": {
        "code": plain("Code"), "libelle": plain("Libellé"), "ordre": plain("Ordre"),
        "est_initial": plain("Statut initial"), "est_final": plain("Statut final"),
    },
    "transition_statut": {
        "statut_depart": m2o("{{libelle}}", "Depuis"), "statut_arrivee": m2o("{{libelle}}", "Vers"),
    },
    "type_equipement": {"libelle": plain("Libellé")},
    "piece": {"reference": plain("Référence")},
}
ALIAS_FIELDS = {("intervention", "pieces"), ("intervention", "historique"), ("client", "equipements"),
                ("client", "contrats"), ("equipement", "interventions"), ("technicien", "interventions")}
# Relations metadata (one-to-many sides, application users) is registered by
# directus/relations.sql: the Directus API would try to recreate foreign keys.

# ---------------------------------------------------------------------------
# Access control
# ---------------------------------------------------------------------------
ME = {"email": {"_eq": "$CURRENT_USER.email"}}
MY_INTERVENTIONS = {"technicien_id": ME}

TECH_PERMISSIONS = [
    ("intervention", "read", ["id", "id_legacy", "statut_code", "technicien_id", "equipement_id", "date_ouverture",
                              "date_cloture", "anomalie_date_incoherente", "anomalie_cloture_sans_date",
                              "pieces", "historique", "modifie_par", "updated_at"], MY_INTERVENTIONS),
    # The technician may only move the status; the database checks the transition
    ("intervention", "update", ["statut_code", "modifie_par"], MY_INTERVENTIONS),
    ("equipement", "read", ["id", "numero_serie", "type_id", "client_id"], {"interventions": MY_INTERVENTIONS}),
    ("client", "read", ["id", "nom", "telephone", "adresse", "code_postal", "ville"],
     {"equipements": {"interventions": MY_INTERVENTIONS}}),
    ("technicien", "read", ["id", "nom", "prenom"], ME),
    ("intervention_piece", "read", ["id", "intervention_id", "piece_id", "quantite"], {"intervention_id": MY_INTERVENTIONS}),
    ("historique_statut", "read", ["id", "intervention_id", "statut_avant", "statut_apres", "modifie_le"],
     {"intervention_id": MY_INTERVENTIONS}),
    ("piece", "read", ["*"], {}),
    ("type_equipement", "read", ["*"], {}),
    ("statut_intervention", "read", ["*"], {}),
    ("transition_statut", "read", ["*"], {}),
]

BUSINESS = ["intervention", "client", "equipement", "technicien", "contrat", "historique_statut",
            "statut_intervention", "transition_statut", "type_equipement", "piece", "intervention_piece"]
MANAGER_PERMISSIONS = (
    [(c, "read", ["*"], {}) for c in BUSINESS]
    + [("intervention", "create", ["equipement_id", "technicien_id", "statut_code", "date_ouverture", "cout_total"], {}),
       ("intervention", "update", ["equipement_id", "technicien_id", "statut_code", "date_ouverture",
                                   "date_cloture", "cout_total", "modifie_par"], {})]
    + [(c, a, ["*"], {}) for c in ["client", "contrat", "technicien", "equipement", "type_equipement", "piece",
                                    "intervention_piece"] for a in ("create", "update")]
    + [("directus_dashboards", "read", ["*"], {}), ("directus_panels", "read", ["*"], {}),
       ("directus_users", "read", ["id", "first_name", "last_name", "email"], {})]
)
# No "delete" anywhere: no intervention may disappear (also refused by the database)

POLICIES = {
    "Technicien": dict(icon="engineering", description="Ses interventions uniquement, changement de statut seul.",
                       permissions=TECH_PERMISSIONS),
    "Manager": dict(icon="insights", description="Vue d'ensemble, affectations, référentiels et tableau de bord.",
                    permissions=MANAGER_PERMISSIONS),
}

TECH_ACCOUNTS = [("0681033603", "karim.durand@example.com"), ("0697457905", "ines.vidal@example.com")]

ANOMALIES = {"_or": [{"anomalie_date_incoherente": {"_eq": True}}, {"anomalie_cloture_sans_date": {"_eq": True}}]}
NOT_CLOSED = {"statut_code": {"_neq": "cloturee"}}

PRESETS = {
    "Technicien": [
        (None, None, None, ["id", "statut_code", "date_ouverture", "equipement_id", "equipement_id.client_id.nom",
                            "equipement_id.client_id.adresse", "date_cloture"]),
        ("Mes interventions à traiter", "pending_actions", NOT_CLOSED,
         ["id", "statut_code", "date_ouverture", "equipement_id", "equipement_id.client_id.nom",
          "equipement_id.client_id.adresse"]),
    ],
    "Manager": [
        (None, None, None, ["id", "statut_code", "date_ouverture", "date_cloture", "technicien_id",
                            "equipement_id.client_id.nom", "cout_total", "anomalie_date_incoherente",
                            "anomalie_cloture_sans_date"]),
        ("Anomalies à vérifier", "warning", ANOMALIES,
         ["id", "id_legacy", "statut_code", "date_ouverture", "date_cloture", "technicien_id",
          "equipement_id.client_id.nom", "anomalie_date_incoherente", "anomalie_cloture_sans_date"]),
        ("Interventions non clôturées", "pending_actions", NOT_CLOSED,
         ["id", "statut_code", "date_ouverture", "technicien_id", "equipement_id.client_id.nom", "cout_total"]),
        ("Interventions en cours", "autorenew", {"statut_code": {"_eq": "en_cours"}},
         ["id", "date_ouverture", "technicien_id", "equipement_id.client_id.nom"]),
    ],
}

DASHBOARD = "Pilotage MaintenancePro"
PANELS = [
    dict(name="Interventions", icon="build", type="metric", position_x=1, position_y=1, width=10, height=6,
         options={"collection": "intervention", "field": "id", "function": "count"}),
    dict(name="Non clôturées", icon="pending_actions", type="metric", position_x=11, position_y=1, width=10, height=6,
         options={"collection": "intervention", "field": "id", "function": "count", "filter": NOT_CLOSED}),
    dict(name="Anomalies à vérifier", icon="warning", color="#E35169", type="metric", position_x=21, position_y=1,
         width=10, height=6,
         options={"collection": "intervention", "field": "id", "function": "count", "filter": ANOMALIES}),
    dict(name="Coût total", icon="euro", type="metric", position_x=31, position_y=1, width=10, height=6,
         options={"collection": "intervention", "field": "cout_total", "function": "sum", "suffix": " €",
                  "maximumFractionDigits": 2, "minimumFractionDigits": 2}),
    dict(name="Interventions par statut", icon="flag", type="bar-chart", position_x=1, position_y=7, width=20, height=14,
         options={"collection": "intervention", "xAxis": "statut_code", "xAxisDisplayField": "libelle",
                  "yAxis": "id", "function": "count", "decimals": 0}),
    dict(name="Charge par technicien", icon="engineering", type="bar-chart", position_x=21, position_y=7, width=20,
         height=14, options={"collection": "intervention", "xAxis": "technicien_id", "xAxisDisplayField": "nom",
                             "yAxis": "id", "function": "count", "decimals": 0, "horizontal": True}),
    dict(name="Interventions ouvertes par mois", icon="timeline", type="time-series", position_x=1, position_y=21,
         width=24, height=14,
         options={"collection": "intervention", "function": "count", "valueField": "id", "dateField": "date_ouverture",
                  "precision": "month", "range": "auto", "decimals": 0}),
    dict(name="Dernières anomalies", icon="report", type="list", position_x=25, position_y=21, width=16, height=14,
         options={"collection": "intervention", "filter": ANOMALIES, "limit": 10, "sortField": "date_ouverture",
                  "sortDirection": "desc", "linkToItem": True,
                  "displayTemplate": "#{{id}} · {{equipement_id.client_id.nom}} · {{date_ouverture}}"}),
]


# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
def configure_settings(dx: Directus) -> None:
    dx.request("PATCH", "/settings", {"project_name": "MaintenancePro", "default_language": "fr-FR",
                                      "project_color": "#2F6FDE"})


def configure_collections(dx: Directus) -> None:
    for name, meta in COLLECTIONS.items():
        meta = {"hidden": False, **meta}
        if name in FOLDERS and not dx.exists(f"/collections/{name}"):
            dx.request("POST", "/collections", {"collection": name, "meta": meta, "schema": None})
        else:
            dx.request("PATCH", f"/collections/{name}", {"meta": meta})


def configure_fields(dx: Directus) -> None:
    for collection, fields in FIELDS.items():
        for field, meta in fields.items():
            if (collection, field) in ALIAS_FIELDS and not dx.exists(f"/fields/{collection}/{field}"):
                dx.request("POST", f"/fields/{collection}", {"field": field, "type": "alias", "meta": meta})
            else:
                dx.request("PATCH", f"/fields/{collection}/{field}", {"meta": meta})


def ensure(dx: Directus, path: str, key: str, value: str, payload: dict) -> str:
    found = dx.find(path, {key: {"_eq": value}}, "id")
    if found:
        dx.request("PATCH", f"{path}/{found[0]['id']}", payload)
        return found[0]["id"]
    return dx.request("POST", path, {key: value, **payload})["id"]


def configure_access(dx: Directus) -> dict[str, str]:
    roles = {}
    for name, spec in POLICIES.items():
        policy_id = ensure(dx, "/policies", "name", name,
                           {"icon": spec["icon"], "description": spec["description"],
                            "app_access": True, "admin_access": False, "enforce_tfa": False})
        # Rebuild the permission set so it always matches the declaration
        old = dx.find("/permissions", {"policy": {"_eq": policy_id}}, "id")
        if old:
            dx.request("DELETE", "/permissions", [p["id"] for p in old])
        dx.request("POST", "/permissions", [
            {"policy": policy_id, "collection": c, "action": a, "fields": f, "permissions": p,
             "validation": {}, "presets": ({"modifie_par": "$CURRENT_USER"} if c == "intervention" and a == "update" else {})}
            for c, a, f, p in spec["permissions"]])
        role_id = ensure(dx, "/roles", "name", name, {"icon": spec["icon"], "description": spec["description"]})
        attached = dx.request("GET", f"/roles/{role_id}", params={"fields": "policies.policy"})["policies"]
        if policy_id not in [a["policy"] for a in attached]:
            dx.request("PATCH", f"/roles/{role_id}", {"policies": {"create": [{"policy": policy_id}]}})
        roles[name] = role_id
    return roles


def configure_users(dx: Directus, roles: dict[str, str]) -> None:
    ensure(dx, "/users", "email", ENV["APP_MANAGER_EMAIL"],
           {"password": ENV["APP_MANAGER_PASSWORD"], "role": roles["Manager"], "first_name": "Manager",
            "last_name": "MaintenancePro", "language": "fr-FR", "status": "active"})
    for phone, email in TECH_ACCOUNTS:
        tech = dx.find("/items/technicien", {"telephone": {"_eq": phone}}, "id,nom,prenom")
        if not tech:
            raise DirectusError(f"Technicien {phone} introuvable : lancer la migration d'abord")
        dx.request("PATCH", f"/items/technicien/{tech[0]['id']}", {"email": email})
        ensure(dx, "/users", "email", email,
               {"password": ENV["APP_TECH_PASSWORD"], "role": roles["Technicien"], "first_name": tech[0]["prenom"],
                "last_name": tech[0]["nom"], "language": "fr-FR", "status": "active"})


def configure_presets(dx: Directus, roles: dict[str, str]) -> None:
    for role_name, presets in PRESETS.items():
        old = dx.find("/presets", {"role": {"_eq": roles[role_name]}, "collection": {"_eq": "intervention"}}, "id")
        if old:
            dx.request("DELETE", "/presets", [p["id"] for p in old])
        for bookmark, icon, flt, columns in presets:
            dx.request("POST", "/presets", {
                "bookmark": bookmark, "icon": icon or "bookmark", "role": roles[role_name],
                "collection": "intervention", "layout": "tabular", "filter": flt,
                "layout_query": {"tabular": {"fields": columns, "sort": ["-date_ouverture"], "limit": 50}}})


def configure_dashboard(dx: Directus) -> None:
    dashboard_id = ensure(dx, "/dashboards", "name", DASHBOARD,
                          {"icon": "insights", "note": "Indicateurs calculés en direct sur la base"})
    old = dx.find("/panels", {"dashboard": {"_eq": dashboard_id}}, "id")
    if old:
        dx.request("DELETE", "/panels", [p["id"] for p in old])
    dx.request("POST", "/panels", [{"dashboard": dashboard_id, "show_header": True, **p} for p in PANELS])


def main() -> int:
    dx = Directus(BASE_URL).login(ENV["DIRECTUS_ADMIN_EMAIL"], ENV["DIRECTUS_ADMIN_PASSWORD"])
    steps = [("Paramètres du projet", lambda: configure_settings(dx)),
             ("Collections", lambda: configure_collections(dx)),
             ("Champs et relations", lambda: configure_fields(dx))]
    for label, step in steps:
        step()
        print(f"[ok] {label}")
    roles = configure_access(dx)
    print("[ok] Policies, permissions et rôles")
    configure_users(dx, roles)
    print("[ok] Comptes de démonstration")
    configure_presets(dx, roles)
    print("[ok] Vues enregistrées")
    configure_dashboard(dx)
    print("[ok] Tableau de bord")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DirectusError as err:
        print(f"[erreur] {err}", file=sys.stderr)
        sys.exit(1)
