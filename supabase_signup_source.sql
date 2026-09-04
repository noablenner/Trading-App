-- ============================================================================
-- Edgio / Trading-App — Migration Supabase : « Comment as-tu entendu parler de nous ? »
--
-- Ajoute à la table `profiles` la provenance déclarée par l'utilisateur à
-- l'inscription (Instagram, TikTok, X, Google, bouche-à-oreille, autre…).
-- L'info est liée à l'utilisateur (une ligne par profil) pour pouvoir être
-- analysée quand on veut (voir les requêtes d'exemple en bas de fichier).
--
-- 100% IDEMPOTENT : relançable autant de fois que nécessaire.
-- À coller dans : Supabase → SQL Editor → New query → Run
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Colonnes
-- ----------------------------------------------------------------------------
alter table public.profiles add column if not exists signup_source        text;
alter table public.profiles add column if not exists signup_source_detail text;
alter table public.profiles add column if not exists signup_source_at     timestamptz;

-- Valeurs autorisées (le front envoie exactement ces clés).
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_signup_source_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_signup_source_check
      check (signup_source is null or signup_source in
        ('instagram','tiktok','x','google','youtube','friend','other','not_asked'));
  end if;
end $$;

create index if not exists profiles_signup_source_idx
  on public.profiles (signup_source);

-- ----------------------------------------------------------------------------
-- 2) Comptes existants : on les laisse à NULL (aucun backfill). Ils verront donc
--    l'écran une fois, à leur prochaine connexion, comme les nouveaux inscrits.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 3) Garde-fou : la réponse ne peut être écrite qu'UNE seule fois par
--    l'utilisateur (pas de réécriture après coup côté client). On complète la
--    fonction existante qui protège déjà les champs de facturation.
-- ----------------------------------------------------------------------------
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
    -- provenance : figée dès qu'elle a été renseignée
    if old.signup_source is not null then
      new.signup_source        := old.signup_source;
      new.signup_source_detail := old.signup_source_detail;
      new.signup_source_at     := old.signup_source_at;
    elsif new.signup_source is not null then
      new.signup_source_at     := now();
    end if;
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
-- 4) Analyse : d'où viennent nos inscrits ?
-- ----------------------------------------------------------------------------
-- Répartition globale :
--   select signup_source, count(*) as inscrits,
--          round(100.0*count(*)/sum(count(*)) over (), 1) as pct
--   from public.profiles
--   where signup_source is not null
--   group by signup_source
--   order by inscrits desc;
--
-- Par mois :
--   select date_trunc('month', created_at) as mois, signup_source, count(*)
--   from public.profiles
--   where signup_source is not null
--   group by 1,2 order by 1 desc, 3 desc;
--
-- Détail des réponses « Autre » :
--   select signup_source_detail, count(*)
--   from public.profiles
--   where signup_source = 'other' and signup_source_detail is not null
--   group by 1 order by 2 desc;
