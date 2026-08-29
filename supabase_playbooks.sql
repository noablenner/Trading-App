-- ============================================================================
-- Edgio / Trading-App — Migration Supabase : playbooks de séance
--
-- Un playbook est une fiche de setup (contexte, entrée, sortie, invalidation,
-- erreurs fréquentes). Les fiches vivent dans accounts.plan -> 'playbooks'
-- (aucune colonne à créer) ; ce script n'ajoute que le lien séance ↔ fiche,
-- qui permet à chaque playbook de porter ses propres statistiques.
--
-- • sessions.playbooks      : ["pb…","pb…"] — les setups joués ce jour-là
-- • accounts.show_playbooks : affiche (ou non) le module dans une séance
--
-- 100 % IDEMPOTENT et SANS RISQUE. À coller dans Supabase → SQL Editor → Run.
-- ============================================================================

alter table public.sessions
  add column if not exists playbooks jsonb not null default '[]'::jsonb;

alter table public.accounts
  add column if not exists show_playbooks boolean default false;

-- (Optionnel) Vérifier :
--   select date, playbooks from public.sessions
--   where jsonb_array_length(playbooks) > 0;
