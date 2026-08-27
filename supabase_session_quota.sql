-- ============================================================================
-- Edgio / Trading-App — Migration Supabase : quota de trades par séance
--
-- Permet de changer le nombre de trades (module scalping) pour UNE séance
-- précise, sans toucher au quota par défaut du compte (accounts.max_trades).
-- Idempotent : peut être relancé sans risque.
--
-- À coller dans : Supabase → SQL Editor → New query → Run
-- ============================================================================

alter table public.sessions
  add column if not exists max_trades_override integer;

-- (Optionnel) Vérifier :
--   select account_id, date, max_trades_override from public.sessions
--   where max_trades_override is not null;
