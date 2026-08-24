-- ============================================================================
-- Edgio / Trading-App — Migration Supabase : PROFILS, ESSAI 14 JOURS & PAYWALL
--
-- Ce script crée :
--   1. La table `profiles` (prénom, nom, essai, statut d'abonnement, IDs Stripe).
--   2. Un trigger qui crée automatiquement une ligne `profiles` à chaque
--      inscription (avec `trial_ends_at = now() + 14 jours`).
--   3. Un remplissage (« backfill ») des utilisateurs déjà existants.
--   4. La fonction `public.has_access()` qui dit si un compte a le droit d'accéder
--      aux données (abonnement actif OU essai en cours).
--   5. Les policies RLS qui APPLIQUENT ce droit d'accès CÔTÉ SERVEUR sur les
--      tables de données (accounts, sessions, trades, user_settings).
--
-- 100 % IDEMPOTENT : tu peux relancer ce script autant de fois que tu veux.
--
-- À coller dans : Supabase → SQL Editor → New query → Run
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1) TABLE profiles
-- ----------------------------------------------------------------------------
create table if not exists public.profiles (
  id                     uuid        primary key references auth.users(id) on delete cascade,
  first_name             text,
  last_name              text,
  trial_ends_at          timestamptz not null default (now() + interval '14 days'),
  subscription_status    text        not null default 'trialing',
  stripe_customer_id     text,
  stripe_subscription_id text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

-- Contrainte de valeurs pour subscription_status (ajoutée seulement si absente).
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_subscription_status_check'
  ) then
    alter table public.profiles
      add constraint profiles_subscription_status_check
      check (subscription_status in ('trialing','active','past_due','canceled'));
  end if;
end $$;

-- Index utile pour retrouver un profil depuis un événement Stripe.
create index if not exists profiles_stripe_customer_id_idx
  on public.profiles (stripe_customer_id);

-- `updated_at` tenu à jour automatiquement.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();


-- ----------------------------------------------------------------------------
-- 2) CRÉATION AUTOMATIQUE DU PROFIL À L'INSCRIPTION
--    Le prénom / nom sont passés par l'app dans les métadonnées d'inscription
--    (supabase auth signUp -> options.data). Le trigger les récupère ici.
-- ----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, first_name, last_name, trial_ends_at, subscription_status)
  values (
    new.id,
    nullif(new.raw_user_meta_data ->> 'first_name', ''),
    nullif(new.raw_user_meta_data ->> 'last_name', ''),
    now() + interval '14 days',
    'trialing'
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
-- 3) BACKFILL : créer un profil pour les utilisateurs déjà inscrits
--    (essai de 14 jours à partir de maintenant). Sans risque : ON CONFLICT.
-- ----------------------------------------------------------------------------
insert into public.profiles (id, first_name, last_name, trial_ends_at, subscription_status)
select
  u.id,
  nullif(u.raw_user_meta_data ->> 'first_name', ''),
  nullif(u.raw_user_meta_data ->> 'last_name', ''),
  now() + interval '14 days',
  'trialing'
from auth.users u
on conflict (id) do nothing;


-- ----------------------------------------------------------------------------
-- 4) FONCTION has_access : le « gate » côté serveur
--    Accès = (abonnement actif) OU (on est encore dans les 14 jours d'essai).
--    SECURITY DEFINER : peut lire `profiles` même quand la RLS bloque le user.
-- ----------------------------------------------------------------------------
create or replace function public.has_access(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = uid
      and (
        p.subscription_status = 'active'
        or now() < p.trial_ends_at
      )
  );
$$;


-- ----------------------------------------------------------------------------
-- 5) RLS
-- ----------------------------------------------------------------------------

-- 5.a) profiles : chaque utilisateur lit / modifie SON profil.
--      IMPORTANT : le profil reste TOUJOURS lisible par son propriétaire, même
--      si l'accès est bloqué — c'est ce qui permet à l'app d'afficher le paywall
--      et le compte à rebours d'essai.
alter table public.profiles enable row level security;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select using (auth.uid() = id);

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- L'utilisateur ne doit JAMAIS pouvoir modifier lui-même son statut d'abonnement
-- ni ses IDs Stripe (sinon il débloquerait l'app en trichant). Seules les Edge
-- Functions (clé service_role, qui contourne la RLS) écrivent ces colonnes.
-- On restreint donc les colonnes modifiables par l'utilisateur à prénom / nom.
revoke update on public.profiles from authenticated;
grant update (first_name, last_name) on public.profiles to authenticated;
-- (Pas d'INSERT accordé : la création passe par le trigger SECURITY DEFINER.)


-- 5.b) Le « gate » sur les tables de données.
--      On remplace TOUTES les policies existantes de chaque table par une
--      policy unique et faisant autorité :
--        propriétaire de la ligne  ET  a le droit d'accès (actif ou en essai).
--      Un utilisateur dont l'essai est fini et sans abonnement ne peut donc plus
--      ni lire ni écrire ses données tant qu'il n'a pas payé — même s'il modifie
--      le JavaScript de la page.
do $$
declare
  t    text;
  pol  record;
  tables text[] := array['accounts','sessions','trades','user_settings'];
begin
  foreach t in array tables loop
    -- La table existe-t-elle ? (sinon on passe)
    if to_regclass('public.' || t) is null then
      continue;
    end if;

    -- Active la RLS.
    execute format('alter table public.%I enable row level security;', t);

    -- Supprime toutes les policies existantes de la table.
    for pol in
      select policyname from pg_policies
      where schemaname = 'public' and tablename = t
    loop
      execute format('drop policy %I on public.%I;', pol.policyname, t);
    end loop;

    -- Policy unique : propriétaire + droit d'accès, pour toutes les opérations.
    execute format($f$
      create policy %1$s_owner_access on public.%1$I
        for all
        using (auth.uid() = user_id and public.has_access(auth.uid()))
        with check (auth.uid() = user_id and public.has_access(auth.uid()));
    $f$, t);
  end loop;
end $$;


-- ----------------------------------------------------------------------------
-- (Optionnel) Vérifications utiles après exécution :
--   select id, first_name, last_name, trial_ends_at, subscription_status
--   from public.profiles;
--
--   select public.has_access(auth.uid());   -- true si actif ou en essai
-- ----------------------------------------------------------------------------
