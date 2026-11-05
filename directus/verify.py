#!/usr/bin/env python3
"""Checks the access separation of the Directus application with real accounts.

Every check logs in as a demo user and calls the REST API like the web app does.
Side effect: one intervention of the technician goes ouverte -> en_cours -> ouverte,
which adds two lines to its status history (this is the feature being tested).

Usage:  python directus/verify.py
"""
from __future__ import annotations

import sys

from setup import BASE_URL, ENV, TECH_ACCOUNTS, Directus, DirectusError

FAILURES: list[str] = []


def check(label: str, condition: bool, detail: str = "") -> None:
    print(f"[{'PASS' if condition else 'FAIL'}] {label}{' (' + detail + ')' if detail else ''}")
    if not condition:
        FAILURES.append(label)


def http_error(fn) -> str:
    """Runs fn and returns the error text, or '' if the call succeeded."""
    try:
        fn()
        return ""
    except DirectusError as err:
        return str(err)


def count(dx: Directus, collection: str, flt: dict | None = None) -> int:
    params = {"aggregate[count]": "*"}
    if flt:
        params["filter"] = flt
    return int(dx.request("GET", f"/items/{collection}", params=params)[0]["count"])


def main() -> int:
    tech_email = TECH_ACCOUNTS[0][1]
    manager = Directus(BASE_URL).login(ENV["APP_MANAGER_EMAIL"], ENV["APP_MANAGER_PASSWORD"])
    tech = Directus(BASE_URL).login(tech_email, ENV["APP_TECH_PASSWORD"])
    me = tech.request("GET", "/users/me", params={"fields": "id"})["id"]
    mine = {"technicien_id": {"email": {"_eq": tech_email}}}

    print("--- Technicien")
    my_tech_id = manager.request("GET", "/items/technicien", params={
        "filter": {"email": {"_eq": tech_email}}, "fields": "id"})[0]["id"]
    seen = tech.request("GET", "/items/intervention", params={"fields": "id,technicien_id", "limit": -1})
    expected = count(manager, "intervention", mine)
    check("ne voit que ses interventions",
          len(seen) == expected and all(i["technicien_id"] == my_tech_id for i in seen),
          f"{len(seen)} vues, {expected} attendues")
    check("ne lit pas les coûts", "HTTP 403" in http_error(
        lambda: tech.request("GET", "/items/intervention", params={"fields": "cout_total", "limit": 1})))
    check("ne lit pas les contrats", "HTTP 403" in http_error(lambda: tech.request("GET", "/items/contrat")))

    other = manager.request("GET", "/items/intervention", params={
        "filter": {"technicien_id": {"email": {"_neq": tech_email}}}, "fields": "id", "limit": 1})[0]["id"]
    check("ne modifie pas l'intervention d'un autre technicien", "HTTP 403" in http_error(
        lambda: tech.request("PATCH", f"/items/intervention/{other}", {"statut_code": "en_cours"})))

    own_open = tech.request("GET", "/items/intervention", params={
        "filter": {"statut_code": {"_eq": "ouverte"}}, "fields": "id", "limit": 1})[0]["id"]
    check("ne modifie pas le coût de son intervention", "HTTP 403" in http_error(
        lambda: tech.request("PATCH", f"/items/intervention/{own_open}", {"cout_total": 1})))
    check("ne supprime pas une intervention", "HTTP 403" in http_error(
        lambda: tech.request("DELETE", f"/items/intervention/{own_open}")))

    # Directus never shows database messages to non-admin users (generic error),
    # so the status is re-read, and the exact message is checked as admin.
    refused = http_error(lambda: tech.request("PATCH", f"/items/intervention/{own_open}", {"statut_code": "cloturee"}))
    unchanged = manager.request("GET", f"/items/intervention/{own_open}", params={"fields": "statut_code"})["statut_code"]
    check("transition interdite refusée (ouverte -> cloturee), statut inchangé", bool(refused) and unchanged == "ouverte")
    admin = Directus(BASE_URL).login(ENV["DIRECTUS_ADMIN_EMAIL"], ENV["DIRECTUS_ADMIN_PASSWORD"])
    by_admin = http_error(lambda: admin.request("PATCH", f"/items/intervention/{own_open}", {"statut_code": "cloturee"}))
    check("la règle vient de la base : même l'admin est refusé", "Transition de statut interdite" in by_admin,
          by_admin[by_admin.find("Transition"):][:45])

    before = count(manager, "historique_statut", {"intervention_id": {"_eq": own_open}})
    ok = not http_error(lambda: tech.request("PATCH", f"/items/intervention/{own_open}", {"statut_code": "en_cours"}))
    ok = ok and not http_error(lambda: tech.request("PATCH", f"/items/intervention/{own_open}", {"statut_code": "ouverte"}))
    history = manager.request("GET", "/items/historique_statut", params={
        "filter": {"intervention_id": {"_eq": own_open}}, "fields": "statut_avant,statut_apres,utilisateur_app,role_bdd",
        "sort": "-id", "limit": 2})
    check("transitions autorisées acceptées et historisées avec l'utilisateur",
          ok and count(manager, "historique_statut", {"intervention_id": {"_eq": own_open}}) == before + 2
          and all(h["utilisateur_app"] == me for h in history),
          f"intervention {own_open} : ouverte -> en_cours -> ouverte")

    print("--- Manager")
    check("voit toutes les interventions", count(manager, "intervention") >= count(manager, "intervention", {"id_legacy": {"_nnull": True}}) > expected)
    check("accède au tableau de bord", len(manager.request("GET", "/panels", params={"fields": "id", "limit": -1})) >= 8)
    check("ne supprime pas une intervention", "HTTP 403" in http_error(
        lambda: manager.request("DELETE", f"/items/intervention/{other}")))
    check("n'accède pas à la table héritée", "HTTP 403" in http_error(
        lambda: manager.request("GET", "/items/interventions_legacy", params={"limit": 1})))
    check("n'administre pas l'application", "HTTP 403" in http_error(
        lambda: manager.request("PATCH", "/settings", {"project_name": "x"})))

    print(f"=== {'tous les contrôles passent' if not FAILURES else str(len(FAILURES)) + ' échec(s)'}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
