-- ============================================================================
-- Edgio / Trading-App — Migration Supabase : auto-évaluation de séance
--
-- Trois curseurs 1–5 notés par le trader en fin de séance — exécution,
-- respect du plan, maîtrise émotionnelle — indépendamment du résultat.
-- Ils alimentent l'Analyse comportementale et le tableau de bord.
--
-- • sessions.self_rating   : { "exec":4, "plan":5, "emo":3 }
-- • accounts.show_rating   : affiche (ou non) le module dans une séance
--
-- 100 % IDEMPOTENT et SANS RISQUE. À coller dans Supabase → SQL Editor → Run.
-- ============================================================================

alter table public.sessions
  add column if not exists self_rating jsonb not null default '{}'::jsonb;

alter table public.accounts
  add column if not exists show_rating boolean default false;

-- (Optionnel) Vérifier :
--   select account_id, date, self_rating from public.sessions
--   where self_rating <> '{}'::jsonb;
