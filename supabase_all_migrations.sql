-- ============================================================================
-- Edgio / Trading-App — Migration Supabase : Paiement (essai 14 j + abonnement)
--
-- 100% IDEMPOTENT ET SANS RISQUE : chaque objet est créé/modifié seulement s'il
-- n'existe pas déjà ou via CREATE OR REPLACE. Tu peux relancer ce script autant
-- de fois que tu veux.
--
-- À coller dans : Supabase → SQL Editor → New query → Run
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Table `profiles` : identité + statut d'abonnement
-- ----------------------------------------------------------------------------
create table if not exists public.profiles (
  id                      uuid primary key references auth.users(id) on delete cascade,
  first_name              text,
  last_name               text,
  trial_ends_at           timestamptz not null default (now() + interval '14 days'),
  subscription_status     text not null default 'trialing'
                          check (subscription_status in ('trialing','active','past_due','canceled')),
  stripe_customer_id      text,
  stripe_subscription_id  text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Chaque utilisateur voit sa propre ligne.
drop policy if exists "profiles: select own" on public.profiles;
create policy "profiles: select own" on public.profiles
  for select using (auth.uid() = id);

-- Chaque utilisateur peut modifier sa ligne (prénom/nom) — le statut d'abonnement
-- et les IDs Stripe sont protégés par le trigger ci-dessous, pas par cette policy :
-- même avec cette policy ouverte, un utilisateur ne peut PAS changer son propre statut.
drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- Garde-fou : un utilisateur connecté (rôle "authenticated") ne peut jamais modifier
-- lui-même subscription_status / trial_ends_at / stripe_customer_id / stripe_subscription_id.
-- Seul le webhook Stripe (clé service_role, qui bypass RLS ET ce trigger n'est pas
-- déclenché pour lui puisqu'il vérifie explicitement le rôle "authenticated") peut le faire.
create or replace function public.guard_profiles_billing_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() = 'authenticated' then
    new.subscription_status    := old.subscription_status;
    new.trial_ends_at          := old.trial_ends_at;
    new.stripe_customer_id     := old.stripe_customer_id;
    new.stripe_subscription_id := old.stripe_subscription_id;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_guard_profiles_billing on public.profiles;
create trigger trg_guard_profiles_billing
  before update on public.profiles
  for each row execute function public.guard_profiles_billing_fields();

-- ----------------------------------------------------------------------------
-- 2) Création automatique du profil à l'inscription
--    Lit prénom/nom depuis les métadonnées passées à supabase.auth.signUp()
--    (options.data.first_name / options.data.last_name).
-- ----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, first_name, last_name)
  values (
    new.id,
    new.raw_user_meta_data ->> 'first_name',
    new.raw_user_meta_data ->> 'last_name'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------------------
-- 3) Fonction d'accès : essai en cours OU abonnement actif
--    Utilisée côté front pour afficher/masquer les pubs et verrouiller la
--    section Analyse. Modèle « freemium », pas un blocage total de l'app :
--    un compte gratuit (essai terminé, pas abonné) garde son journal, son
--    calendrier, son plan de trading… seule l'Analyse est verrouillée, et
--    les publicités reviennent. Donc PAS de policy RESTRICTIVE sur
--    accounts/sessions/trades/user_settings : ces tables restent gouvernées
--    uniquement par les policies d'appartenance déjà en place (auth.uid() =
--    user_id), pour que les comptes gratuits continuent à fonctionner.
-- ----------------------------------------------------------------------------
create or replace function public.has_active_access(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = uid
      and (subscription_status = 'active' or now() < trial_ends_at)
  );
$$;

-- Nettoyage : si une version précédente de ce script avait posé un blocage
-- total (policy RESTRICTIVE "gate: active access"), on le retire.
do $$
declare
  t text;
begin
  foreach t in array array['accounts','sessions','trades','user_settings'] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop policy if exists "gate: active access" on public.%I;', t);
    end if;
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 4) Backfill : crée un profil (essai 14 j à partir de maintenant) pour les
--    comptes déjà existants, créés avant cette migration (le trigger ci-dessus
--    ne joue que pour les nouvelles inscriptions).
-- ----------------------------------------------------------------------------
insert into public.profiles (id, first_name, last_name)
select u.id, null, null
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id);

-- (Optionnel) Vérifier ton propre statut :
--   select id, first_name, last_name, subscription_status, trial_ends_at
--   from public.profiles where id = auth.uid();
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
-- ============================================================================
-- Edgio / Trading-App — Migration Supabase : thème d'interface + tableau de bord
--
-- • user_settings.theme      : "dark" (défaut historique) | "light" | "system"
-- • user_settings.dashboard  : agencement du tableau de bord ORDINATEUR
--                              { v:1, widgets:[{id,w,h}], note:"", chartSymbol:"" }
--
-- 100 % IDEMPOTENT et SANS RISQUE : chaque objet n'est créé que s'il manque.
-- Tu peux relancer ce script autant de fois que tu veux.
--
-- À coller dans : Supabase → SQL Editor → New query → Run
-- ============================================================================

alter table public.user_settings
  add column if not exists theme     text  default 'dark',
  add column if not exists dashboard jsonb not null default '{}'::jsonb;

-- Garde-fou : seules les trois valeurs attendues sont acceptées.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'user_settings_theme_check'
  ) then
    alter table public.user_settings
      add constraint user_settings_theme_check
      check (theme is null or theme in ('dark','light','system'));
  end if;
end $$;

-- (Optionnel) Vérifier :
--   select user_id, theme, jsonb_array_length(dashboard -> 'widgets') as widgets
--   from public.user_settings;
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
