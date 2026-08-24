-- ============================================================================
-- Edgio / Trading-App — Migration Supabase
-- Colonnes de la table `accounts` utilisées par l'app (prop firm + réglages récents)
--
-- 100 % IDEMPOTENT et SANS RISQUE : chaque colonne est ajoutée seulement si
-- elle n'existe pas déjà. Tu peux relancer ce script autant de fois que tu veux.
--
-- À coller dans : Supabase → SQL Editor → New query → Run
-- ============================================================================

-- La config Prop firm est stockée dans accounts.plan -> 'propfirm' (JSON).
-- C'est aussi la colonne qui contient ton Plan de trading (style, règles, objectifs…).
alter table public.accounts
  add column if not exists plan          jsonb   not null default '{}'::jsonb;

-- Réglages récents (modes de saisie dérivés, onboarding par style, champs détaillés).
alter table public.accounts
  add column if not exists style         text,
  add column if not exists logging_mode  text    default 'quick',
  add column if not exists onboarded      boolean default false,
  add column if not exists field_config  jsonb   not null default '{}'::jsonb;

-- (Optionnel) Vérifier que la prop firm d'un compte est bien enregistrée :
--   select id, name, plan -> 'propfirm' as propfirm
--   from public.accounts
--   where plan ? 'propfirm';
