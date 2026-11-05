-- Fingerprint of the exported data, compared before/after a migration re-run
SELECT md5(string_agg(t::text, '|' ORDER BY id_legacy))
       || ' ' || (SELECT string_agg(entite || '=' || nb, ',' ORDER BY entite) FROM v_export_entites)
       || ' n=' || count(*)
FROM v_export_interventions t;
