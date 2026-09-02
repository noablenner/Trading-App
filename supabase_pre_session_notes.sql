-- ============================================================================
-- Edgio / Trading-App — Migration Supabase : journal de début de séance
--
-- L'inverse du « Journal de fin de séance » (sessions.notes) : un champ libre
-- pour noter son état d'esprit AVANT de trader.
--
-- • sessions.pre_notes      : texte libre écrit avant la séance
-- • accounts.show_pre_notes : affiche (ou non) le module dans une séance
--
-- 100 % IDEMPOTENT et SANS RISQUE. À coller dans Supabase → SQL Editor → Run.
-- ============================================================================

alter table public.sessions
  add column if not exists pre_notes text not null default '';

alter table public.accounts
  add column if not exists show_pre_notes boolean default false;

-- (Optionnel) Vérifier :
--   select account_id, date, pre_notes from public.sessions
--   where pre_notes <> '';
