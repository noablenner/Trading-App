-- ============================================================================
-- Edgio / Trading-App — Migration Supabase : BOÎTE AUX LETTRES (messages app)
--
-- Permet à l'équipe d'écrire des messages/notifications visibles dans l'app,
-- adressés à tous les utilisateurs, à un segment (essai, abonnés, gratuits…)
-- ou à une liste précise de comptes.
--
-- 100% IDEMPOTENT : chaque objet est créé/modifié seulement s'il n'existe pas
-- déjà ou via CREATE OR REPLACE. Tu peux relancer ce script autant de fois que
-- tu veux.
--
-- À coller dans : Supabase → SQL Editor → New query → Run
--
-- APRÈS LE RUN : déclare-toi administrateur (sans ça, personne ne peut écrire) :
--   insert into public.app_admins (user_id)
--   select id from auth.users where email = 'ton@email.com'
--   on conflict do nothing;
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) `app_admins` : qui a le droit de rédiger/publier des messages
-- ----------------------------------------------------------------------------
create table if not exists public.app_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.app_admins enable row level security;

-- Personne ne peut s'ajouter soi-même : aucune policy d'insert/update/delete.
-- L'ajout se fait à la main dans le SQL Editor (clé service_role).
-- Chacun peut seulement vérifier s'il est admin (pour afficher l'atelier).
drop policy if exists "app_admins: select own" on public.app_admins;
create policy "app_admins: select own" on public.app_admins
  for select using (auth.uid() = user_id);

-- Fonction utilitaire : security definer pour éviter toute récursion RLS
-- quand elle est appelée depuis les policies des autres tables.
create or replace function public.is_app_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.app_admins a where a.user_id = auth.uid());
$$;

revoke all on function public.is_app_admin() from public;
grant execute on function public.is_app_admin() to authenticated;

-- ----------------------------------------------------------------------------
-- 2) `app_messages` : les messages eux-mêmes
--
--    audience :
--      all        → tout le monde
--      trialing   → comptes encore en essai gratuit
--      active     → abonnés payants
--      past_due   → paiement en échec
--      canceled   → abonnement annulé
--      premium    → essai en cours OU abonnement actif
--      free       → essai terminé et pas d'abonnement actif
--      list       → uniquement les comptes listés dans audience_user_ids
--
--    published_at à NULL = brouillon (invisible pour les utilisateurs).
-- ----------------------------------------------------------------------------
create table if not exists public.app_messages (
  id                uuid primary key default gen_random_uuid(),
  title             text not null,
  body              text not null default '',
  category          text not null default 'info'
                    check (category in ('info','update','promo','alert')),
  audience          text not null default 'all'
                    check (audience in ('all','trialing','active','past_due','canceled','premium','free','list')),
  audience_user_ids uuid[] not null default '{}',
  cta_label         text,
  cta_url           text,
  pinned            boolean not null default false,
  published_at      timestamptz,
  expires_at        timestamptz,
  created_by        uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists app_messages_published_idx
  on public.app_messages (published_at desc);

alter table public.app_messages enable row level security;

-- Est-ce que ce message concerne cet utilisateur ? security definer : la
-- fonction lit `profiles` sans être bloquée par la RLS de `profiles`, et sans
-- exposer autre chose que le booléen.
create or replace function public.message_matches_user(
  p_audience text,
  p_ids      uuid[],
  p_uid      uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_status text;
  v_trial  timestamptz;
begin
  if p_uid is null then return false; end if;
  if p_audience = 'all' then return true; end if;
  if p_audience = 'list' then return p_uid = any(coalesce(p_ids,'{}'::uuid[])); end if;

  select subscription_status, trial_ends_at into v_status, v_trial
  from public.profiles where id = p_uid;
  if not found then return false; end if;

  if p_audience = 'premium' then
    return v_status = 'active' or (v_trial is not null and v_trial > now());
  end if;
  if p_audience = 'free' then
    return v_status <> 'active' and (v_trial is null or v_trial <= now());
  end if;
  return v_status = p_audience;
end;
$$;

revoke all on function public.message_matches_user(text, uuid[], uuid) from public;
grant execute on function public.message_matches_user(text, uuid[], uuid) to authenticated;

-- Lecture : un utilisateur voit les messages publiés, non expirés, qui le
-- concernent. Les brouillons restent invisibles.
drop policy if exists "app_messages: select visible" on public.app_messages;
create policy "app_messages: select visible" on public.app_messages
  for select using (
    published_at is not null
    and published_at <= now()
    and (expires_at is null or expires_at > now())
    and public.message_matches_user(audience, audience_user_ids, auth.uid())
  );

-- Les administrateurs voient tout (brouillons compris) et écrivent.
drop policy if exists "app_messages: admin select" on public.app_messages;
create policy "app_messages: admin select" on public.app_messages
  for select using (public.is_app_admin());

drop policy if exists "app_messages: admin insert" on public.app_messages;
create policy "app_messages: admin insert" on public.app_messages
  for insert with check (public.is_app_admin());

drop policy if exists "app_messages: admin update" on public.app_messages;
create policy "app_messages: admin update" on public.app_messages
  for update using (public.is_app_admin()) with check (public.is_app_admin());

drop policy if exists "app_messages: admin delete" on public.app_messages;
create policy "app_messages: admin delete" on public.app_messages
  for delete using (public.is_app_admin());

create or replace function public.touch_app_messages()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;

drop trigger if exists app_messages_touch on public.app_messages;
create trigger app_messages_touch before update on public.app_messages
  for each row execute function public.touch_app_messages();

-- ----------------------------------------------------------------------------
-- 3) `user_message_state` : lu / archivé, par utilisateur et par message
-- ----------------------------------------------------------------------------
create table if not exists public.user_message_state (
  user_id     uuid not null references auth.users(id) on delete cascade,
  message_id  uuid not null references public.app_messages(id) on delete cascade,
  read_at     timestamptz,
  archived_at timestamptz,
  primary key (user_id, message_id)
);

alter table public.user_message_state enable row level security;

drop policy if exists "user_message_state: all own" on public.user_message_state;
create policy "user_message_state: all own" on public.user_message_state
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ----------------------------------------------------------------------------
-- 4) Annuaire des comptes, réservé aux administrateurs
--    (l'e-mail vit dans auth.users, inaccessible au client : on l'expose ici,
--     uniquement pour un admin, afin de pouvoir cibler des comptes précis.)
-- ----------------------------------------------------------------------------
create or replace function public.admin_list_users()
returns table (
  id                  uuid,
  email               text,
  first_name          text,
  last_name           text,
  subscription_status text,
  trial_ends_at       timestamptz,
  created_at          timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin() then
    raise exception 'not authorized';
  end if;
  return query
    select u.id, u.email::text, p.first_name, p.last_name,
           p.subscription_status, p.trial_ends_at, u.created_at
    from auth.users u
    left join public.profiles p on p.id = u.id
    order by u.created_at desc;
end;
$$;

revoke all on function public.admin_list_users() from public;
grant execute on function public.admin_list_users() to authenticated;
