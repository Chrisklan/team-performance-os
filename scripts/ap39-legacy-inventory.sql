-- AP-39 Legacy Objekte und Audit Inhalte inventarisieren (Team Performance OS)
-- NUR LESEND. Kein INSERT, UPDATE, DELETE, kein DDL. Ergebnis: Audits/2026-09-21-ap39-legacy-audit-inventar.md
--
-- Aufruf je Block einzeln:
--   supabase db query --linked "<Block hier einfuegen>"
-- Zeilenzahlen vor und nach dem Lauf pruefen (Block 0), app.audit_log muss gleich bleiben.

-- Block 0: Grundzahlen vor und nach jedem Lauf
select (select count(*) from app.audit_log)        as audit_log,
       (select count(*) from app.persons)          as persons,
       (select count(*) from app.daily_checkins)   as daily_checkins,
       (select count(*) from app.readiness_scores) as readiness_scores,
       (select count(*) from public.daily_checkins) as public_daily_checkins,
       now() at time zone 'Europe/Berlin'          as jetzt_berlin;

-- Block 1: alle Relationen in app mit Zeilenzahl und RLS Status
select c.relname as tabelle, c.relkind,
       (xpath('/row/cnt/text()', query_to_xml(format('select count(*) as cnt from app.%I', c.relname), false, true, '')))[1]::text::bigint as zeilen,
       c.relrowsecurity as rls
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'app' and c.relkind in ('r','p','v','m')
order by c.relkind, c.relname;

-- Block 2: Rechte von authenticated und anon auf app Relationen
select c.relname, c.relkind, c.reloptions,
       string_agg(distinct a.privilege_type || ':' || a.grantee, ', ' order by a.privilege_type || ':' || a.grantee) as rechte
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) x on true
left join lateral (select x.privilege_type, pg_get_userbyid(x.grantee) as grantee) a on true
where n.nspname = 'app' and c.relkind in ('r','v','m') and a.grantee in ('authenticated','anon')
group by c.relname, c.relkind, c.reloptions
order by c.relkind, c.relname;

-- Block 3: Policies der Legacy Tabellen (22 haengen an app.tenant())
select tablename, policyname, cmd, roles::text, qual, with_check
from pg_policies where schemaname = 'app'
order by tablename, policyname;

-- Block 4: Funktionen in app mit Sicherheitskontext und EXECUTE Rechten
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
       case when p.prosecdef then 'DEFINER' else 'INVOKER' end as sec,
       coalesce((select string_agg(distinct pg_get_userbyid(x.grantee), ',')
                 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) x
                 where pg_get_userbyid(x.grantee) in ('authenticated','anon','public')), '-') as exec_fuer
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'app' and p.prokind = 'f'
order by p.proname;

-- Block 5: Quelltext der Funktionen (fuer die Einordnung liest/schreibt)
select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig, p.prosrc
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'app' and p.prokind = 'f' order by p.proname;

-- Block 6: Spalten der Legacy Tabellen (Gesundheitsbezug bewerten)
select c.relname as tabelle,
       string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' order by a.attnum) as spalten
from pg_class c join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
where n.nspname = 'app' and c.relkind = 'r'
group by c.relname order by c.relname;

-- Block 7: Was steht im audit_log (nur Zaehlung, keine Werte)
select table_name, operation, count(*) as n,
       count(*) filter (where old_row is not null) as mit_old_row,
       count(*) filter (where new_row is not null) as mit_new_row,
       min(occurred_at)::date as von, max(occurred_at)::date as bis
from app.audit_log group by table_name, operation order by table_name, operation;

-- Block 8: welche Felder das audit_log kopiert (nur Schluesselnamen, keine Werte)
select table_name, string_agg(distinct k, ', ' order by k) as schluessel
from (select table_name, jsonb_object_keys(coalesce(new_row, old_row)) as k from app.audit_log) t
group by table_name order by table_name;

-- Block 9: Personenbezug im audit_log (adressierbar fuer einen Loeschpfad?)
with p as (
  select coalesce(coalesce(new_row, old_row)->>'person_id',
                  case when table_name = 'persons' then coalesce(new_row, old_row)->>'id' end) as pid
  from app.audit_log
)
select count(distinct pid) as betroffene_personen,
       count(*) filter (where pid is null) as ohne_personenbezug,
       round(count(*)::numeric / nullif(count(distinct pid), 0), 1) as zeilen_je_person,
       count(*) as gesamt
from p;

-- Block 10: public Schema, Zeilenzahlen, RLS und Rechte
select c.relname as tabelle, c.relkind, c.relrowsecurity as rls,
       (xpath('/row/cnt/text()', query_to_xml(format('select count(*) as cnt from public.%I', c.relname), false, true, '')))[1]::text::bigint as zeilen,
       coalesce((select string_agg(distinct a.privilege_type || ':' || pg_get_userbyid(a.grantee), ', ')
                 from aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                 where pg_get_userbyid(a.grantee) in ('authenticated','anon')), '-') as rechte
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r','v','m')
order by c.relkind, c.relname;

-- Block 11: Medizin Gate im Legacy Pfad. Setzt nur eine Sitzungsvariable (kein Schreibzugriff auf Daten),
-- wertet das Policy Praedikat von public.daily_checkins mit dem Claim eines Trainers aus.
select public.is_staff()        as trainer_gilt_als_staff,
       public.is_medical_role() as trainer_gilt_als_medizin,
       (select count(*) from public.daily_checkins
         where public.is_staff() or player_id = public.current_player_id()) as sichtbare_zeilen,
       (select count(*) from public.daily_checkins
         where (public.is_staff() or player_id = public.current_player_id()) and soreness is not null) as davon_mit_soreness,
       (select count(*) from public.daily_checkins
         where (public.is_staff() or player_id = public.current_player_id()) and free_text is not null) as davon_mit_freitext
from (select set_config('request.jwt.claims',
        '{"app_role":"coach","sub":"00000000-0000-0000-0000-000000000000"}', true) as c) s;

-- Block 12: Funktionen in public mit Sicherheitskontext und EXECUTE Rechten
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
       case when p.prosecdef then 'DEFINER' else 'INVOKER' end as sec,
       coalesce((select string_agg(distinct pg_get_userbyid(x.grantee), ',')
                 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) x
                 where pg_get_userbyid(x.grantee) in ('authenticated','anon','public')), '-') as exec_fuer
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prokind = 'f'
order by p.proname;
