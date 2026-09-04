-- ============================================================================
-- Edgio / Trading-App — Migration Supabase : RÉPONSES AUX MESSAGES (avis, notes)
--
-- Complète supabase_inbox.sql : un message de la boîte aux lettres peut
-- désormais attendre une réponse de l'utilisateur — une note sur 5 étoiles,
-- des remarques en texte libre, ou les deux.
--
-- PRÉREQUIS : supabase_inbox.sql doit avoir été passé avant.
--
-- 100% IDEMPOTENT : relançable autant de fois que tu veux.
-- À coller dans : Supabase → SQL Editor → New query → Run
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Le message peut demander une réponse
--
--    response_type :
--      none        → simple annonce (comportement d'origine)
--      rating      → note sur 5 étoiles seulement
--      text        → remarques en texte libre seulement
--      rating_text → note + remarques (le plus utile pour un avis produit)
-- ----------------------------------------------------------------------------
alter table public.app_messages
  add column if not exists response_type text not null default 'none';

alter table public.app_messages
  add column if not exists response_prompt text;

-- Réponse anonyme autorisée : l'identité n'est alors jamais renvoyée à
-- l'administrateur (voir admin_list_responses plus bas). Les gens sont plus
-- francs quand ils savent que la critique ne leur est pas attribuée.
alter table public.app_messages
  add column if not exists allow_anonymous boolean not null default false;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'app_messages_response_type_check'
      and conrelid = 'public.app_messages'::regclass
  ) then
    alter table public.app_messages
      add constraint app_messages_response_type_check
      check (response_type in ('none','rating','text','rating_text'));
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 2) `message_responses` : une réponse par utilisateur et par message
-- ----------------------------------------------------------------------------
create table if not exists public.message_responses (
  id         uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.app_messages(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  rating     smallint check (rating between 1 and 5),
  comment    text,
  anonymous  boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (message_id, user_id)
);

create index if not exists message_responses_message_idx
  on public.message_responses (message_id, created_at desc);

alter table public.message_responses enable row level security;

-- Chacun gère sa propre réponse (l'écrire, la relire, la corriger).
drop policy if exists "message_responses: all own" on public.message_responses;
create policy "message_responses: all own" on public.message_responses
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Les administrateurs lisent tout (et peuvent supprimer un abus).
drop policy if exists "message_responses: admin select" on public.message_responses;
create policy "message_responses: admin select" on public.message_responses
  for select using (public.is_app_admin());

drop policy if exists "message_responses: admin delete" on public.message_responses;
create policy "message_responses: admin delete" on public.message_responses
  for delete using (public.is_app_admin());

create or replace function public.touch_message_responses()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;

drop trigger if exists message_responses_touch on public.message_responses;
create trigger message_responses_touch before update on public.message_responses
  for each row execute function public.touch_message_responses();

-- ----------------------------------------------------------------------------
-- 3) Lecture administrateur : les réponses AVEC leur contexte
--
--    Un « c'est confus » d'un compte qui a 200 séances et le même mot d'un
--    compte inscrit hier ne veulent pas dire la même chose : on renvoie donc
--    l'ancienneté, le statut d'abonnement et le nombre de séances.
--
--    Si la réponse est anonyme, l'identité est effacée (e-mail, nom, dates) :
--    l'anonymat promis à l'utilisateur est tenu côté serveur, pas côté écran.
--
--    p_message_id à NULL = toutes les réponses de tous les messages
--    (c'est la requête d'export).
-- ----------------------------------------------------------------------------
create or replace function public.admin_list_responses(p_message_id uuid default null)
returns table (
  response_id         uuid,
  message_id          uuid,
  message_title       text,
  created_at          timestamptz,
  rating              smallint,
  comment             text,
  anonymous           boolean,
  user_email          text,
  user_name           text,
  subscription_status text,
  member_since        timestamptz,
  sessions_count      bigint
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
    select
      r.id, r.message_id, m.title, r.created_at, r.rating, r.comment, r.anonymous,
      case when r.anonymous then null else u.email::text end,
      case when r.anonymous then null
           else nullif(trim(coalesce(p.first_name,'')||' '||coalesce(p.last_name,'')),'') end,
      case when r.anonymous then null else p.subscription_status end,
      case when r.anonymous then null else u.created_at end,
      case when r.anonymous then null
           else (select count(*) from public.sessions s where s.user_id = r.user_id) end
    from public.message_responses r
    join public.app_messages m on m.id = r.message_id
    left join auth.users u      on u.id = r.user_id
    left join public.profiles p on p.id = r.user_id
    where p_message_id is null or r.message_id = p_message_id
    order by r.created_at desc;
end;
$$;

revoke all on function public.admin_list_responses(uuid) from public;
grant execute on function public.admin_list_responses(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 4) Compteurs par message (pastille « 12 réponses · 4,2 ★ » dans l'app)
-- ----------------------------------------------------------------------------
create or replace function public.admin_response_stats()
returns table (
  message_id  uuid,
  total       bigint,
  avg_rating  numeric,
  last_at     timestamptz
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
    select r.message_id, count(*)::bigint, round(avg(r.rating)::numeric, 2), max(r.created_at)
    from public.message_responses r
    group by r.message_id;
end;
$$;

revoke all on function public.admin_response_stats() from public;
grant execute on function public.admin_response_stats() to authenticated;

-- ----------------------------------------------------------------------------
-- 5) Vue d'export, pour analyser hors de l'app
--
--    Réservée aux administrateurs (security_invoker : la RLS de
--    message_responses s'applique, donc un utilisateur normal n'y verrait que
--    ses propres réponses). Dans le SQL Editor / Table Editor de Supabase, tu
--    es en service_role : tu vois tout, et tu peux exporter en CSV.
--
--      select * from public.feedback_export order by created_at desc;
-- ----------------------------------------------------------------------------
create or replace view public.feedback_export
with (security_invoker = true) as
  select
    r.created_at,
    m.title  as message,
    r.rating,
    r.comment,
    r.anonymous,
    case when r.anonymous then null else u.email::text end          as email,
    case when r.anonymous then null else p.subscription_status end  as statut,
    case when r.anonymous then null else u.created_at end           as inscrit_le
  from public.message_responses r
  join public.app_messages m on m.id = r.message_id
  left join auth.users u      on u.id = r.user_id
  left join public.profiles p on p.id = r.user_id;
