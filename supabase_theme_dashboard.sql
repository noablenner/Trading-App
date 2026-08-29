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
